const std = @import("std");
const lexical = @import("lexical_index.zig");
const fusion = @import("reciprocal_rank_fusion.zig");
const time = @import("../util/time.zig");

pub const RetrievalError = error{
    NoRetrievers,
    InvalidWeights,
    DeadlineExceeded,
};

pub const Mode = enum(u8) {
    lexical_only,
    dense_only,
    hybrid,
    hybrid_with_dense_expansion,
};

pub const Weights = struct {
    lexical: f64 = 0.5,
    dense: f64 = 0.5,
    quality: f64 = 0.15,
    freshness: f64 = 0.05,
    rrf_constant: f64 = 60.0,
};

pub const DenseHit = struct {
    document_id: u64,
    score: f64,
    quality: f32,
};

pub const LexicalHit = struct {
    document_id: u64,
    score: f64,
    matched_terms: u32,
};

pub const Fused = struct {
    document_id: u64,
    score: f64 = 0.0,
    lexical_score: ?f64 = null,
    dense_score: ?f64 = null,
    lexical_rank: ?u32 = null,
    dense_rank: ?u32 = null,
    quality: f32 = 1.0,
    matched_terms: u32 = 0,
};

pub const Outcome = struct {
    results: []Fused,
    lexical_candidates: usize,
    dense_candidates: usize,
    elapsed_ms: f64,
    mode: Mode,
};

pub const Retriever = struct {
    allocator: std.mem.Allocator,
    weights: Weights,
    mode: Mode = .hybrid,
    lexical_limit: usize = 500,
    dense_limit: usize = 500,
    final_limit: usize = 100,
    minimum_lexical_score: f64 = 0.0,
    searches: u64 = 0,
    total_ms: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, weights: Weights) !Retriever {
        if (weights.lexical < 0.0 or weights.dense < 0.0) return RetrievalError.InvalidWeights;
        return .{ .allocator = allocator, .weights = weights };
    }

    pub fn reciprocalRank(rank: u32, constant: f64) f64 {
        return 1.0 / (constant + @as(f64, @floatFromInt(rank + 1)));
    }

    pub fn combine(self: *Retriever, lexical_hits: []const LexicalHit, dense_hits: []const DenseHit, now_ms: i64, published: *const std.AutoHashMapUnmanaged(u64, i64)) !Outcome {
        const started = time.StopWatch.start();
        var fused = std.AutoHashMap(u64, Fused).init(self.allocator);
        defer fused.deinit();
        for (lexical_hits, 0..) |hit, rank| {
            if (self.mode == .dense_only) continue;
            const entry = try fused.getOrPut(hit.document_id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .document_id = hit.document_id };
            entry.value_ptr.lexical_score = hit.score;
            entry.value_ptr.lexical_rank = @intCast(rank);
            entry.value_ptr.matched_terms = hit.matched_terms;
            entry.value_ptr.score += self.weights.lexical * reciprocalRank(@intCast(rank), self.weights.rrf_constant);
        }
        for (dense_hits, 0..) |hit, rank| {
            if (self.mode == .lexical_only) continue;
            const entry = try fused.getOrPut(hit.document_id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .document_id = hit.document_id };
            entry.value_ptr.dense_score = hit.score;
            entry.value_ptr.dense_rank = @intCast(rank);
            entry.value_ptr.quality = hit.quality;
            entry.value_ptr.score += self.weights.dense * reciprocalRank(@intCast(rank), self.weights.rrf_constant);
        }
        var results = std.ArrayList(Fused).init(self.allocator);
        var iterator = fused.valueIterator();
        while (iterator.next()) |candidate| {
            var adjusted = candidate.*;
            if (self.weights.quality > 0.0) {
                adjusted.score += self.weights.quality * @as(f64, adjusted.quality);
            }
            if (self.weights.freshness > 0.0) {
                if (published.get(adjusted.document_id)) |published_ms| {
                    if (published_ms > 0) {
                        const age_days = @as(f64, @floatFromInt(@max(0, now_ms - published_ms))) / 86400000.0;
                        adjusted.score += self.weights.freshness / (1.0 + @log(1.0 + age_days));
                    }
                }
            }
            try results.append(adjusted);
        }
        std.sort.block(Fused, results.items, {}, struct {
            fn gt(_: void, a: Fused, b: Fused) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.document_id < b.document_id;
            }
        }.gt);
        if (results.items.len > self.final_limit) results.shrinkRetainingCapacity(self.final_limit);
        const elapsed = started.elapsedMs();
        self.searches += 1;
        self.total_ms += elapsed;
        return .{
            .results = try results.toOwnedSlice(),
            .lexical_candidates = lexical_hits.len,
            .dense_candidates = dense_hits.len,
            .elapsed_ms = elapsed,
            .mode = self.mode,
        };
    }

    pub fn combineRankedLists(self: *Retriever, ranked: []const []const u64) ![]Fused {
        var fused = std.AutoHashMap(u64, Fused).init(self.allocator);
        defer fused.deinit();
        for (ranked, 0..) |list, list_index| {
            const weight = if (list_index == 0) self.weights.lexical else self.weights.dense;
            for (list, 0..) |document_id, rank| {
                const entry = try fused.getOrPut(document_id);
                if (!entry.found_existing) entry.value_ptr.* = .{ .document_id = document_id };
                entry.value_ptr.score += weight * reciprocalRank(@intCast(rank), self.weights.rrf_constant);
            }
        }
        var results = std.ArrayList(Fused).init(self.allocator);
        var iterator = fused.valueIterator();
        while (iterator.next()) |candidate| try results.append(candidate.*);
        std.sort.block(Fused, results.items, {}, struct {
            fn gt(_: void, a: Fused, b: Fused) bool {
                return a.score > b.score;
            }
        }.gt);
        return results.toOwnedSlice();
    }

    pub fn averageLatencyMs(self: *const Retriever) f64 {
        if (self.searches == 0) return 0.0;
        return self.total_ms / @as(f64, @floatFromInt(self.searches));
    }
};

pub fn normalizeScores(scores: []f64) void {
    if (scores.len == 0) return;
    var minimum: f64 = std.math.inf(f64);
    var maximum: f64 = -std.math.inf(f64);
    for (scores) |score| {
        if (score < minimum) minimum = score;
        if (score > maximum) maximum = score;
    }
    const range = maximum - minimum;
    for (scores) |*score| {
        if (range <= 0.0) {
            score.* = 1.0;
        } else {
            score.* = (score.* - minimum) / range;
        }
    }
}

pub const fusion_algorithm = "reciprocal_rank_fusion";

pub fn rrfFor(rank: u32, constant: f64) f64 {
    return Retriever.reciprocalRank(rank, constant);
}

pub const fusion_module = fusion;
