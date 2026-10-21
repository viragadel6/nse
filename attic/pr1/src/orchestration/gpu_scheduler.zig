const std = @import("std");
const protocol = @import("workload");

pub const GpuJob = struct {
    id: u64,
    endpoint: []const u8,
    payload: []const u8,
    deadline_ms: u32,
    status: enum { pending, running, completed, failed } = .pending,
    result: ?[]u8 = null,
};

pub const Scheduler = struct {
    jobs: std.ArrayList(GpuJob),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    max_concurrent: u32 = 8,
    running: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{ .jobs = std.ArrayList(GpuJob).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.jobs.items) |*job| self.allocator.free(job.payload);
        self.jobs.deinit();
    }

    pub fn submit(self: *Scheduler, endpoint: []const u8, payload: []const u8, deadline_ms: u32) !u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const id = self.next_id;
        self.next_id += 1;
        _ = try self.jobs.append(GpuJob{ .id = id, .endpoint = try self.allocator.dupe(u8, endpoint), .payload = try self.allocator.dupe(u8, payload), .deadline_ms = deadline_ms });
        return id;
    }

    pub fn status(self: *Scheduler, id: u64) ?enum { pending, running, completed, failed } {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.jobs.items) |job| if (job.id == id) return job.status;
        return null;
    }
};
