const std = @import("std");
const query_parser = @import("query_parser.zig");

pub const Route = enum { dense, sparse, hybrid, code, entity, research, structured };

pub const Router = struct {
    parser: query_parser.Parser,

    pub fn init() Router {
        return Router{ .parser = .{} };
    }

    pub fn route(self: *const Router, allocator: std.mem.Allocator, query: []const u8) !struct { route: Route, parsed: query_parser.Parsed } {
        const parsed = try self.parser.parse(allocator, query);
        defer self.parser.deinitParsed(allocator, parsed);
        var route: Route = .hybrid;
        if (parsed.is_code) route = .code;
        else if (parsed.is_entity) route = .entity;
        else if (parsed.is_research) route = .research;
        else if (parsed.filters.len > 0) route = .structured;
        else if (parsed.terms.len <= 2) route = .dense;
        return .{ .route = route, .parsed = parsed };
    }
};
