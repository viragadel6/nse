const std = @import("std");
const hashing = @import("hashing.zig");
const checksums = @import("checksums.zig");
const codec = @import("binary_codec.zig");

pub const BloomError = error{
    InvalidCapacity,
    InvalidHashCount,
    TruncatedFilter,
    ChecksumMismatch,
    VersionMismatch,
    CapacityExceeded,
};

pub const format_version: u32 = 3;
pub const magic = "NBLM";

pub const BloomFilter = struct {
    bits: []u64,
    bit_count: u64,
    hash_count: u32,
    inserted: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, expected_items: u64, false_positive_rate: f64) !BloomFilter {
        if (expected_items == 0) return BloomError.InvalidCapacity;
        const rate = @max(1e-9, @min(0.5, false_positive_rate));
        const ln2_sq: f64 = 0.4804530139182014;
        const m_f = -(@as(f64, @floatFromInt(expected_items)) * @log(rate)) / ln2_sq;
        const m: u64 = @intFromFloat(@ceil(m_f));
        const words = @max(1, @divFloor(m + 63, 64));
        const k: u32 = @intFromFloat(@max(1.0, @round(@as(f64, @floatFromInt(words * 64)) / @as(f64, @floatFromInt(expected_items)) * @log(2.0))));
        return initExact(allocator, words * 64, k);
    }

    pub fn initExact(allocator: std.mem.Allocator, bit_count: u64, hash_count: u32) !BloomFilter {
        if (bit_count == 0 or hash_count == 0) return BloomError.InvalidHashCount;
        const words = @divFloor(bit_count + 63, 64);
        const bits = try allocator.alloc(u64, words);
        @memset(bits, 0);
        return .{ .bits = bits, .bit_count = words * 64, .hash_count = hash_count, .inserted = 0, .allocator = allocator };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bits);
    }

    pub fn reset(self: *BloomFilter) void {
        @memset(self.bits, 0);
        self.inserted = 0;
    }

    pub fn add(self: *BloomFilter, value: u64) void {
        const h = hashing.mix64(value);
        self.addHash(h);
    }

    pub fn addBytes(self: *BloomFilter, value: []const u8) void {
        self.addHash(hashing.hash64(0x5DEECE66D, value));
    }

    fn addHash(self: *BloomFilter, hash_value: u64) void {
        const h1: u64 = @truncate(hash_value);
        var h2: u64 = @truncate(hash_value >> 32);
        if (h2 == 0) h2 = 0x9E3779B97F4A7C15;
        var i: u32 = 0;
        while (i < self.hash_count) : (i += 1) {
            const index = @mod(h1 +% @as(u64, i) *% h2, self.bit_count);
            self.bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }
        self.inserted += 1;
    }

    pub fn mayContain(self: *const BloomFilter, value: u64) bool {
        const hash_value = hashing.mix64(value);
        return self.mayContainHash(hash_value);
    }

    pub fn mayContainBytes(self: *const BloomFilter, value: []const u8) bool {
        return self.mayContainHash(hashing.hash64(0x5DEECE66D, value));
    }

    fn mayContainHash(self: *const BloomFilter, hash_value: u64) bool {
        const h1: u64 = @truncate(hash_value);
        var h2: u64 = @truncate(hash_value >> 32);
        if (h2 == 0) h2 = 0x9E3779B97F4A7C15;
        var i: u32 = 0;
        while (i < self.hash_count) : (i += 1) {
            const index = @mod(h1 +% @as(u64, i) *% h2, self.bit_count);
            if (self.bits[index / 64] & (@as(u64, 1) << @intCast(index % 64)) == 0) return false;
        }
        return true;
    }

    pub fn fillRatio(self: *const BloomFilter) f64 {
        var set: u64 = 0;
        for (self.bits) |word| set += @popCount(word);
        return @as(f64, @floatFromInt(set)) / @as(f64, @floatFromInt(self.bit_count));
    }

    pub fn estimatedFalsePositiveRate(self: *const BloomFilter) f64 {
        const ratio = self.fillRatio();
        return std.math.pow(f64, ratio, @as(f64, @floatFromInt(self.hash_count)));
    }

    pub fn merge(self: *BloomFilter, other: *const BloomFilter) BloomError!void {
        if (self.bit_count != other.bit_count or self.hash_count != other.hash_count) return BloomError.VersionMismatch;
        for (self.bits, other.bits) |*a, b| a.* |= b;
        self.inserted += other.inserted;
    }

    pub fn serialize(self: *const BloomFilter, allocator: std.mem.Allocator) ![]u8 {
        var out = codec.SliceWriter.init(allocator);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll(magic);
        try w.writeU32(format_version);
        try w.writeU64(self.bit_count);
        try w.writeU32(self.hash_count);
        try w.writeU64(self.inserted);
        for (self.bits) |word| try w.writeU64(word);
        const crc = checksums.crc32c(self.byteView(), 0);
        try w.writeU32(crc);
        return out.items.toOwnedSlice(allocator);
    }

    fn byteView(self: *const BloomFilter) []const u8 {
        return std.mem.sliceAsBytes(self.bits);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !BloomFilter {
        var r = codec.Reader.init(data);
        const head = try r.readBytes(4);
        if (!std.mem.eql(u8, head, magic)) return BloomError.TruncatedFilter;
        const version = try r.readU32();
        if (version != format_version) return BloomError.VersionMismatch;
        const bit_count = try r.readU64();
        const hash_count = try r.readU32();
        const inserted = try r.readU64();
        var filter = try BloomFilter.initExact(allocator, bit_count, hash_count);
        errdefer filter.deinit();
        filter.inserted = inserted;
        for (filter.bits) |*word| word.* = try r.readU64();
        const expected = try r.readU32();
        if (checksums.crc32c(filter.byteView(), 0) != expected) return BloomError.ChecksumMismatch;
        return filter;
    }
};

pub const PartitionedBloom = struct {
    partitions: []BloomFilter,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, partition_count: u32, expected_items: u64, false_positive_rate: f64) !PartitionedBloom {
        if (partition_count == 0) return BloomError.InvalidCapacity;
        const partitions = try allocator.alloc(BloomFilter, partition_count);
        errdefer allocator.free(partitions);
        const per_partition = @max(1, expected_items / partition_count);
        for (partitions) |*p| {
            p.* = try BloomFilter.initExact(allocator, @max(1024, per_partition * 12), 1);
        }
        _ = false_positive_rate;
        return .{ .partitions = partitions, .allocator = allocator };
    }

    pub fn deinit(self: *PartitionedBloom) void {
        for (self.partitions) |*p| p.deinit();
        self.allocator.free(self.partitions);
    }

    pub fn add(self: *PartitionedBloom, value: u64) void {
        const h = hashing.hash128(0x123456789ABCDEF, std.mem.asBytes(&value));
        for (self.partitions, 0..) |*p, i| {
            const mixed = h[0] ^ (h[1] *% (@as(u64, @intCast(i)) + 1));
            p.addHash(hashing.mix64(mixed));
        }
    }

    pub fn mayContain(self: *const PartitionedBloom, value: u64) bool {
        const h = hashing.hash128(0x123456789ABCDEF, std.mem.asBytes(&value));
        for (self.partitions, 0..) |*p, i| {
            const mixed = h[0] ^ (h[1] *% (@as(u64, @intCast(i)) + 1));
            if (!p.mayContainHash(hashing.mix64(mixed))) return false;
        }
        return true;
    }

    pub fn fillRatio(self: *const PartitionedBloom) f64 {
        var total: f64 = 0;
        for (self.partitions) |*p| total += p.fillRatio();
        return total / @as(f64, @floatFromInt(self.partitions.len));
    }
};

pub const ScalableBloom = struct {
    layers: std.ArrayListUnmanaged(BloomFilter) = .{},
    allocator: std.mem.Allocator,
    initial_capacity: u64,
    error_rate: f64,
    growth: u32,
    tightening: f64,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: u64, error_rate: f64) !ScalableBloom {
        return .{
            .allocator = allocator,
            .initial_capacity = @max(64, initial_capacity),
            .error_rate = @max(1e-6, @min(0.25, error_rate)),
            .growth = 2,
            .tightening = 0.9,
            .layers = .{},
        };
    }

    pub fn deinit(self: *ScalableBloom) void {
        for (self.layers.items) |*layer| layer.deinit();
        self.layers.deinit(self.allocator);
    }

    pub fn add(self: *ScalableBloom, value: u64) !void {
        if (self.layers.items.len == 0) try self.addLayer(0);
        const active = &self.layers.items[self.layers.items.len - 1];
        if (active.inserted + 1 > capacityOf(self.initial_capacity, self.layers.items.len - 1, self.growth)) {
            try self.addLayer(self.layers.items.len);
        }
        self.layers.items[self.layers.items.len - 1].add(value);
    }

    fn addLayer(self: *ScalableBloom, index: usize) !void {
        const cap = capacityOf(self.initial_capacity, index, self.growth);
        const rate = self.error_rate * std.math.pow(f64, self.tightening, @as(f64, @floatFromInt(index)));
        const filter = try BloomFilter.init(self.allocator, cap, rate);
        try self.layers.append(self.allocator, filter);
    }

    fn capacityOf(initial: u64, index: usize, growth: u32) u64 {
        var cap = initial;
        var i: usize = 0;
        while (i < index) : (i += 1) cap *%= @as(u64, growth);
        return cap;
    }

    pub fn mayContain(self: *const ScalableBloom, value: u64) bool {
        for (self.layers.items) |*layer| {
            if (layer.mayContain(value)) return true;
        }
        return false;
    }

    pub fn layerCount(self: *const ScalableBloom) usize {
        return self.layers.items.len;
    }

    pub fn totalInserted(self: *const ScalableBloom) u64 {
        var total: u64 = 0;
        for (self.layers.items) |*layer| total += layer.inserted;
        return total;
    }
};

pub const CountingBloom = struct {
    counters: []u16,
    hash_count: u32,
    allocator: std.mem.Allocator,
    inserted: u64 = 0,
    removed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, slots: u64, hash_count: u32) !CountingBloom {
        if (slots == 0 or hash_count == 0) return BloomError.InvalidCapacity;
        const counters = try allocator.alloc(u16, slots);
        @memset(counters, 0);
        return .{ .counters = counters, .hash_count = hash_count, .allocator = allocator };
    }

    pub fn deinit(self: *CountingBloom) void {
        self.allocator.free(self.counters);
    }

    pub fn add(self: *CountingBloom, value: u64) void {
        const base = hashing.mix64(value);
        for (0..self.hash_count) |i| {
            const index = @mod(base +% @as(u64, i) *% 0x9E3779B97F4A7C15, @as(u64, @intCast(self.counters.len)));
            if (self.counters[index] < 65535) self.counters[index] += 1;
        }
        self.inserted += 1;
    }

    pub fn remove(self: *CountingBloom, value: u64) void {
        const base = hashing.mix64(value);
        for (0..self.hash_count) |i| {
            const index = @mod(base +% @as(u64, i) *% 0x9E3779B97F4A7C15, @as(u64, @intCast(self.counters.len)));
            if (self.counters[index] > 0) self.counters[index] -= 1;
        }
        self.removed += 1;
    }

    pub fn contains(self: *const CountingBloom, value: u64) bool {
        const base = hashing.mix64(value);
        for (0..self.hash_count) |i| {
            const index = @mod(base +% @as(u64, i) *% 0x9E3779B97F4A7C15, @as(u64, @intCast(self.counters.len)));
            if (self.counters[index] == 0) return false;
        }
        return true;
    }

    pub fn loadFactor(self: *const CountingBloom) f64 {
        var used: u64 = 0;
        for (self.counters) |c| {
            if (c > 0) used += 1;
        }
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.counters.len));
    }
};
