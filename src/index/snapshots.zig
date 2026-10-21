const std = @import("std");

pub const Snapshot = struct {
    generation: u64,
    path: []const u8,
    document_count: u64,
    created_at: i64,
};

pub const Manager = struct {
    snapshots: std.ArrayList(Snapshot),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return Manager{ .snapshots = std.ArrayList(Snapshot).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.snapshots.items) |*snapshot| self.allocator.free(snapshot.path);
        self.snapshots.deinit();
    }

    pub fn record(self: *Manager, generation: u64, path: []const u8, document_count: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.snapshots.append(Snapshot{ .generation = generation, .path = path, .document_count = document_count, .created_at = std.time.milliTimestamp(std.time.Clock.wall()) catch 0 });
    }

    pub fn latest(self: *Manager) ?*Snapshot {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.snapshots.items.len == 0) return null;
        return &self.snapshots.items[self.snapshots.items.len - 1];
    }
};
