const std = @import("std");

pub const Checkpoint = struct {
    version: u64,
    path: []const u8,
    checksum: [32]u8,
    created_at: i64,
};

pub const Store = struct {
    checkpoints: std.ArrayList(Checkpoint),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return Store{ .checkpoints = std.ArrayList(Checkpoint).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.checkpoints.items) |*checkpoint| self.allocator.free(checkpoint.path);
        self.checkpoints.deinit();
    }

    pub fn record(self: *Store, version: u64, path: []const u8, checksum: [32]u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.checkpoints.append(Checkpoint{ .version = version, .path = try self.allocator.dupe(u8, path), .checksum = checksum, .created_at = std.time.milliTimestamp(std.time.Clock.wall()) catch 0 });
    }

    pub fn latest(self: *Store) ?*Checkpoint {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.checkpoints.items.len == 0) return null;
        return &self.checkpoints.items[self.checkpoints.items.len - 1];
    }
};
