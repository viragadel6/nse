const std = @import("std");

pub const Edge = struct {
    source: u64,
    target: u64,
    weight: f32 = 1.0,
    anchor_text: []const u8 = "",
    timestamp_ms: i64 = 0,
};

pub const Store = struct {
    edges: std.ArrayList(Edge),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return Store{ .edges = std.ArrayList(Edge).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.edges.items) |*edge| self.allocator.free(edge.anchor_text);
        self.edges.deinit();
    }

    pub fn add(self: *Store, source: u64, target: u64, weight: f32, anchor_text: []const u8, timestamp_ms: i64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.edges.append(Edge{ .source = source, .target = target, .weight = weight, .anchor_text = try self.allocator.dupe(u8, anchor_text), .timestamp_ms = timestamp_ms });
    }

    pub fn count(self: *Store) usize {
        self.lock.lock();
        const count = self.edges.items.len;
        self.lock.unlock();
        return count;
    }
};
