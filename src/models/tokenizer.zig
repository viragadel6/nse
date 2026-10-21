const std = @import("std");

pub const Token = struct { text: []const u8, start: usize, end: usize };

pub const Iterator = struct {
    text: []const u8,
    offset: usize = 0,

    fn word(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte >= 128 or byte == '_';
    }

    pub fn next(self: *Iterator) ?Token {
        while (self.offset < self.text.len and !word(self.text[self.offset])) self.offset += 1;
        if (self.offset == self.text.len) return null;
        const start = self.offset;
        while (self.offset < self.text.len and word(self.text[self.offset])) self.offset += 1;
        return .{ .text = self.text[start..self.offset], .start = start, .end = self.offset };
    }
};

pub fn normalized(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, text);
    for (output) |*byte| byte.* = std.ascii.toLower(byte.*);
    return output;
}

pub fn terms(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var output = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (output.items) |term| allocator.free(term);
        output.deinit();
    }
    var iterator = Iterator{ .text = text };
    while (iterator.next()) |token| try output.append(try normalized(allocator, token.text));
    return output.toOwnedSlice();
}
