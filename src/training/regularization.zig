const std = @import("std");

pub const Regularizer = struct {
    l2_weight: f32 = 0.01,
    variance_weight: f32 = 0.01,
    covariance_weight: f32 = 0.01,
    decorrelation_weight: f32 = 0.01,

    pub fn l2(self: *const Regularizer, parameters: []const f32) f32 {
        var sum: f32 = 0;
        for (parameters) |value| sum += value * value;
        return self.l2_weight * sum;
    }

    pub fn variance(self: *const Regularizer, embeddings: [][]const f32) f32 {
        var total: f32 = 0;
        for (embeddings) |embedding| {
            var mean: f32 = 0;
            for (embedding) |value| mean += value;
            mean = mean / @as(f32, @intCast(embedding.len));
            var variance: f32 = 0;
            for (embedding) |value| variance += (value - mean) * (value - mean);
            variance = variance / @as(f32, @intCast(embedding.len));
            total += 1 / (variance + 0.00001);
        }
        return self.variance_weight * total;
    }

    pub fn covariance(self: *const Regularizer, embeddings: [][]const f32) f32 {
        var total: f32 = 0;
        var i: usize = 0;
        while (i < embeddings.len) {
            var j: usize = i + 1;
            while (j < embeddings.len) {
                var dot: f32 = 0;
                var k: usize = 0;
                while (k < embeddings[i].len) {
                    dot += embeddings[i][k] * embeddings[j][k];
                    k += 1;
                }
                total += dot * dot;
                j += 1;
            }
            i += 1;
        }
        return self.covariance_weight * total;
    }

    pub fn antiCollapse(self: *const Regularizer, embeddings: [][]const f32) f32 {
        var centroid: []f32 = try? std.heap.page_allocator.alloc(f32, embeddings[0].len) or return 0;
        defer std.heap.page_allocator.free(centroid);
        for (centroid) |*value| value.* = 0;
        for (embeddings) |embedding| for (embedding, 0..) |value, i| centroid[i] += value;
        var i: usize = 0;
        while (i < embeddings[0].len) { centroid[i] = centroid[i] / @as(f32, @intCast(embeddings.len)); i += 1; }
        var spread: f32 = 0;
        for (embeddings) |embedding| {
            var d: f32 = 0;
            var j: usize = 0;
            while (j < embedding.len) { d += (embedding[j] - centroid[j]) * (embedding[j] - centroid[j]); j += 1; }
            spread += d;
        }
        return self.decorrelation_weight * spread / @as(f32, @intCast(embeddings.len));
    }
};
