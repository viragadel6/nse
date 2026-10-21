const std = @import("std");
const quantization = @import("../index/binary_quantization.zig");

pub const Table = struct {
    values: [32][256]f32,

    pub fn init(query: []const f32) !Table {
        if (query.len != quantization.dimensions) return error.InvalidEmbeddingDimensions;
        var result: Table = undefined;
        for (&result.values, 0..) |*subvector, index| {
            for (subvector, 0..) |*entry, bits| {
                var value: f64 = 0;
                for (0..8) |bit| {
                    const coordinate = query[index * 8 + bit];
                    if (!std.math.isFinite(coordinate)) return error.InvalidEmbeddingValue;
                    value += if ((bits & (@as(usize, 1) << @intCast(bit))) != 0) @as(f64, coordinate) else -@as(f64, coordinate);
                }
                entry.* = @floatCast(value);
            }
        }
        return result;
    }

    pub fn score(self: *const Table, binary_vector: quantization.Packed) f64 {
        var sum: f64 = 0;
        for (binary_vector.signs, 0..) |bits, index| sum += self.values[index][bits];
        return sum * @as(f64, binary_vector.mean_absolute);
    }
};
