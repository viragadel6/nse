const std = @import("std");
const fetcher = @import("fetcher.zig");
const frontier = @import("frontier.zig");
const dedup = @import("deduplication.zig");
const velocity = @import("domain_velocity.zig");
const state = @import("crawl_state.zig");
const Engine = @import("../runtime/lifecycle.zig").Engine;

pub const Coordinator = struct {
    engine: *Engine,
    frontier: *frontier.Frontier,
    dedup: *dedup.Dedup,
    velocity: *velocity.DomainVelocity,
    crawl_state: *state.CrawlState,
    allocator: std.mem.Allocator,
    max_depth: u32,
    max_concurrent: u32,

    pub fn init(engine: *Engine, frontier: *frontier.Frontier, dedup: *dedup.Dedup, velocity: *velocity.DomainVelocity, crawl_state: *state.CrawlState, allocator: std.mem.Allocator, max_depth: u32, max_concurrent: u32) Coordinator {
        return Coordinator{ .engine = engine, .frontier = frontier, .dedup = dedup, .velocity = velocity, .crawl_state = crawl_state, .allocator = allocator, .max_depth = max_depth, .max_concurrent = max_concurrent };
    }

    pub fn processUrl(self: *Coordinator, url: []const u8, now: i64) !void {
        const domain = try std.mem.splitScalar(u8, url, '/').next() orelse return;
        if (self.dedup.check(try? std.crypto.hash.sha2.Sha256.hash(url, @as([32]u8, undefined), .{}) catch [32]u8{}) |_|) {
            self.crawl_state.recordDuplicate();
            return;
        }
        const fingerprint = try std.crypto.hash.sha2.Sha256.hash(url, @as([32]u8, undefined), .{});
        _ = self.dedup.insert(fingerprint);
        _ = self.frontier.discover(url, url, 0, now);
        const result = try fetcher.fetch(self.engine, self.allocator, url);
        self.crawl_state.recordFetch(result.body.len);
        const extracted = try documentExtract(self.allocator, result.body, self.max_depth);
        _ = extracted;
        self.velocity.observe(domain, true, now);
    }
};

fn documentExtract(allocator: std.mem.Allocator, html: []const u8, max_depth: u32) !void {
    const extractor = @import("document_extractor.zig");
    _ = try extractor.extract(allocator, html, max_depth);
}
