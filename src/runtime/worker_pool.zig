const std = @import("std");
const time = @import("../util/time.zig");

pub const PoolError = error{
    QueueFull,
    PoolStopped,
    InvalidConfiguration,
    InvalidPriority,
};

pub const Priority = enum(u8) {
    background = 0,
    normal = 1,
    high = 2,
    interactive = 3,
};

pub const WorkFn = *const fn (ctx: *anyopaque) void;

pub const Job = struct {
    callback: WorkFn,
    context: *anyopaque,
    priority: Priority,
    sequence: u64,
    submitted_at_ms: i64,
    label: []const u8,
};

pub const Stats = struct {
    submitted: u64,
    completed: u64,
    rejected: u64,
    queue_depth: usize,
    wait_time_ms: f64,
    run_time_ms: f64,
    active_workers: u32,
};

fn orderJobs(context: void, a: Job, b: Job) bool {
    _ = context;
    if (a.priority != b.priority) return @intFromEnum(a.priority) > @intFromEnum(b.priority);
    return a.sequence < b.sequence;
}

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    work_available: std.Thread.Condition = .{},
    idle: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged(Job) = .{},
    workers: []std.Thread,
    capacity: usize,
    running: bool = false,
    sequence: u64 = 0,
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_wait_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_run_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, worker_count: usize, capacity: usize) !WorkerPool {
        if (worker_count == 0 or capacity == 0) return PoolError.InvalidConfiguration;
        const workers = try allocator.alloc(std.Thread, worker_count);
        return .{ .allocator = allocator, .workers = workers, .capacity = capacity, .name = name };
    }

    pub fn deinit(self: *WorkerPool) void {
        self.shutdown();
        self.mutex.lock();
        self.queue.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.free(self.workers);
    }

    pub fn start(self: *WorkerPool) !void {
        self.mutex.lock();
        if (self.running) {
            self.mutex.unlock();
            return;
        }
        self.running = true;
        self.mutex.unlock();
        var spawned: usize = 0;
        for (0..self.workers.len) |index| {
            self.workers[index] = std.Thread.spawn(.{}, workerMain, .{ self, index }) catch break;
            spawned += 1;
        }
        if (spawned == 0) {
            self.mutex.lock();
            self.running = false;
            self.mutex.unlock();
            return error.OutOfMemory;
        }
        if (spawned < self.workers.len) {
            const trimmed = self.allocator.realloc(self.workers, spawned) catch self.workers[0..spawned];
            self.workers = trimmed;
        }
    }

    pub fn shutdown(self: *WorkerPool) void {
        self.mutex.lock();
        if (!self.running) {
            self.mutex.unlock();
            return;
        }
        self.running = false;
        self.mutex.unlock();
        self.work_available.broadcast();
        for (self.workers) |worker| worker.join();
    }

    pub fn submit(self: *WorkerPool, priority: Priority, label: []const u8, callback: WorkFn, context: *anyopaque) PoolError!void {
        self.mutex.lock();
        if (!self.running) {
            self.mutex.unlock();
            _ = self.rejected.fetchAdd(1, .monotonic);
            return PoolError.PoolStopped;
        }
        if (self.queue.items.len >= self.capacity) {
            self.mutex.unlock();
            _ = self.rejected.fetchAdd(1, .monotonic);
            return PoolError.QueueFull;
        }
        self.sequence += 1;
        self.queue.append(self.allocator, .{
            .callback = callback,
            .context = context,
            .priority = priority,
            .sequence = self.sequence,
            .submitted_at_ms = time.nowMs(),
            .label = label,
        }) catch {
            self.mutex.unlock();
            _ = self.rejected.fetchAdd(1, .monotonic);
            return PoolError.QueueFull;
        };
        self.mutex.unlock();
        _ = self.submitted.fetchAdd(1, .monotonic);
        self.work_available.signal();
    }

    pub fn submitBlocking(self: *WorkerPool, priority: Priority, label: []const u8, callback: WorkFn, context: *anyopaque) void {
        while (true) {
            if (self.submit(priority, label, callback, context)) {
                return;
            } else |err| {
                if (err == PoolError.PoolStopped) return;
            }
            if (!self.running) return;
            std.Thread.sleep(1 * time.ns_per_ms);
        }
    }

    fn takeJob(self: *WorkerPool) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len == 0) {
            if (!self.running) return null;
            self.work_available.wait(&self.mutex);
        }
        std.sort.block(Job, self.queue.items, {}, orderJobs);
        return self.queue.orderedRemove(0);
    }

    fn workerMain(self: *WorkerPool, index: usize) void {
        _ = index;
        while (true) {
            const job = self.takeJob() orelse {
                if (!self.running) return;
                continue;
            };
            _ = self.active.fetchAdd(1, .monotonic);
            const run_start = time.monotonicNs();
            const wait_ns = (time.nowMs() - job.submitted_at_ms) * @as(i64, time.ns_per_ms);
            if (wait_ns > 0) _ = self.total_wait_ns.fetchAdd(@intCast(wait_ns), .monotonic);
            job.callback(job.context);
            _ = self.total_run_ns.fetchAdd(time.monotonicNs() - run_start, .monotonic);
            _ = self.completed.fetchAdd(1, .monotonic);
            _ = self.active.fetchSub(1, .monotonic);
        }
    }

    pub fn drain(self: *WorkerPool, timeout_ms: u64) !void {
        const deadline = time.Deadline.fromTimeout(timeout_ms);
        while (self.queueDepth() > 0 or self.active.load(.monotonic) > 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            std.Thread.sleep(1 * time.ns_per_ms);
        }
    }

    pub fn queueDepth(self: *WorkerPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }

    pub fn utilization(self: *WorkerPool) f64 {
        const running = self.active.load(.monotonic);
        return @as(f64, @floatFromInt(running)) / @as(f64, @floatFromInt(self.workers.len));
    }

    pub fn stats(self: *WorkerPool) Stats {
        const completed = self.completed.load(.monotonic);
        const wait = self.total_wait_ns.load(.monotonic);
        const run = self.total_run_ns.load(.monotonic);
        return .{
            .submitted = self.submitted.load(.monotonic),
            .completed = completed,
            .rejected = self.rejected.load(.monotonic),
            .queue_depth = self.queueDepth(),
            .wait_time_ms = if (completed > 0) @as(f64, @floatFromInt(wait)) / @as(f64, @floatFromInt(completed)) / 1e6 else 0.0,
            .run_time_ms = if (completed > 0) @as(f64, @floatFromInt(run)) / @as(f64, @floatFromInt(completed)) / 1e6 else 0.0,
            .active_workers = self.active.load(.monotonic),
        };
    }

    pub fn workerCount(self: *WorkerPool) usize {
        return self.workers.len;
    }
};

pub const WeightedPoolSet = struct {
    allocator: std.mem.Allocator,
    interactive: *WorkerPool,
    background: *WorkerPool,
    interactive_share: f64,

    pub fn init(allocator: std.mem.Allocator, interactive: *WorkerPool, background: *WorkerPool, share: f64) WeightedPoolSet {
        return .{ .allocator = allocator, .interactive = interactive, .background = background, .interactive_share = @max(0.05, @min(0.95, share)) };
    }

    pub fn submit(self: *WeightedPoolSet, priority: Priority, label: []const u8, callback: WorkFn, context: *anyopaque) PoolError!void {
        const interactive_pressure = @as(f64, @floatFromInt(self.interactive.queueDepth())) / @as(f64, @floatFromInt(@max(1, self.interactive.capacity)));
        if (priority == .interactive or interactive_pressure < self.interactive_share) {
            return self.interactive.submit(priority, label, callback, context);
        }
        return self.background.submit(Priority.background, label, callback, context);
    }

    pub fn stats(self: *WeightedPoolSet) [2]Stats {
        return .{ self.interactive.stats(), self.background.stats() };
    }
};

pub const ScopedWork = struct {
    pool: *WorkerPool,
    pending: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.Thread.Condition = .{},
    mutex: std.Thread.Mutex = .{},

    fn trampoline(context: *anyopaque) void {
        const self: *ScopedWork = @ptrCast(@alignCast(context));
        _ = self.pending.fetchSub(1, .acq_rel);
        self.mutex.lock();
        self.mutex.unlock();
        self.done.signal();
    }

    pub fn fork(self: *ScopedWork, priority: Priority, label: []const u8, callback: WorkFn, context: *anyopaque) !void {
        _ = self.pending.fetchAdd(1, .monotonic);
        self.pool.submit(priority, label, callback, context) catch |err| {
            _ = self.pending.fetchSub(1, .monotonic);
            return err;
        };
    }

    pub fn join(self: *ScopedWork, timeout_ms: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = time.Deadline.fromTimeout(timeout_ms);
        while (self.pending.load(.acquire) > 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            self.done.timedWait(&self.mutex, @intCast(deadline.remainingNs())) catch {};
        }
    }
};

pub fn parallelFor(pool: *WorkerPool, total: usize, chunk_size: usize, context: *anyopaque, callback: *const fn (ctx: *anyopaque, start: usize, end: usize) void) !void {
    if (total == 0) return;
    const chunks = @max(1, @divFloor(total + chunk_size - 1, chunk_size));
    var scoped = ScopedWork{ .pool = pool };
    const ranges = try std.heap.page_allocator.alloc(Range, chunks);
    defer std.heap.page_allocator.free(ranges);
    for (ranges, 0..) |*range, index| {
        range.* = .{ .start = index * chunk_size, .end = @min(total, (index + 1) * chunk_size), .context = context, .callback = callback, .scoped = &scoped };
        try scoped.fork(Priority.normal, "parallel-for", Range.run, range);
    }
    try scoped.join(60000);
}

const Range = struct {
    start: usize,
    end: usize,
    context: *anyopaque,
    callback: *const fn (ctx: *anyopaque, start: usize, end: usize) void,
    scoped: *ScopedWork,

    fn run(ctx: *anyopaque) void {
        const self: *Range = @ptrCast(@alignCast(ctx));
        self.callback(self.context, self.start, self.end);
        _ = self.scoped.pending.fetchSub(1, .acq_rel);
        self.scoped.mutex.lock();
        self.scoped.mutex.unlock();
        self.scoped.done.signal();
    }
};
