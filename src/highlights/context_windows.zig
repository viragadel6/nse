const std = @import("std");

pub const Window = struct {
    start: usize,
    end: usize,
    text: []const u8,
    relevance: f32,
};

pub const Builder = struct {
    window_bytes: usize = 320,
    context_bytes: usize = 64,

    pub fn build(self: *const Builder, source: []const u8, start: usize, end: usize) Window {
        var window_start = if (start > self.context_bytes) start - self.context_bytes else 0;
        var window_end = @min(source.len, end + self.context_bytes);
        while (window_start > 0 and source[window_start - 1] != ' ' and source[window_start - 1] != '\\n') window_start -= 1;
        while (window_end < source.len and source[window_end] != ' ' and source[window_end] != '\\n') window_end += 1;
        return Window{ .start = window_start, .end = window_end, .text = source[window_start..window_end], .relevance = 0 };
    }
};
