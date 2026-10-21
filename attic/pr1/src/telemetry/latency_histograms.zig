const std = @import("std");

pub const Histogram = struct {
    buckets: []u64,
    boundaries: []f64,
    count: u64 = 0,
    sum: f64 = 0,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, boundaries: []const f64) !Histogram {
        const buckets = try allocator.alloc(u64, boundaries.len + 1);
        for (buckets) |*bucket| bucket.* = 0;
        const boundaries_copy = try allocator.dup(f64, boundaries);
        return Histogram{ .buckets = buckets, .boundaries = boundaries_copy };
    }

    pub fn deinit(self: *Histogram, allocator: std.mem.Allocator) void {
        allocator.free(self.buckets);
        allocator.free(self.boundaries);
    }

    pub fn observe(self: *Histogram, value: f64) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.count += 1;
        self.sum += value;
        var i: usize = 0;
        while (i < self.boundaries.len) {
            if (value <= self.boundaries[i]) { self.buckets[i] += 1; break; }
            i += 1;
        }
        if (i == self.boundaries.len) self.buckets[self.boundaries.len] += 1;
    }

    pub fn percentile(self: *Histogram, p: f64) f64 {
        self.lock.lock();
        defer self.lock.unlock();
        var target = @as(f64, @intCast(self.count)) * p;
        var accumulated: f64 = 0;
        var i: usize = 0;
        while (i < self.boundaries.len) {
            accumulated += @as(f64, @intCast(self.buckets[i]));
            if (accumulated >= target) return self.boundaries[i];
            i += 1;
        }
        return self.boundaries[self.boundaries.len - 1];
    }
};
