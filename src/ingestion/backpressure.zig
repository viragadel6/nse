const std = @import("std");
const time = @import("../util/time.zig");

pub const Decision = enum(u8) {
    admit,
    defer_admission,
    reject,
};

pub const TokenBucket = struct {
    capacity: f64,
    tokens: f64,
    refill_per_ms: f64,
    last_ms: i64,
    mutex: std.Thread.Mutex = .{},
    granted: u64 = 0,
    denied: u64 = 0,

    pub fn init(rate_per_second: f64, capacity: f64) TokenBucket {
        const now = time.monotonicMs();
        return .{
            .capacity = capacity,
            .tokens = capacity,
            .refill_per_ms = rate_per_second / 1000.0,
            .last_ms = @intCast(now),
            .granted = 0,
            .denied = 0,
        };
    }

    pub fn consume(self: *TokenBucket, amount: f64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now: i64 = @intCast(time.monotonicMs());
        const elapsed: f64 = @as(f64, @floatFromInt(now - self.last_ms));
        self.last_ms = now;
        self.tokens = @min(self.capacity, self.tokens + elapsed * self.refill_per_ms);
        if (self.tokens < amount) {
            self.denied += 1;
            return false;
        }
        self.tokens -= amount;
        self.granted += 1;
        return true;
    }

    pub fn available(self: *TokenBucket) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tokens;
    }
};

pub const Watermarks = struct {
    low: usize,
    high: usize,
    limit: usize,

    pub fn ratio(self: *const Watermarks, depth: usize) f64 {
        if (self.high == 0) return 0.0;
        return @as(f64, @floatFromInt(depth)) / @as(f64, @floatFromInt(self.high));
    }
};

pub const Controller = struct {
    bucket: TokenBucket,
    watermarks: Watermarks,
    depth: usize = 0,
    bytes_in_flight: usize = 0,
    max_bytes_in_flight: usize,
    mutex: std.Thread.Mutex = .{},
    admitted: u64 = 0,
    deferred: u64 = 0,
    rejected: u64 = 0,
    completions: u64 = 0,
    latency_estimate_ms: f64 = 1.0,
    batch_size: usize = 32,
    min_batch_size: usize = 1,
    max_batch_size: usize = 4096,

    pub fn init(rate_per_second: f64, burst: f64, watermarks: Watermarks, max_bytes_in_flight: usize) Controller {
        return .{
            .bucket = TokenBucket.init(rate_per_second, burst),
            .watermarks = watermarks,
            .max_bytes_in_flight = max_bytes_in_flight,
        };
    }

    pub fn admit(self: *Controller, weight: f64, bytes: usize) Decision {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.depth >= self.watermarks.limit or self.bytes_in_flight + bytes > self.max_bytes_in_flight) {
            self.rejected += 1;
            return .reject;
        }
        if (self.depth >= self.watermarks.high) {
            self.deferred += 1;
            return .defer_admission;
        }
        if (!self.bucket.consume(weight)) {
            if (self.depth >= self.watermarks.high) {
                self.rejected += 1;
                return .reject;
            }
            self.deferred += 1;
            return .defer_admission;
        }
        self.depth += 1;
        self.bytes_in_flight += bytes;
        self.admitted += 1;
        return .admit;
    }

    pub fn complete(self: *Controller, bytes: usize, latency_ms: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.depth -|= 1;
        self.bytes_in_flight -|= bytes;
        self.completions += 1;
        self.latency_estimate_ms = self.latency_estimate_ms * 0.9 + latency_ms * 0.1;
        self.batch_size = @min(self.max_batch_size, @max(self.min_batch_size, @divFloor(self.batch_size * 2, 3) + @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.depth)) / 4.0))));
    }

    pub fn currentBatchSize(self: *Controller) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.batch_size;
    }

    pub fn depthRatio(self: *Controller) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.watermarks.ratio(self.depth);
    }

    pub fn waitMs(self: *Controller) u64 {
        const ratio = self.depthRatio();
        if (ratio <= 0.5) return 0;
        if (ratio >= 1.0) return 25;
        return @intFromFloat((ratio - 0.5) * 50.0);
    }

    pub fn stats(self: *Controller) ControllerStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .depth = self.depth,
            .bytes_in_flight = self.bytes_in_flight,
            .admitted = self.admitted,
            .deferred = self.deferred,
            .rejected = self.rejected,
            .completions = self.completions,
            .latency_estimate_ms = self.latency_estimate_ms,
            .batch_size = self.batch_size,
            .tokens = self.bucket.tokens,
        };
    }
};

pub const ControllerStats = struct {
    depth: usize,
    bytes_in_flight: usize,
    admitted: u64,
    deferred: u64,
    rejected: u64,
    completions: u64,
    latency_estimate_ms: f64,
    batch_size: usize,
    tokens: f64,
};
