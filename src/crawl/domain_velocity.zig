const std = @import("std");
const time = @import("../util/time.zig");

pub const VelocityError = error{
    UnknownDomain,
    InvalidWindow,
};

pub const Observation = struct {
    domain_hash: u64,
    changed: bool,
    observed_ms: i64,
    content_fingerprint: u64,
    token_count: u32,
    has_publication_date: bool,
};

pub const DomainProfile = struct {
    domain_hash: u64,
    fetch_count: u32 = 0,
    change_count: u32 = 0,
    change_rate: f64 = 0.05,
    publication_rate: f64 = 0.0,
    volatility: f64 = 0.0,
    last_change_ms: i64 = 0,
    last_observed_ms: i64 = 0,
    average_interval_ms: f64 = 86400000.0,
    link_growth: f64 = 0.0,
    content_length_mean: f64 = 0.0,
    content_length_variance: f64 = 0.0,
    fingerprint_history: [8]u64 = @splat(0),
    fingerprint_position: u8 = 0,
    burst_score: f64 = 0.0,
    quality_prior: f64 = 0.5,

    pub fn changeProbability(self: *const DomainProfile, now_ms: i64) f64 {
        const age_hours = @as(f64, @floatFromInt(@max(0, now_ms - self.last_observed_ms))) / 3600000.0;
        const interval_hours = @max(0.001, self.average_interval_ms / 3600000.0);
        const elapsed_ratio = age_hours / interval_hours;
        const base = @min(1.0, self.change_rate * (0.25 + 0.75 * @min(4.0, elapsed_ratio)));
        return @min(1.0, base + 0.2 * self.burst_score);
    }

    pub fn recommendedInterval(self: *const DomainProfile, min_interval_ms: u64, max_interval_ms: u64) u64 {
        const rate = @max(0.0005, self.change_rate);
        const raw = self.average_interval_ms / (0.25 + 4.0 * rate);
        return @min(max_interval_ms, @max(min_interval_ms, @as(u64, @intFromFloat(raw))));
    }

    pub fn fingerprintDiversity(self: *const DomainProfile) f64 {
        var unique: usize = 0;
        var outer: usize = 0;
        while (outer < self.fingerprint_history.len) : (outer += 1) {
            if (self.fingerprint_history[outer] == 0) continue;
            var distinct = true;
            var inner: usize = 0;
            while (inner < outer) : (inner += 1) {
                if (self.fingerprint_history[inner] == self.fingerprint_history[outer]) distinct = false;
            }
            if (distinct) unique += 1;
        }
        if (unique == 0) return 0.0;
        return @as(f64, @floatFromInt(unique)) / @as(f64, @floatFromInt(self.fingerprint_history.len));
    }
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    profiles: std.AutoHashMapUnmanaged(u64, DomainProfile) = .{},
    mutex: std.Thread.Mutex = .{},
    window_ms: u64,
    observations: u64 = 0,
    changes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, window_ms: u64) Tracker {
        return .{ .allocator = allocator, .window_ms = window_ms };
    }

    pub fn deinit(self: *Tracker) void {
        self.profiles.deinit(self.allocator);
    }

    pub fn observe(self: *Tracker, observation: Observation) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = try self.profiles.getOrPut(self.allocator, observation.domain_hash);
        if (!entry.found_existing) entry.value_ptr.* = .{ .domain_hash = observation.domain_hash };
        const entry_profile = entry.value_ptr;
        const previous_observation = entry_profile.last_observed_ms;
        entry_profile.fetch_count += 1;
        entry_profile.last_observed_ms = observation.observed_ms;
        if (observation.changed) {
            entry_profile.change_count += 1;
            entry_profile.last_change_ms = observation.observed_ms;
            self.changes += 1;
        }
        self.observations += 1;
        if (previous_observation > 0) {
            const delta = @as(f64, @floatFromInt(@max(0, observation.observed_ms - previous_observation)));
            entry_profile.average_interval_ms = entry_profile.average_interval_ms * 0.8 + delta * 0.2;
        }
        const window_fetches = @max(1.0, @as(f64, @floatFromInt(@min(entry_profile.fetch_count, 128))));
        entry_profile.change_rate = entry_profile.change_rate * 0.7 + (@as(f64, @floatFromInt(entry_profile.change_count)) / window_fetches) * 0.3;
        entry_profile.fingerprint_history[entry_profile.fingerprint_position % entry_profile.fingerprint_history.len] = observation.content_fingerprint;
        entry_profile.fingerprint_position +%= 1;
        const previous_mean = entry_profile.content_length_mean;
        entry_profile.content_length_mean = previous_mean + (@as(f64, @floatFromInt(observation.token_count)) - previous_mean) / window_fetches;
        const deviation = @as(f64, @floatFromInt(observation.token_count)) - entry_profile.content_length_mean;
        entry_profile.content_length_variance = entry_profile.content_length_variance * 0.9 + (deviation * deviation) * 0.1;
        entry_profile.volatility = entry_profile.fingerprintDiversity();
        if (observation.has_publication_date) entry_profile.publication_rate = entry_profile.publication_rate * 0.95 + 0.05;
        const burst_window = @as(f64, @floatFromInt(self.window_ms));
        const since_change = @as(f64, @floatFromInt(@max(0, observation.observed_ms - entry_profile.last_change_ms)));
        entry_profile.burst_score = if (burst_window > 0) @max(0.0, 1.0 - since_change / burst_window) * entry_profile.change_rate else 0.0;
    }

    pub fn profile(self: *Tracker, domain_hash: u64) ?DomainProfile {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.profiles.get(domain_hash);
    }

    pub fn changeProbability(self: *Tracker, domain_hash: u64, now_ms: i64) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const known = self.profiles.get(domain_hash) orelse return 0.05;
        return known.changeProbability(now_ms);
    }

    pub fn recommendedInterval(self: *Tracker, domain_hash: u64, min_interval_ms: u64, max_interval_ms: u64) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const known = self.profiles.get(domain_hash) orelse return max_interval_ms / 2;
        return known.recommendedInterval(min_interval_ms, max_interval_ms);
    }

    pub fn observeLinkGrowth(self: *Tracker, domain_hash: u64, new_links: u32, known_links: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = try self.profiles.getOrPut(self.allocator, domain_hash);
        if (!entry.found_existing) entry.value_ptr.* = .{ .domain_hash = domain_hash };
        if (known_links == 0) {
            entry.value_ptr.link_growth = 1.0;
            return;
        }
        const ratio = @as(f64, @floatFromInt(new_links)) / @as(f64, @floatFromInt(known_links));
        entry.value_ptr.link_growth = entry.value_ptr.link_growth * 0.8 + ratio * 0.2;
    }

    pub fn setQualityPrior(self: *Tracker, domain_hash: u64, value: f64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = try self.profiles.getOrPut(self.allocator, domain_hash);
        if (!entry.found_existing) entry.value_ptr.* = .{ .domain_hash = domain_hash };
        entry.value_ptr.quality_prior = @max(0.0, @min(1.0, value));
    }

    pub fn topVolatile(self: *Tracker, allocator: std.mem.Allocator, limit: usize) ![]DomainProfile {
        self.mutex.lock();
        defer self.mutex.unlock();
        var all = try allocator.alloc(DomainProfile, self.profiles.count());
        defer allocator.free(all);
        var index: usize = 0;
        var iterator = self.profiles.valueIterator();
        while (iterator.next()) |candidate| {
            all[index] = candidate.*;
            index += 1;
        }
        std.sort.block(DomainProfile, all, {}, struct {
            fn gt(_: void, a: DomainProfile, b: DomainProfile) bool {
                return a.change_rate > b.change_rate;
            }
        }.gt);
        const count = @min(limit, all.len);
        return allocator.dupe(DomainProfile, all[0..count]);
    }

    pub fn stats(self: *Tracker) VelocityStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        var total_change_rate: f64 = 0;
        var bursting: usize = 0;
        var iterator = self.profiles.valueIterator();
        while (iterator.next()) |candidate| {
            total_change_rate += candidate.change_rate;
            if (candidate.burst_score > 0.5) bursting += 1;
        }
        const count = @max(1, self.profiles.count());
        return .{
            .domains = self.profiles.count(),
            .observations = self.observations,
            .changes = self.changes,
            .mean_change_rate = total_change_rate / @as(f64, @floatFromInt(count)),
            .bursting_domains = bursting,
        };
    }

    pub fn prune(self: *Tracker, older_than_ms: i64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var stale = std.ArrayList(u64).init(self.allocator);
        defer stale.deinit();
        var iterator = self.profiles.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_observed_ms < older_than_ms) try stale.append(entry.key_ptr.*);
        }
        for (stale.items) |key| _ = self.profiles.remove(key);
        return stale.items.len;
    }

    pub fn nowMs() i64 {
        return time.nowMs();
    }
};

pub const VelocityStats = struct {
    domains: usize,
    observations: u64,
    changes: u64,
    mean_change_rate: f64,
    bursting_domains: usize,
};
