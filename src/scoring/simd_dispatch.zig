const std = @import("std");
const platform = @import("../../util/platform.zig");

pub const Dispatch = struct {
    features: platform.CpuFeatures,

    pub fn init() Dispatch {
        return Dispatch{ .features = platform.detectCpuFeatures() };
    }

    pub fn scoreBinary(self: *const Dispatch, query_bits: []const u8, document_bits: []const u8, length: usize) !u64 {
        if (query_bits.len < length or document_bits.len < length) return error.BufferTooSmall;
        if (self.features.avx512f) return self.scoreAvx512(query_bits, document_bits, length);
        if (self.features.avx2) return self.scoreAvx2(query_bits, document_bits, length);
        if (self.features.neon) return self.scoreNeon(query_bits, document_bits, length);
        return self.scoreScalar(query_bits, document_bits, length);
    }

    fn scoreScalar(self: *const Dispatch, query_bits: []const u8, document_bits: []const u8, length: usize) u64 {
        var matches: u64 = 0;
        var i: usize = 0;
        while (i < length) {
            const xor = query_bits[i] ^ document_bits[i];
            matches += @popcount(xor);
            i += 1;
        }
        return matches;
    }

    fn scoreAvx2(self: *const Dispatch, query_bits: []const u8, document_bits: []const u8, length: usize) u64 {
        return self.scoreScalar(query_bits, document_bits, length);
    }

    fn scoreAvx512(self: *const Dispatch, query_bits: []const u8, document_bits: []const u8, length: usize) u64 {
        return self.scoreScalar(query_bits, document_bits, length);
    }

    fn scoreNeon(self: *const Dispatch, query_bits: []const u8, document_bits: []const u8, length: usize) u64 {
        return self.scoreScalar(query_bits, document_bits, length);
    }
};
