const std = @import("std");

pub const Entity = struct {
    category: []const u8,
    start: usize,
    end: usize,
    text: []const u8,
    confidence: f32,
    aliases: [][]const u8,
};

pub const Classifier = struct {
    threshold: f32 = 0.5,
    categories: [][]const u8 = &[_][]const u8{ "organization", "person", "product", "technology", "funding", "publication", "date" },

    pub fn classify(self: *const Classifier, text: []const u8) ![]Entity {
        var results = std.ArrayList(Entity).init(std.heap.page_allocator);
        var i: usize = 0;
        while (i < self.categories.len) {
            const category = self.categories[i];
            var offset: usize = 0;
            while (offset < text.len) {
                const found = std.mem.indexOfScalarPos(u8, text, offset, category[0]) orelse break;
                if (found + category.len <= text.len and std.mem.eqlIgnoreCase(u8, text[found..][0..category.len], category)) {
                    try results.append(Entity{ .category = category, .start = found, .end = found + category.len, .text = text[found..][0..category.len], .confidence = 0.9, .aliases = &[_][]const u8{} });
                }
                offset = found + 1;
            }
            i += 1;
        }
        return results.toOwnedSlice();
    }
};
