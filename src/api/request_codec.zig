const std = @import("std");

pub const Mode = enum { sparse, dense, hybrid };
pub const Filters = struct {
    domains: []const []const u8 = &.{},
    language: ?[]const u8 = null,
    minimum_quality: f32 = 0,
    published_after: ?i64 = null,
    published_before: ?i64 = null,
};

pub const Search = struct {
    query: []const u8,
    mode: Mode = .hybrid,
    result_count: u32 = 10,
    deadline_ms: ?u32 = null,
    embedding: ?[]const f32 = null,
    model_version: u64 = 1,
    filters: Filters = .{},
    highlights: bool = true,

    pub fn validate(self: Search) !void {
        if (std.mem.trim(u8, self.query, " \r\n\t").len == 0 or !std.unicode.utf8ValidateSlice(self.query) or self.result_count == 0) return error.InvalidQuery;
        if (self.deadline_ms != null and self.deadline_ms.? == 0) return error.InvalidDeadline;
        if (!std.math.isFinite(self.filters.minimum_quality) or self.filters.minimum_quality < 0 or self.filters.minimum_quality > 1) return error.InvalidFilter;
        if (self.filters.published_after != null and self.filters.published_before != null and self.filters.published_after.? > self.filters.published_before.?) return error.InvalidFilter;
        for (self.filters.domains) |domain| if (domain.len == 0) return error.InvalidFilter;
    }
};

pub const Highlights = struct { query: []const u8, document_ids: []const u64, window_bytes: u32 = 320 };
pub const Deletion = struct { document_id: u64 };

pub fn parse(comptime T: type, allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" });
}
