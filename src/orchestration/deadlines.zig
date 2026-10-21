const std = @import("std");
const cancellation = @import("../runtime/cancellation.zig");

pub const BranchDeadline = struct {
    deadline: cancellation.Deadline,
    budget_ms: u32,
    consumed_ms: i64 = 0,

    pub fn init(total_ms: u32, share_ms: u32) BranchDeadline {
        return BranchDeadline{ .deadline = cancellation.Deadline.init(total_ms), .budget_ms = share_ms };
    }

    pub fn check(self: *BranchDeadline) !void {
        try self.deadline.check();
    }

    pub fn expired(self: *BranchDeadline) bool {
        return self.deadline.exceeded();
    }
};
