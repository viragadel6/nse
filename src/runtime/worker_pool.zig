const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        items: []T,
        head: usize = 0,
        count: usize = 0,
        closed: bool = false,
        mutex: std.Thread.Mutex = .{},
        readable: std.Thread.Condition = .{},
        writable: std.Thread.Condition = .{},

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidQueueCapacity;
            return .{ .allocator = allocator, .items = try allocator.alloc(T, capacity) };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.QueueClosed;
            if (self.count == self.items.len) return error.QueueFull;
            self.items[(self.head + self.count) % self.items.len] = item;
            self.count += 1;
            self.readable.signal();
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count == 0 and !self.closed) self.readable.wait(&self.mutex);
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
            self.writable.signal();
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.readable.broadcast();
            self.writable.broadcast();
        }
    };
}
