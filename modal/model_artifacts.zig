const std = @import("std");
const protocol = @import("workload");

pub const Metadata = struct {
    format_version: u32 = 1,
    model_version: u64,
    dimensions: u16 = 4096,
    retained_dimensions: u16 = 256,
    hidden: u16,
    layers: u16,
    max_tokens: u16,
    step: u64 = 0,
    last_loss: ?f32 = null,
    seed: u64,
    tokenizer: []const u8 = "utf8_bytes_v1",
    architecture: []const u8 = "dual_structural_transformer_v1",
    precision: []const u8 = "float32",
    parameter_count: u64,
};
pub const Checkpoint = struct {
    metadata: Metadata,
    parameters: []f32,
    first_moment: []f32,
    second_moment: []f32,
    digest: [32]u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Checkpoint) void {
        self.allocator.free(self.parameters);
        self.allocator.free(self.first_moment);
        self.allocator.free(self.second_moment);
    }
};
pub const Record = struct { format_version: u16 = 1, model_version: u64, dimensions: u16 = 4096, retained_dimensions: u16 = 256, checkpoint: []const u8, sha256: []const u8, step: u64 };

pub fn parameterCount(hidden: u16, layers: u16, tokens: u16) !usize {
    const h: usize = hidden;
    const tables = try std.math.mul(usize, 257 + @as(usize, tokens) + 6 + 4096, h);
    const matrices = try std.math.mul(usize, try std.math.mul(usize, h, h), try std.math.mul(usize, layers, 12));
    return try std.math.add(usize, try std.math.mul(usize, try std.math.add(usize, tables, matrices), 2), 1);
}

pub fn validate(metadata: Metadata) !void {
    if (metadata.last_loss) |loss| if (!std.math.isFinite(loss)) return error.InvalidTrainingLoss;
    if (metadata.format_version != 1 or metadata.model_version == 0 or metadata.dimensions != protocol.dimensions or metadata.retained_dimensions != protocol.retained_dimensions) return error.IncompatibleCheckpoint;
    if (metadata.hidden < 16 or metadata.hidden > 1024 or metadata.layers == 0 or metadata.layers > 24 or metadata.max_tokens == 0 or metadata.max_tokens > 4096) return error.InvalidModelArchitecture;
    if (!std.mem.eql(u8, metadata.tokenizer, "utf8_bytes_v1") or !std.mem.eql(u8, metadata.architecture, "dual_structural_transformer_v1") or !std.mem.eql(u8, metadata.precision, "float32")) return error.IncompatibleModelArchitecture;
    if (metadata.parameter_count != try parameterCount(metadata.hidden, metadata.layers, metadata.max_tokens)) return error.InvalidParameterCount;
}

pub fn atomicWrite(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    const id = try protocol.requestId(allocator);
    defer allocator.free(id);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{s}.pending", .{ path, id });
    defer allocator.free(temporary);
    errdefer std.fs.cwd().deleteFile(temporary) catch {};
    const file = try std.fs.cwd().createFile(temporary, .{ .exclusive = true });
    {
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    try std.fs.cwd().rename(temporary, path);
    var directory = try std.fs.cwd().openDir(std.fs.path.dirname(path) orelse ".", .{ .iterate = true });
    defer directory.close();
    try std.posix.fsync(directory.fd);
}

pub fn checkpointPath(allocator: std.mem.Allocator, root: []const u8, model_version: u64) ![]u8 {
    if (model_version == 0) return error.InvalidModelVersion;
    return std.fmt.allocPrint(allocator, "{s}/checkpoints/model-{d}.bin", .{ root, model_version });
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, metadata: Metadata, parameters: []const f32, first: []const f32, second: []const f32) ![32]u8 {
    try validate(metadata);
    if (parameters.len != metadata.parameter_count or first.len != parameters.len or second.len != parameters.len) return error.InvalidParameterCount;
    const header = try std.json.stringifyAlloc(allocator, metadata, .{});
    defer allocator.free(header);
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try buffer.appendSlice("NSEMOD01");
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, std.math.cast(u32, header.len) orelse return error.CheckpointTooLarge, .little);
    try buffer.appendSlice(&length);
    try buffer.appendSlice(header);
    for ([_][]const f32{ parameters, first, second }) |values| {
        for (values) |value| {
            if (!std.math.isFinite(value)) return error.NonFiniteCheckpoint;
            std.mem.writeInt(u32, &length, @bitCast(value), .little);
            try buffer.appendSlice(&length);
        }
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buffer.items, &digest, .{});
    try buffer.appendSlice(&digest);
    try atomicWrite(allocator, path, buffer.items);
    return digest;
}

pub fn load(allocator: std.mem.Allocator, path: []const u8, expected_version: ?u64) !Checkpoint {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..8], "NSEMOD01")) return error.InvalidCheckpointHeader;
    const end = bytes.len - 32;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..end], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[end..])) return error.CheckpointChecksumMismatch;
    const header_length = std.mem.readInt(u32, bytes[8..12], .little);
    const begin = try std.math.add(usize, 12, header_length);
    if (begin > end) return error.TruncatedCheckpoint;
    const parsed = try protocol.parse(Metadata, allocator, bytes[12..begin]);
    defer parsed.deinit();
    var metadata = parsed.value;
    try validate(metadata);
    if (expected_version) |v| if (v != metadata.model_version) return error.IncompatibleCheckpoint;
    const count = std.math.cast(usize, metadata.parameter_count) orelse return error.CheckpointTooLarge;
    if (try std.math.mul(usize, count, 12) != end - begin) return error.InvalidCheckpointLength;
    metadata.tokenizer = "utf8_bytes_v1";
    metadata.architecture = "dual_structural_transformer_v1";
    metadata.precision = "float32";
    const parameters = try allocator.alloc(f32, count);
    errdefer allocator.free(parameters);
    const first = try allocator.alloc(f32, count);
    errdefer allocator.free(first);
    const second = try allocator.alloc(f32, count);
    errdefer allocator.free(second);
    var offset = begin;
    for ([_][]f32{ parameters, first, second }, 0..) |values, group| {
        for (values) |*value| {
            value.* = @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
            offset += 4;
            if (!std.math.isFinite(value.*) or (group == 2 and value.* < 0)) return error.NonFiniteCheckpoint;
        }
    }
    return .{ .metadata = metadata, .parameters = parameters, .first_moment = first, .second_moment = second, .digest = digest, .allocator = allocator };
}

pub fn register(allocator: std.mem.Allocator, root: []const u8, request: protocol.RegistryRequest) !Record {
    if (request.protocol_version != protocol.version) return error.IncompatibleWorkload;
    const path = try checkpointPath(allocator, root, request.model_version);
    defer allocator.free(path);
    var checkpoint = try load(allocator, path, request.model_version);
    defer checkpoint.deinit();
    if (checkpoint.metadata.step == 0) return error.UntrainedModel;
    const registry_path = try std.fs.path.join(allocator, &.{ root, "registry.json" });
    defer allocator.free(registry_path);
    const lock_path = try std.fs.path.join(allocator, &.{ root, "registry.lock" });
    defer allocator.free(lock_path);
    const lock = try std.fs.cwd().createFile(lock_path, .{ .truncate = false });
    defer lock.close();
    try lock.lock(.exclusive);
    defer lock.unlock();
    if (request.expected_current_version) |expected| {
        const previous = std.fs.cwd().readFileAlloc(allocator, registry_path, 65536) catch |err| switch (err) {
            error.FileNotFound => if (expected == 0) null else return error.ModelRolloutConflict,
            else => return err,
        };
        if (previous) |bytes| {
            defer allocator.free(bytes);
            const parsed = try protocol.parse(Record, allocator, bytes);
            defer parsed.deinit();
            if (parsed.value.model_version != expected) return error.ModelRolloutConflict;
        }
    }
    const digest = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(checkpoint.digest, .lower)});
    const owned_path = try allocator.dupe(u8, path);
    const record = Record{ .model_version = request.model_version, .checkpoint = owned_path, .sha256 = digest, .step = checkpoint.metadata.step };
    const bytes = try std.json.stringifyAlloc(allocator, record, .{});
    defer allocator.free(bytes);
    try atomicWrite(allocator, registry_path, bytes);
    return record;
}
