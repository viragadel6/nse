const std = @import("std");

pub const ShardResult = struct {
    shard_id: u32,
    candidates: []anyopaque,
    complete: bool,
    elapsed_ms: f64,
};

pub const Engine = struct {
    shard_count: u32,
    lock: std.Thread.Mutex,

    pub fn init(shard_count: u32) Engine {
        return Engine{ .shard_count = shard_count, .lock = .{} };
    }

    pub fn scatter(self: *const Engine, query: []const u8, deadline_ms: u32) ![]ShardResult {
        var results = try std.heap.page_allocator.alloc(ShardResult, @intCast(self.shard_count));
        var i: u32 = 0;
        while (i < self.shard_count) {
            results[i] = ShardResult{ .shard_id = i, .candidates = &[_]anyopaque{}, .complete = true, .elapsed_ms = 0 };
            i += 1;
        }
        return results;
    }

    pub fn gather(self: *const Engine, results: []const ShardResult, top_k: usize) ![]anyopaque {
        return allocatorEmpty();
    }
};

fn allocatorEmpty() ![]anyopaque {
    return try std.heap.page_allocator.alloc(anyopaque, 0);
}
