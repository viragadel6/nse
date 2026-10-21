const std = @import("std");

pub const Health = struct {
    generation: u64,
    document_count: u64,
    embedded_count: u64,
    shard_count: u32,
    healthy_shards: u32,
    replication_lag_ms: i64,
    centroid_imbalance: f32,
    tombstone_ratio: f32,
};

pub const Monitor = struct {
    shards: std.ArrayList(struct { id: u32, healthy: bool, lag_ms: i64 }),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Monitor {
        return Monitor{ .shards = std.ArrayList(struct { id: u32, healthy: bool, lag_ms: i64 }).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Monitor) void {
        self.shards.deinit();
    }

    pub fn report(self: *Monitor, shard_id: u32, healthy: bool, lag_ms: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        var found = false;
        for (self.shards.items) |*shard| if (shard.id == shard_id) { shard.healthy = healthy; shard.lag_ms = lag_ms; found = true; break; }
        if (!found) _ = try self.shards.append({ .id = shard_id, .healthy = healthy, .lag_ms = lag_ms });
    }

    pub fn snapshot(self: *Monitor) Health {
        self.lock.lock();
        defer self.lock.unlock();
        var healthy: u32 = 0;
        var max_lag: i64 = 0;
        for (self.shards.items) |shard| {
            if (shard.healthy) healthy += 1;
            if (shard.lag_ms > max_lag) max_lag = shard.lag_ms;
        }
        return Health{ .generation = 1, .document_count = 0, .embedded_count = 0, .shard_count = @as(u32, @intCast(self.shards.items.len)), .healthy_shards = healthy, .replication_lag_ms = max_lag, .centroid_imbalance = 0, .tombstone_ratio = 0 };
    }
};
