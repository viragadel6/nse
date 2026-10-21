const std = @import("std");

pub const Centroid = struct {
    id: u32,
    vector: []f32,
    document_count: u64 = 0,
    assignment_sum: []f32 = undefined,
};

pub const Manager = struct {
    count: u32,
    dimensions: u16,
    centroids: []Centroid,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, count: u32, dimensions: u16) !Manager {
        var centroids = try allocator.alloc(Centroid, @intCast(count));
        var i: u32 = 0;
        while (i < count) {
            const vector = try allocator.alloc(f32, @intCast(dimensions));
            centroids[i] = Centroid{ .id = i, .vector = vector, .document_count = 0, .assignment_sum = try allocator.alloc(f32, @intCast(dimensions)) };
            i += 1;
        }
        return Manager{ .count = count, .dimensions = dimensions, .centroids = centroids, .lock = .{} };
    }

    pub fn deinit(self: *Manager, allocator: std.mem.Allocator) void {
        var i: u32 = 0;
        while (i < self.count) {
            allocator.free(self.centroids[i].vector);
            allocator.free(self.centroids[i].assignment_sum);
            i += 1;
        }
        allocator.free(self.centroids);
    }

    pub fn assign(self: *Manager, document_id: u64, vector: []const f32) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        var best: u32 = 0;
        var best_distance: f32 = std.math.max(f32);
        var i: u32 = 0;
        while (i < self.count) {
            var distance: f32 = 0;
            var j: usize = 0;
            while (j < @intCast(self.dimensions)) {
                const delta = vector[j] - self.centroids[i].vector[j];
                distance += delta * delta;
                j += 1;
            }
            if (distance < best_distance) {
                best_distance = distance;
                best = i;
            }
            i += 1;
        }
        self.centroids[best].document_count += 1;
        return best;
    }

    pub fn recentre(self: *Manager, index: u32, vector: []const f32, rate: f32) void {
        self.lock.lock();
        defer self.lock.unlock();
        var j: usize = 0;
        while (j < @intCast(self.dimensions)) {
            self.centroids[index].vector[j] += rate * (vector[j] - self.centroids[index].vector[j]);
            j += 1;
        }
    }

    pub fn occupancy(self: *Manager) []u64 {
        var counts = try? std.heap.page_allocator.alloc(u64, @intCast(self.count)) or return &[_]u64{};
        var i: u32 = 0;
        while (i < self.count) { counts[i] = self.centroids[i].document_count; i += 1; }
        return counts;
    }
};
