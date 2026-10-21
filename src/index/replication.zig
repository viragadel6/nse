const std = @import("std");

pub const Replica = struct {
    node_id: []const u8,
    shard_id: u32,
    lag_ms: i64 = 0,
    healthy: bool = true,
};

pub const Coordinator = struct {
    replicas: std.ArrayList(Replica),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Coordinator {
        return Coordinator{ .replicas = std.ArrayList(Replica).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Coordinator) void {
        self.replicas.deinit();
    }

    pub fn addReplica(self: *Coordinator, node_id: []const u8, shard_id: u32) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.replicas.append(Replica{ .node_id = node_id, .shard_id = shard_id });
    }

    pub fn lag(self: *Coordinator, shard_id: u32) i64 {
        self.lock.lock();
        defer self.lock.unlock();
        var max: i64 = 0;
        for (self.replicas.items) |replica| if (replica.shard_id == shard_id and replica.lag_ms > max) max = replica.lag_ms;
        return max;
    }
};
