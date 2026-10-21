const std = @import("std");

pub const Filter = enum { domain, language, date_range, quality, document_type, freshness };

pub const Predicate = struct {
    field: Filter,
    values: [][]const u8,
    after: i64 = 0,
    before: i64 = 0,
    minimum_quality: f32 = 0,
};

pub const Engine = struct {
    predicates: []Predicate,
    lock: std.Thread.Mutex,

    pub fn init(predicates: []Predicate) Engine {
        return Engine{ .predicates = predicates, .lock = .{} };
    }

    pub fn matches(self: *const Engine, domain: []const u8, language: []const u8, published_at: i64, quality: f32) bool {
        var i: usize = 0;
        while (i < self.predicates.len) {
            const predicate = self.predicates[i];
            switch (predicate.field) {
                .domain => {
                    var found = false;
                    var j: usize = 0;
                    while (j < predicate.values.len) {
                        if (std.ascii.eqlIgnoreCase(domain, predicate.values[j])) { found = true; break; }
                        j += 1;
                    }
                    if (!found) return false;
                }
                .language => {
                    if (!std.ascii.eqlIgnoreCase(language, predicate.values[0])) return false;
                }
                .date_range => {
                    if (published_at < predicate.after or published_at > predicate.before) return false;
                }
                .quality => {
                    if (quality < predicate.minimum_quality) return false;
                }
                else => {},
            }
            i += 1;
        }
        return true;
    }
};
