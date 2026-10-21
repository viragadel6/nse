const std = @import("std");

pub const Signal = struct {
    name: []const u8,
    value: f64,
    timestamp_ms: i64,
    anomaly: bool,
    z_score: f64,
};

pub const Detector = struct {
    window: []f64,
    capacity: usize,
    count: usize = 0,
    head: usize = 0,
    threshold: f64 = 3.5,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, threshold: f64) !Detector {
        const window = try allocator.alloc(f64, capacity);
        return Detector{ .window = window, .capacity = capacity, .threshold = threshold, .lock = .{} };
    }

    pub fn deinit(self: *Detector, allocator: std.mem.Allocator) void {
        allocator.free(self.window);
    }

    pub fn observe(self: *Detector, value: f64, timestamp_ms: i64) Signal {
        self.lock.lock();
        defer self.lock.unlock();
        var mean: f64 = 0;
        var i: usize = 0;
        while (i < self.count) { mean += self.window[i]; i += 1; }
        mean = mean / @as(f64, @intCast(@max(self.count, 1)));
        var variance: f64 = 0;
        i = 0;
        while (i < self.count) { variance += (self.window[i] - mean) * (self.window[i] - mean); i += 1; }
        variance = variance / @as(f64, @intCast(@max(self.count, 1)));
        const std_dev = @sqrt(variance);
        const z_score = if (std_dev > 0) @abs(value - mean) / std_dev else 0;
        const anomaly = z_score > self.threshold;
        self.window[self.head] = value;
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
        return Signal{ .name = "", .value = value, .timestamp_ms = timestamp_ms, .anomaly = anomaly, .z_score = z_score };
    }
};
