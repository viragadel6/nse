const std = @import("std");
const protocol = @import("workload");
const artifacts = @import("artifacts");
const cuda = @import("cuda_runtime.zig");
const transformer = @import("gpu_transformer.zig");
const signals = @import("../runtime/signals.zig");

pub fn embed(allocator: std.mem.Allocator, runtime: *cuda.Runtime, root: []const u8, request: protocol.EmbeddingRequest) !protocol.EmbeddingResponse {
    try protocol.validateEmbedding(request);
    var timer = try std.time.Timer.start();
    const path = try artifacts.checkpointPath(allocator, root, request.model_version);
    defer allocator.free(path);
    var checkpoint = try artifacts.load(allocator, path, request.model_version);
    defer checkpoint.deinit();
    if (checkpoint.metadata.step == 0) return error.UntrainedModel;
    var model = try transformer.Model.init(runtime, checkpoint.metadata, checkpoint.parameters, checkpoint.first_moment, checkpoint.second_moment);
    defer model.deinit();
    const output = try allocator.alloc(protocol.Embedding, request.items.len);
    errdefer allocator.free(output);
    var initialized: usize = 0;
    errdefer for (output[0..initialized]) |item| { allocator.free(item.embedding); allocator.free(item.retained); allocator.free(item.binary); };
    for (request.items, output) |item, *result| {
        if (signals.stopping()) return error.Cancelled;
        if (timer.read() / std.time.ns_per_ms >= request.deadline_ms) return error.DeadlineExceeded;
        var graph = transformer.Graph.init(allocator, &model);
        defer graph.deinit();
        const id = try graph.encode(item);
        const values = try graph.read(id);
        errdefer allocator.free(values);
        const retained = try allocator.alloc(f32, 256);
        errdefer allocator.free(retained);
        const binary = try allocator.alloc(u16, 32);
        errdefer allocator.free(binary);
        @memset(binary, 0);
        var norm: f64 = 0;
        for (values[0..256]) |value| norm += @as(f64, value) * value;
        if (norm <= 1e-20 or !std.math.isFinite(norm)) return error.InvalidRetainedEmbedding;
        const scale: f32 = @floatCast(1 / @sqrt(norm));
        for (retained, values[0..256], 0..) |*coordinate, value, i| {
            coordinate.* = value * scale;
            if (coordinate.* >= 0) binary[i / 8] |= @as(u16, 1) << @as(u4, @intCast(i % 8));
        }
        result.* = .{ .id = item.id, .embedding = values, .retained = retained, .binary = binary };
        initialized += 1;
    }
    return .{ .model_version = request.model_version, .embeddings = output, .elapsed_ms = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms, .gpu = runtime.name() };
}

pub fn health(allocator: std.mem.Allocator, runtime: *cuda.Runtime, root: []const u8, model_version: u64) !protocol.Health {
    const path = try artifacts.checkpointPath(allocator, root, model_version);
    defer allocator.free(path);
    var checkpoint = artifacts.load(allocator, path, model_version) catch |err| switch (err) {
        error.FileNotFound => return .{ .ready = false, .model_version = model_version, .gpu = runtime.name() },
        else => return err,
    };
    defer checkpoint.deinit();
    if (checkpoint.metadata.step == 0) return .{ .ready = false, .model_version = model_version, .gpu = runtime.name() };
    var model = try transformer.Model.init(runtime, checkpoint.metadata, checkpoint.parameters, checkpoint.first_moment, checkpoint.second_moment);
    defer model.deinit();
    const hash = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(checkpoint.digest, .lower)});
    return .{ .ready = true, .model_version = model_version, .gpu = runtime.name(), .checkpoint_sha256 = hash };
}
