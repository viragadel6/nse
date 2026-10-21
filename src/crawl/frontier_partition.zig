const std = @import("std");
const hashing = @import("../../util/hashing.zig");

pub const PartitionId = u32;

pub fn partitionUrl(url: []const u8, partition_count: u32) PartitionId {
    return @as(u32, @intCast(hashing.fnv1a_64(url) % @as(u64, @intCast(partition_count))));
}

pub const PartitionMap = struct {
    partitions: []u64,
    count: u32,

    pub fn init(allocator: std.mem.Allocator, count: u32) !PartitionMap {
        const partitions = try allocator.alloc(u64, @intCast(count));
        for (partitions) |*p| p.* = 0;
        return PartitionMap{ .partitions = partitions, .count = count };
    }

    pub fn deinit(self: *PartitionMap, allocator: std.mem.Allocator) void {
        allocator.free(self.partitions);
    }

    pub fn record(self: *PartitionMap, partition: PartitionId, record_bytes: u64) void {
        self.partitions[@intCast(partition)] += record_bytes;
    }

    pub fn skew(self: *const PartitionMap) f64 {
        var max: u64 = 0;
        var total: u64 = 0;
        var i: u32 = 0;
        while (i < self.count) {
            const value = self.partitions[@intCast(i)];
            if (value > max) max = value;
            total += value;
            i += 1;
        }
        if (total == 0) return 0;
        return @as(f64, @intCast(max)) / (@as(f64, @intCast(total)) / @as(f64, @intCast(self.count)));
    }
};
