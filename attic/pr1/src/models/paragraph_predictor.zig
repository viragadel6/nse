const std = @import("std");

pub const Boundary = struct {
    position: usize,
    confidence: f32,
};

pub const Predictor = struct {
    threshold: f32 = 0.5,
    min_paragraph_length: usize = 32,
    max_paragraph_length: usize = 2048,
};

pub fn predict(self: *const Predictor, text: []const u8, boundaries: []Boundary) usize {
    var count: usize = 0;
    var position: usize = 0;
    while (position < text.len and count < boundaries.len) {
        const end = std.mem.indexOfScalarPos(u8, text, position, '.') orelse text.len;
        if (end - position >= self.min_paragraph_length and end - position <= self.max_paragraph_length) {
            boundaries[count] = .{ .position = end + 1, .confidence = 0.9 };
            count += 1;
            position = end + 1;
            while (position < text.len and text[position] == ' ') position += 1;
        } else {
            position = end + 1;
        }
    }
    return count;
}
