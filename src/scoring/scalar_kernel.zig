const std = @import("std");

pub fn dot(left: []const f32, right: []const f32) !f64 {
    if (left.len != right.len) return error.DimensionMismatch;
    var sum: f64 = 0;
    var correction: f64 = 0;
    for (left, right) |a, b| {
        const value = @as(f64, a) * b - correction;
        const next = sum + value;
        correction = (next - sum) - value;
        sum = next;
    }
    if (!std.math.isFinite(sum)) return error.InvalidNumericValue;
    return sum;
}
