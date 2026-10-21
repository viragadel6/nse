const std = @import("std");
const Candidate = @import("sparse_index.zig").Candidate;

pub fn better(left: Candidate, right: Candidate) bool {
    return left.score > right.score or (left.score == right.score and left.id < right.id);
}

fn before(_: void, left: Candidate, right: Candidate) bool {
    return better(left, right);
}

pub const Heap = struct {
    items: std.ArrayList(Candidate),
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Heap {
        if (capacity == 0) return error.InvalidCandidatePool;
        var items = std.ArrayList(Candidate).init(allocator);
        try items.ensureTotalCapacity(capacity);
        return .{ .items = items, .capacity = capacity };
    }

    pub fn deinit(self: *Heap) void {
        self.items.deinit();
    }

    pub fn offer(self: *Heap, candidate: Candidate) void {
        if (self.items.items.len < self.capacity) {
            self.items.appendAssumeCapacity(candidate);
            var child = self.items.items.len - 1;
            while (child > 0) {
                const parent = (child - 1) / 2;
                if (!better(self.items.items[parent], self.items.items[child])) break;
                std.mem.swap(Candidate, &self.items.items[parent], &self.items.items[child]);
                child = parent;
            }
            return;
        }
        if (!better(candidate, self.items.items[0])) return;
        self.items.items[0] = candidate;
        var parent: usize = 0;
        while (parent < self.items.items.len / 2) {
            var child = parent * 2 + 1;
            if (child + 1 < self.items.items.len and better(self.items.items[child], self.items.items[child + 1])) child += 1;
            if (!better(self.items.items[parent], self.items.items[child])) break;
            std.mem.swap(Candidate, &self.items.items[parent], &self.items.items[child]);
            parent = child;
        }
    }

    pub fn finish(self: *Heap) ![]Candidate {
        std.mem.sort(Candidate, self.items.items, {}, before);
        return self.items.toOwnedSlice();
    }
};
