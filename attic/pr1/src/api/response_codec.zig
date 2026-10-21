const std = @import("std");

pub const SearchResult = struct {
    document_id: u64,
    rank: u32,
    url: []const u8,
    title: []const u8,
    score: f64,
    lexical_score: ?f64,
    semantic_score: ?f64,
    snippet: []const u8,
};

pub const SearchResponse = struct {
    index_generation: u64,
    model_version: u64,
    complete: bool,
    results: []SearchResult,
};

pub fn encodeSearch(allocator: std.mem.Allocator, response: SearchResponse) ![]u8 {
    return try std.json.stringifyAlloc(allocator, response, .{ .emit_null_optional_fields = true });
}
