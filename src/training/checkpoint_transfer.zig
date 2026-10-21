const std = @import("std");
const checkpoint = @import("../models/checkpoint.zig");
const artifacts = @import("artifacts");

pub fn transfer(allocator: std.mem.Allocator, endpoint: []const u8, version: u64, destination: []const u8, timeout_ms: u32) !void {
    const file = try std.fs.cwd().readFileAlloc(allocator, destination, 4 * 1024 * 1024 * 1024);
    defer allocator.free(file);
    const loaded = try checkpoint.load(allocator, destination);
    if (loaded.model_version != version) return error.ModelVersionConflict;
    _ = endpoint;
    _ = timeout_ms;
}
