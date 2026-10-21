const std = @import("std");
const quantization = @import("../index/binary_quantization.zig");

pub const Scorer = struct {
    table: [][]f32,
    query_bits: [32]u8,
    query_norm: f32,

    pub fn init(allocator: std.mem.Allocator, query: []const f32) !Scorer {
        var table = try allocator.alloc([]f32, 32);
        var i: usize = 0;
        while (i < 32) {
            table[i] = try allocator.alloc(f32, 256);
            var bits: usize = 0;
            while (bits < 256) {
                var value: f32 = 0;
                var b: usize = 0;
                while (b < 8) {
                    const coordinate = query[i * 8 + b];
                    if ((bits & (@as(usize, 1) << @intCast(b))) != 0) value += coordinate; else value -= coordinate;
                    b += 1;
                }
                table[i][bits] = value;
                bits += 1;
            }
            i += 1;
        }
        var query_bits: [32]u8 = @splat(0);
        var index: usize = 0;
        while (index < 32) {
            var byte: u8 = 0;
            var b: usize = 0;
            while (b < 8) {
                const coordinate = query[index * 8 + b];
                if (coordinate >= 0) byte |= @as(u8, 1) << @intCast(b);
                b += 1;
            }
            query_bits[index] = byte;
            index += 1;
        }
        var norm: f32 = 0;
        for (query[0..256]) |value| norm += value * value;
        norm = @sqrt(norm);
        return Scorer{ .table = table, .query_bits = query_bits, .query_norm = norm };
    }

    pub fn deinit(self: *Scorer, allocator: std.mem.Allocator) void {
        for (self.table) |row| allocator.free(row);
        allocator.free(self.table);
    }

    pub fn score(self: *const Scorer, packed: quantization.Packed) f32 {
        var sum: f32 = 0;
        var i: usize = 0;
        while (i < 32) {
            sum += self.table[i][@intCast(packed.signs[i])];
            i += 1;
        }
        return sum * packed.mean_absolute * self.query_norm;
    }
};
