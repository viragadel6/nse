const std = @import("std");
const server = @import("../network/http_server.zig");
const configuration = @import("../runtime/configuration.zig");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const documents = @import("../storage/document.zig");
const request = @import("request_codec.zig");
const inference = @import("../models/inference_client.zig");
const pipeline = @import("../crawl/pipeline.zig");
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
        const Crawl = struct { url: []const u8, max_pages: u32 = 0 };
        const parsed = try request.parse(Crawl, allocator, body);
        defer parsed.deinit();
        return json(allocator, try crawl(allocator, engine, parsed.value.url, parsed.value.max_pages));
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

pub const CrawlReport = struct {
    seed: []const u8,
    pages_fetched: u64,
    pages_deduplicated: u64,
    pages_rejected: u64,
    pages_denied: u64,
    pages_challenged: u64,
    pages_redirected: u64,
    links_discovered: u64,
    documents_stored: u64,
    bytes_fetched: u64,
    tracked_urls: u64,
    elapsed_ms: f64,
};

const IngestSink = struct {
    engine: *Engine,
};

fn storeCrawledDocument(context: *anyopaque, url: []const u8, title: []const u8, text: []const u8, quality: f32, published_ms: i64) !bool {
    const sink: *IngestSink = @ptrCast(@alignCast(context));
    const mutation = sink.engine.ingest(sink.engine.allocator, .{
        .url = url,
        .title = title,
        .text = text,
        .language = normalize.detectLanguage(text),
        .quality = quality,
        .published_at = published_ms,
        .model_version = sink.engine.config.model.model_version,
    }) catch |err| switch (err) {
        error.InvalidDocumentText, error.InvalidDocumentMetadata => return false,
        else => return err,
    };
    return mutation.changed or mutation.inserted;
}

pub fn crawl(allocator: std.mem.Allocator, engine: *Engine, url: []const u8, max_pages: u32) !CrawlReport {
    var sink = IngestSink{ .engine = engine };
    const summary = try pipeline.run(allocator, engine.config, .{
        .seed = url,
        .max_pages = if (max_pages == 0) pipeline.default_page_budget else @as(u64, max_pages),
        .max_links_per_page = @as(usize, engine.config.crawler.max_links_per_page),
        .max_text_bytes = @as(usize, engine.config.ingestion.max_document_bytes),
    }, .{ .context = &sink, .store = storeCrawledDocument });
    return .{
        .seed = try allocator.dupe(u8, url),
        .pages_fetched = summary.pages_fetched,
        .pages_deduplicated = summary.pages_deduplicated,
        .pages_rejected = summary.pages_rejected,
        .pages_denied = summary.pages_denied,
        .pages_challenged = summary.pages_challenged,
        .pages_redirected = summary.pages_redirected,
        .links_discovered = summary.links_discovered,
        .documents_stored = summary.documents_stored,
        .bytes_fetched = summary.bytes_fetched,
        .tracked_urls = summary.tracked_urls,
        .elapsed_ms = summary.elapsed_ms,
    };
}
