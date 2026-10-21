const std = @import("std");
const classifier = @import("../models/entity_classifier.zig");

pub const Handler = struct {
    allocator: std.mem.Allocator,
    classifier: classifier.Classifier,

    pub fn init(allocator: std.mem.Allocator) Handler {
        return Handler{ .allocator = allocator, .classifier = .{} };
    }

    pub fn handle(self: *Handler, body: []const u8) !struct { entities: []classifier.Entity } {
        const Request = struct { text: []const u8, categories: [][]const u8 = &[_][]const u8{} };
        const parsed = try request.parse(Request, self.allocator, body);
        defer parsed.deinit();
        return .{ .entities = try self.classifier.classify(parsed.value.text) };
    }

    pub fn deinitEntities(self: *Handler, entities: []classifier.Entity) void {
        for (entities) |*entity| {
            self.allocator.free(entity.category);
            self.allocator.free(entity.text);
        }
        self.allocator.free(entities);
    }
};
