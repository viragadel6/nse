const std = @import("std");
const sketches = @import("../util/sketches.zig");

pub const Signal = struct {
    term: []const u8,
    novelty: f32,
    timestamp_ms: i64,
};

pub const Detector = struct {
    vocabulary: std.StringHashMap(void),
    sketches: sketches.CountMinSketch,
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Detector {
        const sketch = try sketches.CountMinSketch.init(allocator, 16, 1024);
        return Detector{ .vocabulary = std.StringHashMap(void).init(allocator), .sketches = sketch, .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Detector) void {
        self.vocabulary.deinit();
        self.sketches.deinit(self.allocator);
    }

    pub fn observe(self: *Detector, term: []const u8, timestamp_ms: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = self.sketches;
        _ = timestamp_ms;
        if (self.vocabulary.contains(term)) return;
        _ = try self.vocabulary.put(try self.allocator.dupe(u8, term), {});
    }

    pub fn novelty(self: *Detector, term: []const u8) f32 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.vocabulary.contains(term)) return 0;
        return 1.0;
    }
};
