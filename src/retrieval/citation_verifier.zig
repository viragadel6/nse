const std = @import("std");

pub const Claim = struct {
    text: []const u8,
    source_document_id: u64,
    source_url: []const u8,
    evidence_span_start: usize = 0,
    evidence_span_end: usize = 0,
};

pub const Status = enum { supported, partial, contradicted, insufficient };

pub const Result = struct {
    claim: Claim,
    status: Status,
    confidence: f32 = 0,
    contradictions: [][]const u8 = &[_][]const u8{},
};

pub const Verifier = struct {
    threshold: f32 = 0.5,

    pub fn verify(self: *const Verifier, claim: Claim, document_text: []const u8) Result {
        var confidence: f32 = 0;
        var overlap: usize = 0;
        var iterator = std.mem.splitWhitespace(u8, claim.text);
        while (iterator.next()) |term| {
            if (std.mem.indexOfScalar(u8, document_text, term[0]) != null) overlap += 1;
        }
        confidence = if (claim.text.len > 0) @as(f32, @intCast(overlap)) / @as(f32, @intCountWords(claim.text)) else 0;
        var status: Status = .insufficient;
        if (confidence >= self.threshold) status = .supported;
        else if (confidence > 0.2) status = .partial;
        return Result{ .claim = claim, .status = status, .confidence = confidence };
    }

    fn intCountWords(text: []const u8) usize {
        var count: usize = 0;
        var iterator = std.mem.splitWhitespace(u8, text);
        while (iterator.next()) |_| count += 1;
        return count;
    }
};
