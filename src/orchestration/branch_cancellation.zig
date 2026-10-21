const std = @import("std");
const cancellation = @import("../runtime/cancellation.zig");

pub const Branch = struct {
    id: u64,
    token: cancellation.Token,
    cancelled: bool = false,
};

pub const Manager = struct {
    branches: std.HashMap(u64, Branch),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return Manager{ .branches = std.HashMap(u64, Branch).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.branches.deinit();
    }

    pub fn spawn(self: *Manager) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const id = self.next_id;
        self.next_id += 1;
        _ = try self.branches.put(id, Branch{ .id = id, .token = .{}, .cancelled = false });
        return id;
    }

    pub fn cancel(self: *Manager, id: u64) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.branches.get(id)) |branch| {
            branch.value_ptr().*.cancelled = true;
            branch.value_ptr().*.token.cancel();
            return true;
        }
        return false;
    }

    pub fn isCancelled(self: *Manager, id: u64) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.branches.get(id) |branch| branch.value_ptr().*.cancelled else false;
    }
};
