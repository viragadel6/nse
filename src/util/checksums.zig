const std = @import("std");

pub fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

pub fn content(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
