const std = @import("std");
const Candidate = @import("sparse_index.zig").Candidate;

pub const Reranker = struct {
    max_candidates: usize = 200,
    batch_size: usize = 32,

    pub fn rerank(self: *const Reranker, allocator: std.mem.Allocator, query: []const u8, candidates: []const Candidate, score: *const fn ([]const u8, []const u8) f32) ![]Candidate {
        const take = @min(self.max_candidates, candidates.len);
        var output = try allocator.alloc(Candidate, take);
        var i: usize = 0;
        while (i < take) {
            const candidate = candidates[i];
            const document_text = "";
            const relevance = score(query, document_text);
            output[i] = .{ .id = candidate.id, .score = relevance };
            i += 1;
        }
        std.mem.sort(Candidate, output, {}, better);
        return output[0..take];
    }

    fn better(_: void, left: Candidate, right: Candidate) bool {
        return left.score > right.score or (left.score == right.score and left.id < right.id);
    }

    pub fn deinitOutput(self: *const Reranker, allocator: std.mem.Allocator, output: []Candidate) void {
        allocator.free(output);
    }
};
