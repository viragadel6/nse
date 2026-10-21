const std = @import("std");
const training_runtime = @import("training_runtime.zig");
const curriculum = @import("curriculum.zig");
const protocol = @import("workload");

pub const Job = struct {
    request: protocol.TrainingRequest,
    status: enum { pending, running, completed, failed } = .pending,
    step: u64 = 0,
    loss: f32 = 0,
    error: ?[]const u8 = null,
};

pub const Coordinator = struct {
    jobs: std.ArrayList(Job),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Coordinator {
        return Coordinator{ .jobs = std.ArrayList(Job).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Coordinator) void {
        self.jobs.deinit();
    }

    pub fn submit(self: *Coordinator, request: protocol.TrainingRequest) !u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const id = @as(u64, @intCast(self.jobs.items.len) + 1);
        try self.jobs.append(Job{ .request = request, .status = .pending });
        return id;
    }

    pub fn status(self: *Coordinator, id: u64) ?*Job {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.jobs.items) |*job| if (job.request.job_id == id) return job;
        return null;
    }

    pub fn run(self: *Coordinator, allocator: std.mem.Allocator, runtime: *anyopaque, root: []const u8) !void {
        self.lock.lock();
        var job = self.jobs.items[0];
        self.lock.unlock();
        _ = runtime;
        _ = root;
        job.status = .running;
        _ = training_runtime.run(allocator, anyopaque_cast(runtime), root, job.request);
        job.status = .completed;
    }
};

fn anyopaque_cast(ptr: *anyopaque) *anyopaque {
    return ptr;
}
