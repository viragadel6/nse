const std = @import("std");
const server = @import("../network/http_server.zig");
const configuration = @import("../runtime/configuration.zig");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const documents = @import("../storage/document.zig");
const request = @import("request_codec.zig");
const inference = @import("../models/inference_client.zig");
const fetcher = @import("../crawl/fetcher.zig");
const extractor = @import("../crawl/document_extractor.zig");
const normalize = @import("../ingestion/text_normalizer.zig");

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
        return json(allocator, try crawl(allocator, engine, parsed.value.url));
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

fn handle(context: *anyopaque, http_request: *server.Request, response: *server.Response) !void {
    const engine: *Engine = @ptrCast(@alignCast(context));
    const method = switch (http_request.verb) {
        .GET => std.http.Method.GET,
        .HEAD => std.http.Method.HEAD,
        .POST => std.http.Method.POST,
        .PUT => std.http.Method.PUT,
        .DELETE => std.http.Method.DELETE,
        else => std.http.Method.GET,
    };
    const allocator = http_request.allocator;
    const result = dispatch(engine, allocator, method, http_request.target, http_request.body) catch |err| {
        response.setStatus(statusFor(err), server.statusReason(statusFor(err)));
        try response.writeJson(.{ .@"error" = .{ .code = @errorName(err) } });
        return;
    };
    defer allocator.free(result.body);
    response.setStatus(@intFromEnum(result.status), server.statusReason(@intFromEnum(result.status)));
    response.setContentType(result.content_type);
    try response.writeBody(result.body);
}

fn statusFor(err: anyerror) u16 {
    if (err == error.DocumentNotFound or err == error.IndexDocumentMissing) return 404;
    if (err == error.InvalidDocumentText or err == error.InvalidDocumentMetadata or err == error.InvalidHighlightInput) return 400;
    if (err == error.IndexNotReady) return 503;
    if (err == error.Cancelled or err == error.DeadlineExceeded) return 504;
    if (err == error.EmbeddingServiceNotConfigured) return 501;
    return 500;
}

pub fn serve(allocator: std.mem.Allocator, engine: *Engine, config: configuration.Config) !void {
    return server.serve(allocator, config.api.bind_address, config.api.port, handle, engine, .{
        .max_request_bytes = config.api.max_request_bytes,
        .max_response_bytes = config.api.max_response_bytes,
        .max_connections = config.api.max_connections,
        .read_timeout_ms = config.api.request_timeout_ms,
        .write_timeout_ms = config.api.request_timeout_ms,
        .keep_alive_timeout_ms = config.api.keep_alive_timeout_ms,
    });
}

pub const CrawlOutcome = struct {
    url: []const u8,
    final_url: []const u8,
    status: u16,
    outcome: []const u8,
    bytes: usize,
    denied: bool,
    challenge: bool,
    links: usize,
    token_count: u32,
    document_id: u64,
    ingested: bool,
    changed: bool,
    elapsed_ms: f64,
};

pub fn crawl(allocator: std.mem.Allocator, engine: *Engine, url: []const u8) !CrawlOutcome {
    var page_fetcher = try fetcher.Fetcher.init(allocator, .{
        .user_agent = engine.config.crawler.user_agent,
        .max_response_bytes = engine.config.crawler.max_response_bytes,
        .request_timeout_ms = engine.config.crawler.request_timeout_ms,
        .max_redirects = engine.config.crawler.max_redirects,
        .politeness_delay_ms = engine.config.crawler.politeness_delay_ms,
        .max_retries = engine.config.crawler.fetch_retry_attempts,
        .retry_base_ms = engine.config.crawler.fetch_retry_base_ms,
        .retry_max_ms = engine.config.crawler.fetch_retry_max_ms,
    });
    defer page_fetcher.deinit();
    var result = try page_fetcher.fetch(url, .{});
    defer result.deinit();
    if (result.outcome != .success or result.body.len == 0) {
        return .{
            .url = try allocator.dupe(u8, result.url),
            .final_url = try allocator.dupe(u8, result.final_url),
            .status = result.status,
            .outcome = @tagName(result.outcome),
            .bytes = result.bytes,
            .denied = result.denied,
            .challenge = result.challenge,
            .links = 0,
            .token_count = 0,
            .document_id = 0,
            .ingested = false,
            .changed = false,
            .elapsed_ms = result.elapsed_ms,
        };
    }
    var page_extractor = extractor.Extractor.init(allocator, .{
        .max_nodes = engine.config.crawler.dom_executor_max_nodes,
        .max_text_bytes = engine.config.ingestion.max_document_bytes,
        .base_url = result.final_url,
    });
    defer page_extractor.deinit();
    const document = try page_extractor.extract(result.body);
    defer document.release(allocator);
    const target = if (document.canonical_url.len > 0) document.canonical_url else result.final_url;
    const language = if (document.language.len > 0) document.language else normalize.detectLanguage(document.text);
    const mutation = try engine.ingest(allocator, .{
        .url = target,
        .title = document.title,
        .text = document.text,
        .language = language,
        .quality = @max(0.0, 1.0 - document.boilerplate_ratio),
        .published_at = document.published_ms,
        .model_version = engine.config.model.model_version,
    });
    return .{
        .url = try allocator.dupe(u8, result.url),
        .final_url = try allocator.dupe(u8, target),
        .status = result.status,
        .outcome = @tagName(result.outcome),
        .bytes = result.bytes,
        .denied = result.denied,
        .challenge = result.challenge,
        .links = document.links.len,
        .token_count = document.token_count,
        .document_id = mutation.id,
        .ingested = true,
        .changed = mutation.changed,
        .elapsed_ms = result.elapsed_ms,
    };
}
