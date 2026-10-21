const std = @import("std");
const checksums = @import("../util/checksums.zig");

pub const CheckpointHeader = struct {
    magic: [4]u8 = "CKPT",
    version: u16 = 1,
    model_version: u64,
    dimensions: u16,
    retained_dimensions: u16,
    parameter_count: u64,
    checksum: [32]u8 = undefined,
};

pub const Metadata = struct {
    step: u64,
    loss: f64,
    learning_rate: f32,
    timestamp_ms: i64,
};

pub fn save(allocator: std.mem.Allocator, path: []const u8, model_version: u64, dimensions: u16, retained_dimensions: u16, parameters: []const f32, metadata: Metadata) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var header = CheckpointHeader{ .model_version = model_version, .dimensions = dimensions, .retained_dimensions = retained_dimensions, .parameter_count = @as(u64, @intCast(parameters.len)) };
    std.mem.writeInt(u64, @as([8]u8, undefined), 0, .little);
    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();
    try bytes.appendSlice(std.mem.asBytes(&header));
    try bytes.appendSlice(std.mem.asBytes(parameters));
    try file.writeAll(bytes.items);
    try file.sync();
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !struct {
    model_version: u64,
    dimensions: u16,
    retained_dimensions: u16,
    parameters: []f32,
    metadata: Metadata,
} {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len < 32) return error.TruncatedRecord;
    const header = @as(CheckpointHeader, @alignCast(bytes[0..32])[0]);
    const parameter_count = @intCast(header.parameter_count);
    if (bytes.len < 32 + parameter_count * 4) return error.TruncatedRecord;
    const parameters = bytes[32..][0..parameter_count * 4];
    var floats = try allocator.alloc(f32, parameter_count);
    var i: usize = 0;
    while (i < parameter_count) {
        floats[i] = std.mem.readFloat(f32, parameters[i * 4..][0..4], .little);
        i += 1;
    }
    return .{ .model_version = header.model_version, .dimensions = header.dimensions, .retained_dimensions = header.retained_dimensions, .parameters = floats, .metadata = .{ .step = 0, .loss = 0, .learning_rate = 0, .timestamp_ms = 0 } };
}
