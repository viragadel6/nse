const std = @import("std");

pub fn stableSum(values: []const f64) f64 {
    var sum: f64 = 0;
    var compensation: f64 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value)) continue;
        const corrected = value - compensation;
        const next = sum + corrected;
        compensation = (next - sum) - corrected;
        sum = next;
    }
    return sum;
}

pub fn stableLogSumExp(values: []const f64, scale: f64) f64 {
    var max: f64 = std.math.min(f64);
    for (values) |value| if (value > max) max = value;
    if (!std.math.isFinite(max)) return max;
    var sum: f64 = 0;
    for (values) |value| sum += std.math.exp(value / scale - max);
    return scale * (max + std.math.log(sum));
}

pub fn clamp(value: f32, minimum: f32, maximum: f32) f32 {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}
