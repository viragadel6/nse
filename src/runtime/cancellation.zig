const std = @import("std");

pub const Token = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *Token) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const Token) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Deadline = struct {
    started: std.time.Instant,
    budget_ns: u64,
    cancellation: ?*const Token = null,

    pub fn init(milliseconds: u32, cancellation: ?*const Token) !Deadline {
        return .{ .started = try std.time.Instant.now(), .budget_ns = @as(u64, milliseconds) * std.time.ns_per_ms, .cancellation = cancellation };
    }

    pub fn elapsed(self: Deadline) !u64 {
        return (try std.time.Instant.now()).since(self.started);
    }

    pub fn remainingMilliseconds(self: Deadline) !u32 {
        try self.check();
        const remaining = self.budget_ns -| try self.elapsed();
        return @intCast(@max(1, @min(std.math.maxInt(u32), remaining / std.time.ns_per_ms)));
    }

    pub fn check(self: Deadline) !void {
        if (self.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        if (try self.elapsed() >= self.budget_ns) return error.DeadlineExceeded;
    }
};
