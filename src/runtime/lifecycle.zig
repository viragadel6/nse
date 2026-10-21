const std = @import("std");
const Configuration = @import("configuration.zig").Config;
const cancellation = @import("cancellation.zig");
const Store = @import("../storage/document_collection.zig").Store;
const Mutation = @import("../storage/document_collection.zig").Mutation;
const documents = @import("../storage/document.zig");
const sparse = @import("../retrieval/sparse_index.zig");
const vector = @import("../index/vector_index.zig");
const hybrid = @import("../retrieval/hybrid_retriever.zig");
const filters = @import("../retrieval/filter_engine.zig");
const request = @import("../api/request_codec.zig");
const inference = @import("../models/inference_client.zig");
const highlights = @import("../highlights/highlight_extractor.zig");
const urls = @import("../crawl/url_normalization.zig");
const Metrics = @import("../telemetry/metrics.zig").Metrics;
const txlog = @import("../storage/transaction_log.zig");

pub const HighlightResult = struct { document_id: u64, url: []const u8, highlight: highlights.Highlight };

pub const ReplayEntry = struct {
    sequence: u64,
    timestamp_ms: i64,
    kind: txlog.RecordKind,
    payload: []const u8,
};

fn releaseDocument(allocator: std.mem.Allocator, document: *documents.Document) void {
    allocator.free(document.url);
    allocator.free(document.title);
    allocator.free(document.text);
    allocator.free(document.language);
    if (document.embedding) |coordinates| allocator.free(coordinates);
}

pub const Result = struct {
    document_id: u64,
    rank: u32,
    url: []const u8,
    title: []const u8,
    language: []const u8,
    published_at: i64,
    indexed_at: i64,
    quality: f32,
    score: f64,
    lexical_score: ?f64,
    semantic_score: ?f64,
    highlight: ?highlights.Highlight,
};

pub const SearchResponse = struct {
    index_generation: u64,
    model_version: u64,
    complete: bool,
    semantic_status: enum { available, not_requested, not_configured, failed },
    elapsed_ms: f64,
    results: []Result,
};

pub const Status = struct {
    ready: bool,
    index_generation: u64,
    documents: usize,
    embedded_documents: usize,
    model_version: u64,
    dimensions: u16,
    recovered_records: u64,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    config: Configuration,
    store: Store,
    wal: txlog.Log,
    wal_dir: []const u8,
    sparse_index: sparse.Index,
    vector_index: vector.Index,
    retriever: hybrid.Retriever,
    filter_engine: filters.Engine,
    published_index: std.AutoHashMapUnmanaged(u64, i64) = .{},
    lock: std.Thread.RwLock = .{},
    cancellation: cancellation.Token = .{},
    metrics: Metrics = .{},
    recovered_mutations: u64 = 0,
    ready: bool = true,

    pub fn open(allocator: std.mem.Allocator, config: Configuration) !Engine {
        const record_bytes = try std.math.add(u32, config.api.max_request_bytes, 65536);
        var store = try Store.open(allocator, config.runtime.data_dir, record_bytes);
        errdefer store.close();
        const wal_dir = try allocator.dupe(u8, config.storage.transaction_log_dir);
        errdefer allocator.free(wal_dir);
        var wal = try txlog.Log.init(allocator, .{
            .dir = wal_dir,
            .sync_on_write = config.storage.sync_on_write,
            .verify_on_replay = config.storage.verify_checksums_on_read,
        });
        errdefer wal.deinit();
        var result = Engine{
            .allocator = allocator,
            .config = config,
            .store = store,
            .wal = wal,
            .wal_dir = wal_dir,
            .sparse_index = undefined,
            .vector_index = undefined,
            .retriever = try hybrid.Retriever.init(allocator, .{
                .lexical = config.ranking.fusion_sparse_weight,
                .dense = config.ranking.fusion_dense_weight,
                .quality = config.ranking.source_quality_weight,
                .freshness = config.ranking.fusion_freshness_weight,
                .rrf_constant = config.ranking.fusion_rank_constant,
            }),
            .filter_engine = filters.Engine.init(allocator),
        };
        try result.replayWal();
        result.sparse_index = try sparse.Index.build(allocator, &result.store);
        result.vector_index = try vector.Index.build(allocator, &result.store, config.model.model_version);
        try result.rebuildPublished();
        result.metrics.recovered.store(store.recovered_records, .monotonic);
        return result;
    }

    fn rebuildPublished(self: *Engine) !void {
        var next = std.AutoHashMapUnmanaged(u64, i64){};
        errdefer next.deinit(self.allocator);
        var iterator = self.store.entries.valueIterator();
        while (iterator.next()) |document| try next.put(self.allocator, document.id, document.published_at);
        self.published_index.deinit(self.allocator);
        self.published_index = next;
    }

    fn replayWal(self: *Engine) !void {
        const Collector = struct {
            entries: std.ArrayList(ReplayEntry),
            allocator: std.mem.Allocator,

            fn visit(context: *anyopaque, record: txlog.Record) anyerror!void {
                const self_collector: *@This() = @ptrCast(@alignCast(context));
                try self_collector.entries.append(.{
                    .sequence = record.sequence,
                    .timestamp_ms = record.timestamp_ms,
                    .kind = record.kind,
                    .payload = try self_collector.allocator.dupe(u8, record.payload),
                });
            }
        };
        var collector: Collector = .{ .entries = std.ArrayList(ReplayEntry).init(self.allocator), .allocator = self.allocator };
        defer {
            for (collector.entries.items) |entry| self.allocator.free(entry.payload);
            collector.entries.deinit();
        }
        _ = try self.wal.replay(&collector, Collector.visit);
        std.sort.block(ReplayEntry, collector.entries.items, {}, struct {
            fn lt(_: void, a: ReplayEntry, b: ReplayEntry) bool {
                if (a.timestamp_ms != b.timestamp_ms) return a.timestamp_ms < b.timestamp_ms;
                return a.sequence < b.sequence;
            }
        }.lt);
        for (collector.entries.items) |entry| {
            switch (entry.kind) {
                .document_upsert => {
                    const document = documents.Document.decode(self.allocator, entry.payload, self.store.sequence + 1) catch continue;
                    const value = document.*;
                    self.allocator.destroy(document);
                    if (self.store.entries.getPtr(value.id)) |previous| {
                        var stale = previous.*;
                        previous.* = value;
                        releaseDocument(self.allocator, &stale);
                    } else {
                        self.sequenceBump();
                        var stored = value;
                        stored.sequence = self.store.sequence;
                        try self.store.put(stored);
                    }
                    self.recovered_mutations += 1;
                },
                .document_delete => {
                    if (entry.payload.len < 8) continue;
                    const id = std.mem.readInt(u64, entry.payload[0..8], .little);
                    if (self.store.remove(id)) self.recovered_mutations += 1;
                },
                else => {},
            }
        }
    }

    fn sequenceBump(self: *Engine) void {
        self.store.sequence += 1;
    }

    pub fn close(self: *Engine) void {
        self.cancellation.cancel();
        self.wal.flush() catch {};
        self.vector_index.deinit();
        self.sparse_index.deinit();
        self.published_index.deinit(self.allocator);
        self.wal.deinit();
        self.store.close();
        self.allocator.free(self.wal_dir);
    }

    fn rebuildLocked(self: *Engine) !void {
        var next_sparse = try sparse.Index.build(self.allocator, &self.store);
        errdefer next_sparse.deinit();
        const next_vector = try vector.Index.build(self.allocator, &self.store, self.config.model.model_version);
        self.sparse_index.deinit();
        self.vector_index.deinit();
        self.sparse_index = next_sparse;
        self.vector_index = next_vector;
        try self.rebuildPublished();
        self.ready = true;
    }

    pub fn ingest(self: *Engine, allocator: std.mem.Allocator, input: documents.Input) !Mutation {
        if (input.model_version != self.config.model.model_version) return error.IncompatibleEmbeddingModel;
        var effective = input;
        const embedding = if (input.embedding == null and self.config.model.embedding_endpoint.len > 0) try inference.embed(allocator, self.config.model, input.text, .document, self.config.runtime.connection_timeout_ms) else null;
        defer if (embedding) |coordinates| allocator.free(coordinates);
        if (embedding) |coordinates| effective.embedding = coordinates;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.cancellation.isCancelled()) return error.Cancelled;
        const result = self.store.upsert(effective) catch |err| {
            if (err == error.WriteStateUnknown) self.ready = false;
            return err;
        };
        if (result.changed) {
            try self.appendWal(result.id, true);
            self.ready = false;
            try self.rebuildLocked();
            Metrics.increment(&self.metrics.ingested);
        }
        return result;
    }

    fn appendWal(self: *Engine, id: u64, upsert: bool) !void {
        if (upsert) {
            const document = self.store.get(id) orelse return error.IndexDocumentMissing;
            const encoded = try document.encode(self.allocator);
            defer self.allocator.free(encoded);
            _ = try self.wal.append(.document_upsert, encoded);
        } else {
            var payload: [8]u8 = undefined;
            std.mem.writeInt(u64, &payload, id, .little);
            _ = try self.wal.append(.document_delete, &payload);
        }
        try self.wal.flush();
    }

    pub fn delete(self: *Engine, id: u64) !bool {
        self.lock.lock();
        defer self.lock.unlock();
        const deleted = try self.store.delete(id);
        if (deleted) {
            try self.appendWal(id, false);
            self.ready = false;
            try self.rebuildLocked();
            Metrics.increment(&self.metrics.deleted);
        }
        return deleted;
    }

    pub fn refresh(self: *Engine, snapshot: bool) !Status {
        self.lock.lock();
        defer self.lock.unlock();
        if (snapshot) {
            try self.store.snapshot();
            try self.wal.reset();
        }
        try self.rebuildLocked();
        return self.statusLocked();
    }

    fn statusLocked(self: *const Engine) Status {
        return .{ .ready = self.ready and !self.cancellation.isCancelled(), .index_generation = self.store.sequence, .documents = self.store.entries.count(), .embedded_documents = self.vector_index.records.len, .model_version = self.config.model.model_version, .dimensions = @as(u16, @intCast(self.config.vector_index.dimensions)), .recovered_records = self.store.recovered_records };
    }

    pub fn status(self: *Engine) Status {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.statusLocked();
    }

    fn buildFilter(allocator: std.mem.Allocator, input: request.Filters) !filters.Filter {
        var builder = filters.Builder.init(allocator);
        errdefer builder.deinit();
        try builder.addNumeric("quality", .gte, @as(f64, input.minimum_quality), 0.0);
        if (input.language) |language| try builder.addTermSet("language", &[_][]const u8{language}, &[_][]const u8{});
        if (input.published_after) |after| try builder.addInteger("published", .gte, after, 0);
        if (input.published_before) |before| try builder.addInteger("published", .lte, before, 0);
        if (input.domains.len > 0) try builder.addTermSet("domain", input.domains, &[_][]const u8{});
        const filter = try builder.build(.and_);
        builder.deinit();
        return filter;
    }

    fn attributes(allocator: std.mem.Allocator, document: *const documents.Document, with_domain: bool) filters.DocumentAttributes {
        var domain: []const u8 = "";
        if (with_domain) {
            if (urls.parse(document.url)) |parsed| {
                if (urls.registrableDomain(allocator, parsed.host)) |resolved| domain = resolved else |_| {}
            } else |_| {}
        }
        return .{
            .document_id = document.id,
            .language = document.language,
            .domain = domain,
            .url = document.url,
            .site = "",
            .kind = "",
            .quality = @as(f64, document.quality),
            .spam_score = 0.0,
            .authority = @as(f64, document.quality),
            .published_ms = document.published_at,
            .fetched_ms = 0,
            .indexed_ms = document.indexed_at,
            .length = @as(u32, @intCast(document.text.len)),
            .link_count = 0,
            .inbound_links = 0,
            .embedding_version = @as(u32, @intCast(document.model_version)),
            .flags = 0,
        };
    }

    pub fn search(self: *Engine, allocator: std.mem.Allocator, input: request.Search) !SearchResponse {
        try input.validate();
        const deadline = try cancellation.Deadline.init(input.deadline_ms orelse self.config.api.default_deadline_ms, &self.cancellation);
        var semantic_status: @FieldType(SearchResponse, "semantic_status") = if (input.mode == .sparse) .not_requested else .available;
        var supplied = input.embedding;
        var generated: ?[]f32 = null;
        defer if (generated) |coordinates| allocator.free(coordinates);
        if (input.mode != .sparse) {
            if (input.model_version != self.config.model.model_version) return error.IncompatibleEmbeddingModel;
            if (supplied == null) {
                if (self.config.model.embedding_endpoint.len == 0) {
                    if (input.mode == .dense) return error.EmbeddingServiceNotConfigured;
                    semantic_status = .not_configured;
                } else {
                    generated = inference.embed(allocator, self.config.model, input.query, .query, try deadline.remainingMilliseconds()) catch |err| {
                        if (input.mode == .dense) return err;
                        semantic_status = .failed;
                        return self.lexicalFallback(allocator, input, deadline, semantic_status);
                    };
                    supplied = generated;
                }
            }
        }
        return self.searchLocked(allocator, input, deadline, supplied, semantic_status);
    }

    fn lexicalFallback(self: *Engine, allocator: std.mem.Allocator, input: request.Search, deadline: cancellation.Deadline, semantic_status: @FieldType(SearchResponse, "semantic_status")) !SearchResponse {
        return self.searchLocked(allocator, input, deadline, null, semantic_status);
    }

    fn searchLocked(self: *Engine, allocator: std.mem.Allocator, input: request.Search, deadline: cancellation.Deadline, embedding: ?[]const f32, semantic_status: @FieldType(SearchResponse, "semantic_status")) !SearchResponse {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (!self.ready) return error.IndexNotReady;
        try deadline.check();
        const sparse_candidates = if (input.mode != .dense) try self.sparse_index.search(allocator, input.query, self.config.ranking, deadline) else try allocator.alloc(sparse.Candidate, 0);
        defer allocator.free(sparse_candidates);
        const dense_candidates = if (embedding) |coordinates| try self.vector_index.search(allocator, &self.store, coordinates, self.config.ranking.default_candidate_count, deadline) else try allocator.alloc(sparse.Candidate, 0);
        defer allocator.free(dense_candidates);
        const lexical_hits = try allocator.alloc(hybrid.LexicalHit, sparse_candidates.len);
        defer allocator.free(lexical_hits);
        for (sparse_candidates, 0..) |candidate, index| lexical_hits[index] = .{ .document_id = candidate.id, .score = candidate.score, .matched_terms = 0 };
        const dense_hits = try allocator.alloc(hybrid.DenseHit, dense_candidates.len);
        defer allocator.free(dense_hits);
        for (dense_candidates, 0..) |candidate, index| {
            dense_hits[index] = .{
                .document_id = candidate.id,
                .score = candidate.score,
                .quality = if (self.store.entries.getPtr(candidate.id)) |stored| stored.quality else 1.0,
            };
        }
        var retriever = self.retriever;
        retriever.final_limit = input.result_count;
        retriever.mode = switch (input.mode) {
            .sparse => .lexical_only,
            .dense => .dense_only,
            .hybrid => .hybrid,
        };
        var filter_engine = self.filter_engine;
        var filter = try buildFilter(allocator, input.filters);
        defer filter.release();
        const outcome = try retriever.combine(lexical_hits, dense_hits, std.time.milliTimestamp(), &self.published_index);
        defer allocator.free(outcome.results);
        var output = std.ArrayList(Result).init(allocator);
        errdefer output.deinit();
        for (outcome.results) |candidate| {
            if (output.items.len == input.result_count) break;
            try deadline.check();
            const document = self.store.entries.getPtr(candidate.document_id) orelse return error.IndexDocumentMissing;
            const document_attributes = attributes(allocator, document, input.filters.domains.len > 0);
            defer if (document_attributes.domain.len > 0) allocator.free(document_attributes.domain);
            if (!try filter_engine.evaluate(&filter, document_attributes)) continue;
            var selected_highlight: ?highlights.Highlight = null;
            if (input.highlights) {
                var selected = try highlights.extract(allocator, input.query, document.text, 320);
                selected.text = try allocator.dupe(u8, selected.text);
                selected_highlight = selected;
            }
            try output.append(.{
                .document_id = document.id,
                .rank = @intCast(output.items.len + 1),
                .url = try allocator.dupe(u8, document.url),
                .title = try allocator.dupe(u8, document.title),
                .language = try allocator.dupe(u8, document.language),
                .published_at = document.published_at,
                .indexed_at = document.indexed_at,
                .quality = document.quality,
                .score = candidate.score,
                .lexical_score = candidate.lexical_score,
                .semantic_score = candidate.dense_score,
                .highlight = selected_highlight,
            });
        }
        const elapsed = try deadline.elapsed();
        self.metrics.observe(elapsed);
        Metrics.increment(&self.metrics.searches);
        return .{ .index_generation = self.store.sequence, .model_version = self.config.model.model_version, .complete = semantic_status == .available or semantic_status == .not_requested, .semantic_status = semantic_status, .elapsed_ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms, .results = try output.toOwnedSlice() };
    }

    pub fn highlight(self: *Engine, allocator: std.mem.Allocator, input: request.Highlights) ![]HighlightResult {
        if (input.query.len == 0 or input.window_bytes == 0) return error.InvalidHighlightInput;
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const Item = HighlightResult;
        var output = std.ArrayList(Item).init(allocator);
        errdefer output.deinit();
        for (input.document_ids) |id| {
            const document = self.store.entries.getPtr(id) orelse return error.DocumentNotFound;
            var selected = try highlights.extract(allocator, input.query, document.text, input.window_bytes);
            selected.text = try allocator.dupe(u8, selected.text);
            try output.append(.{ .document_id = id, .url = try allocator.dupe(u8, document.url), .highlight = selected });
        }
        return output.toOwnedSlice();
    }
};
