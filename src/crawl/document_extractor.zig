const std = @import("std");
const parser = @import("html_parser.zig");

pub const Extracted = struct {
    title: []u8,
    text: []u8,
    language: []u8,
    canonical: ?[]const u8,
    links: []parser.Link,
    paragraphs: []parser.Paragraph,
};

pub fn extract(allocator: std.mem.Allocator, html: []const u8, maximum_depth: u32) !Extracted {
    const parsed = try parser.parse(allocator, html, maximum_depth);
    defer parsed.deinit();
    return Extracted{
        .title = parsed.title,
        .text = parsed.text,
        .language = parsed.language,
        .canonical = parsed.canonical,
        .links = parsed.links,
        .paragraphs = parsed.paragraphs,
    };
}
