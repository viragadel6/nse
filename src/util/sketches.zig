const std = @import("std");
const hashing = @import("hashing.zig");

pub const CountMinSketch = struct {
    depth: usize,
    width: usize,
    table: [][]u64,

    pub fn init(allocator: std.mem.Allocator, depth: usize, width: usize) !CountMinSketch {
        var table = try allocator.alloc([]u64, depth);
        var i: usize = 0;
        while (i < depth) {
            table[i] = try allocator.alloc(u64, width);
            i += 1;
        }
        return CountMinSketch{ .depth = depth, .width = width, .table = table };
    }

    pub fn deinit(self: *CountMinSketch, allocator: std.mem.Allocator) void {
        for (self.table) |row| allocator.free(row);
        allocator.free(self.table);
    }

    pub fn add(self: *CountMinSketch, item: []const u8, count: u64) void {
        var i: usize = 0;
        while (i < self.depth) {
            const h = hashing.hash64(item, @as(u64, @intCast(i) + 1));
            self.table[i][h % self.width] += count;
            i += 1;
        }
    }

    pub fn estimate(self: *const CountMinSketch, item: []const u8) u64 {
        var min: u64 = std.math.max(u64);
        var i: usize = 0;
        while (i < self.depth) {
            const h = hashing.hash64(item, @as(u64, @intCast(i) + 1));
            const value = self.table[i][h % self.width];
            if (value < min) min = value;
            i += 1;
        }
        return min;
    }
};

pub const HyperLogLog = struct {
    precision: u8,
    m: usize,
    registers: []u8,

    pub fn init(allocator: std.mem.Allocator, precision: u8) !HyperLogLog {
        if (precision < 4 or precision > 16) return error.InvalidPrecision;
        const m = 1 << precision;
        const registers = try allocator.alloc(u8, m);
        for (registers) |*r| r.* = 0;
        return HyperLogLog{ .precision = precision, .m = m, .registers = registers };
    }

    pub fn deinit(self: *HyperLogLog, allocator: std.mem.Allocator) void {
        allocator.free(self.registers);
    }

    pub fn add(self: *HyperLogLog, item: []const u8) void {
        const h = hashing.fnv1a_64(item);
        const index = @as(usize, @intCast(h & (@as(u64, 1) << @as(u64, self.precision)) - 1));
        const w = h >> @as(u64, self.precision);
        const leading = @as(u8, @clz(w)) + 1;
        if (@intCast(leading) > @intCast(self.registers[index])) self.registers[index] = leading;
    }

    pub fn estimate(self: *const HyperLogLog) f64 {
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < self.m) {
            sum += 1.0 / @as(f64, @intCast(self.registers[i]));
            i += 1;
        }
        const alpha = 0.7213 / (1.0 + 1.079 / @as(f64, @intCast(self.m)));
        var estimate = alpha * @as(f64, @intCast(self.m)) * @as(f64, @intCast(self.m)) / sum;
        if (estimate <= 2.5 * @as(f64, @intCast(self.m))) {
            var zeros: usize = 0;
            var i = 0;
            while (i < self.m) {
                if (self.registers[i] == 0) zeros += 1;
                i += 1;
            }
            if (zeros != 0) estimate = @as(f64, @intCast(self.m)) * std.math.log(@as(f64, @intCast(self.m)) / @as(f64, @intCast(zeros)));
        }
        return estimate;
    }
};
