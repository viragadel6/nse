const std = @import("std");
const query_dag = @import("query_dag.zig");
const cancellation = @import("../runtime/cancellation.zig");

pub const Scheduled = struct {
    node_id: query_dag.NodeId,
    deadline: cancellation.Deadline,
};

pub const Scheduler = struct {
    dag: *query_dag.Dag,
    concurrency: u32,
    running: usize = 0,
    lock: std.Thread.Mutex,

    pub fn init(dag: *query_dag.Dag, concurrency: u32) Scheduler {
        return Scheduler{ .dag = dag, .concurrency = concurrency, .lock = .{} };
    }

    pub fn schedule(self: *Scheduler, id: query_dag.NodeId, completed: std.HashMap(query_dag.NodeId, void), deadline_ms: u32) !Scheduled {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.running >= @intCast(self.concurrency)) return error.QueueFull;
        self.running += 1;
        return Scheduled{ .node_id = id, .deadline = cancellation.Deadline.init(deadline_ms) };
    }

    pub fn complete(self: *Scheduler) void {
        self.lock.lock();
        if (self.running > 0) self.running -= 1;
        self.lock.unlock();
    }

    pub fn runningCount(self: *Scheduler) usize {
        self.lock.lock();
        const count = self.running;
        self.lock.unlock();
        return count;
    }
};
