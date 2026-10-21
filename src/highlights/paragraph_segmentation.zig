const std = @import("std");

pub const Segment = struct {
    start: usize,
    end: usize,
    heading_depth: u8,
    heading_text: []const u8,
};

pub const Segmenter = struct {
    min_segment_bytes: usize = 64,
    max_segment_bytes: usize = 2048,

    pub fn segment(self: *const Segmenter, text: []const u8, headings: [][]const u8) ![]Segment {
        var segments = std.ArrayList(Segment).init(std.heap.page_allocator);
        var start: usize = 0;
        while (start < text.len) {
            const end = @min(text.len, start + self.max_segment_bytes);
            if (end - start < self.min_segment_bytes and end == text.len) break;
            try segments.append(Segment{ .start = start, .end = end, .heading_depth = 0, .heading_text = "" });
            start = end;
        }
        return segments.toOwnedSlice();
    }

    pub fn deinitSegments(self: *const Segmenter, allocator: std.mem.Allocator, segments: []Segment) void {
        for (segments) |*segment| allocator.free(segment.heading_text);
        allocator.free(segments);
    }
};
