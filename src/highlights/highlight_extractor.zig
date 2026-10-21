const std = @import("std");
const tokenizer = @import("../models/tokenizer.zig");

pub const Highlight = struct { start: usize, end: usize, text: []const u8, score: f64 };

pub fn extract(allocator: std.mem.Allocator, query: []const u8, source: []const u8, window_bytes: usize) !Highlight {
    if (!std.unicode.utf8ValidateSlice(source) or window_bytes == 0) return error.InvalidHighlightInput;
    const query_terms = try tokenizer.terms(allocator, query);
    defer {
        for (query_terms) |term| allocator.free(term);
        allocator.free(query_terms);
    }
    var best_start: usize = 0;
    var best_end: usize = @min(source.len, window_bytes);
    var best_score: f64 = 0;
    var candidates = tokenizer.Iterator{ .text = source };
    while (candidates.next()) |candidate| {
        var matched = false;
        for (query_terms) |term| if (std.ascii.eqlIgnoreCase(candidate.text, term)) { matched = true; break; };
        if (!matched) continue;
        var start = candidate.start -| (window_bytes / 3);
        while (start > 0 and source[start - 1] != ' ' and source[start - 1] != '\n') start -= 1;
        var end = @min(source.len, start +| window_bytes);
        while (end < source.len and (source[end] & 0xC0) == 0x80) end += 1;
        while (end < source.len and source[end] != ' ' and source[end] != '\n' and end - start < window_bytes +| 128) end += 1;
        var tokens = tokenizer.Iterator{ .text = source[start..end] };
        var score: f64 = 0;
        while (tokens.next()) |token| for (query_terms) |term| if (std.ascii.eqlIgnoreCase(token.text, term)) { score += 1; };
        if (score > best_score) {
            best_start = start;
            best_end = end;
            best_score = score;
        }
    }
    while (best_end < source.len and (source[best_end] & 0xC0) == 0x80) best_end += 1;
    return .{ .start = best_start, .end = best_end, .text = source[best_start..best_end], .score = best_score };
}
