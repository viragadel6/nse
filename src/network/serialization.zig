const std = @import("std");
const checksums = @import("../util/checksums.zig");
const codec = @import("../util/binary_codec.zig");

pub const frame_magic = "NMSG";
pub const frame_header_bytes = 30;
pub const max_frame_bytes: u32 = 64 * 1024 * 1024;
pub const protocol_version: u8 = 3;

pub const SerializationError = error{
    TruncatedFrame,
    InvalidMagic,
    VersionMismatch,
    ChecksumMismatch,
    FrameTooLarge,
    CapacityExceeded,
    InvalidEncoding,
};

pub const Flags = packed struct(u16) {
    compressed: bool = false,
    requires_ack: bool = false,
    streaming: bool = false,
    priority: bool = false,
    trace: bool = false,
    reserved: u11 = 0,
};

pub const FrameHeader = struct {
    length: u32,
    method: u16,
    flags: Flags,
    request_id: u64,
    sequence: u32,
    shard: u32,

    pub fn encode(self: FrameHeader, buffer: []u8) SerializationError![]u8 {
        if (buffer.len < frame_header_bytes) return SerializationError.CapacityExceeded;
        @memcpy(buffer[0..4], frame_magic);
        buffer[4] = protocol_version;
        buffer[5] = 0;
        std.mem.writeInt(u16, buffer[6..8], self.method, .little);
        std.mem.writeInt(u16, buffer[8..10], @bitCast(self.flags), .little);
        std.mem.writeInt(u64, buffer[10..18], self.request_id, .little);
        std.mem.writeInt(u32, buffer[18..22], self.sequence, .little);
        std.mem.writeInt(u32, buffer[22..26], self.shard, .little);
        std.mem.writeInt(u32, buffer[26..30], self.length, .little);
        return buffer[0..frame_header_bytes];
    }

    pub fn decode(buffer: []const u8) SerializationError!FrameHeader {
        if (buffer.len < frame_header_bytes) return SerializationError.TruncatedFrame;
        if (!std.mem.eql(u8, buffer[0..4], frame_magic)) return SerializationError.InvalidMagic;
        if (buffer[4] != protocol_version) return SerializationError.VersionMismatch;
        const length = std.mem.readInt(u32, buffer[26..30], .little);
        if (length > max_frame_bytes) return SerializationError.FrameTooLarge;
        return .{
            .length = length,
            .method = std.mem.readInt(u16, buffer[6..8], .little),
            .flags = @bitCast(std.mem.readInt(u16, buffer[8..10], .little)),
            .request_id = std.mem.readInt(u64, buffer[10..18], .little),
            .sequence = std.mem.readInt(u32, buffer[18..22], .little),
            .shard = std.mem.readInt(u32, buffer[22..26], .little),
        };
    }
};

pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,
    checksum: u32,

    pub fn init(method: u16, request_id: u64, shard: u32, payload: []const u8, flags: Flags) Frame {
        return .{
            .header = .{ .length = @intCast(payload.len), .method = method, .flags = flags, .request_id = request_id, .sequence = 0, .shard = shard },
            .payload = payload,
            .checksum = checksums.crc32c(payload, 0),
        };
    }

    pub fn encodedSize(self: Frame) usize {
        return frame_header_bytes + self.payload.len + 4;
    }

    pub fn encode(self: Frame, buffer: []u8) SerializationError![]u8 {
        if (buffer.len < self.encodedSize()) return SerializationError.CapacityExceeded;
        var header = self.header;
        header.length = @intCast(self.payload.len);
        _ = try header.encode(buffer);
        @memcpy(buffer[frame_header_bytes .. frame_header_bytes + self.payload.len], self.payload);
        std.mem.writeInt(u32, buffer[frame_header_bytes + self.payload.len ..][0..4], self.checksum, .little);
        return buffer[0..self.encodedSize()];
    }

    pub fn verify(self: Frame) bool {
        return checksums.crc32c(self.payload, 0) == self.checksum;
    }
};

pub const FrameReader = struct {
    buffer: []u8,
    length: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !FrameReader {
        return .{ .buffer = try allocator.alloc(u8, capacity) };
    }

    pub fn deinit(self: *FrameReader, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn push(self: *FrameReader, data: []const u8) SerializationError!void {
        if (self.length + data.len > self.buffer.len) return SerializationError.CapacityExceeded;
        @memcpy(self.buffer[self.length .. self.length + data.len], data);
        self.length += data.len;
    }

    pub fn take(self: *FrameReader) SerializationError!?Frame {
        if (self.length < frame_header_bytes) return null;
        const header = try FrameHeader.decode(self.buffer[0..frame_header_bytes]);
        const total = frame_header_bytes + header.length + 4;
        if (self.length < total) return null;
        const payload = self.buffer[frame_header_bytes .. frame_header_bytes + header.length];
        const checksum = std.mem.readInt(u32, self.buffer[frame_header_bytes + header.length ..][0..4], .little);
        const frame = Frame{ .header = header, .payload = payload, .checksum = checksum };
        if (!frame.verify()) {
            self.consume(total);
            return SerializationError.ChecksumMismatch;
        }
        return frame;
    }

    pub fn consume(self: *FrameReader, count: usize) void {
        if (count >= self.length) {
            self.length = 0;
            return;
        }
        std.mem.copyForwards(u8, self.buffer[0 .. self.length - count], self.buffer[count..self.length]);
        self.length -= count;
    }

    pub fn pending(self: *const FrameReader) usize {
        return self.length;
    }
};

pub const PayloadWriter = struct {
    items: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PayloadWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PayloadWriter) void {
        self.items.deinit(self.allocator);
    }

    pub fn bytes(self: *const PayloadWriter) []const u8 {
        return self.items.items;
    }

    pub fn writeByte(self: *PayloadWriter, value: u8) !void {
        try self.items.append(self.allocator, value);
    }

    pub fn writeBytes(self: *PayloadWriter, value: []const u8) !void {
        try self.items.appendSlice(self.allocator, value);
    }

    pub fn writeU16(self: *PayloadWriter, value: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, value, .little);
        try self.writeBytes(&b);
    }

    pub fn writeU32(self: *PayloadWriter, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .little);
        try self.writeBytes(&b);
    }

    pub fn writeU64(self: *PayloadWriter, value: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .little);
        try self.writeBytes(&b);
    }

    pub fn writeI32(self: *PayloadWriter, value: i32) !void {
        try self.writeU32(@bitCast(value));
    }

    pub fn writeI64(self: *PayloadWriter, value: i64) !void {
        try self.writeU64(@bitCast(value));
    }

    pub fn writeF32(self: *PayloadWriter, value: f32) !void {
        try self.writeU32(@bitCast(value));
    }

    pub fn writeF64(self: *PayloadWriter, value: f64) !void {
        try self.writeU64(@bitCast(value));
    }

    pub fn writeVarint(self: *PayloadWriter, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.writeByte(@as(u8, @truncate(v)) | 0x80);
            v >>= 7;
        }
        try self.writeByte(@as(u8, @truncate(v)));
    }

    pub fn writeString(self: *PayloadWriter, value: []const u8) !void {
        try self.writeVarint(value.len);
        try self.writeBytes(value);
    }

    pub fn writeBool(self: *PayloadWriter, value: bool) !void {
        try self.writeByte(if (value) 1 else 0);
    }

    pub fn writeFloatSlice(self: *PayloadWriter, values: []const f32) !void {
        try self.writeVarint(values.len);
        for (values) |value| try self.writeF32(value);
    }

    pub fn writeU64Slice(self: *PayloadWriter, values: []const u64) !void {
        try self.writeVarint(values.len);
        for (values) |value| try self.writeU64(value);
    }

    pub fn writeU32Slice(self: *PayloadWriter, values: []const u32) !void {
        try self.writeVarint(values.len);
        for (values) |value| try self.writeU32(value);
    }
};

pub const PayloadReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PayloadReader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const PayloadReader) usize {
        return self.data.len - self.pos;
    }

    fn take(self: *PayloadReader, count: usize) SerializationError![]const u8 {
        if (count > self.remaining()) return SerializationError.TruncatedFrame;
        const slice = self.data[self.pos .. self.pos + count];
        self.pos += count;
        return slice;
    }

    pub fn readByte(self: *PayloadReader) SerializationError!u8 {
        return (try self.take(1))[0];
    }

    pub fn readBytes(self: *PayloadReader, count: usize) SerializationError![]const u8 {
        return self.take(count);
    }

    pub fn readU16(self: *PayloadReader) SerializationError!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    pub fn readU32(self: *PayloadReader) SerializationError!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    pub fn readU64(self: *PayloadReader) SerializationError!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    pub fn readI32(self: *PayloadReader) SerializationError!i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readI64(self: *PayloadReader) SerializationError!i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readF32(self: *PayloadReader) SerializationError!f32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF64(self: *PayloadReader) SerializationError!f64 {
        return @bitCast(try self.readU64());
    }

    pub fn readVarint(self: *PayloadReader) SerializationError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var index: usize = 0;
        while (true) {
            if (index >= 10) return SerializationError.InvalidEncoding;
            const b = try self.readByte();
            index += 1;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    pub fn readString(self: *PayloadReader, limit: usize) SerializationError![]const u8 {
        const length = try self.readVarint();
        if (length > limit) return SerializationError.InvalidEncoding;
        return self.take(@intCast(length));
    }

    pub fn readBool(self: *PayloadReader) SerializationError!bool {
        return (try self.readByte()) != 0;
    }

    pub fn readU64Slice(self: *PayloadReader, allocator: std.mem.Allocator, limit: usize) ![]u64 {
        const count = try self.readVarint();
        if (count > limit) return SerializationError.InvalidEncoding;
        const out = try allocator.alloc(u64, @intCast(count));
        for (out) |*value| value.* = try self.readU64();
        return out;
    }

    pub fn readU32Slice(self: *PayloadReader, allocator: std.mem.Allocator, limit: usize) ![]u32 {
        const count = try self.readVarint();
        if (count > limit) return SerializationError.InvalidEncoding;
        const out = try allocator.alloc(u32, @intCast(count));
        for (out) |*value| value.* = try self.readU32();
        return out;
    }

    pub fn readFloatSlice(self: *PayloadReader, allocator: std.mem.Allocator, limit: usize) ![]f32 {
        const count = try self.readVarint();
        if (count > limit) return SerializationError.InvalidEncoding;
        const out = try allocator.alloc(f32, @intCast(count));
        for (out) |*value| value.* = try self.readF32();
        return out;
    }
};

pub fn varintEncodedLength(value: u64) usize {
    return codec.varintLength(value);
}
