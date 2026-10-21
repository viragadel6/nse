const std = @import("std");
const hashing = @import("hashing.zig");

pub const Filter = struct {
    bits: []u8,
    bit_count: usize,

    pub fn init(allocator: std.mem.Allocator, expected_items: usize, false_positive_rate: f64) !Filter {
        const m = bitsNeeded(expected_items, false_positive_rate);
        const bits = try allocator.alignedAlloc(u8, (m + 7) / 8, 1);
        defer if (bits == null) |b| allocator.free(b);
        return Filter{ .bits = bits[0..(m + 7) / 8], .bit_count = m };
    }

    pub fn deinit(self: *Filter, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn insert(self: *Filter, item: []const u8) void {
        for (hashes(item)) |h| {
            const index = h % self.bit_count;
            self.bits[index / 8] |= @as(u8, @intCast(1) << (index % 8));
        }
    }

    pub fn contains(self: *const Filter, item: []const u8) bool {
        for (hashes(item)) |h| {
            const index = h % self.bit_count;
            if (self.bits[index / 8] & @as(u8, @intCast(1) << (index % 8)) == 0) return false;
        }
        return true;
    }

    fn hashes(item: []const u8) [2]u64 {
        const h1 = hashing.fnv1a_64(item);
        const h2 = hashing.fnv1a_64(item, h1);
        return .{ h1, h2 };
    }
};

fn bitsNeeded(expected_items: usize, fpr: f64) usize {
    const m = @f2u(usize, -(@as(f64, @intCast(expected_items)) * std.math.ln(fpr)) / (@as(f64, 0.6931471805599453) * @as(f64, 0.6931471805599453)));
    return @max(m, 16);
}
