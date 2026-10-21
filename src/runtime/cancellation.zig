const std = @import("std");
const time = @import("../util/time.zig");

pub const CancellationError = error{Cancelled};

pub const Reason = enum(u32) {
    none = 0,
    shutdown,
    deadline,
    caller_request,
    parent_cancelled,
    branch_pruned,
    superseded,
    resource_limit,
    failure,
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    reason: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    parent: ?*Scope = null,
    children: std.ArrayListUnmanaged(*Scope) = .{},
    cancelled_at_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    name: []const u8,
    waiters: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, parent: ?*Scope) !*Scope {
        const self = try allocator.create(Scope);
        self.* = .{ .allocator = allocator, .name = name, .parent = parent };
        if (parent) |p| {
            p.mutex.lock();
            p.children.append(allocator, self) catch {
                p.mutex.unlock();
                allocator.destroy(self);
                return error.OutOfMemory;
            };
            p.mutex.unlock();
            if (p.isCancelled()) {
                self.state.store(1, .release);
                self.reason.store(@intFromEnum(Reason.parent_cancelled), .release);
            }
        }
        return self;
    }

    pub fn deinit(self: *Scope) void {
        if (self.parent) |parent| {
            parent.mutex.lock();
            var index: usize = 0;
            while (index < parent.children.items.len) {
                if (parent.children.items[index] == self) {
                    _ = parent.children.orderedRemove(index);
                } else {
                    index += 1;
                }
            }
            parent.mutex.unlock();
        }
        self.mutex.lock();
        const children = self.children.toOwnedSlice(self.allocator) catch &[_]*Scope{};
        self.mutex.unlock();
        for (children) |descendant| {
            descendant.parent = null;
            descendant.cancel(Reason.parent_cancelled);
        }
        if (children.len > 0) self.allocator.free(children);
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn cancel(self: *Scope, reason: Reason) void {
        if (reason == Reason.none) return;
        if (self.state.cmpxchgStrong(0, 1, .acq_rel, .acquire)) |expected| {
            if (expected != 0) return;
        }
        self.reason.store(@intFromEnum(reason), .release);
        self.cancelled_at_ms.store(time.nowMs(), .release);
        self.mutex.lock();
        const children = self.children.toOwnedSlice(self.allocator) catch &[_]*Scope{};
        self.waiters = 0;
        self.mutex.unlock();
        for (children) |descendant| {
            descendant.cancel(Reason.parent_cancelled);
        }
        if (children.len > 0) self.allocator.free(children);
        self.condition.broadcast();
    }

    pub fn isCancelled(self: *const Scope) bool {
        return self.state.load(.acquire) != 0;
    }

    pub fn reasonFor(self: *const Scope) Reason {
        return @enumFromInt(self.reason.load(.acquire));
    }

    pub fn cancelledAtMs(self: *const Scope) i64 {
        return self.cancelled_at_ms.load(.acquire);
    }

    pub fn check(self: *const Scope) CancellationError!void {
        if (self.state.load(.acquire) != 0) return CancellationError.Cancelled;
    }

    pub fn child(self: *Scope, name: []const u8) !*Scope {
        return Scope.init(self.allocator, name, self);
    }

    pub fn wait(self: *Scope, timeout_ms: u64) void {
        if (self.isCancelled()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.waiters += 1;
        defer self.waiters -= 1;
        if (timeout_ms == 0) {
            while (!self.isCancelled()) self.condition.wait(&self.mutex);
        } else {
            const deadline = time.Deadline.fromTimeout(timeout_ms);
            while (!self.isCancelled() and !deadline.expired()) {
                self.condition.timedWait(&self.mutex, @intCast(deadline.remainingNs())) catch {};
            }
        }
    }

    pub fn deadlineScope(self: *Scope, name: []const u8, timeout_ms: u64) !*Scope {
        const scope = try self.child(name);
        const handle = try self.allocator.create(DeadlineGuard);
        handle.* = .{ .scope = scope, .timeout_ms = timeout_ms, .thread = undefined };
        handle.thread = std.Thread.spawn(.{}, DeadlineGuard.run, .{handle}) catch |err| {
            self.allocator.destroy(handle);
            scope.deinit();
            return err;
        };
        return scope;
    }
};

const DeadlineGuard = struct {
    scope: *Scope,
    timeout_ms: u64,
    thread: std.Thread,

    fn run(self: *DeadlineGuard) void {
        const deadline = time.Deadline.fromTimeout(self.timeout_ms);
        while (!self.scope.isCancelled() and !deadline.expired()) {
            std.Thread.sleep(@min(@as(u64, 5) * time.ns_per_ms, @as(u64, @intCast(@max(1, deadline.remainingNs())))));
        }
        if (!self.scope.isCancelled()) self.scope.cancel(Reason.deadline);
    }
};

pub const Token = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    reason: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    cancelled_at_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn init() Token {
        return .{};
    }

    pub fn cancel(self: *Token) void {
        self.cancelWith(Reason.caller_request);
    }

    pub fn cancelWith(self: *Token, cause: Reason) void {
        if (self.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            self.reason.store(@intFromEnum(cause), .release);
            self.cancelled_at_ms.store(time.nowMs(), .release);
        }
    }

    pub fn isCancelled(self: *const Token) bool {
        return self.state.load(.acquire) != 0;
    }

    pub fn reasonFor(self: *const Token) Reason {
        return @enumFromInt(self.reason.load(.acquire));
    }

    pub fn check(self: *const Token) CancellationError!void {
        if (self.isCancelled()) return CancellationError.Cancelled;
    }

    pub fn reset(self: *Token) void {
        self.state.store(0, .release);
        self.reason.store(0, .release);
        self.cancelled_at_ms.store(0, .release);
    }
};

pub const Deadline = struct {
    token: *Token,
    deadline: time.Deadline,
    budget_ms: u32,

    pub fn init(timeout_ms: u32, token: *Token) !Deadline {
        return .{ .token = token, .deadline = time.Deadline.fromTimeout(timeout_ms), .budget_ms = timeout_ms };
    }

    pub fn check(self: *const Deadline) (CancellationError || error{DeadlineExceeded})!void {
        try self.token.check();
        if (self.deadline.expired()) return error.DeadlineExceeded;
    }

    pub fn expired(self: *const Deadline) bool {
        return self.token.isCancelled() or self.deadline.expired();
    }

    pub fn remainingMs(self: *const Deadline) i64 {
        return @max(0, self.deadline.remainingMs());
    }

    pub fn remainingMilliseconds(self: *const Deadline) !u32 {
        const remaining = self.remainingMs();
        if (remaining <= 0) return error.DeadlineExceeded;
        return @intCast(@min(remaining, std.math.maxInt(u32)));
    }

    pub fn elapsed(self: *const Deadline) !u64 {
        try self.check();
        return self.deadline.elapsedMs();
    }

    pub fn elapsedMs(self: *const Deadline) u64 {
        return self.deadline.elapsedMs();
    }

    pub fn budgetRatio(self: *const Deadline) f64 {
        return self.deadline.budgetRatio();
    }

    pub fn unixMs(self: *const Deadline) i64 {
        return self.deadline.unixMs();
    }

    pub fn budgetMs(self: *const Deadline) u32 {
        return self.budget_ms;
    }

};

pub const Cooperative = struct {
    scope: *Scope,
    deadline: time.Deadline,

    pub fn init(scope: *Scope, deadline: time.Deadline) Cooperative {
        return .{ .scope = scope, .deadline = deadline };
    }

    pub fn check(self: *const Cooperative) (CancellationError || error{DeadlineExceeded})!void {
        if (self.scope.isCancelled()) return CancellationError.Cancelled;
        if (self.deadline.expired()) return error.DeadlineExceeded;
    }

    pub fn yield(self: *const Cooperative, iteration: usize) (CancellationError || error{DeadlineExceeded})!void {
        if (iteration % 64 == 0) return self.check();
    }

    pub fn remainingMs(self: *const Cooperative) i64 {
        return self.deadline.remainingMs();
    }
};

pub const MultiScope = struct {
    scopes: []*Scope,

    pub fn cancelled(self: *const MultiScope) bool {
        for (self.scopes) |scope| {
            if (scope.isCancelled()) return true;
        }
        return false;
    }

    pub fn check(self: *const MultiScope) CancellationError!void {
        if (self.cancelled()) return CancellationError.Cancelled;
    }

    pub fn cancelAll(self: *const MultiScope, reason: Reason) void {
        for (self.scopes) |scope| scope.cancel(reason);
    }
};

pub const Barrier = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: usize,
    generation: usize = 0,

    pub fn init(parties: usize) Barrier {
        return .{ .pending = parties };
    }

    pub fn arrive(self: *Barrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending == 0) return;
        self.pending -= 1;
        self.generation += 1;
        if (self.pending == 0) self.condition.broadcast();
    }

    pub fn wait(self: *Barrier, timeout_ms: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = time.Deadline.fromTimeout(timeout_ms);
        while (self.pending > 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            self.condition.timedWait(&self.mutex, @intCast(deadline.remainingNs())) catch {};
        }
    }
};

pub const Latch = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    value: std.atomic.Value(i64),

    pub fn init(count: i64) Latch {
        return .{ .value = std.atomic.Value(i64).init(count) };
    }

    pub fn countDown(self: *Latch) void {
        _ = self.value.fetchSub(1, .acq_rel);
        self.mutex.lock();
        self.mutex.unlock();
        self.condition.broadcast();
    }

    pub fn wait(self: *Latch, timeout_ms: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = time.Deadline.fromTimeout(timeout_ms);
        while (self.value.load(.acquire) > 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            self.condition.timedWait(&self.mutex, @intCast(deadline.remainingNs())) catch {};
        }
    }

    pub fn get(self: *Latch) i64 {
        return self.value.load(.acquire);
    }
};
