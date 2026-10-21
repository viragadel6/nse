const std = @import("std");
const frontier_module = @import("frontier.zig");
const scheduler_module = @import("recrawl_scheduler.zig");
const fetcher = @import("fetcher.zig");
const deduplication = @import("deduplication.zig");
const velocity = @import("domain_velocity.zig");
const coordinator_module = @import("crawl_coordinator.zig");
const configuration = @import("../runtime/configuration.zig");

pub const default_page_budget: u64 = 8;

pub const Options = struct {
    seed: []const u8,
    max_pages: u64 = default_page_budget,
    batch_size: usize = 4,
    max_links_per_page: usize = 256,
    follow_external_links: bool = false,
    deduplicate: bool = true,
    idle_sleep_ms: u64 = 25,
    max_text_bytes: usize = 4194304,
};

pub const Sink = struct {
    context: *anyopaque,
    store: *const fn (context: *anyopaque, url: []const u8, title: []const u8, text: []const u8, quality: f32, published_ms: i64) anyerror!bool,
    flush: ?*const fn (context: *anyopaque) anyerror!void = null,
};

pub const Summary = struct {
    seed: []const u8,
    pages_fetched: u64 = 0,
    pages_deduplicated: u64 = 0,
    pages_rejected: u64 = 0,
    pages_denied: u64 = 0,
    pages_challenged: u64 = 0,
    pages_redirected: u64 = 0,
    links_discovered: u64 = 0,
    documents_stored: u64 = 0,
    bytes_fetched: u64 = 0,
    tracked_urls: u64 = 0,
    elapsed_ms: f64 = 0,
};

const Collector = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    duplicates: std.AutoHashMapUnmanaged(u64, void) = .{},
    stored: u64 = 0,

    fn deinit(self: *Collector) void {
        self.duplicates.deinit(self.allocator);
    }

    fn emit(context: *anyopaque, event: coordinator_module.CrawlEvent) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        switch (event.kind) {
            .deduplicated => try self.duplicates.put(self.allocator, event.canonical_hash, {}),
            .fetched => {
                if (event.text.len > 0 and !self.duplicates.contains(event.canonical_hash)) {
                    if (try self.sink.store(self.sink.context, event.url, event.title, event.text, event.quality, event.published_ms)) self.stored += 1;
                }
            },
            else => {},
        }
        event.release();
    }

    fn flush(context: *anyopaque) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (self.sink.flush) |sync| try sync(self.sink.context);
    }
};

pub fn run(allocator: std.mem.Allocator, config: configuration.Config, options: Options, sink: Sink) !Summary {
    const started_ms = std.time.milliTimestamp();
    const frontier_dir = try std.fmt.allocPrint(allocator, "{s}/frontier", .{config.runtime.data_dir});
    defer allocator.free(frontier_dir);
    const frontier_wal_dir = try std.fmt.allocPrint(allocator, "{s}/frontier/wal", .{config.runtime.data_dir});
    defer allocator.free(frontier_wal_dir);
    var frontier = try frontier_module.Frontier.init(allocator, .{
        .dir = frontier_dir,
        .wal_dir = frontier_wal_dir,
        .partition_count = config.crawler.frontier_partitions,
        .capacity_urls = config.crawler.frontier_capacity_urls,
        .min_interval_ms = config.crawler.recrawl_min_interval_ms,
        .max_interval_ms = config.crawler.recrawl_max_interval_ms,
    });
    defer frontier.deinit();
    var tracker = velocity.Tracker.init(allocator, config.crawler.velocity_window_ms);
    defer tracker.deinit();
    var scheduler = try scheduler_module.Scheduler.init(allocator, &tracker, &frontier);
    defer scheduler.deinit();
    var page_fetcher = try fetcher.Fetcher.init(allocator, .{
        .user_agent = config.crawler.user_agent,
        .max_response_bytes = config.crawler.max_response_bytes,
        .request_timeout_ms = config.crawler.request_timeout_ms,
        .max_redirects = config.crawler.max_redirects,
        .politeness_delay_ms = config.crawler.politeness_delay_ms,
        .max_retries = config.crawler.fetch_retry_attempts,
        .retry_base_ms = config.crawler.fetch_retry_base_ms,
        .retry_max_ms = config.crawler.fetch_retry_max_ms,
        .tls_enabled = true,
    });
    defer page_fetcher.deinit();
    var deduplicator = try deduplication.Deduplicator.init(allocator, @max(1024, options.max_pages * 4));
    defer deduplicator.deinit();
    var collector = Collector{ .allocator = allocator, .sink = sink };
    defer collector.deinit();
    var coordinator = try coordinator_module.Coordinator.init(allocator, .{
        .batch_size = options.batch_size,
        .max_pages = options.max_pages,
        .idle_sleep_ms = options.idle_sleep_ms,
        .max_links_per_page = options.max_links_per_page,
        .follow_external_links = options.follow_external_links,
        .deduplicate = options.deduplicate,
        .max_text_bytes = options.max_text_bytes,
    }, &frontier, &scheduler, &page_fetcher, &deduplicator, &tracker, .{
        .context = &collector,
        .emit = Collector.emit,
        .flush = Collector.flush,
    });
    defer coordinator.deinit();
    _ = try coordinator.seed(options.seed);
    var pages: u64 = 0;
    var idle_rounds: usize = 0;
    while (pages < options.max_pages) {
        const processed = try coordinator.runOnce();
        if (processed == 0) {
            idle_rounds += 1;
            if (idle_rounds >= 3) break;
            std.Thread.sleep(options.idle_sleep_ms * std.time.ns_per_ms);
            continue;
        }
        idle_rounds = 0;
        pages += processed;
    }
    const stats = coordinator.stats();
    return .{
        .seed = options.seed,
        .pages_fetched = stats.pages_fetched,
        .pages_deduplicated = stats.pages_deduplicated,
        .pages_rejected = stats.pages_rejected,
        .pages_denied = stats.pages_denied,
        .pages_challenged = stats.pages_challenged,
        .pages_redirected = stats.pages_redirected,
        .links_discovered = stats.links_discovered,
        .documents_stored = collector.stored,
        .bytes_fetched = stats.bytes_fetched,
        .tracked_urls = frontier.trackedCount(),
        .elapsed_ms = @as(f64, @floatFromInt(std.time.milliTimestamp() - started_ms)),
    };
}
