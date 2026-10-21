const std = @import("std");

pub const dimensions = 4096;
pub const retained_dimensions = 256;
pub const Packed = struct { signs: [32]u8, retained_norm: f32, mean_absolute: f32 };

pub fn normalize(allocator: std.mem.Allocator, input: []const f32) ![]f32 {
    if (input.len != dimensions) return error.InvalidEmbeddingDimensions;
    var squared: f64 = 0;
    for (input) |coordinate| {
        if (!std.math.isFinite(coordinate)) return error.InvalidEmbeddingValue;
        squared += @as(f64, coordinate) * coordinate;
    }
    if (!std.math.isFinite(squared) or squared <= 0) return error.ZeroEmbedding;
    const inverse: f64 = 1.0 / @sqrt(squared);
    const output = try allocator.alloc(f32, dimensions);
    for (input, output) |coordinate, *value| value.* = @floatCast(@as(f64, coordinate) * inverse);
    return output;
}

pub fn pack(input: []const f32) !Packed {
    if (input.len != dimensions) return error.InvalidEmbeddingDimensions;
    var result = Packed{ .signs = @splat(0), .retained_norm = 0, .mean_absolute = 0 };
    var squared: f64 = 0;
    var absolute: f64 = 0;
    for (input[0..retained_dimensions], 0..) |coordinate, index| {
        if (!std.math.isFinite(coordinate)) return error.InvalidEmbeddingValue;
        if (coordinate >= 0) result.signs[index / 8] |= @as(u8, 1) << @intCast(index % 8);
        squared += @as(f64, coordinate) * coordinate;
        absolute += @abs(@as(f64, coordinate));
    }
    result.retained_norm = @floatCast(@sqrt(squared));
    result.mean_absolute = @floatCast(absolute / retained_dimensions);
    return result;
}
