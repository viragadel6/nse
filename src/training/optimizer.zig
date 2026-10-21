const std = @import("std");

pub const AdamW = struct {
    learning_rate: f32,
    beta1: f32 = 0.9,
    beta2: f32 = 0.999,
    epsilon: f32 = 0.000001,
    weight_decay: f32 = 0.01,
    m: []f32,
    v: []f32,
    step: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, parameter_count: usize, learning_rate: f32) !AdamW {
        const m = try allocator.alloc(f32, parameter_count);
        const v = try allocator.alloc(f32, parameter_count);
        for (m) |*value| value.* = 0;
        for (v) |*value| value.* = 0;
        return AdamW{ .learning_rate = learning_rate, .m = m, .v = v };
    }

    pub fn deinit(self: *AdamW, allocator: std.mem.Allocator) void {
        allocator.free(self.m);
        allocator.free(self.v);
    }

    pub fn update(self: *AdamW, parameters: []f32, gradients: []const f32) !void {
        if (parameters.len != gradients.len) return error.LengthMismatch;
        self.step += 1;
        var i: usize = 0;
        while (i < parameters.len) {
            const grad = gradients[i];
            if (!std.math.isFinite(grad)) return error.NonFiniteGradient;
            self.m[i] = self.beta1 * self.m[i] + (1 - self.beta1) * grad;
            self.v[i] = self.beta2 * self.v[i] + (1 - self.beta2) * grad * grad;
            const bias_correction1 = 1 - std.math.pow(self.beta1, @as(f32, @floatFromInt(self.step)));
            const bias_correction2 = 1 - std.math.pow(self.beta2, @as(f32, @floatFromInt(self.step)));
            const m_hat = self.m[i] / bias_correction1;
            const v_hat = self.v[i] / bias_correction2;
            parameters[i] -= self.learning_rate * (m_hat / (std.math.sqrt(v_hat) + self.epsilon) + self.weight_decay * parameters[i]);
            i += 1;
        }
    }
};

pub const Sgd = struct {
    learning_rate: f32,
    momentum: f32 = 0.9,
    weight_decay: f32 = 0,
    velocity: []f32,
    step: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, parameter_count: usize, learning_rate: f32) !Sgd {
        const velocity = try allocator.alloc(f32, parameter_count);
        for (velocity) |*value| value.* = 0;
        return Sgd{ .learning_rate = learning_rate, .velocity = velocity };
    }

    pub fn deinit(self: *Sgd, allocator: std.mem.Allocator) void {
        allocator.free(self.velocity);
    }

    pub fn update(self: *Sgd, parameters: []f32, gradients: []const f32) !void {
        if (parameters.len != gradients.len) return error.LengthMismatch;
        self.step += 1;
        var i: usize = 0;
        while (i < parameters.len) {
            const grad = gradients[i];
            if (!std.math.isFinite(grad)) return error.NonFiniteGradient;
            self.velocity[i] = self.momentum * self.velocity[i] + grad;
            parameters[i] -= self.learning_rate * (self.velocity[i] + self.weight_decay * parameters[i]);
            i += 1;
        }
    }
};
