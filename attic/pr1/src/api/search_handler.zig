const std = @import("std");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const request = @import("request_codec.zig");

pub const Handler = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,

    pub fn init(engine: *Engine, allocator: std.mem.Allocator) Handler {
        return Handler{ .engine = engine, .allocator = allocator };
    }

    pub fn handle(self: *Handler, body: []const u8) !struct {
        index_generation: u64,
        model_version: u64,
        complete: bool,
        results: []anyopaque,
    } {
        const parsed = try request.parse(request.Search, self.allocator, body);
        defer parsed.deinit();
        const result = try self.engine.search(self.allocator, parsed.value);
        var output = try self.allocator.alloc(anyopaque, result.results.len);
        var i: usize = 0;
        while (i < result.results.len) {
            output[i] = @bitCast(@as(*anyopaque, &result.results[i]));
            i += 1;
        }
        return .{ .index_generation = result.index_generation, .model_version = result.model_version, .complete = result.complete, .results = output };
    }

    pub fn deinitOutput(self: *Handler, output: []anyopaque) void {
        self.allocator.free(output);
    }
};
