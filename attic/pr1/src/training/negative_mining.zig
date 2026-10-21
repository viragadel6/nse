const std = @import("std");
const tensor_ops = @import("../models/tensor_ops.zig");

pub const Candidate = struct {
    document_id: u64,
    embedding: []const f32,
    score: f32,
    model_version: u64,
    index_generation: u64,
    retrieved_ms: i64,
};

pub const Miner = struct {
    max_candidates: u32 = 1024,
    drift_threshold: f32 = 0.15,
    queue_capacity: u32 = 100000,
    queue: []Candidate,
    queue_count: usize = 0,
    head: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Miner {
        const queue = try allocator.alloc(Candidate, @intCast(capacity));
        return Miner{ .queue_capacity = capacity, .queue = queue };
    }

    pub fn deinit(self: *Miner, allocator: std.mem.Allocator) void {
        allocator.free(self.queue);
    }

    pub fn push(self: *Miner, candidate: Candidate) bool {
        if (self.queue_count >= @intCast(self.queue_capacity)) return false;
        const index = (self.head + self.queue_count) % @intCast(self.queue_capacity);
        self.queue[index] = candidate;
        self.queue_count += 1;
        return true;
    }

    pub fn mine(self: *Miner, query: []const f32, count: u32) ![]Candidate {
        if (self.queue_count == 0) return error.EmptyNegativePool;
        const take = @min(@intCast(count), self.queue_count);
        var selected = try std.heap.page_allocator.alloc(Candidate, take);
        var i: usize = 0;
        while (i < take) {
            const index = (self.head + i) % @intCast(self.queue_capacity);
            selected[i] = self.queue[index];
            i += 1;
        }
        var a: usize = 0;
        while (a < take) {
            var b: usize = a + 1;
            while (b < take) {
                if (selected[b].score > selected[a].score) {
                    const temp = selected[a];
                    selected[a] = selected[b];
                    selected[b] = temp;
                }
                b += 1;
            }
            a += 1;
        }
        return selected[0..take];
    }

    pub fn isStale(self: *Miner, candidate: Candidate, current_model_version: u64, current_index_generation: u64) bool {
        return candidate.model_version != current_model_version or candidate.index_generation != current_index_generation;
    }
};
