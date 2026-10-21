const std = @import("std");

pub const Step = struct {
    id: u64,
    subquery: []const u8,
    status: enum { pending, running, completed, failed } = .pending,
    evidence: [][]const u8 = &[_][]const u8{},
    error: ?[]const u8 = null,
};

pub const Job = struct {
    job_id: u64,
    query: []const u8,
    steps: []Step,
    completed_steps: usize = 0,
    total_steps: usize = 0,
    status: enum { pending, running, completed, failed } = .pending,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

pub const Pipeline = struct {
    jobs: std.ArrayList(Job),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Pipeline {
        return Pipeline{ .jobs = std.ArrayList(Job).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Pipeline) void {
        for (self.jobs.items) |*job| {
            for (job.steps) |*step| {
                self.allocator.free(step.subquery);
                for (step.evidence) |evidence| self.allocator.free(evidence);
            }
            self.allocator.free(job.steps);
            self.allocator.free(job.query);
        }
        self.jobs.deinit();
    }

    pub fn start(self: *Pipeline, query: []const u8, subqueries: [][]const u8) !u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const id = self.next_id;
        self.next_id += 1;
        var steps = try self.allocator.alloc(Step, subqueries.len);
        var i: usize = 0;
        while (i < subqueries.len) {
            steps[i] = Step{ .id = @as(u64, @intCast(i) + 1), .subquery = try self.allocator.dupe(u8, subqueries[i]) };
            i += 1;
        }
        _ = try self.jobs.append(Job{ .job_id = id, .query = try self.allocator.dupe(u8, query), .steps = steps, .total_steps = subqueries.len, .status = .running, .created_at = std.time.milliTimestamp(std.time.Clock.wall()) catch 0 });
        return id;
    }

    pub fn status(self: *Pipeline, job_id: u64) ?*Job {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.jobs.items) |*job| if (job.job_id == job_id) return job;
        return null;
    }

    pub fn completeStep(self: *Pipeline, job_id: u64, step_id: u64, evidence: [][]const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.jobs.items) |*job| if (job.job_id == job_id) {
            for (job.steps) |*step| if (step.id == step_id) {
                step.status = .completed;
                var evidence_copy = try self.allocator.alloc([]const u8, evidence.len);
                var k: usize = 0;
                while (k < evidence.len) {
                    evidence_copy[k] = try self.allocator.dupe(u8, evidence[k]);
                    k += 1;
                }
                step.evidence = evidence_copy;
                job.completed_steps += 1;
                if (job.completed_steps >= job.total_steps) job.status = .completed;
                job.updated_at = std.time.milliTimestamp(std.time.Clock.wall()) catch 0;
            }
        }
    }

    pub fn fail(self: *Pipeline, job_id: u64, error: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.jobs.items) |*job| if (job.job_id == job_id) job.status = .failed;
    }
};
