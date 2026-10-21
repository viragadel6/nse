const std = @import("std");
const protocol = @import("workload");
const artifacts = @import("artifacts");
const cuda = @import("models/cuda_runtime.zig");
const embeddings = @import("models/embedding_service.zig");
const training = @import("training/training_runtime.zig");
const signals = @import("runtime/signals.zig");

fn output(value: anytype) !void {
    try std.json.stringify(value, .{}, std.io.getStdOut().writer());
    try std.io.getStdOut().writer().writeByte('\n');
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) return error.InvalidWorkerArguments;
    const operation = args[1];
    const root = args[2];
    if (!std.fs.path.isAbsolute(root)) return error.InvalidArtifactRoot;
    try std.fs.cwd().makePath(root);
    var input = std.ArrayList(u8).init(allocator);
    try std.io.getStdIn().reader().readAllArrayList(&input, 64 * 1024 * 1024);
    signals.install();
    if (std.mem.eql(u8, operation, "register")) {
        const request = try protocol.parse(protocol.RegistryRequest, allocator, input.items);
        return output(try artifacts.register(allocator, root, request.value));
    }
    if (std.mem.eql(u8, operation, "artifact")) {
        const Request = struct { protocol_version: u16 = 1, model_version: u64 };
        const request = try protocol.parse(Request, allocator, input.items);
        if (request.value.protocol_version != protocol.version) return error.IncompatibleWorkload;
        const path = try artifacts.checkpointPath(allocator, root, request.value.model_version);
        var checkpoint = try artifacts.load(allocator, path, request.value.model_version);
        defer checkpoint.deinit();
        const file = try std.fs.cwd().openFile(path, .{}); defer file.close();
        var buffer: [65536]u8 = undefined;
        while (true) { const n = try file.read(&buffer); if (n == 0) break; try std.io.getStdOut().writer().writeAll(buffer[0..n]); }
        return;
    }
    var runtime = try cuda.Runtime.init(allocator, @embedFile("models/gpu_kernels.cu"));
    defer runtime.deinit();
    if (std.mem.eql(u8, operation, "train")) {
        const request = try protocol.parse(protocol.TrainingRequest, allocator, input.items);
        return output(try training.run(std.heap.page_allocator, &runtime, root, request.value));
    }
    if (std.mem.eql(u8, operation, "embed")) {
        const request = try protocol.parse(protocol.EmbeddingRequest, allocator, input.items);
        return output(try embeddings.embed(allocator, &runtime, root, request.value));
    }
    if (std.mem.eql(u8, operation, "single")) {
        const parsed = try protocol.parse(protocol.SingleRequest, allocator, input.items);
        const request = parsed.value;
        const items = [_]protocol.Item{.{ .text = request.text, .kind = request.kind, .structure = request.structure }};
        const result = try embeddings.embed(allocator, &runtime, root, .{ .protocol_version = request.protocol_version, .model_version = request.model_version, .dimensions = request.dimensions, .items = &items, .deadline_ms = request.deadline_ms });
        return output(.{ .protocol_version = protocol.version, .model_version = result.model_version, .dimensions = result.dimensions, .embedding = result.embeddings[0].embedding, .elapsed_ms = result.elapsed_ms, .gpu = result.gpu });
    }
    if (std.mem.eql(u8, operation, "health")) {
        const Request = struct { model_version: u64 = 1 };
        const request = try protocol.parse(Request, allocator, input.items);
        return output(try embeddings.health(allocator, &runtime, root, request.value.model_version));
    }
    return error.UnknownWorkerOperation;
}

pub fn main() u8 {
    run() catch |err| {
        std.json.stringify(.{ .@"error" = .{ .code = @errorName(err), .retryable = switch (err) { error.CudaOperationFailed, error.CudaDeviceUnavailable, error.TrainingJobAlreadyRunning => true, else => false } } }, .{}, std.io.getStdErr().writer()) catch return 1;
        std.io.getStdErr().writer().writeByte('\n') catch return 1;
        return 1;
    };
    return 0;
}
