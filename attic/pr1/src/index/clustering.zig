const std = @import("std");
const centroid_manager = @import("centroid_manager.zig");

pub const Clusterer = struct {
    centroid: centroid_manager.Manager,
    dimensions: u16,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, count: u32, dimensions: u16) !*Clusterer {
        const manager = try centroid_manager.Manager.init(allocator, count, dimensions);
        var self_ptr = try allocator.alloc(Clusterer, 1);
        self_ptr.* = Clusterer{ .centroid = manager, .dimensions = dimensions, .lock = .{} };
        return self_ptr;
    }

    pub fn deinit(self: *Clusterer, allocator: std.mem.Allocator) void {
        self.centroid.deinit(allocator);
        allocator.free(self);
    }

    pub fn assign(self: *Clusterer, document_id: u64, vector: []const f32) u32 {
        return self.centroid.assign(document_id, vector);
    }

    pub fn updateBatch(self: *Clusterer, vectors: [][]const f32, assignments: []const u32, rate: f32) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < vectors.len) {
            const assignment = @intCast(assignments[i]);
            self.centroid.recentre(assignment, vectors[i], rate);
            i += 1;
        }
    }
};
