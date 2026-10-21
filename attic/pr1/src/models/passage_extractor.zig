const std = @import("std");

pub const Passage = struct {
    start: usize,
    end: usize,
    text: []const u8,
    score: f32,
    heading: []const u8,
};

pub const Extractor = struct {
    max_passage_length: usize = 512,
    min_passage_length: usize = 32,
};

pub fn extract(self: *const Extractor, document: []const u8, query_terms: [][]const u8, max_passages: usize) ![]Passage {
    var passages = std.ArrayList(Passage).init(std.heap.page_allocator);
    var position: usize = 0;
    while (position < document.len and passages.items.len < max_passages) {
        const end = @min(document.len, position + self.max_passage_length);
        if (end - position < self.min_passage_length) break;
        var score: f32 = 0;
        var i: usize = 0;
        while (i < query_terms.len) {
            const term = query_terms[i];
            var offset: usize = 0;
            while (offset < end - position) {
                const found = std.mem.indexOfScalarPos(u8, document, position + offset, term[0]) orelse break;
                if (found < end and std.mem.eqlIgnoreCase(u8, document[found..][0..@min(term.len, end - found)], term)) {
                    score += 1;
                    break;
                }
                offset = found - position + 1;
            }
            i += 1;
        }
        try passages.append(Passage{ .start = position, .end = end, .text = document[position..end], .score = score, .heading = "" });
        position = end;
    }
    return passages.toOwnedSlice();
}
