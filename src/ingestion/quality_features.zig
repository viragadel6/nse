const std = @import("std");

pub const Features = struct {
    length: usize = 0,
    unique_tokens: usize = 0,
    link_density: f32 = 0,
    heading_ratio: f32 = 0,
    boilerplate_ratio: f32 = 0,
    language_confidence: f32 = 0,
    quality: f32 = 0,
};

pub fn compute(text: []const u8, links: usize, headings: usize) Features {
    var unique = std.StringHashMap(void).init(std.heap.page_allocator);
    defer unique.deinit();
    var tokens = std.mem.splitWhitespace(u8, text);
    while (tokens.next()) |token| { _ = unique.put(token, {}); }
    const length = text.len;
    const unique_count = unique.items.len;
    const link_density = if (length > 0) @as(f32, @intCast(links)) / @as(f32, @intCast(length)) else 0;
    const heading_ratio = if (length > 0) @as(f32, @intCast(headings)) / @as(f32, @intCast(length)) else 0;
    var quality: f32 = 0.5;
    if (unique_count > 100) quality += 0.2;
    if (link_density < 0.3) quality += 0.2;
    if (heading_ratio > 0.01) quality += 0.1;
    if (quality > 1.0) quality = 1.0;
    return Features{ .length = length, .unique_tokens = unique_count, .link_density = link_density, .heading_ratio = heading_ratio, .quality = quality };
}
