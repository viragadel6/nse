const std = @import("std");
const simd_dispatch = @import("simd_dispatch.zig");

pub const CandidateScore = struct {
    document_id: u64,
    score: f32,
    binary_score: f32,
    norm_compensated: f32,
};

pub const Scanner = struct {
    dispatch: simd_dispatch.Dispatch,
    compensator: @import("norm_compensation.zig").Compensator,

    pub fn init() Scanner {
        return Scanner{ .dispatch = simd_dispatch.Dispatch.init(), .compensator = .{} };
    }

    pub fn scan(self: *Scanner, query_bits: []const u8, documents: [][]const u8, norms: []f32, query_norm: f32) ![]CandidateScore {
        var results = try std.heap.page_allocator.alloc(CandidateScore, documents.len);
        var i: usize = 0;
        while (i < documents.len) {
            const matches = try self.dispatch.scoreBinary(query_bits, documents[i], documents[i].len);
            const binary_score = @floatCast(@intCast(matches)) / @as(f32, @intCast(documents[i].len * 8));
            const compensated = self.compensator.compensate(binary_score, norms[i], query_norm, norms[i]);
            results[i] = CandidateScore{ .document_id = @as(u64, @intCast(i)), .score = compensated, .binary_score = binary_score, .norm_compensated = compensated };
            i += 1;
        }
        return results;
    }

    pub fn deinit(self: *Scanner) void {
    }
};
