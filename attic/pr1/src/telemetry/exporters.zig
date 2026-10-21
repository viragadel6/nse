const std = @import("std");

pub const Exporter = struct {
    endpoint: []const u8,
    interval_ms: u64,
    lock: std.Thread.Mutex,
    buffered: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, interval_ms: u64) !Exporter {
        return Exporter{ .endpoint = try allocator.dupe(u8, endpoint), .interval_ms = interval_ms, .lock = .{}, .buffered = std.ArrayList([]u8).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Exporter) void {
        for (self.buffered.items) |buffer| self.allocator.free(buffer);
        self.buffered.deinit();
        self.allocator.free(self.endpoint);
    }

    pub fn export(self: *Exporter, event: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.buffered.append(try self.allocator.dupe(u8, event));
    }

    pub fn flush(self: *Exporter) !void {
        self.lock.lock();
        defer self.lock.unlock();
        while (self.buffered.items.len > 0) {
            const event = self.buffered.items.pop();
            self.allocator.free(event);
        }
    }
};
