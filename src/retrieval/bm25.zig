const std = @import("std");

pub fn score(documents: usize, frequency: usize, term_frequency: f64, length: u32, average_length: f64, k1: f64, b: f64) f64 {
    if (documents == 0 or frequency == 0 or term_frequency <= 0 or average_length <= 0) return 0;
    const n: f64 = @floatFromInt(documents);
    const df: f64 = @floatFromInt(frequency);
    const dl: f64 = @floatFromInt(length);
    const inverse_frequency = @log(1.0 + (n - df + 0.5) / (df + 0.5));
    const denominator = term_frequency + k1 * (1.0 - b + b * dl / average_length);
    return inverse_frequency * term_frequency * (k1 + 1.0) / denominator;
}
