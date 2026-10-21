const std = @import("std");

pub const Manager = struct {
    tombstones: std.HashMap(u64, []u8),
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return Manager{ .tombstones = std.HashMap(u64, []u8).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.tombstones.iterator()) |*entry| self.allocator.free(entry.value_ptr().*);
        self.tombstones.deinit();
    }

    pub fn delete(self: *Manager, document_id: u64, reason: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.tombstones.put(document_id, try self.allocator.dupe(u8, reason));
    }

    pub fn isDeleted(self: *Manager, document_id: u64) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.tombstones.contains(document_id);
    }

    pub fn purge(self: *Manager, document_id: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.tombstones.remove(document_id)) |reason| self.allocator.free(reason);
    }
};
