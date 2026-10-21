const std = @import("std");

pub fn fnv1a_64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash = @mulWithOverflow(hash, 0x100000001b3).result;
        hash = @xor(hash, @as(u64, @intCast(byte)));
    }
    return hash;
}

pub fn fnv1a_64_string(text: []const u8) u64 {
    return fnv1a_64(text);
}

pub fn hash64(bytes: []const u8, seed: u64) u64 {
    var hash: u64 = seed;
    for (bytes) |byte| {
        hash = @mulWithOverflow(hash, 0x100000001b3).result;
        hash = @xor(hash, @as(u64, @intCast(byte)));
    }
    return hash;
}

pub fn combine(a: u64, b: u64) u64 {
    return @xor(a, @mulWithOverflow(b, 0x9ddfea08eb382d69).result);
}

pub fn u64_leb128(value: u64) []const u8 {
    const std = @import("std");
    var buffer: [10]u8 = undefined;
    var i: usize = 0;
    while (true) {
        var byte = @as(u8, @intCast(value & 0x7f));
        value = value >> 7;
        if (value != 0) {
            byte = byte | 0x80;
        }
        buffer[i] = byte;
        i += 1;
        if (value == 0) break;
    }
    return buffer[0..i];
}

pub fn read_u64_leb128(bytes: []const u8, offset: *usize) !u64 {
    var result: u64 = 0;
    var shift: u64 = 0;
    while (true) {
        if (offset.* >= bytes.len) return error.TruncatedRecord;
        const byte = bytes[offset.*];
        offset.* += 1;
        result = result | (@as(u64, @intCast(byte & 0x7f)) << shift);
        if (byte & 0x80 == 0) break;
        shift += 7;
        if (shift > 63) return error.RecordTooLarge;
    }
    return result;
}
