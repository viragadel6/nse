const std = @import("std");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const request = @import("request_codec.zig");

pub const Handler = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,

    pub fn init(engine: *Engine, allocator: std.mem.Allocator) Handler {
        return Handler{ .engine = engine, .allocator = allocator };
    }

    pub fn handle(self: *Handler, body: []const u8) !struct { highlights: []anyopaque } {
        const parsed = try request.parse(request.Highlights, self.allocator, body);
        defer parsed.deinit();
        const results = try self.engine.highlight(self.allocator, parsed.value);
        var output = try self.allocator.alloc(anyopaque, results.len);
        var i: usize = 0;
        while (i < results.len) {
            output[i] = @bitCast(@as(*anyopaque, &results[i]));
            i += 1;
        }
        return .{ .highlights = output };
    }

    pub fn deinitOutput(self: *Handler, output: []anyopaque) void {
        self.allocator.free(output);
    }
};
