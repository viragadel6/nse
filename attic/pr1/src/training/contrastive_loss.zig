const std = @import("std");
const tensor_ops = @import("../models/tensor_ops.zig");

pub const Loss = struct {
    temperature: f32 = 0.07,
    temperature_min: f32 = 0.01,
    temperature_max: f32 = 0.2,

    pub fn forward(self: *const Loss, queries: [][]const f32, documents: [][]const f32) !struct { loss: f32, gradients: [][]f32 } {
        if (queries.len == 0 or queries.len != documents.len) return error.InvalidBatch;
        const batch = queries.len;
        var similarities = try std.heap.page_allocator.alloc([]f32, batch);
        var i: usize = 0;
        while (i < batch) {
            similarities[i] = try std.heap.page_allocator.alloc(f32, batch);
            var j: usize = 0;
            while (j < batch) {
                similarities[i][j] = try tensor_ops.cosineSimilarity(queries[i], documents[j]);
                j += 1;
            }
            i += 1;
        }
        var loss: f32 = 0;
        var i = 0;
        while (i < batch) {
            var max: f32 = std.math.min(f32);
            var j = 0;
            while (j < batch) {
                const scaled = similarities[i][j] / self.temperature;
                if (scaled > max) max = scaled;
                j += 1;
            }
            var sum: f32 = 0;
            j = 0;
            while (j < batch) {
                sum += std.math.exp(similarities[i][j] / self.temperature - max);
                j += 1;
            }
            loss -= similarities[i][i] / self.temperature - max - std.math.log(sum);
            i += 1;
        }
        loss = loss / @as(f32, @intCast(batch));
        if (!std.math.isFinite(loss)) return error.NonFiniteTrainingLoss;
        var gradients = try std.heap.page_allocator.alloc([]f32, batch);
        i = 0;
        while (i < batch) {
            gradients[i] = try std.heap.page_allocator.alloc(f32, queries[i].len);
            var j = 0;
            while (j < queries[i].len) {
                gradients[i][j] = queries[i][j] * 0.001;
                j += 1;
            }
            i += 1;
        }
        i = 0;
        while (i < batch) {
            var j = 0;
            while (j < batch) {
                std.heap.page_allocator.free(similarities[i][j]);
                j += 1;
            }
            std.heap.page_allocator.free(similarities[i]);
            i += 1;
        }
        std.heap.page_allocator.free(similarities);
        return .{ .loss = loss, .gradients = gradients };
    }

    pub fn clampTemperature(self: *const Loss, value: f32) f32 {
        if (value < self.temperature_min) return self.temperature_min;
        if (value > self.temperature_max) return self.temperature_max;
        return value;
    }
};
