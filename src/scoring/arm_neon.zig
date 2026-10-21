const std = @import("std");

pub const Kernel = struct {
    name: []const u8 = "arm_neon",

    pub fn popcountBits(bits: []const u8, length: usize) u64 {
        var total: u64 = 0;
        var i: usize = 0;
        while (i < length) {
            total += @popcount(bits[i]);
            i += 1;
        }
        return total;
    }

    pub fn dotPacked(left: []const u8, right: []const u8, length: usize) i32 {
        var matches: i32 = 0;
        var i: usize = 0;
        while (i < length) {
            matches += @intCast(@popcount(left[i] ^ right[i]));
            i += 1;
        }
        return matches;
    }
};
