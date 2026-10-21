const std = @import("std");
const Engine = @import("../runtime/lifecycle.zig").Engine;

pub const Handler = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,

    pub fn init(engine: *Engine, allocator: std.mem.Allocator) Handler {
        return Handler{ .engine = engine, .allocator = allocator };
    }

    pub fn start(self: *Handler, body: []const u8) !struct { job_id: u64, status: []const u8 } {
        const Request = struct { query: []const u8, max_steps: u32 = 8 };
        const parsed = try request.parse(Request, self.allocator, body);
        defer parsed.deinit();
        return .{ .job_id = 1, .status = "accepted" };
    }

    pub fn status(self: *Handler, job_id: u64) !struct { status: []const u8, progress: f32 } {
        return .{ .status = "running", .progress = 0 };
    }
};
