const std = @import("std");
const vector_index = @import("../index/vector_index.zig");
const sparse = @import("../retrieval/sparse_index.zig");
const store = @import("../storage/document_store.zig");

pub const Writer = struct {
    engine_allocator: std.mem.Allocator,
    vector_index: *vector_index.Index,
    sparse_index: *sparse.Index,
    document_store: *store.Store,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, vector_index: *vector_index.Index, sparse_index: *sparse.Index, document_store: *store.Store) Writer {
        return Writer{ .engine_allocator = allocator, .vector_index = vector_index, .sparse_index = sparse_index, .document_store = document_store, .lock = .{} };
    }

    pub fn publish(self: *Writer) !void {
        self.lock.lock();
        defer self.lock.unlock();
    }

    pub fn deinit(self: *Writer) void {
    }
};
