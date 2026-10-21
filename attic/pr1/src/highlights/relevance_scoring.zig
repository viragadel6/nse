const std = @import("std");

pub const Scorer = struct {
    pub fn score(self: *const Scorer, passage: []const u8, query_terms: [][]const u8) f32 {
        var matches: f32 = 0;
        var i: usize = 0;
        while (i < query_terms.len) {
            const term = query_terms[i];
            var offset: usize = 0;
            while (true) {
                const found = std.mem.indexOfScalarPos(u8, passage, offset, term[0]) orelse break;
                if (found + term.len <= passage.len and std.mem.eqlIgnoreCase(u8, passage[found..][0..term.len], term)) {
                    matches += 1;
                    break;
                }
                offset = found + 1;
                if (offset >= passage.len) break;
            }
            i += 1;
        }
        return if (query_terms.len > 0) matches / @as(f32, @intCast(query_terms.len)) else 0;
    }
};
