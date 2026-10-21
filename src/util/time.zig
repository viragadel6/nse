const std = @import("std");

pub fn nowMs() i64 {
    return std.time.milliTimestamp(std.time.Clock.wall()) catch 0;
}

pub fn nowMonotonicMs() i64 {
    return std.time.milliTimestamp(std.time.Clock.monotonic()) catch 0;
}

pub const Deadline = struct {
    deadline_ms: i64,

    pub fn init(timeout_ms: u64) Deadline {
        return Deadline{ .deadline_ms = nowMs() + @as(i64, @intCast(timeout_ms)) };
    }

    pub fn remainingMs(self: *const Deadline) i64 {
        return self.deadline_ms - nowMs();
    }

    pub fn exceeded(self: *const Deadline) bool {
        return self.remainingMs() <= 0;
    }

    pub fn check(self: *const Deadline) !void {
        if (self.exceeded()) return error.DeadlineExceeded;
    }
};
