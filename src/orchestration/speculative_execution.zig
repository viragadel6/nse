const std = @import("std");

pub const Speculation = struct {
    enabled: bool = true,
    cost_limit_ms: u32 = 2000,
    expected_benefit_ms: u32 = 5000,

    pub fn shouldSpeculate(self: *const Speculation, estimated_cost_ms: u32, expected_benefit_ms: u32) bool {
        if (!self.enabled) return false;
        if (estimated_cost_ms > self.cost_limit_ms) return false;
        return expected_benefit_ms > estimated_cost_ms;
    }
};
