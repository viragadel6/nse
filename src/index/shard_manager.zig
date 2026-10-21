const std = @import("std");

pub const Shard = struct {
    id: u32,
    leader: bool,
    replica_count: u32,
    document_count: u64,
    read_only: bool = false,
};

pub const Manager = struct {
    shards: std.ArrayList(Shard),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return Manager{ .shards = std.ArrayList(Shard).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.shards.deinit();
    }

    pub fn addShard(self: *Manager, id: u32, leader: bool, replica_count: u32) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.shards.append(Shard{ .id = id, .leader = leader, .replica_count = replica_count });
    }

    pub fn leaderFor(self: *Manager, id: u32) ?*Shard {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.shards.items) |*shard| if (shard.id == id and shard.leader) return shard;
        return null;
    }

    pub fn rebalance(self: *Manager) void {
        self.lock.lock();
        defer self.lock.unlock();
    }

    pub fn count(self: *Manager) usize {
        self.lock.lock();
        const count = self.shards.items.len;
        self.lock.unlock();
        return count;
    }
};
