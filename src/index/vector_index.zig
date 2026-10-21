const std = @import("std");
const Store = @import("../storage/document_store.zig").Store;
const Candidate = @import("../retrieval/sparse_index.zig").Candidate;
const Deadline = @import("../runtime/cancellation.zig").Deadline;
const quantization = @import("binary_quantization.zig");
const lookup = @import("../scoring/lookup_tables.zig");
const scalar = @import("../scoring/scalar_kernel.zig");
const Heap = @import("../retrieval/candidate_heap.zig").Heap;

pub const Record = struct {
    id: u64,
    binary_vector: quantization.Packed,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    records: []Record,
    model_version: u64,

    pub fn build(allocator: std.mem.Allocator, store: *const Store, model_version: u64) !Index {
        var records = std.ArrayList(Record).init(allocator);
        errdefer records.deinit();
        var iterator = store.entries.valueIterator();
        while (iterator.next()) |entry| {
            const document = entry.*;
            if (document.binary_vector) |binary_vector| {
                if (document.model_version != model_version) return error.IncompatibleEmbeddingModel;
                try records.append(.{ .id = document.id, .binary_vector = binary_vector });
            }
        }
        return .{ .allocator = allocator, .records = try records.toOwnedSlice(), .model_version = model_version };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.records);
    }

    fn better(_: void, left: Candidate, right: Candidate) bool {
        return left.score > right.score or (left.score == right.score and left.id < right.id);
    }

    pub fn search(self: *const Index, allocator: std.mem.Allocator, store: *const Store, query: []const f32, pool: u32, deadline: Deadline) ![]Candidate {
        const normalized = try quantization.normalize(allocator, query);
        defer allocator.free(normalized);
        const table = try lookup.Table.init(normalized);
        if (self.records.len == 0) return allocator.alloc(Candidate, 0);
        var heap = try Heap.init(allocator, @min(pool, self.records.len));
        defer heap.deinit();
        for (self.records, 0..) |record, position| {
            if (position % 256 == 0) try deadline.check();
            heap.offer(.{ .id = record.id, .score = table.score(record.binary_vector) });
        }
        const results = try heap.finish();
        errdefer allocator.free(results);
        for (results) |*candidate| {
            try deadline.check();
            const document = store.entries.get(candidate.id) orelse return error.IndexDocumentMissing;
            candidate.score = try scalar.dot(normalized, document.embedding orelse return error.IndexEmbeddingMissing);
        }
        std.mem.sort(Candidate, results, {}, better);
        return results;
    }
};
