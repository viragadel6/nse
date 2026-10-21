const std = @import("std");
const checksums = @import("../util/checksums.zig");

pub const FrameType = enum(u8) {
    data = 0,
    control = 1,
    heartbeat = 2,
    close = 3,
};

pub const FrameHeader = struct {
    magic: u16 = 0x4E53,
    version: u8 = 1,
    frame_type: FrameType = .data,
    flags: u8 = 0,
    stream_id: u32 = 0,
    payload_length: u32 = 0,
    checksum: u32 = 0,
};

pub fn encodeHeader(header: FrameHeader, buffer: [20]u8) void {
    std.mem.writeInt(u16, buffer[0..2], header.magic, .little);
    buffer[2] = header.version;
    buffer[3] = @enumToInt(header.frame_type);
    buffer[4] = header.flags;
    std.mem.writeInt(u32, buffer[5..8], header.stream_id, .little);
    std.mem.writeInt(u32, buffer[8..12], header.payload_length, .little);
    buffer[12..20] = @as([4]u8, undefined);
}

pub fn computeChecksum(header: FrameHeader, payload: []const u8) u32 {
    var crc: u32 = checksums.crc32(std.mem.asBytes(&header)[0..12]);
    crc = checksums.crc32(payload);
    return crc;
}

pub const Envelope = struct {
    stream_id: u32,
    sequence: u64,
    frame_type: FrameType,
    payload: []const u8,
};
