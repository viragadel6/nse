const std = @import("std");
const vector_index = @import("../index/vector_index.zig");
const Candidate = @import("../retrieval/sparse_index.zig").Candidate;
const Deadline = @import("../runtime/cancellation.zig").Deadline;

pub const Searcher = struct {
    index: *vector_index.Index,
    store: *anyopaque,
    pool: u32 = 500,

    pub fn init(index: *vector_index.Index, store: *anyopaque) Searcher {
        return Searcher{ .index = index, .store = store, .pool = 500 };
    }

    pub fn search(self: *Searcher, allocator: std.mem.Allocator, embedding: []const f32, deadline: Deadline) ![]Candidate {
        return self.index.search(allocator, @fieldParent(anyopaque, "", self.store), embedding, self.pool, deadline);
    }
};
