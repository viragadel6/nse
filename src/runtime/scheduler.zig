const std = @import("std");
const time = @import("../util/time.zig");

pub const SchedulerError = error{
    SchedulerStopped,
    QueueFull,
    InvalidTask,
    NotFound,
};

pub const TaskFn = *const fn (ctx: *anyopaque) void;

pub const Task = struct {
    id: u64,
    deadline_ns: u64,
    period_ms: u64,
    callback: TaskFn,
    context: *anyopaque,
    cancelled: bool = false,
    label: []const u8,
    runs: u64 = 0,
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    tasks: std.ArrayListUnmanaged(Task) = .{},
    next_id: u64 = 1,
    running: bool = false,
    wake_generation: u64 = 0,
    thread: ?std.Thread = null,
    executed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    missed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_tasks: usize,

    pub fn init(allocator: std.mem.Allocator, max_tasks: usize) Scheduler {
        return .{ .allocator = allocator, .max_tasks = max_tasks };
    }

    pub fn deinit(self: *Scheduler) void {
        self.stop();
        self.mutex.lock();
        self.tasks.deinit(self.allocator);
        self.mutex.unlock();
    }

    pub fn start(self: *Scheduler) !void {
        self.mutex.lock();
        if (self.running) {
            self.mutex.unlock();
            return;
        }
        self.running = true;
        self.mutex.unlock();
        self.thread = std.Thread.spawn(.{}, runLoop, .{self}) catch |err| {
            self.mutex.lock();
            self.running = false;
            self.mutex.unlock();
            return err;
        };
    }

    pub fn stop(self: *Scheduler) void {
        self.mutex.lock();
        if (!self.running) {
            self.mutex.unlock();
            return;
        }
        self.running = false;
        self.wake_generation += 1;
        self.mutex.unlock();
        self.condition.broadcast();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn schedule(self: *Scheduler, delay_ms: u64, label: []const u8, callback: TaskFn, context: *anyopaque) !u64 {
        return self.schedulePeriodic(delay_ms, 0, label, callback, context);
    }

    pub fn schedulePeriodic(self: *Scheduler, delay_ms: u64, period_ms: u64, label: []const u8, callback: TaskFn, context: *anyopaque) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.running) return SchedulerError.SchedulerStopped;
        if (self.tasks.items.len >= self.max_tasks) return SchedulerError.QueueFull;
        const id = self.next_id;
        self.next_id += 1;
        try self.tasks.append(self.allocator, .{
            .id = id,
            .deadline_ns = time.monotonicNs() + delay_ms * time.ns_per_ms,
            .period_ms = period_ms,
            .callback = callback,
            .context = context,
            .label = label,
        });
        self.wake_generation += 1;
        self.condition.signal();
        return id;
    }

    pub fn cancel(self: *Scheduler, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.tasks.items) |*task| {
            if (task.id == id) {
                task.cancelled = true;
                self.wake_generation += 1;
                self.condition.signal();
                return true;
            }
        }
        return false;
    }

    pub fn pending(self: *Scheduler) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (!task.cancelled) count += 1;
        }
        return count;
    }

    pub fn nextDeadlineNs(self: *Scheduler) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var best: u64 = std.math.maxInt(u64);
        for (self.tasks.items) |task| {
            if (!task.cancelled and task.deadline_ns < best) best = task.deadline_ns;
        }
        return best;
    }

    fn runLoop(self: *Scheduler) void {
        while (true) {
            self.mutex.lock();
            while (self.running and !self.hasDue()) {
                const wait_ns: u64 = blk: {
                    var best: u64 = std.math.maxInt(u64);
                    for (self.tasks.items) |task| {
                        if (!task.cancelled and task.deadline_ns < best) best = task.deadline_ns;
                    }
                    if (best == std.math.maxInt(u64)) break :blk 50 * time.ns_per_ms;
                    const now = time.monotonicNs();
                    break :blk if (best > now) @min(best - now, 5 * time.ns_per_s) else 0;
                };
                if (wait_ns > 0) {
                    self.condition.timedWait(&self.mutex, wait_ns) catch {};
                } else {
                    self.mutex.unlock();
                    self.mutex.lock();
                }
            }
            if (!self.running) {
                self.mutex.unlock();
                return;
            }
            var due = self.popDue();
            self.mutex.unlock();
            for (due.items) |*task| {
                if (task.cancelled) continue;
                task.runs += 1;
                task.callback(task.context);
                _ = self.executed.fetchAdd(1, .monotonic);
                if (task.period_ms > 0) {
                    self.mutex.lock();
                    self.reschedule(task);
                    self.mutex.unlock();
                }
            }
            due.deinit(self.allocator);
        }
    }

    fn hasDue(self: *Scheduler) bool {
        const now = time.monotonicNs();
        for (self.tasks.items) |task| {
            if (!task.cancelled and task.deadline_ns <= now) return true;
        }
        return false;
    }

    fn popDue(self: *Scheduler) std.ArrayListUnmanaged(Task) {
        var due: std.ArrayListUnmanaged(Task) = .{};
        const now = time.monotonicNs();
        var index: usize = 0;
        while (index < self.tasks.items.len) {
            const task = self.tasks.items[index];
            if (task.cancelled or task.deadline_ns <= now) {
                due.append(self.allocator, task) catch {};
                _ = self.tasks.orderedRemove(index);
                if (task.deadline_ns + 1000 * time.ns_per_ms < now and !task.cancelled) {
                    _ = self.missed.fetchAdd(1, .monotonic);
                }
            } else {
                index += 1;
            }
        }
        return due;
    }

    fn reschedule(self: *Scheduler, task: *const Task) void {
        var next = task.*;
        next.deadline_ns = time.monotonicNs() + task.period_ms * time.ns_per_ms;
        self.tasks.append(self.allocator, next) catch {};
        self.wake_generation += 1;
        self.condition.signal();
    }

    pub fn stats(self: *Scheduler) SchedulerStats {
        return .{
            .pending = self.pending(),
            .executed = self.executed.load(.monotonic),
            .missed = self.missed.load(.monotonic),
        };
    }
};

pub const SchedulerStats = struct {
    pending: usize,
    executed: u64,
    missed: u64,
};

pub const DeadlineWatch = struct {
    scheduler: *Scheduler,
    task_id: u64 = 0,

    pub fn arm(self: *DeadlineWatch, timeout_ms: u64, callback: TaskFn, context: *anyopaque) !void {
        if (self.task_id != 0) _ = self.scheduler.cancel(self.task_id);
        self.task_id = try self.scheduler.schedule(timeout_ms, "deadline-watch", callback, context);
    }

    pub fn disarm(self: *DeadlineWatch) void {
        if (self.task_id != 0) {
            _ = self.scheduler.cancel(self.task_id);
            self.task_id = 0;
        }
    }
};

pub const PeriodicJob = struct {
    scheduler: *Scheduler,
    id: u64 = 0,
    period_ms: u64,

    pub fn start(self: *PeriodicJob, callback: TaskFn, context: *anyopaque) !void {
        if (self.id != 0) return;
        self.id = try self.scheduler.schedulePeriodic(self.period_ms, self.period_ms, "periodic", callback, context);
    }

    pub fn stop(self: *PeriodicJob) void {
        if (self.id != 0) {
            _ = self.scheduler.cancel(self.id);
            self.id = 0;
        }
    }
};
