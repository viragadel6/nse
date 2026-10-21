const std = @import("std");

pub const DriftSignal = struct {
    metric: []const u8,
    baseline: f64,
    current: f64,
    drift: f64,
    threshold: f64,
    triggered: bool,
    timestamp_ms: i64,
};

pub const Detector = struct {
    threshold: f64 = 0.15,
    lock: std.Thread.Mutex,
    signals: std.ArrayList(DriftSignal),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, threshold: f64) Detector {
        return Detector{ .threshold = threshold, .lock = .{}, .signals = std.ArrayList(DriftSignal).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Detector) void {
        for (self.signals.items) |*signal| self.allocator.free(signal.metric);
        self.signals.deinit();
    }

    pub fn evaluate(self: *Detector, metric: []const u8, baseline: f64, current: f64, timestamp_ms: i64) DriftSignal {
        self.lock.lock();
        defer self.lock.unlock();
        const drift = if (baseline != 0) @abs(current - baseline) / @abs(baseline) else 0;
        const triggered = drift > self.threshold;
        const signal = DriftSignal{ .metric = try self.allocator.dupe(u8, metric), .baseline = baseline, .current = current, .drift = drift, .threshold = self.threshold, .triggered = triggered, .timestamp_ms = timestamp_ms };
        _ = try self.signals.append(signal);
        return signal;
    }
};
