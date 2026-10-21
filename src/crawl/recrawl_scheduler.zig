const std = @import("std");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");
const state = @import("crawl_state.zig");
const velocity = @import("domain_velocity.zig");
const frontier = @import("frontier.zig");

pub const SchedulerError = error{
    NoCandidates,
    InvalidPolicy,
    UnknownClass,
};

pub const UrlClass = enum(u8) {
    general = 0,
    news = 1,
    preprint_repository = 2,
    funding_announcement = 3,
    code_repository = 4,
    corporate_site = 5,
    archive = 6,
    forum = 7,
    government = 8,
    documentation = 9,
};

pub const Policy = struct {
    class: UrlClass = .general,
    min_interval_ms: u64 = 3600000,
    max_interval_ms: u64 = 2592000000,
    velocity_weight: f64 = 0.65,
    freshness_weight: f64 = 0.25,
    capacity_share: f64 = 0.1,
    priority_boost: u16 = 0,
    enabled: bool = true,
};

pub const policy_count = 10;

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    policies: [policy_count]Policy,
    tracker: *velocity.Tracker,
    frontier_ref: *frontier.Frontier,
    overrides: std.AutoHashMapUnmanaged(u64, Policy) = .{},
    mutex: std.Thread.Mutex = .{},
    scheduled: u64 = 0,
    rescheduled: u64 = 0,
    evaluated: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, tracker: *velocity.Tracker, frontier_ref: *frontier.Frontier) !Scheduler {
        var policies: [policy_count]Policy = undefined;
        policies[@intFromEnum(UrlClass.general)] = .{ .class = .general, .min_interval_ms = 3600000, .max_interval_ms = 2592000000, .velocity_weight = 0.65, .freshness_weight = 0.25, .capacity_share = 0.3 };
        policies[@intFromEnum(UrlClass.news)] = .{ .class = .news, .min_interval_ms = 120000, .max_interval_ms = 604800000, .velocity_weight = 0.9, .freshness_weight = 0.6, .capacity_share = 0.2, .priority_boost = 20000 };
        policies[@intFromEnum(UrlClass.preprint_repository)] = .{ .class = .preprint_repository, .min_interval_ms = 600000, .max_interval_ms = 604800000, .velocity_weight = 0.8, .freshness_weight = 0.5, .capacity_share = 0.12, .priority_boost = 15000 };
        policies[@intFromEnum(UrlClass.funding_announcement)] = .{ .class = .funding_announcement, .min_interval_ms = 300000, .max_interval_ms = 2592000000, .velocity_weight = 0.7, .freshness_weight = 0.7, .capacity_share = 0.08, .priority_boost = 25000 };
        policies[@intFromEnum(UrlClass.code_repository)] = .{ .class = .code_repository, .min_interval_ms = 21600000, .max_interval_ms = 2592000000, .velocity_weight = 0.5, .freshness_weight = 0.2, .capacity_share = 0.08 };
        policies[@intFromEnum(UrlClass.corporate_site)] = .{ .class = .corporate_site, .min_interval_ms = 43200000, .max_interval_ms = 2592000000, .velocity_weight = 0.4, .freshness_weight = 0.2, .capacity_share = 0.1 };
        policies[@intFromEnum(UrlClass.archive)] = .{ .class = .archive, .min_interval_ms = 2592000000, .max_interval_ms = 2592000000, .velocity_weight = 0.05, .freshness_weight = 0.05, .capacity_share = 0.02 };
        policies[@intFromEnum(UrlClass.forum)] = .{ .class = .forum, .min_interval_ms = 1800000, .max_interval_ms = 1209600000, .velocity_weight = 0.75, .freshness_weight = 0.3, .capacity_share = 0.05 };
        policies[@intFromEnum(UrlClass.government)] = .{ .class = .government, .min_interval_ms = 86400000, .max_interval_ms = 2592000000, .velocity_weight = 0.3, .freshness_weight = 0.1, .capacity_share = 0.03 };
        policies[@intFromEnum(UrlClass.documentation)] = .{ .class = .documentation, .min_interval_ms = 604800000, .max_interval_ms = 2592000000, .velocity_weight = 0.2, .freshness_weight = 0.1, .capacity_share = 0.02 };
        return .{ .allocator = allocator, .policies = policies, .tracker = tracker, .frontier_ref = frontier_ref };
    }

    pub fn deinit(self: *Scheduler) void {
        self.overrides.deinit(self.allocator);
    }

    pub fn setOverride(self: *Scheduler, domain_hash: u64, policy: Policy) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.overrides.put(self.allocator, domain_hash, policy);
    }

    pub fn policyFor(self: *Scheduler, domain_hash: u64) Policy {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overrides.get(domain_hash)) |override| return override;
        const profile = self.tracker.profile(domain_hash);
        if (profile) |known| {
            if (known.publication_rate > 0.5 and known.change_rate > 0.5) return self.policies[@intFromEnum(UrlClass.news)];
            if (known.change_rate > 0.35) return self.policies[@intFromEnum(UrlClass.forum)];
            if (known.change_rate < 0.01) return self.policies[@intFromEnum(UrlClass.archive)];
        }
        return self.policies[@intFromEnum(UrlClass.general)];
    }

    pub fn classifyUrl(self: *Scheduler, canonical_url: []const u8, domain_hash: u64) UrlClass {
        const policy = self.policyFor(domain_hash);
        _ = canonical_url;
        return policy.class;
    }

    pub fn nextIntervalMs(self: *Scheduler, record: *const state.UrlRecord, now_ms: i64) u64 {
        const policy = self.policyFor(record.domain_hash);
        self.evaluated += 1;
        const velocity_interval = self.tracker.recommendedInterval(record.domain_hash, policy.min_interval_ms, policy.max_interval_ms);
        const change_probability = self.tracker.changeProbability(record.domain_hash, now_ms);
        if (change_probability > 0.6) {
            return @max(policy.min_interval_ms, @min(velocity_interval, policy.min_interval_ms * 4));
        }
        if (change_probability < 0.02) {
            return policy.max_interval_ms;
        }
        return @min(policy.max_interval_ms, @max(policy.min_interval_ms, velocity_interval));
    }

    pub fn applyAfterFetch(self: *Scheduler, record: *const state.UrlRecord, changed: bool) !u64 {
        const now = time.nowMs();
        const interval = self.nextIntervalMs(record, now);
        if (changed) {
            self.rescheduled += 1;
            try self.frontier_ref.reschedule(record.canonical_hash, @max(interval / 4, 60000));
            return @max(interval / 4, 60000);
        }
        self.scheduled += 1;
        try self.frontier_ref.reschedule(record.canonical_hash, interval);
        return interval;
    }

    pub const Budget = struct {
        total: usize,
        per_class: [policy_count]usize,

        pub fn forClass(self: *const Budget, class: UrlClass) usize {
            return self.per_class[@intFromEnum(class)];
        }
    };

    pub fn allocateBudget(self: *Scheduler, total: usize) Budget {
        var budget = Budget{ .total = total, .per_class = @splat(0) };
        const remaining = total;
        var assigned: usize = 0;
        for (self.policies, 0..) |policy, index| {
            if (!policy.enabled) continue;
            const share: usize = @intFromFloat(@as(f64, @floatFromInt(total)) * policy.capacity_share);
            budget.per_class[index] = share;
            assigned += share;
        }
        if (assigned < remaining) {
            const general = @intFromEnum(UrlClass.general);
            budget.per_class[general] += remaining - assigned;
        }
        return budget;
    }

    pub fn capacityForDomain(self: *Scheduler, domain_hash: u64, budget: *const Budget) usize {
        return budget.forClass(self.policyFor(domain_hash).class);
    }

    pub const Selection = struct {
        records: []state.UrlRecord,
        skipped: usize,

        pub fn release(self: Selection, allocator: std.mem.Allocator) void {
            for (self.records) |*record| record.release(allocator);
            allocator.free(self.records);
        }
    };

    pub fn select(self: *Scheduler, worker_id: u32, capacity: usize, now_ms: i64) !Selection {
        const leased = try self.frontier_ref.lease(worker_id, @max(1, capacity * 2), now_ms);
        var selected = std.ArrayList(state.UrlRecord).init(self.allocator);
        var skipped: usize = 0;
        for (leased) |record| {
            if (selected.items.len >= capacity) {
                record.release(self.allocator);
                skipped += 1;
                continue;
            }
            const policy = self.policyFor(record.domain_hash);
            if (!policy.enabled) {
                record.release(self.allocator);
                skipped += 1;
                continue;
            }
            try selected.append(record);
        }
        self.allocator.free(leased);
        if (selected.items.len == 0) return SchedulerError.NoCandidates;
        std.sort.block(state.UrlRecord, selected.items, {}, struct {
            fn gt(context: void, a: state.UrlRecord, b: state.UrlRecord) bool {
                _ = context;
                if (a.priority != b.priority) return a.priority > b.priority;
                return a.next_fetch_ms < b.next_fetch_ms;
            }
        }.gt);
        return .{ .records = try selected.toOwnedSlice(), .skipped = skipped };
    }

    pub fn stats(self: *Scheduler) SchedulerStats {
        return .{
            .scheduled = self.scheduled,
            .rescheduled = self.rescheduled,
            .evaluated = self.evaluated,
            .overrides = self.overrides.count(),
        };
    }

    pub fn domainKey(host: []const u8) u64 {
        return hashing.hash64(0x243F6A8885A308D3, host);
    }
};

pub const SchedulerStats = struct {
    scheduled: u64,
    rescheduled: u64,
    evaluated: u64,
    overrides: usize,
};
