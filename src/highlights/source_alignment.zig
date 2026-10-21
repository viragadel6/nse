const std = @import("std");

pub const Alignment = struct {
    document_id: u64,
    source_url: []const u8,
    span_start: usize,
    span_end: usize,
    supported: bool,
};

pub const Aligner = struct {
    pub fn align(self: *const Aligner, document_id: u64, source_url: []const u8, highlight_start: usize, highlight_end: usize, source_text: []const u8, highlight_text: []const u8) Alignment {
        var supported = false;
        var offset: usize = 0;
        while (true) {
            const found = std.mem.indexOfScalarPos(u8, source_text, offset, highlight_text[0]) orelse break;
            if (found + highlight_text.len <= source_text.len and std.mem.eqlIgnoreCase(u8, source_text[found..][0..highlight_text.len], highlight_text)) {
                supported = true;
                break;
            }
            offset = found + 1;
            if (offset >= source_text.len) break;
        }
        return Alignment{ .document_id = document_id, .source_url = source_url, .span_start = highlight_start, .span_end = highlight_end, .supported = supported };
    }
};
