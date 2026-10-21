const std = @import("std");

pub const Parsed = struct {
    terms: [][]const u8,
    entities: [][]const u8,
    phrases: [][]const u8,
    filters: [][]const u8,
    is_code: bool,
    is_research: bool,
    is_entity: bool,
};

pub const Parser = struct {
    stopwords: [][]const u8 = &[_][]const u8{ "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "from" },

    pub fn parse(self: *const Parser, allocator: std.mem.Allocator, query: []const u8) !Parsed {
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
        var terms = std.ArrayList([]const u8).init(allocator);
        var entities = std.ArrayList([]const u8).init(allocator);
        var phrases = std.ArrayList([]const u8).init(allocator);
        var filters = std.ArrayList([]const u8).init(allocator);
        var iterator = std.mem.splitWhitespace(u8, query);
        var is_code = false;
        var is_research = false;
        var is_entity = false;
        while (iterator.next()) |token| {
            if (token.len == 0) continue;
            if (std.mem.indexOfScalar(u8, token, ':') != null) {
                try filters.append(try allocator.dupe(u8, token));
            } else if (token[0] == '@') {
                is_entity = true;
                try entities.append(try allocator.dupe(u8, token[1..]));
            } else if (std.mem.indexOfScalar(u8, token, '_') != null or std.mem.indexOfScalar(u8, token, '(') != null) {
                is_code = true;
                try terms.append(try allocator.dupe(u8, token));
            } else if (token.len > 3 and (token[0] == 'h' or token[0] == 'H') and std.ascii.eqlIgnoreCase(token, "how") or std.ascii.eqlIgnoreCase(token, "why")) {
                is_research = true;
                try terms.append(try allocator.dupe(u8, token));
            } else {
                var skip = false;
                for (self.stopwords) |stopword| if (std.ascii.eqlIgnoreCase(token, stopword)) { skip = true; break; }
                if (!skip) try terms.append(try allocator.dupe(u8, token));
            }
        }
        return Parsed{
            .terms = try terms.toOwnedSlice(),
            .entities = try entities.toOwnedSlice(),
            .phrases = try phrases.toOwnedSlice(),
            .filters = try filters.toOwnedSlice(),
            .is_code = is_code,
            .is_research = is_research,
            .is_entity = is_entity,
        };
    }

    pub fn deinitParsed(self: *const Parser, allocator: std.mem.Allocator, parsed: Parsed) void {
        for (parsed.terms) |term| allocator.free(term);
        for (parsed.entities) |entity| allocator.free(entity);
        for (parsed.phrases) |phrase| allocator.free(phrase);
        for (parsed.filters) |filter| allocator.free(filter);
        allocator.free(parsed.terms);
        allocator.free(parsed.entities);
        allocator.free(parsed.phrases);
        allocator.free(parsed.filters);
    }
};
