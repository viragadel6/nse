const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const PartitionerError = error{
    NoShards,
    InvalidWeight,
    UnknownShard,
};

pub const Shard = struct {
    id: u32,
    node: u32,
    weight: f64 = 1.0,
    capacity_documents: u64 = 1 << 40,
    documents: u64 = 0,
    state: State = .active,

    pub const State = enum(u8) {
        active,
        draining,
        sealed,
        offline,
    };

    pub fn utilization(self: *const Shard) f64 {
        if (self.capacity_documents == 0) return 1.0;
        return @as(f64, @floatFromInt(self.documents)) / @as(f64, @floatFromInt(self.capacity_documents));
    }
};

pub const Partitioner = struct {
    allocator: std.mem.Allocator,
    shards: []Shard,
    replica_count: u32,
    mutex: std.Thread.Mutex = .{},
    placements: u64 = 0,
    rebalances: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, shard_count: u32, replica_count: u32) !Partitioner {
        if (shard_count == 0) return PartitionerError.NoShards;
        const shards = try allocator.alloc(Shard, shard_count);
        for (shards, 0..) |*shard, index| {
            shard.* = .{ .id = @intCast(index), .node = @intCast(index) };
        }
        return .{ .allocator = allocator, .shards = shards, .replica_count = replica_count };
    }

    pub fn deinit(self: *Partitioner) void {
        self.allocator.free(self.shards);
    }

    pub fn shardCount(self: *const Partitioner) u32 {
        return @intCast(self.shards.len);
    }

    pub fn setWeight(self: *Partitioner, shard_id: u32, weight: f64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (shard_id >= self.shards.len) return PartitionerError.UnknownShard;
        if (weight <= 0.0) return PartitionerError.InvalidWeight;
        self.shards[shard_id].weight = weight;
    }

    pub fn setNode(self: *Partitioner, shard_id: u32, node: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (shard_id >= self.shards.len) return PartitionerError.UnknownShard;
        self.shards[shard_id].node = node;
    }

    pub fn setState(self: *Partitioner, shard_id: u32, state: Shard.State) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (shard_id >= self.shards.len) return PartitionerError.UnknownShard;
        self.shards[shard_id].state = state;
    }

    pub fn assign(self: *Partitioner, key: u64) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.placements += 1;
        return hashing.jumpConsistent(key, @intCast(self.shards.len));
    }

    pub fn assignWeighted(self: *Partitioner, key: u64) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var best_index: u32 = 0;
        var best_score: f64 = -1.0;
        for (self.shards, 0..) |shard, index| {
            if (shard.state != .active) continue;
            const mixing = @as(f64, @floatFromInt(hashing.mix64(key ^ (@as(u64, index) *% 0x9E3779B97F4A7C15)))) / @as(f64, @floatFromInt(std.math.maxInt(u64)));
            const score = shard.weight * (1.0 - shard.utilization()) * (mixing + 0.001);
            if (score > best_score) {
                best_score = score;
                best_index = @intCast(index);
            }
        }
        self.placements += 1;
        return best_index;
    }

    pub fn replicasFor(self: *Partitioner, key: u64) ![]u32 {
        const count = @min(self.replica_count, @as(u32, @intCast(self.shards.len)));
        const out = try self.allocator.alloc(u32, count);
        const primary = try self.assign(key);
        if (count == 0) return out;
        out[0] = primary;
        var chosen: usize = 1;
        var offset: u64 = 1;
        while (chosen < count) : (offset += 1) {
            var candidate = try self.assign(key ^ (offset *% 0xBF58476D1CE4E5B9));
            var duplicate = false;
            for (out[0..chosen]) |existing| {
                if (existing == candidate) duplicate = true;
            }
            if (duplicate) {
                if (offset > 1000) {
                    candidate = @intCast(@mod(@as(u64, primary) + offset, @as(u64, @intCast(self.shards.len))));
                } else {
                    continue;
                }
            }
            out[chosen] = candidate;
            chosen += 1;
        }
        return out;
    }

    pub fn noteDocuments(self: *Partitioner, shard_id: u32, count: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (shard_id >= self.shards.len) return PartitionerError.UnknownShard;
        self.shards[shard_id].documents += count;
    }

    pub const Movement = struct {
        shard_from: u32,
        shard_to: u32,
        documents: u64,
    };

    pub fn planRebalance(self: *Partitioner, tolerance: f64) ![]Movement {
        self.mutex.lock();
        defer self.mutex.unlock();
        var movements = std.ArrayList(Movement).init(self.allocator);
        var total_weight: f64 = 0.0;
        var total_documents: u64 = 0;
        for (self.shards) |shard| {
            if (shard.state != .active) continue;
            total_weight += shard.weight;
            total_documents += shard.documents;
        }
        if (total_weight <= 0.0) return movements.toOwnedSlice();
        var donors = std.ArrayList(u32).init(self.allocator);
        defer donors.deinit();
        var receivers = std.ArrayList(u32).init(self.allocator);
        defer receivers.deinit();
        for (self.shards, 0..) |shard, index| {
            if (shard.state != .active) continue;
            const target = @as(f64, @floatFromInt(total_documents)) * (shard.weight / total_weight);
            const actual = @as(f64, @floatFromInt(shard.documents));
            const deviation = if (target > 0.0) (actual - target) / target else 0.0;
            if (deviation > tolerance) try donors.append(@intCast(index));
            if (deviation < -tolerance) try receivers.append(@intCast(index));
        }
        for (donors.items) |donor| {
            for (receivers.items) |receiver| {
                const donor_target = @as(f64, @floatFromInt(total_documents)) * (self.shards[donor].weight / total_weight);
                const receiver_target = @as(f64, @floatFromInt(total_documents)) * (self.shards[receiver].weight / total_weight);
                const donor_excess: i64 = @intFromFloat(@max(0.0, @as(f64, @floatFromInt(self.shards[donor].documents)) - donor_target));
                const receiver_deficit: i64 = @intFromFloat(@max(0.0, receiver_target - @as(f64, @floatFromInt(self.shards[receiver].documents))));
                const amount = @min(donor_excess, receiver_deficit);
                if (amount <= 0) continue;
                try movements.append(.{ .shard_from = donor, .shard_to = receiver, .documents = @intCast(amount) });
                self.shards[donor].documents -= @intCast(amount);
                self.shards[receiver].documents += @intCast(amount);
            }
        }
        self.rebalances += 1;
        return movements.toOwnedSlice();
    }

    pub fn addShard(self: *Partitioner, node: u32, weight: f64) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const shards = try self.allocator.realloc(self.shards, self.shards.len + 1);
        shards[shards.len - 1] = .{ .id = @intCast(shards.len - 1), .node = node, .weight = weight };
        self.shards = shards;
        return @intCast(shards.len - 1);
    }

    pub fn distribution(self: *Partitioner, keys: []const u64) ![]u64 {
        const counts = try self.allocator.alloc(u64, self.shards.len);
        @memset(counts, 0);
        for (keys) |key| {
            const shard = hashing.jumpConsistent(key, @intCast(self.shards.len));
            counts[shard] += 1;
        }
        return counts;
    }

    pub fn stats(self: *Partitioner) PartitionerStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        var documents: u64 = 0;
        var max_utilization: f64 = 0.0;
        var min_utilization: f64 = 1.0;
        for (self.shards) |shard| {
            documents += shard.documents;
            const utilization = shard.utilization();
            if (utilization > max_utilization) max_utilization = utilization;
            if (utilization < min_utilization) min_utilization = utilization;
        }
        return .{
            .shards = self.shards.len,
            .replicas = self.replica_count,
            .documents = documents,
            .placements = self.placements,
            .rebalances = self.rebalances,
            .skew = max_utilization - min_utilization,
        };
    }
};

pub const PartitionerStats = struct {
    shards: usize,
    replicas: u32,
    documents: u64,
    placements: u64,
    rebalances: u64,
    skew: f64,
};
