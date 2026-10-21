const std = @import("std");

pub const Decision = enum { accept, reject, quarantine };

pub const Filter = struct {
    minimum_length: usize = 50,
    maximum_length: usize = 4 * 1024 * 1024,
    minimum_quality: f32 = 0.0,

    pub fn filter(self: *const Filter, text: []const u8, quality: f32) Decision {
        if (text.len < self.minimum_length) return .reject;
        if (text.len > self.maximum_length) return .reject;
        if (quality < self.minimum_quality) return .reject;
        return .accept;
    }
};
