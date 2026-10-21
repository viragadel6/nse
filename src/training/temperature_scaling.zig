const std = @import("std");

pub const Scaler = struct {
    value: f32 = 0.07,
    min: f32 = 0.01,
    max: f32 = 0.2,
    learning_rate: f32 = 0.01,

    pub fn init(value: f32, min: f32, max: f32, learning_rate: f32) Scaler {
        return Scaler{ .value = value, .min = min, .max = max, .learning_rate = learning_rate };
    }

    pub fn update(self: *Scaler, gradient: f32) void {
        self.value -= self.learning_rate * gradient;
        if (self.value < self.min) self.value = self.min;
        if (self.value > self.max) self.value = self.max;
    }

    pub fn current(self: *const Scaler) f32 {
        return self.value;
    }
};
