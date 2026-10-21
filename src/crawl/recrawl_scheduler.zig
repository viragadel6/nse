const std = @import("std");

pub const Policy = struct {
    base_interval_ms: i64 = 3600000,
    min_interval_ms: i64 = 300000,
    max_interval_ms: i64 = 604800000,
    volatility_weight: f64 = 1.0,
    freshness_weight: f64 = 1.0,
};

pub const Scheduler = struct {
    policy: Policy,
    domain_scores: std.StringHashMap(f64),

    pub fn init(policy: Policy) Scheduler {
        return Scheduler{ .policy = policy, .domain_scores = std.StringHashMap(f64).init(std.heap.page_allocator) };
    }

    pub fn deinit(self: *Scheduler) void {
        self.domain_scores.deinit();
    }

    pub fn nextInterval(self: *Scheduler, domain: []const u8, changed: bool, volatility: f64, now: i64) i64 {
        var score: f64 = 1.0;
        if (self.domain_scores.contains(domain)) score = self.domain_scores.get(domain).?;
        if (changed) score += self.policy.volatility_weight * volatility;
        var interval = @as(i64, @f2u(i64, @as(f64, @intCast(self.policy.base_interval_ms)) * (1.0 / (score + 1.0))));
        if (interval < self.policy.min_interval_ms) interval = self.policy.min_interval_ms;
        if (interval > self.policy.max_interval_ms) interval = self.policy.max_interval_ms;
        return interval;
    }
};
