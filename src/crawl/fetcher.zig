const std = @import("std");
const http = @import("../network/http_client.zig");
const parser = @import("html_parser.zig");
const urls = @import("url_normalization.zig");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const Metrics = @import("../telemetry/metrics.zig").Metrics;
const Mutation = @import("../storage/document_store.zig").Mutation;

pub const Result = struct { url: []const u8, http_status: u16, mutation: Mutation, discovered_links: []const []const u8, paragraphs: []parser.Paragraph };

pub fn fetch(engine: *Engine, allocator: std.mem.Allocator, url: []const u8) !Result {
    const normalized = try urls.normalize(allocator, url);
    const response = http.request(allocator, .GET, normalized, null, engine.config.api.body_bytes, engine.config.runtime.connection_timeout_ms) catch |err| {
        Metrics.increment(&engine.metrics.fetch_errors);
        return err;
    };
    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) {
        Metrics.increment(&engine.metrics.fetch_errors);
        return error.SourceHttpFailure;
    }
    const extracted = try parser.parse(allocator, response.body, 1024);
    const canonical = if (extracted.canonical) |reference| urls.resolve(allocator, normalized, reference) catch normalized else normalized;
    const mutation = try engine.ingest(allocator, .{ .url = canonical, .title = extracted.title, .text = extracted.text, .language = extracted.language, .model_version = engine.config.model.model_version });
    var links = std.ArrayList([]const u8).init(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    for (extracted.links) |link| {
        const resolved = urls.resolve(allocator, normalized, link.url) catch continue;
        if (seen.contains(resolved)) continue;
        try seen.put(resolved, {});
        try links.append(resolved);
    }
    Metrics.increment(&engine.metrics.fetched);
    return .{ .url = canonical, .http_status = @intFromEnum(response.status), .mutation = mutation, .discovered_links = try links.toOwnedSlice(), .paragraphs = extracted.paragraphs };
}
