const std = @import("std");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");
const cancellation = @import("../runtime/cancellation.zig");
const state = @import("crawl_state.zig");
const urls = @import("url_normalization.zig");
const frontier = @import("frontier.zig");
const scheduler = @import("recrawl_scheduler.zig");
const fetcher = @import("fetcher.zig");
const extractor = @import("document_extractor.zig");
const canonicalization = @import("canonicalization.zig");
const deduplication = @import("deduplication.zig");
const velocity = @import("domain_velocity.zig");

pub const EventKind = enum(u8) {
    discovered,
    fetched,
    rejected,
    redirected,
    deduplicated,
    updated,
    deleted,
    recrawled,
    challenge,
    denied,
};

pub const CrawlEvent = struct {
    kind: EventKind,
    canonical_hash: u64,
    domain_hash: u64,
    url: []const u8,
    source_url: []const u8,
    content_hash: u64,
    title: []const u8,
    status: u16,
    text_length: u32,
    link_count: u32,
    reason: u16,
    timestamp_ms: i64,
    allocator: std.mem.Allocator,

    pub fn release(self: CrawlEvent) void {
        self.allocator.free(self.url);
        self.allocator.free(self.source_url);
        self.allocator.free(self.title);
    }
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: CrawlEvent) anyerror!void,
    flush: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn deliver(self: *const Sink, event: CrawlEvent) !void {
        try self.emit(self.context, event);
    }

    pub fn sync(self: *const Sink) !void {
        if (self.flush) |flush| try flush(self.context);
    }
};

pub const Options = struct {
    worker_id: u32 = 0,
    batch_size: usize = 16,
    max_pages: u64 = 0,
    idle_sleep_ms: u64 = 50,
    max_links_per_page: usize = 256,
    follow_external_links: bool = true,
    deduplicate: bool = true,
    collect_events: bool = true,
    max_depth: u32 = 512,
    max_text_bytes: usize = 4194304,
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    options: Options,
    frontier_ref: *frontier.Frontier,
    scheduler_ref: *scheduler.Scheduler,
    fetcher_ref: *fetcher.Fetcher,
    deduplicator: *deduplication.Deduplicator,
    velocity_tracker: *velocity.Tracker,
    extractor: extractor.Extractor,
    sink: Sink,
    pages_fetched: u64 = 0,
    pages_rejected: u64 = 0,
    pages_deduplicated: u64 = 0,
    pages_redirected: u64 = 0,
    pages_denied: u64 = 0,
    pages_challenged: u64 = 0,
    links_discovered: u64 = 0,
    events_emitted: u64 = 0,
    bytes_fetched: u64 = 0,
    running: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
        frontier_ref: *frontier.Frontier,
        scheduler_ref: *scheduler.Scheduler,
        fetcher_ref: *fetcher.Fetcher,
        deduplicator: *deduplication.Deduplicator,
        velocity_tracker: *velocity.Tracker,
        sink: Sink,
    ) !Coordinator {
        return .{
            .allocator = allocator,
            .options = options,
            .frontier_ref = frontier_ref,
            .scheduler_ref = scheduler_ref,
            .fetcher_ref = fetcher_ref,
            .deduplicator = deduplicator,
            .velocity_tracker = velocity_tracker,
            .extractor = extractor.Extractor.init(allocator, .{ .max_depth = options.max_depth }),
            .sink = sink,
        };
    }

    pub fn deinit(self: *Coordinator) void {
        self.extractor.deinit();
    }

    fn canonicalHash(self: *Coordinator, url: []const u8) !u64 {
        return canonicalization.canonicalKey(self.allocator, url);
    }

    pub fn seed(self: *Coordinator, url: []const u8) !frontier.DiscoveryOutcome {
        const normalized = try urls.normalize(self.allocator, url);
        defer self.allocator.free(normalized);
        const components = try urls.parse(normalized);
        var record = state.UrlRecord{
            .canonical_hash = try self.canonicalHash(normalized),
            .url_hash = hashing.hash64(0xA5A5A5A5, normalized),
            .domain_hash = urls.hostHash(components.host),
            .canonical_url = try self.allocator.dupe(u8, normalized),
            .original_url = try self.allocator.dupe(u8, url),
            .state = .discovered,
            .discovered_ms = time.nowMs(),
            .next_fetch_ms = time.nowMs(),
            .priority = 65535,
            .flags = state.UrlRecord.flag_manual_seed,
        };
        defer record.release(self.allocator);
        return self.frontier_ref.discover(record);
    }

    pub fn stop(self: *Coordinator) void {
        self.running = false;
    }

    pub fn runOnce(self: *Coordinator) !usize {
        const selection = self.scheduler_ref.select(self.options.worker_id, self.options.batch_size, time.nowMs()) catch |err| switch (err) {
            error.NoCandidates => return 0,
            else => return err,
        };
        defer selection.release(self.allocator);
        var processed: usize = 0;
        for (selection.records) |record| {
            const handled = self.processRecord(record) catch |err| switch (err) {
                error.FetchFailed, error.Timeout, error.PolitenessBlocked, error.RobotsDisallowed => blk: {
                    self.pages_rejected += 1;
                    self.frontier_ref.reject(record.canonical_hash, .low_quality) catch {};
                    break :blk false;
                },
                else => return err,
            };
            if (handled) processed += 1;
        }
        return processed;
    }

    pub fn run(self: *Coordinator, scope: *cancellation.Scope) !void {
        self.running = true;
        var pages: u64 = 0;
        while (self.running) {
            if (scope.isCancelled()) break;
            if (self.options.max_pages > 0 and pages >= self.options.max_pages) break;
            const processed = try self.runOnce();
            if (processed == 0) {
                std.Thread.sleep(self.options.idle_sleep_ms * std.time.ns_per_ms);
                continue;
            }
            pages += processed;
            try self.sink.sync();
        }
        self.running = false;
    }

    fn processRecord(self: *Coordinator, record: state.UrlRecord) !bool {
        const components = try urls.parse(record.canonical_url);
        var result = try self.fetcher_ref.fetch(record.canonical_url, .{});
        defer result.deinit();
        self.bytes_fetched += result.bytes;
        if (result.outcome == .denied) {
            self.pages_denied += 1;
            try self.frontier_ref.reject(record.canonical_hash, .denied_access);
            try self.emit(.denied, record, &result, 0, 0, 0, "");
            return false;
        }
        if (result.outcome == .challenge) {
            self.pages_challenged += 1;
            try self.frontier_ref.reschedule(record.canonical_hash, 3600000);
            try self.emit(.challenge, record, &result, 0, 0, 0, "");
            return false;
        }
        if (result.outcome == .redirect) {
            self.pages_redirected += 1;
            if (result.redirect_target.len > 0) {
                const resolved = try canonicalization.resolveReference(self.allocator, record.canonical_url, result.redirect_target);
                defer self.allocator.free(resolved);
                const canonical = canonicalization.canonicalize(self.allocator, resolved, "", &.{}, .{}) catch |err| switch (err) {
                    error.UnsupportedScheme, error.InvalidUrl, error.RedirectLoop, error.TooManyRedirects => return false,
                    else => return err,
                };
                defer canonical.release(self.allocator);
                try self.frontier_ref.redirect(record.canonical_hash, canonical.canonical, canonical.canonical_hash, result.status);
            } else {
                try self.frontier_ref.reject(record.canonical_hash, .invalid_url);
            }
            try self.emit(.redirected, record, &result, 0, 0, 0, "");
            return true;
        }
        if (result.outcome == .not_modified) {
            try self.frontier_ref.complete(record.canonical_hash, .not_modified, result.status, 0, false);
            const interval = try self.scheduler_ref.applyAfterFetch(&record, false);
            _ = interval;
            try self.emit(.recrawled, record, &result, 0, 0, 0, "");
            return true;
        }
        if (result.outcome == .client_error) {
            self.pages_rejected += 1;
            try self.frontier_ref.reject(record.canonical_hash, .malformed_document);
            try self.emit(.rejected, record, &result, 0, 0, 0, "");
            return false;
        }
        if (result.status != 200) {
            self.pages_rejected += 1;
            try self.frontier_ref.reschedule(record.canonical_hash, self.scheduler_ref.nextIntervalMs(&record, time.nowMs()));
            try self.emit(.rejected, record, &result, 0, 0, 0, "");
            return false;
        }
        const is_html = std.mem.startsWith(u8, result.content_type, "text/html") or std.mem.indexOf(u8, result.content_type, "xml") != null;
        if (!is_html) {
            try self.frontier_ref.reject(record.canonical_hash, .unsupported_scheme);
            return false;
        }
        const decoded = try fetcher.Fetcher.decompressIfNeeded(self.allocator, result.body, result.content_type);
        defer if (decoded) |owned| self.allocator.free(owned);
        const html = if (decoded) |owned| owned else result.body;
        var extracted = self.extractor.extract(html) catch |err| switch (err) {
            error.EmptyDocument => {
                self.pages_rejected += 1;
                try self.frontier_ref.reject(record.canonical_hash, .malformed_document);
                return false;
            },
            else => return err,
        };
        defer extracted.release(self.allocator);
        const content_hash = hashing.hash64(0xC2B2AE3D27D4EB4F, extracted.text);
        if (self.options.deduplicate) {
            const verdict = try self.deduplicator.classify(record.canonical_hash, record.domain_hash, extracted.text);
            if (verdict.class != .unique) {
                self.pages_deduplicated += 1;
                try self.emit(.deduplicated, record, &result, content_hash, extracted.text.len, extracted.links.len, extracted.title);
            }
        }
        const previous = self.velocity_tracker.profile(record.domain_hash);
        const changed = if (previous) |known| known.fingerprint_history[0] != content_hash else true;
        try self.velocity_tracker.observe(.{
            .domain_hash = record.domain_hash,
            .changed = changed,
            .observed_ms = time.nowMs(),
            .content_fingerprint = content_hash,
            .token_count = extracted.token_count,
            .has_publication_date = extracted.published_ms != 0,
        });
        try self.frontier_ref.complete(record.canonical_hash, .success, result.status, content_hash, changed);
        const interval = try self.scheduler_ref.applyAfterFetch(&record, changed);
        _ = interval;
        self.pages_fetched += 1;
        try self.emit(.fetched, record, &result, content_hash, extracted.text.len, extracted.links.len, extracted.title);
        try self.discoverLinks(&extracted, record, components);
        return true;
    }

    fn discoverLinks(self: *Coordinator, document: *const extractor.ExtractedDocument, record: state.UrlRecord, source: urls.Components) !void {
        var discovered: usize = 0;
        for (document.links) |link| {
            if (discovered >= self.options.max_links_per_page) break;
            if (link.target.len == 0) continue;
            if (std.mem.startsWith(u8, link.target, "#")) continue;
            if (std.ascii.startsWithIgnoreCase(link.target, "mailto:")) continue;
            if (std.ascii.startsWithIgnoreCase(link.target, "javascript:")) continue;
            if (std.ascii.startsWithIgnoreCase(link.target, "data:")) continue;
            const resolved = canonicalization.resolveReference(self.allocator, record.canonical_url, link.target) catch continue;
            defer self.allocator.free(resolved);
            const normalized = urls.normalize(self.allocator, resolved) catch continue;
            defer self.allocator.free(normalized);
            const target_components = urls.parse(normalized) catch continue;
            if (!std.mem.eql(u8, target_components.scheme, "http") and !std.mem.eql(u8, target_components.scheme, "https")) continue;
            if (!self.options.follow_external_links and !std.mem.eql(u8, target_components.host, source.host)) continue;
            const target_hash = try canonicalization.canonicalKey(self.allocator, normalized);
            if (target_hash == record.canonical_hash) continue;
            if (try self.frontier_ref.contains(target_hash)) continue;
            const depth: u16 = @intCast(@min(record.flags & 0xFFFF, 65535));
            const session = urls.looksLikeSessionPath(target_components.path);
            var candidate = state.UrlRecord{
                .canonical_hash = target_hash,
                .url_hash = hashing.hash64(0xA5A5A5A5, normalized),
                .domain_hash = urls.hostHash(target_components.host),
                .canonical_url = try self.allocator.dupe(u8, normalized),
                .original_url = try self.allocator.dupe(u8, link.target),
                .state = .discovered,
                .discoverer_domain_hash = record.domain_hash,
                .discovered_ms = time.nowMs(),
                .next_fetch_ms = time.nowMs(),
                .priority = if (session) 4096 else 32768,
                .flags = if (session) 0 else 0,
            };
            defer candidate.release(self.allocator);
            const outcome = try self.frontier_ref.discover(candidate);
            if (outcome == .inserted) {
                self.links_discovered += 1;
                discovered += 1;
            }
            _ = depth;
        }
    }

    fn emit(
        self: *Coordinator,
        kind: EventKind,
        record: state.UrlRecord,
        result: *const fetcher.FetchResult,
        content_hash: u64,
        text_length: usize,
        link_count: usize,
        title: []const u8,
    ) !void {
        if (!self.options.collect_events) return;
        const event = CrawlEvent{
            .kind = kind,
            .canonical_hash = record.canonical_hash,
            .domain_hash = record.domain_hash,
            .url = try self.allocator.dupe(u8, record.canonical_url),
            .source_url = try self.allocator.dupe(u8, result.final_url),
            .content_hash = content_hash,
            .title = try self.allocator.dupe(u8, title),
            .status = result.status,
            .text_length = @intCast(@min(text_length, std.math.maxInt(u32))),
            .link_count = @intCast(@min(link_count, std.math.maxInt(u32))),
            .reason = 0,
            .timestamp_ms = time.nowMs(),
            .allocator = self.allocator,
        };
        try self.sink.deliver(event);
        self.events_emitted += 1;
    }

    pub fn stats(self: *const Coordinator) CoordinatorStats {
        return .{
            .pages_fetched = self.pages_fetched,
            .pages_rejected = self.pages_rejected,
            .pages_deduplicated = self.pages_deduplicated,
            .pages_redirected = self.pages_redirected,
            .pages_denied = self.pages_denied,
            .pages_challenged = self.pages_challenged,
            .links_discovered = self.links_discovered,
            .events_emitted = self.events_emitted,
            .bytes_fetched = self.bytes_fetched,
        };
    }
};

pub const CoordinatorStats = struct {
    pages_fetched: u64,
    pages_rejected: u64,
    pages_deduplicated: u64,
    pages_redirected: u64,
    pages_denied: u64,
    pages_challenged: u64,
    links_discovered: u64,
    events_emitted: u64,
    bytes_fetched: u64,
};
