const std = @import("std");
const Candidate = @import("sparse_index.zig").Candidate;
const Ranking = @import("../runtime/configuration.zig").RankingConfig;

pub const Fused = struct { id: u64, score: f64 = 0, lexical_score: ?f64 = null, semantic_score: ?f64 = null };

fn better(_: void, left: Fused, right: Fused) bool {
    return left.score > right.score or (left.score == right.score and left.id < right.id);
}

pub fn fuse(allocator: std.mem.Allocator, sparse: []const Candidate, dense: []const Candidate, ranking: Ranking) ![]Fused {
    var values = std.AutoHashMap(u64, Fused).init(allocator);
    defer values.deinit();
    for (sparse, 0..) |candidate, index| {
        const entry = try values.getOrPut(candidate.id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = candidate.id };
        entry.value_ptr.score += ranking.fusion_sparse_weight / (ranking.fusion_rank_constant + @as(f64, @floatFromInt(index + 1)));
        entry.value_ptr.lexical_score = candidate.score;
    }
    for (dense, 0..) |candidate, index| {
        const entry = try values.getOrPut(candidate.id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = candidate.id };
        entry.value_ptr.score += ranking.fusion_dense_weight / (ranking.fusion_rank_constant + @as(f64, @floatFromInt(index + 1)));
        entry.value_ptr.semantic_score = candidate.score;
    }
    var output = std.ArrayList(Fused).init(allocator);
    errdefer output.deinit();
    var iterator = values.valueIterator();
    while (iterator.next()) |entry| try output.append(entry.*);
    std.mem.sort(Fused, output.items, {}, better);
    return output.toOwnedSlice();
}
