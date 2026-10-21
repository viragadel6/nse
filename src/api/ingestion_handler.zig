const std = @import("std");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const documents = @import("../storage/document.zig");
const request = @import("request_codec.zig");

pub const Handler = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,

    pub fn init(engine: *Engine, allocator: std.mem.Allocator) Handler {
        return Handler{ .engine = engine, .allocator = allocator };
    }

    pub fn handle(self: *Handler, body: []const u8) !struct { accepted: bool, document_id: u64 } {
        const parsed = try request.parse(documents.Input, self.allocator, body);
        defer parsed.deinit();
        const mutation = try self.engine.ingest(self.allocator, parsed.value);
        return .{ .accepted = true, .document_id = mutation.document_id };
    }
};
