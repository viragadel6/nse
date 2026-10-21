const std = @import("std");
const Configuration = @import("configuration.zig").Configuration;
const cancellation = @import("cancellation.zig");
const Store = @import("../storage/document_store.zig").Store;
const Mutation = @import("../storage/document_store.zig").Mutation;
const documents = @import("../storage/document.zig");
const sparse = @import("../retrieval/sparse_index.zig");
const vector = @import("../index/vector_index.zig");
const fusion = @import("../retrieval/reciprocal_rank_fusion.zig");
const request = @import("../api/request_codec.zig");
const inference = @import("../models/inference_client.zig");
const highlights = @import("../highlights/highlight_extractor.zig");
const urls = @import("../crawl/url_normalization.zig");
const Metrics = @import("../telemetry/metrics.zig").Metrics;

pub const HighlightResult = struct { document_id: u64, url: []const u8, highlight: highlights.Highlight };

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
    sparse_index: sparse.Index,
    vector_index: vector.Index,
    lock: std.Thread.RwLock = .{},
    cancellation: cancellation.Token = .{},
    metrics: Metrics = .{},
    ready: bool = true,

    pub fn open(allocator: std.mem.Allocator, config: Configuration) !Engine {
        const record_bytes = try std.math.add(u32, config.api.body_bytes, 65536);
        var store = try Store.open(allocator, config.runtime.data_path, record_bytes);
        errdefer store.close();
        var sparse_index = try sparse.Index.build(allocator, &store);
        errdefer sparse_index.deinit();
        const vector_index = try vector.Index.build(allocator, &store, config.vector_index.model_version);
        var result = Engine{ .allocator = allocator, .config = config, .store = store, .sparse_index = sparse_index, .vector_index = vector_index };
        result.metrics.recovered.store(store.recovered_records, .monotonic);
        return result;
    }

    pub fn close(self: *Engine) void {
        self.cancellation.cancel();
        self.vector_index.deinit();
        self.sparse_index.deinit();
        self.store.close();
    }

    fn rebuildLocked(self: *Engine) !void {
        var next_sparse = try sparse.Index.build(self.allocator, &self.store);
        errdefer next_sparse.deinit();
        const next_vector = try vector.Index.build(self.allocator, &self.store, self.config.vector_index.model_version);
        self.sparse_index.deinit();
        self.vector_index.deinit();
        self.sparse_index = next_sparse;
        self.vector_index = next_vector;
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
            self.ready = false;
            try self.rebuildLocked();
            Metrics.increment(&self.metrics.ingested);
        }
        return result;
    }

    pub fn delete(self: *Engine, id: u64) !bool {
        self.lock.lock();
        defer self.lock.unlock();
        const deleted = try self.store.delete(id);
        if (deleted) {
            self.ready = false;
            try self.rebuildLocked();
            Metrics.increment(&self.metrics.deleted);
        }
        return deleted;
    }

    pub fn refresh(self: *Engine, snapshot: bool) !Status {
        self.lock.lock();
        defer self.lock.unlock();
        if (snapshot) try self.store.snapshot();
        try self.rebuildLocked();
        return self.statusLocked();
    }

    fn statusLocked(self: *const Engine) Status {
        return .{ .ready = self.ready and !self.cancellation.isCancelled(), .index_generation = self.store.sequence, .documents = self.store.entries.count(), .embedded_documents = self.vector_index.records.len, .model_version = self.config.model.model_version, .dimensions = self.config.vector_index.dimensions, .recovered_records = self.store.recovered_records };
    }

    pub fn status(self: *Engine) Status {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.statusLocked();
    }

    fn matches(document: *const documents.Document, filters: request.Filters) bool {
        if (document.quality < filters.minimum_quality) return false;
        if (filters.language) |language| if (!std.ascii.eqlIgnoreCase(document.language, language)) return false;
        if (filters.published_after) |after| if (document.published_at < after) return false;
        if (filters.published_before) |before| if (document.published_at > before) return false;
        if (filters.domains.len > 0) {
            const domain = urls.domain(document.url) catch return false;
            var found = false;
            for (filters.domains) |wanted| if (std.ascii.eqlIgnoreCase(domain, wanted)) { found = true; break; };
            if (!found) return false;
        }
        return true;
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
        const dense_candidates = if (embedding) |coordinates| try self.vector_index.search(allocator, &self.store, coordinates, self.config.vector_index.candidate_pool, deadline) else try allocator.alloc(sparse.Candidate, 0);
        defer allocator.free(dense_candidates);
        const fused = try fusion.fuse(allocator, sparse_candidates, dense_candidates, self.config.ranking);
        defer allocator.free(fused);
        var output = std.ArrayList(Result).init(allocator);
        errdefer output.deinit();
        for (fused) |candidate| {
            if (output.items.len == input.result_count) break;
            try deadline.check();
            const document = self.store.entries.get(candidate.id) orelse return error.IndexDocumentMissing;
            if (!matches(document, input.filters)) continue;
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
                .semantic_score = candidate.semantic_score,
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
            const document = self.store.entries.get(id) orelse return error.DocumentNotFound;
            var selected = try highlights.extract(allocator, input.query, document.text, input.window_bytes);
            selected.text = try allocator.dupe(u8, selected.text);
            try output.append(.{ .document_id = id, .url = try allocator.dupe(u8, document.url), .highlight = selected });
        }
        return output.toOwnedSlice();
    }
};
