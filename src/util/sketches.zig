const std = @import("std");
const hashing = @import("hashing.zig");

pub const SketchError = error{
    InvalidPrecision,
    InvalidConfiguration,
    TruncatedSketch,
    VersionMismatch,
    IncompatibleSketch,
};

pub const HyperLogLog = struct {
    registers: []u8,
    precision: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, precision: u8) !HyperLogLog {
        if (precision < 4 or precision > 18) return SketchError.InvalidPrecision;
        const register_count: usize = @as(usize, 1) << @intCast(precision);
        const registers = try allocator.alloc(u8, register_count);
        @memset(registers, 0);
        return .{ .registers = registers, .precision = precision, .allocator = allocator };
    }

    pub fn deinit(self: *HyperLogLog) void {
        self.allocator.free(self.registers);
    }

    pub fn add(self: *HyperLogLog, value: u64) void {
        const h = hashing.mix64(value);
        const index: usize = @truncate(h >> @intCast(64 - self.precision));
        const w = h << @intCast(self.precision) | (@as(u64, 1) << @intCast(self.precision - 1));
        const rho = @as(u8, @intCast(@clz(w) + 1));
        if (rho > self.registers[index]) self.registers[index] = rho;
    }

    pub fn addBytes(self: *HyperLogLog, value: []const u8) void {
        self.add(hashing.hash64(0xABCDEF0123456789, value));
    }

    pub fn rawEstimate(self: *const HyperLogLog) f64 {
        const m: f64 = @floatFromInt(self.registers.len);
        var sum: f64 = 0;
        for (self.registers) |r| sum += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(r)));
        const alpha = alphaFor(self.registers.len);
        return alpha * m * m / sum;
    }

    fn alphaFor(m: usize) f64 {
        if (m == 16) return 0.673;
        if (m == 32) return 0.697;
        if (m == 64) return 0.709;
        return 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(m)));
    }

    pub fn count(self: *const HyperLogLog) u64 {
        const m: f64 = @floatFromInt(self.registers.len);
        const estimate = self.rawEstimate();
        if (estimate <= 2.5 * m) {
            var zeros: usize = 0;
            for (self.registers) |r| {
                if (r == 0) zeros += 1;
            }
            if (zeros != 0) {
                const linear = m * @log(m / @as(f64, @floatFromInt(zeros)));
                return @intFromFloat(@round(linear));
            }
        }
        const pow2_32: f64 = 4294967296.0;
        if (estimate > pow2_32 / 30.0) {
            const corrected = -pow2_32 * @log(1.0 - estimate / pow2_32);
            return @intFromFloat(@round(corrected));
        }
        return @intFromFloat(@round(estimate));
    }

    pub fn merge(self: *HyperLogLog, other: *const HyperLogLog) SketchError!void {
        if (self.precision != other.precision) return SketchError.IncompatibleSketch;
        for (self.registers, other.registers) |*a, b| {
            if (b > a.*) a.* = b;
        }
    }

    pub fn serialize(self: *const HyperLogLog, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, 2 + self.registers.len);
        out[0] = 1;
        out[1] = self.precision;
        @memcpy(out[2..], self.registers);
        return out;
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !HyperLogLog {
        if (data.len < 3) return SketchError.TruncatedSketch;
        if (data[0] != 1) return SketchError.VersionMismatch;
        const precision = data[1];
        var hll = try HyperLogLog.init(allocator, precision);
        if (hll.registers.len != data.len - 2) {
            hll.deinit();
            return SketchError.TruncatedSketch;
        }
        @memcpy(hll.registers, data[2..]);
        return hll;
    }
};

pub const CountMinSketch = struct {
    rows: []u32,
    depth: usize,
    width: usize,
    total: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, depth: usize, width: usize) !CountMinSketch {
        if (depth == 0 or width == 0) return SketchError.InvalidConfiguration;
        const rows = try allocator.alloc(u32, depth * width);
        @memset(rows, 0);
        return .{ .rows = rows, .depth = depth, .width = width, .total = 0, .allocator = allocator };
    }

    pub fn deinit(self: *CountMinSketch) void {
        self.allocator.free(self.rows);
    }

    pub fn add(self: *CountMinSketch, value: []const u8, count: u32) void {
        const h = hashing.hash128(0x2545F4914F6CDD1D, value);
        var h1: u64 = @truncate(h[0]);
        var h2: u64 = @truncate(h[1]);
        if (h1 == 0) h1 = 0x9E3779B97F4A7C15;
        if (h2 == 0) h2 = 0xC2B2AE3D27D4EB4F;
        for (0..self.depth) |row| {
            const index = @mod(h1 +% @as(u64, @intCast(row)) *% h2, @as(u64, @intCast(self.width)));
            const slot = &self.rows[row * self.width + index];
            if (slot.* > std.math.maxInt(u32) - count) {
                slot.* = std.math.maxInt(u32);
            } else {
                slot.* += count;
            }
        }
        self.total += count;
    }

    pub fn estimate(self: *const CountMinSketch, value: []const u8) u32 {
        const h = hashing.hash128(0x2545F4914F6CDD1D, value);
        var h1: u64 = @truncate(h[0]);
        var h2: u64 = @truncate(h[1]);
        if (h1 == 0) h1 = 0x9E3779B97F4A7C15;
        if (h2 == 0) h2 = 0xC2B2AE3D27D4EB4F;
        var min: u32 = std.math.maxInt(u32);
        for (0..self.depth) |row| {
            const index = @mod(h1 +% @as(u64, @intCast(row)) *% h2, @as(u64, @intCast(self.width)));
            min = @min(min, self.rows[row * self.width + index]);
        }
        return min;
    }

    pub fn merge(self: *CountMinSketch, other: *const CountMinSketch) SketchError!void {
        if (self.depth != other.depth or self.width != other.width) return SketchError.IncompatibleSketch;
        for (self.rows, other.rows) |*a, b| {
            a.* = if (a.* > std.math.maxInt(u32) - b) std.math.maxInt(u32) else a.* + b;
        }
        self.total += other.total;
    }

    pub fn loadFactor(self: *const CountMinSketch) f64 {
        var used: u64 = 0;
        for (self.rows) |c| {
            if (c > 0) used += 1;
        }
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.rows.len));
    }
};

pub const Centroid = struct {
    mean: f64,
    weight: f64,
};

pub const TDigest = struct {
    centroids: std.ArrayListUnmanaged(Centroid) = .{},
    compression: f64,
    total_weight: f64,
    min: f64,
    max: f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, compression: f64) TDigest {
        return .{
            .centroids = .{},
            .compression = @max(20.0, compression),
            .total_weight = 0,
            .min = std.math.inf(f64),
            .max = -std.math.inf(f64),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TDigest) void {
        self.centroids.deinit(self.allocator);
    }

    pub fn add(self: *TDigest, value: f64) !void {
        try self.addWeighted(value, 1.0);
    }

    pub fn addWeighted(self: *TDigest, value: f64, weight: f64) !void {
        if (std.math.isNan(value)) return;
        if (value < self.min) self.min = value;
        if (value > self.max) self.max = value;
        try self.centroids.append(self.allocator, .{ .mean = value, .weight = weight });
        self.total_weight += weight;
        if (self.centroids.items.len > @as(usize, @intFromFloat(self.compression * 4.0))) try self.compress();
    }

    pub fn compress(self: *TDigest) !void {
        if (self.centroids.items.len < 2) return;
        std.sort.block(Centroid, self.centroids.items, {}, struct {
            fn lt(_: void, a: Centroid, b: Centroid) bool {
                return a.mean < b.mean;
            }
        }.lt);
        var merged: std.ArrayListUnmanaged(Centroid) = .{};
        errdefer merged.deinit(self.allocator);
        var current = self.centroids.items[0];
        var weight_so_far: f64 = 0;
        for (self.centroids.items[1..]) |next| {
            const position = (weight_so_far + current.weight) / self.total_weight;
            const limit = 4.0 * self.total_weight * position * (1.0 - position) / self.compression;
            if (current.weight + next.weight <= limit) {
                current.mean = (current.mean * current.weight + next.mean * next.weight) / (current.weight + next.weight);
                current.weight += next.weight;
            } else {
                try merged.append(self.allocator, current);
                weight_so_far += current.weight;
                current = next;
            }
        }
        try merged.append(self.allocator, current);
        self.centroids.deinit(self.allocator);
        self.centroids = merged;
    }

    pub fn quantile(self: *TDigest, q: f64) f64 {
        if (self.centroids.items.len == 0) return 0.0;
        if (q <= 0) return self.min;
        if (q >= 1) return self.max;
        const target = q * self.total_weight;
        var cumulative: f64 = 0;
        for (self.centroids.items, 0..) |c, i| {
            const next = cumulative + c.weight;
            if (target <= next) {
                if (i == 0 or i + 1 == self.centroids.items.len) return c.mean;
                const previous = self.centroids.items[i - 1];
                const following = self.centroids.items[i + 1];
                const left = (previous.mean + c.mean) / 2.0;
                const right = (c.mean + following.mean) / 2.0;
                const position = (target - cumulative) / c.weight;
                return left + (right - left) * position;
            }
            cumulative = next;
        }
        return self.max;
    }

    pub fn median(self: *TDigest) f64 {
        return self.quantile(0.5);
    }

    pub fn count(self: *TDigest) f64 {
        return self.total_weight;
    }
};

pub const Reservoir = struct {
    samples: []f64,
    seen: u64,
    seed: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, seed: u64) !Reservoir {
        const samples = try allocator.alloc(f64, capacity);
        @memset(samples, 0);
        return .{ .samples = samples, .seen = 0, .seed = seed, .allocator = allocator };
    }

    pub fn deinit(self: *Reservoir) void {
        self.allocator.free(self.samples);
    }

    pub fn add(self: *Reservoir, value: f64, source_hash: u64) void {
        if (self.samples.len == 0) return;
        if (self.seen < @as(u64, self.samples.len)) {
            self.samples[@intCast(self.seen)] = value;
            self.seen += 1;
            return;
        }
        self.seen += 1;
        const mixed = hashing.mix64(source_hash ^ (self.seed +% self.seen));
        const index = @mod(mixed, self.seen);
        if (index < @as(u64, self.samples.len)) self.samples[@intCast(index)] = value;
    }

    pub fn snapshot(self: *Reservoir, allocator: std.mem.Allocator) ![]f64 {
        const count = @min(self.seen, @as(u64, self.samples.len));
        const out = try allocator.alloc(f64, count);
        @memcpy(out, self.samples[0..@intCast(count)]);
        return out;
    }
};

pub const ExponentialMovingAverage = struct {
    value: f64 = 0,
    alpha: f64,
    samples: u64 = 0,

    pub fn init(half_life_samples: f64) ExponentialMovingAverage {
        return .{ .alpha = if (half_life_samples <= 0) 1.0 else 1.0 - std.math.pow(f64, 0.5, 1.0 / half_life_samples) };
    }

    pub fn update(self: *ExponentialMovingAverage, sample: f64) f64 {
        if (self.samples == 0) {
            self.value = sample;
        } else {
            self.value += self.alpha * (sample - self.value);
        }
        self.samples += 1;
        return self.value;
    }

    pub fn get(self: *const ExponentialMovingAverage) f64 {
        return self.value;
    }
};

pub const ChangeDetector = struct {
    window: []f64,
    position: usize,
    filled: usize,
    baseline_mean: f64,
    baseline_stddev: f64,
    threshold: f64,

    pub fn init(allocator: std.mem.Allocator, window_size: usize, threshold: f64) !ChangeDetector {
        if (window_size < 4) return SketchError.InvalidConfiguration;
        const window = try allocator.alloc(f64, window_size);
        @memset(window, 0);
        return .{
            .window = window,
            .position = 0,
            .filled = 0,
            .baseline_mean = 0,
            .baseline_stddev = 0,
            .threshold = threshold,
        };
    }

    pub fn deinit(self: *ChangeDetector, allocator: std.mem.Allocator) void {
        allocator.free(self.window);
    }

    pub fn push(self: *ChangeDetector, value: f64) bool {
        self.window[self.position] = value;
        self.position = (self.position + 1) % self.window.len;
        if (self.filled < self.window.len) {
            self.filled += 1;
            return false;
        }
        var sum: f64 = 0;
        for (self.window) |v| sum += v;
        const mean = sum / @as(f64, @floatFromInt(self.window.len));
        var variance: f64 = 0;
        for (self.window) |v| variance += (v - mean) * (v - mean);
        variance /= @as(f64, @floatFromInt(self.window.len));
        const stddev = @sqrt(variance);
        if (self.baseline_stddev == 0) {
            self.baseline_mean = mean;
            self.baseline_stddev = @max(stddev, 1e-9);
            return false;
        }
        const drift = @abs(mean - self.baseline_mean) / self.baseline_stddev;
        if (drift > self.threshold) {
            self.baseline_mean = mean;
            self.baseline_stddev = @max(stddev, 1e-9);
            return true;
        }
        if (stddev > 0) {
            self.baseline_mean += 0.05 * (mean - self.baseline_mean);
            self.baseline_stddev = @max(1e-9, self.baseline_stddev + 0.05 * (stddev - self.baseline_stddev));
        }
        return false;
    }
};
