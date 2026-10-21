const std = @import("std");
const http = @import("../network/http_client.zig");
const ModelConfig = @import("../runtime/configuration.zig").ModelConfig;
const quantization = @import("../index/binary_quantization.zig");
const protocol = @import("workload");
const modal = @import("../orchestration/modal_client.zig");

pub const Health = protocol.Health;

pub fn health(allocator: std.mem.Allocator, model: ModelConfig) !Health {
    if (model.health_endpoint.len == 0) return error.EmbeddingServiceNotConfigured;
    const url = try std.fmt.allocPrint(allocator, "{s}{s}model_version={d}", .{ model.health_endpoint, if (std.mem.indexOfScalar(u8, model.health_endpoint, '?') == null) "?" else "&", model.model_version });
    defer allocator.free(url);
    var client = http.Client.init(allocator, .{
        .connect_timeout_ms = 10000,
        .read_timeout_ms = 10000,
        .write_timeout_ms = 10000,
        .max_response_bytes = model.response_bytes,
    });
    defer client.deinit();
    var response = try client.get(url);
    defer response.deinit();
    if (!response.isSuccess()) return error.EmbeddingServiceUnavailable;
    const parsed = try std.json.parseFromSlice(Health, allocator, response.body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (parsed.value.protocol_version != protocol.version or !parsed.value.ready or parsed.value.model_version != model.model_version or parsed.value.dimensions != @as(u16, @intCast(model.primary_dim)) or parsed.value.retained_dimensions != @as(u16, @intCast(model.retained_dim))) return error.IncompatibleEmbeddingModel;
    var result = parsed.value;
    result.gpu = try allocator.dupe(u8, parsed.value.gpu);
    if (result.checkpoint_sha256) |hash| result.checkpoint_sha256 = try allocator.dupe(u8, hash);
    return result;
}

pub fn embed(allocator: std.mem.Allocator, model: ModelConfig, text: []const u8, kind: enum { query, document }, timeout_ms: u32) ![]f32 {
    if (model.embedding_endpoint.len == 0) return error.EmbeddingServiceNotConfigured;
    const payload = try std.json.stringifyAlloc(allocator, protocol.SingleRequest{ .text = text, .kind = if (kind == .query) .query else .document, .model_version = model.model_version, .dimensions = @as(u16, @intCast(model.primary_dim)), .deadline_ms = timeout_ms }, .{});
    defer allocator.free(payload);
    var client = http.Client.init(allocator, .{
        .connect_timeout_ms = timeout_ms,
        .read_timeout_ms = timeout_ms,
        .write_timeout_ms = timeout_ms,
        .max_response_bytes = model.response_bytes,
    });
    defer client.deinit();
    var response = try client.post(model.embedding_endpoint, &.{ .{ .name = "content-type", .value = "application/json" } }, payload);
    defer response.deinit();
    if (!response.isSuccess()) return error.EmbeddingServiceUnavailable;
    const Result = struct { protocol_version: u16 = 1, embedding: []const f32, model_version: u64, dimensions: u16, elapsed_ms: f64 = 0, gpu: []const u8 = "" };
    const parsed = try std.json.parseFromSlice(Result, allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value.protocol_version != protocol.version or parsed.value.model_version != model.model_version or parsed.value.dimensions != @as(u16, @intCast(model.primary_dim)) or parsed.value.embedding.len != model.primary_dim) return error.IncompatibleEmbeddingModel;
    return quantization.normalize(allocator, parsed.value.embedding);
}

pub fn batch(allocator: std.mem.Allocator, model: ModelConfig, items: []const protocol.Item, timeout_ms: u32) !std.json.Parsed(protocol.EmbeddingResponse) {
    const request = protocol.EmbeddingRequest{ .model_version = model.model_version, .dimensions = @as(u16, @intCast(model.primary_dim)), .items = items, .deadline_ms = timeout_ms };
    try protocol.validateEmbedding(request);
    const result = try modal.call(protocol.EmbeddingResponse, allocator, model.workload_endpoint, .POST, "/embeddings", request, timeout_ms);
    errdefer result.deinit();
    if (result.value.protocol_version != protocol.version or result.value.model_version != model.model_version or result.value.dimensions != @as(u16, @intCast(model.primary_dim)) or result.value.embeddings.len != items.len) return error.IncompatibleEmbeddingModel;
    for (result.value.embeddings, items) |embedding, item| {
        if (embedding.id != item.id or embedding.embedding.len != 4096 or embedding.retained.len != 256 or embedding.binary.len != 32) return error.InvalidEmbeddingResponse;
        for (embedding.embedding) |value| if (!std.math.isFinite(value)) return error.InvalidEmbeddingResponse;
        for (embedding.retained) |value| if (!std.math.isFinite(value)) return error.InvalidEmbeddingResponse;
    }
    return result;
}
