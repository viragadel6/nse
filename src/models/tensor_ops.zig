const std = @import("std");
const Tensor = @import("tensor.zig").Tensor;

pub fn add(a: []const f32, b: []const f32, output: []f32) void {
    var i: usize = 0;
    while (i < output.len) {
        output[i] = a[i] + b[i];
        i += 1;
    }
}

pub fn sub(a: []const f32, b: []const f32, output: []f32) void {
    var i: usize = 0;
    while (i < output.len) {
        output[i] = a[i] - b[i];
        i += 1;
    }
}

pub fn mul(a: []const f32, b: []const f32, output: []f32) void {
    var i: usize = 0;
    while (i < output.len) {
        output[i] = a[i] * b[i];
        i += 1;
    }
}

pub fn relu(input: []f32) void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] < 0) input[i] = 0;
        i += 1;
    }
}

pub fn gelu(input: []f32) void {
    var i: usize = 0;
    while (i < input.len) {
        const x = input[i];
        input[i] = 0.5 * x * (1.0 + std.math.tanh(0.7978845608028654 * (x + 0.044715 * x * x * x)));
        i += 1;
    }
}

pub fn softmax(logits: []f32) void {
    var max: f32 = std.math.min(f32);
    for (logits) |value| if (value > max) max = value;
    var sum: f32 = 0;
    for (logits) |value| sum += std.math.exp(value - max);
    var i: usize = 0;
    while (i < logits.len) {
        logits[i] = std.math.exp(logits[i] - max) / sum;
        i += 1;
    }
}

pub fn layerNorm(input: []f32, gamma: []const f32, beta: []const f32, epsilon: f32) void {
    var mean: f32 = 0;
    for (input) |value| mean += value;
    mean = mean / @as(f32, @intCast(input.len));
    var variance: f32 = 0;
    for (input) |value| variance += (value - mean) * (value - mean);
    variance = variance / @as(f32, @intCast(input.len));
    var i: usize = 0;
    while (i < input.len) {
        const normalized = (input[i] - mean) / std.math.sqrt(variance + epsilon);
        input[i] = gamma[i] * normalized + beta[i];
        i += 1;
    }
}

pub fn matmul(a: [][]const f32, b: [][]const f32, output: [][]f32) void {
    var i: usize = 0;
    while (i < output.len) {
        var j: usize = 0;
        while (j < output[i].len) {
            var sum: f32 = 0;
            var k: usize = 0;
            while (k < a[i].len) {
                sum += a[i][k] * b[k][j];
                k += 1;
            }
            output[i][j] = sum;
            j += 1;
        }
        i += 1;
    }
}

pub fn cosineSimilarity(a: []const f32, b: []const f32) !f32 {
    if (a.len != b.len) return error.LengthMismatch;
    var dot: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;
    var i: usize = 0;
    while (i < a.len) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
        i += 1;
    }
    const denom = std.math.sqrt(norm_a * norm_b);
    if (denom == 0) return 0;
    return dot / denom;
}

pub fn l2Normalize(vector: []f32) void {
    var norm: f32 = 0;
    for (vector) |value| norm += value * value;
    norm = std.math.sqrt(norm);
    if (norm == 0) return;
    var i: usize = 0;
    while (i < vector.len) {
        vector[i] = vector[i] / norm;
        i += 1;
    }
}
