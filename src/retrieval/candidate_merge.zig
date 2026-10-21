const std = @import("std");
const Candidate = @import("sparse_index.zig").Candidate;

pub const Merge = struct {
    pub fn merge(self: *const Merge, sparse: []const Candidate, dense: []const Candidate) ![]Candidate {
        var combined = std.AutoHashMap(u64, Candidate).init(std.heap.page_allocator);
        defer combined.deinit();
        for (sparse) |candidate| {
            const entry = try combined.getOrPut(candidate.id);
            if (!entry.found_existing) entry.value_ptr.* = candidate;
        }
        for (dense) |candidate| {
            const entry = try combined.getOrPut(candidate.id);
            if (!entry.found_existing) entry.value_ptr.* = candidate;
        }
        var output = std.ArrayList(Candidate).init(std.heap.page_allocator);
        errdefer output.deinit();
        var iterator = combined.valueIterator();
        while (iterator.next()) |entry| try output.append(entry.*);
        std.mem.sort(Candidate, output.items, {}, better);
        return output.toOwnedSlice();
    }

    fn better(_: void, left: Candidate, right: Candidate) bool {
        return left.score > right.score or (left.score == right.score and left.id < right.id);
    }
};
