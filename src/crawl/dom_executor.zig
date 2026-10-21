const std = @import("std");

pub const DomResult = struct {
    html: []u8,
    links: [][]u8,
    rendered_ms: i64,
};

pub fn execute(allocator: std.mem.Allocator, html: []const u8, deadline_ms: u32) !DomResult {
    _ = allocator;
    _ = html;
    _ = deadline_ms;
    var output = std.ArrayList(u8).init(allocator);
    try output.appendSlice(html);
    return DomResult{ .html = try output.toOwnedSlice(), .links = &[_][]u8{}, .rendered_ms = 0 };
}
