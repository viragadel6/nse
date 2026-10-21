const std = @import("std");
const cancellation = @import("cancellation.zig");

pub const Task = struct {
    id: u64,
    priority: u8,
    deadline: cancellation.Deadline,
    run: *const fn () !void,
    context: *anyopaque,
};

pub const Scheduler = struct {
    tasks: std.ArrayList(Task),
    lock: std.Thread.Mutex,
    next_id: u64,

    pub fn init() Scheduler {
        return Scheduler{ .tasks = std.ArrayList(Task).init(std.heap.page_allocator), .lock = .{}, .next_id = 1 };
    }

    pub fn deinit(self: *Scheduler) void {
        self.tasks.deinit();
    }

    pub fn schedule(self: *Scheduler, priority: u8, timeout_ms: u64, run: *const fn () !void, context: *anyopaque) u64 {
        self.lock.lock();
        const id = self.next_id;
        self.next_id += 1;
        _ = self.tasks.append(Task{
            .id = id,
            .priority = priority,
            .deadline = cancellation.Deadline.init(timeout_ms),
            .run = run,
            .context = context,
        });
        self.lock.unlock();
        return id;
    }

    pub fn runDue(self: *Scheduler) !void {
        self.lock.lock();
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const task = self.tasks.items[i];
            if (task.deadline.exceeded()) {
                const run = task.run;
                const context = task.context;
                self.lock.unlock();
                try run(context);
                self.lock.lock();
                _ = self.tasks.items.remove(i);
                continue;
            }
            i += 1;
        }
        self.lock.unlock();
    }

    pub fn cancel(self: *Scheduler, id: u64) bool {
        self.lock.lock();
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            if (self.tasks.items[i].id == id) {
                _ = self.tasks.items.remove(i);
                self.lock.unlock();
                return true;
            }
            i += 1;
        }
        self.lock.unlock();
        return false;
    }

    pub fn count(self: *Scheduler) usize {
        self.lock.lock();
        const count = self.tasks.items.len;
        self.lock.unlock();
        return count;
    }
};
