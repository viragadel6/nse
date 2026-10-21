const std = @import("std");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const documents = @import("../storage/document.zig");
const request = @import("request_codec.zig");
const inference = @import("../models/inference_client.zig");
const fetcher = @import("../crawl/fetcher.zig");

pub const Response = struct { status: std.http.Status = .ok, content_type: []const u8 = "application/json", body: []const u8 };

fn json(allocator: std.mem.Allocator, value: anytype) !Response {
    return .{ .body = try std.json.stringifyAlloc(allocator, value, .{ .emit_null_optional_fields = true }) };
}

pub fn dispatch(engine: *Engine, allocator: std.mem.Allocator, method: std.http.Method, target: []const u8, body: []const u8) !Response {
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (method == .GET and std.mem.eql(u8, path, "/health")) {
        const state = engine.status();
        var result = try json(allocator, .{ .ready = state.ready, .state = state, .embedding_configured = engine.config.model.embedding_endpoint.len > 0 });
        if (!state.ready) result.status = .service_unavailable;
        return result;
    }
    if (method == .GET and std.mem.eql(u8, path, "/metrics")) return .{ .content_type = "text/plain; version=0.0.4", .body = try engine.metrics.render(allocator) };
    if (method == .GET and std.mem.eql(u8, path, "/index/status")) return json(allocator, engine.status());
    if (method == .POST and std.mem.eql(u8, path, "/search")) {
        const parsed = try request.parse(request.Search, allocator, body);
        defer parsed.deinit();
        return json(allocator, try engine.search(allocator, parsed.value));
    }
    if (method == .POST and std.mem.eql(u8, path, "/ingest")) {
        const parsed = try request.parse(documents.Input, allocator, body);
        defer parsed.deinit();
        var result = try json(allocator, try engine.ingest(allocator, parsed.value));
        result.status = .created;
        return result;
    }
    if (method == .POST and std.mem.eql(u8, path, "/crawl")) {
        const Crawl = struct { url: []const u8 };
        const parsed = try request.parse(Crawl, allocator, body);
        defer parsed.deinit();
        return json(allocator, try fetcher.fetch(engine, allocator, parsed.value.url));
    }
    if (method == .POST and std.mem.eql(u8, path, "/highlights")) {
        const parsed = try request.parse(request.Highlights, allocator, body);
        defer parsed.deinit();
        return json(allocator, .{ .highlights = try engine.highlight(allocator, parsed.value) });
    }
    if (method == .POST and std.mem.eql(u8, path, "/index/delete")) {
        const parsed = try request.parse(request.Deletion, allocator, body);
        defer parsed.deinit();
        return json(allocator, .{ .deleted = try engine.delete(parsed.value.document_id), .index = engine.status() });
    }
    if (method == .POST and std.mem.eql(u8, path, "/index/refresh")) return json(allocator, try engine.refresh(true));
    if (method == .POST and std.mem.eql(u8, path, "/models/refresh")) return json(allocator, try inference.health(allocator, engine.config.model));
    return .{ .status = .not_found, .body = try std.json.stringifyAlloc(allocator, .{ .@"error" = .{ .code = "route_not_found", .path = path } }, .{}) };
}
