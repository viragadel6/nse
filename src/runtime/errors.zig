const std = @import("std");
const time = @import("../util/time.zig");

pub const Subsystem = enum(u8) {
    runtime,
    configuration,
    network,
    storage,
    crawl,
    ingestion,
    model,
    training,
    index,
    scoring,
    retrieval,
    orchestration,
    highlights,
    cache,
    api,
    telemetry,
    gpu,
    deployment,
};

pub const Severity = enum(u8) {
    info,
    degraded,
    failure,
    fatal,
};

pub const EngineError = error{
    InvalidConfiguration,
    MissingConfiguration,
    IncompatibleVersion,
    NotInitialized,
    AlreadyInitialized,
    ShuttingDown,
    CapacityExceeded,
    Backpressure,
    QueueFull,
    Cancelled,
    DeadlineExceeded,
    ResourceUnavailable,
    DependencyUnavailable,
    CorruptRecord,
    TruncatedRecord,
    ChecksumMismatch,
    UnsupportedFormat,
    InvalidArgument,
    InvalidState,
    NotFound,
    AlreadyExists,
    OutOfMemory,
    DiskFull,
    NetworkUnreachable,
    ConnectionClosed,
    ProtocolError,
    TlsFailure,
    DnsFailure,
    Timeout,
    GpuUnavailable,
    ModelUnavailable,
    CheckpointIncompatible,
    ShardUnavailable,
    ReplicaDiverged,
    IndexGenerationConflict,
    SerializationFailure,
    DuplicateRecord,
    StaleRepresentation,
};

pub const Failure = struct {
    subsystem: Subsystem,
    operation: []const u8,
    code: []const u8,
    detail: []const u8,
    severity: Severity,
    retriable: bool,
    timestamp_ms: i64,

    pub fn record(self: Failure, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{{\"subsystem\":\"{s}\",\"operation\":\"{s}\",\"code\":\"{s}\",\"detail\":\"{s}\",\"severity\":\"{s}\",\"retriable\":{s},\"timestamp_ms\":{d}}}",
            .{
                @tagName(self.subsystem),
                self.operation,
                self.code,
                self.detail,
                @tagName(self.severity),
                if (self.retriable) "true" else "false",
                self.timestamp_ms,
            },
        );
    }
};

const transient_codes = [_][]const u8{
    "Timeout",
    "NetworkUnreachable",
    "ConnectionClosed",
    "DependencyUnavailable",
    "ResourceUnavailable",
    "ShardUnavailable",
    "GpuUnavailable",
    "Backpressure",
    "QueueFull",
    "CapacityExceeded",
    "TlsFailure",
    "DnsFailure",
    "DiskFull",
};

pub fn isRetriable(err: anyerror) bool {
    const name = @errorName(err);
    for (transient_codes) |code| {
        if (std.mem.eql(u8, code, name)) return true;
    }
    return false;
}

pub fn severityOf(err: anyerror) Severity {
    return switch (err) {
        error.Cancelled, error.DeadlineExceeded, error.Backpressure, error.QueueFull, error.CapacityExceeded => .info,
        error.CorruptRecord, error.TruncatedRecord, error.ChecksumMismatch, error.UnsupportedFormat, error.CheckpointIncompatible, error.ReplicaDiverged => .fatal,
        error.OutOfMemory, error.DiskFull, error.ModelUnavailable, error.GpuUnavailable => .failure,
        else => .degraded,
    };
}

pub fn classify(subsystem: Subsystem, operation: []const u8, err: anyerror) Failure {
    return .{
        .subsystem = subsystem,
        .operation = operation,
        .code = @errorName(err),
        .detail = @errorName(err),
        .severity = severityOf(err),
        .retriable = isRetriable(err),
        .timestamp_ms = time.nowMs(),
    };
}

pub fn withDetail(allocator: std.mem.Allocator, subsystem: Subsystem, operation: []const u8, err: anyerror, comptime fmt: []const u8, args: anytype) !Failure {
    var failure = classify(subsystem, operation, err);
    failure.detail = try std.fmt.allocPrint(allocator, fmt, args);
    return failure;
}

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    records: std.ArrayListUnmanaged(Failure) = .{},
    capacity: usize,
    total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Diagnostics {
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.records.items) |entry| {
            if (entry.detail.len > 0 and !isStaticCode(entry.detail)) self.allocator.free(entry.detail);
        }
        self.records.deinit(self.allocator);
    }

    fn isStaticCode(detail: []const u8) bool {
        inline for (transient_codes) |code| {
            if (detail.ptr == code.ptr) return true;
        }
        return false;
    }

    pub fn record(self: *Diagnostics, failure: Failure) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.items.len >= self.capacity) {
            const dropped = self.records.orderedRemove(0);
            if (dropped.detail.len > 0 and !isStaticCode(dropped.detail)) self.allocator.free(dropped.detail);
        }
        self.records.append(self.allocator, failure) catch return;
        self.total += 1;
    }

    pub fn recordError(self: *Diagnostics, subsystem: Subsystem, operation: []const u8, err: anyerror) void {
        self.record(classify(subsystem, operation, err));
    }

    pub fn snapshot(self: *Diagnostics, allocator: std.mem.Allocator) ![]Failure {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.alloc(Failure, self.records.items.len);
        var index: usize = 0;
        for (self.records.items) |entry| {
            out[index] = .{
                .subsystem = entry.subsystem,
                .operation = entry.operation,
                .code = entry.code,
                .detail = try allocator.dupe(u8, entry.detail),
                .severity = entry.severity,
                .retriable = entry.retriable,
                .timestamp_ms = entry.timestamp_ms,
            };
            index += 1;
        }
        return out;
    }

    pub fn count(self: *Diagnostics) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total;
    }
};

pub const RetryPolicy = struct {
    max_attempts: u32 = 4,
    base_delay_ms: u64 = 25,
    max_delay_ms: u64 = 2000,
    multiplier: f64 = 2.0,
    jitter_ratio: f64 = 0.2,
    retry_on_timeout: bool = true,

    pub fn validate(self: RetryPolicy) EngineError!void {
        if (self.max_attempts == 0) return EngineError.InvalidConfiguration;
        if (self.base_delay_ms == 0 or self.max_delay_ms < self.base_delay_ms) return EngineError.InvalidConfiguration;
        if (self.multiplier < 1.0) return EngineError.InvalidConfiguration;
        if (self.jitter_ratio < 0.0 or self.jitter_ratio > 1.0) return EngineError.InvalidConfiguration;
    }

    pub fn delayFor(self: RetryPolicy, attempt: u32) u64 {
        if (attempt == 0) return 0;
        const exponent = @as(f64, @floatFromInt(@min(attempt, 32)));
        const raw = @as(f64, @floatFromInt(self.base_delay_ms)) * std.math.pow(f64, self.multiplier, exponent);
        var delay: u64 = @intFromFloat(@min(raw, @as(f64, @floatFromInt(self.max_delay_ms))));
        if (self.jitter_ratio > 0) {
            const jitter = @as(f64, @floatFromInt(delay)) * self.jitter_ratio;
            const random = @as(f64, @floatFromInt(@mod(std.crypto.random.int(u64), 1000))) / 1000.0;
            delay = @intFromFloat(@as(f64, @floatFromInt(delay)) + (random - 0.5) * 2.0 * jitter);
        }
        return @max(1, delay);
    }

    pub fn shouldRetry(self: RetryPolicy, err: anyerror, attempt: u32) bool {
        if (attempt + 1 >= self.max_attempts) return false;
        if (err == error.Cancelled or err == error.DeadlineExceeded) return false;
        if (err == error.Timeout and !self.retry_on_timeout) return false;
        return isRetriable(err);
    }
};

pub const Backoff = struct {
    policy: RetryPolicy,
    attempt: u32 = 0,
    last_error: ?anyerror = null,

    pub fn init(policy: RetryPolicy) Backoff {
        return .{ .policy = policy };
    }

    pub fn nextDelay(self: *Backoff) u64 {
        const delay = self.policy.delayFor(self.attempt);
        self.attempt += 1;
        return delay;
    }

    pub fn note(self: *Backoff, err: anyerror) void {
        self.last_error = err;
    }

    pub fn reset(self: *Backoff) void {
        self.attempt = 0;
        self.last_error = null;
    }

    pub fn exhausted(self: *const Backoff) bool {
        return self.attempt >= self.policy.max_attempts;
    }
};

pub const CircuitState = enum(u8) {
    closed,
    open,
    probe,
};

pub const FailureTracker = struct {
    window_size: usize,
    failures: usize = 0,
    successes: usize = 0,
    consecutive: u32 = 0,
    threshold: u32,
    state: CircuitState = .closed,
    last_failure_ms: i64 = 0,

    pub fn init(window_size: usize, threshold: u32) FailureTracker {
        return .{ .window_size = window_size, .threshold = threshold };
    }

    pub fn noteFailure(self: *FailureTracker) void {
        self.failures += 1;
        self.consecutive += 1;
        self.last_failure_ms = time.nowMs();
        if (self.consecutive >= self.threshold) self.state = .open;
    }

    pub fn noteSuccess(self: *FailureTracker) void {
        self.successes += 1;
        self.consecutive = 0;
        if (self.state == .probe) self.state = .closed;
    }

    pub fn failureRate(self: *const FailureTracker) f64 {
        const total = self.failures + self.successes;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.failures)) / @as(f64, @floatFromInt(total));
    }

    pub fn allows(self: *FailureTracker, now_ms: i64) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                if (now_ms - self.last_failure_ms > 5000) {
                    self.state = .probe;
                    return true;
                }
                return false;
            },
            .probe => return true,
        }
    }
};

pub fn describe(err: anyerror) []const u8 {
    return @errorName(err);
}

pub fn errnoMessage(err: anyerror, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}", .{@errorName(err)}) catch "unknown";
}
