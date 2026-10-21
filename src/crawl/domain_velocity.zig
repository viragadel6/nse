const std = @import("std");

pub const VelocityEstimate = struct {
    fetch_count: u64 = 0,
    change_count: u64 = 0,
    last_change_ms: i64 = 0,
    volatility: f64 = 0,
};

pub const DomainVelocity = struct {
    estimates: std.StringHashMap(VelocityEstimate),
    lock: std.Thread.Mutex,

    pub fn init() DomainVelocity {
        return DomainVelocity{ .estimates = std.StringHashMap(VelocityEstimate).init(std.heap.page_allocator), .lock = .{} };
    }

    pub fn deinit(self: *DomainVelocity) void {
        self.estimates.deinit();
    }

    pub fn observe(self: *DomainVelocity, domain: []const u8, changed: bool, now: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        var estimate = self.estimates.getOrPut(domain, .{}) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => return,
        };
        estimate.value.fetch_count += 1;
        if (changed) {
            estimate.value.change_count += 1;
            estimate.value.last_change_ms = now;
            const elapsed = @as(f64, @intCast(now - estimate.value.last_change_ms));
            estimate.value.volatility = estimate.value.volatility * 0.9 + 0.1;
        } else {
            estimate.value.volatility = estimate.value.volatility * 0.95;
        }
    }

    pub fn volatility(self: *DomainVelocity, domain: []const u8) f64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.estimates.get(domain) |estimate| estimate.volatility else 0;
    }
};
