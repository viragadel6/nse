const std = @import("std");

pub const max_varint_bytes = 10;
pub const record_alignment = 8;

pub const CodecError = error{
    CapacityExceeded,
    Truncated,
    InvalidVarint,
    InvalidLength,
    OutOfRange,
    AlignmentFault,
};

pub fn varintLength(value: u64) usize {
    var v = value;
    var n: usize = 1;
    while (v >= 0x80) : (n += 1) v >>= 7;
    return n;
}

pub fn zigzagEncode(value: i64) u64 {
    const u: u64 = @bitCast(value);
    return (u << 1) ^ (u >> 63);
}

pub fn zigzagDecode(value: u64) i64 {
    const u = (value >> 1) ^ (~(value & 1) +% 1);
    return @bitCast(u);
}

pub fn alignUp(value: usize, alignment: usize) usize {
    if (alignment == 0) return value;
    const rem = value % alignment;
    return if (rem == 0) value else value + (alignment - rem);
}

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn written(self: Writer) []u8 {
        return self.buf[0..self.pos];
    }

    pub fn remaining(self: Writer) usize {
        return self.buf.len - self.pos;
    }

    pub fn seek(self: *Writer, pos: usize) CodecError!void {
        if (pos > self.buf.len) return CodecError.CapacityExceeded;
        self.pos = pos;
    }

    pub fn skip(self: *Writer, count: usize) CodecError!void {
        if (count > self.remaining()) return CodecError.CapacityExceeded;
        self.pos += count;
    }

    pub fn reserve(self: *Writer, count: usize) CodecError![]u8 {
        if (count > self.remaining()) return CodecError.CapacityExceeded;
        const slice = self.buf[self.pos .. self.pos + count];
        self.pos += count;
        return slice;
    }

    pub fn writeByte(self: *Writer, value: u8) CodecError!void {
        if (self.pos >= self.buf.len) return CodecError.CapacityExceeded;
        self.buf[self.pos] = value;
        self.pos += 1;
    }

    pub fn writeBytes(self: *Writer, value: []const u8) CodecError!void {
        if (value.len > self.remaining()) return CodecError.CapacityExceeded;
        @memcpy(self.buf[self.pos .. self.pos + value.len], value);
        self.pos += value.len;
    }

    pub fn writeU16(self: *Writer, value: u16) CodecError!void {
        if (self.remaining() < 2) return CodecError.CapacityExceeded;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], value, .little);
        self.pos += 2;
    }

    pub fn writeU24(self: *Writer, value: u32) CodecError!void {
        if (value > 0xFFFFFF) return CodecError.OutOfRange;
        if (self.remaining() < 3) return CodecError.CapacityExceeded;
        self.buf[self.pos] = @truncate(value & 0xFF);
        self.buf[self.pos + 1] = @truncate((value >> 8) & 0xFF);
        self.buf[self.pos + 2] = @truncate((value >> 16) & 0xFF);
        self.pos += 3;
    }

    pub fn writeU32(self: *Writer, value: u32) CodecError!void {
        if (self.remaining() < 4) return CodecError.CapacityExceeded;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], value, .little);
        self.pos += 4;
    }

    pub fn writeU48(self: *Writer, value: u64) CodecError!void {
        if (value > 0xFFFFFFFFFFFF) return CodecError.OutOfRange;
        if (self.remaining() < 6) return CodecError.CapacityExceeded;
        for (0..6) |i| self.buf[self.pos + i] = @truncate((value >> @intCast(i * 8)) & 0xFF);
        self.pos += 6;
    }

    pub fn writeU64(self: *Writer, value: u64) CodecError!void {
        if (self.remaining() < 8) return CodecError.CapacityExceeded;
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], value, .little);
        self.pos += 8;
    }

    pub fn writeI16(self: *Writer, value: i16) CodecError!void {
        return self.writeU16(@bitCast(value));
    }

    pub fn writeI32(self: *Writer, value: i32) CodecError!void {
        return self.writeU32(@bitCast(value));
    }

    pub fn writeI64(self: *Writer, value: i64) CodecError!void {
        return self.writeU64(@bitCast(value));
    }

    pub fn writeF32(self: *Writer, value: f32) CodecError!void {
        return self.writeU32(@bitCast(value));
    }

    pub fn writeF64(self: *Writer, value: f64) CodecError!void {
        return self.writeU64(@bitCast(value));
    }

    pub fn writeVarint(self: *Writer, value: u64) CodecError!void {
        var v = value;
        while (v >= 0x80) {
            try self.writeByte(@as(u8, @truncate(v)) | 0x80);
            v >>= 7;
        }
        return self.writeByte(@as(u8, @truncate(v)));
    }

    pub fn writeZigZag(self: *Writer, value: i64) CodecError!void {
        return self.writeVarint(zigzagEncode(value));
    }

    pub fn writeLengthPrefixed(self: *Writer, value: []const u8) CodecError!void {
        try self.writeVarint(value.len);
        return self.writeBytes(value);
    }

    pub fn writePadding(self: *Writer, alignment: usize) CodecError!void {
        const target = alignUp(self.pos, alignment);
        while (self.pos < target) {
            try self.writeByte(0);
        }
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn remaining(self: Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn consumed(self: Reader) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn seek(self: *Reader, pos: usize) CodecError!void {
        if (pos > self.buf.len) return CodecError.Truncated;
        self.pos = pos;
    }

    pub fn readByte(self: *Reader) CodecError!u8 {
        if (self.pos >= self.buf.len) return CodecError.Truncated;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readBytes(self: *Reader, count: usize) CodecError![]const u8 {
        if (count > self.remaining()) return CodecError.Truncated;
        const slice = self.buf[self.pos .. self.pos + count];
        self.pos += count;
        return slice;
    }

    pub fn readInto(self: *Reader, dst: []u8) CodecError!void {
        if (dst.len > self.remaining()) return CodecError.Truncated;
        @memcpy(dst, self.buf[self.pos .. self.pos + dst.len]);
        self.pos += dst.len;
    }

    pub fn readU16(self: *Reader) CodecError!u16 {
        const b = try self.readBytes(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    pub fn readU24(self: *Reader) CodecError!u32 {
        const b = try self.readBytes(3);
        return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
    }

    pub fn readU32(self: *Reader) CodecError!u32 {
        const b = try self.readBytes(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    pub fn readU48(self: *Reader) CodecError!u64 {
        const b = try self.readBytes(6);
        var v: u64 = 0;
        for (0..6) |i| v |= @as(u64, b[i]) << @intCast(i * 8);
        return v;
    }

    pub fn readU64(self: *Reader) CodecError!u64 {
        const b = try self.readBytes(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }

    pub fn readI16(self: *Reader) CodecError!i16 {
        return @bitCast(try self.readU16());
    }

    pub fn readI32(self: *Reader) CodecError!i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readI64(self: *Reader) CodecError!i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readF32(self: *Reader) CodecError!f32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF64(self: *Reader) CodecError!f64 {
        return @bitCast(try self.readU64());
    }

    pub fn readVarint(self: *Reader) CodecError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var index: usize = 0;
        while (true) {
            if (index >= max_varint_bytes) return CodecError.InvalidVarint;
            const b = try self.readByte();
            index += 1;
            if (shift >= 64) return CodecError.InvalidVarint;
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    pub fn readZigZag(self: *Reader) CodecError!i64 {
        return zigzagDecode(try self.readVarint());
    }

    pub fn readLengthPrefixed(self: *Reader, limit: usize) CodecError![]const u8 {
        const len = try self.readVarint();
        if (len > limit) return CodecError.InvalidLength;
        return self.readBytes(@intCast(len));
    }

    pub fn alignTo(self: *Reader, alignment: usize) CodecError!void {
        const target = alignUp(self.pos, alignment);
        if (target > self.buf.len) return CodecError.Truncated;
        self.pos = target;
    }
};

pub const SliceWriter = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: std.mem.Allocator) SliceWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SliceWriter) void {
        self.items.deinit(self.allocator);
    }

    pub fn bytes(self: SliceWriter) []const u8 {
        return self.items.items;
    }

    pub fn writer(self: *SliceWriter) WriterProxy {
        return .{ .owner = self };
    }

    pub const WriterProxy = struct {
        owner: *SliceWriter,

        pub fn writeAll(self: WriterProxy, data: []const u8) CodecError!void {
            self.owner.items.appendSlice(self.owner.allocator, data) catch return CodecError.CapacityExceeded;
        }

        pub fn writeByte(self: WriterProxy, value: u8) CodecError!void {
            self.owner.items.append(self.owner.allocator, value) catch return CodecError.CapacityExceeded;
        }

        pub fn writeU16(self: WriterProxy, value: u16) CodecError!void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, value, .little);
            return self.writeAll(&b);
        }

        pub fn writeU32(self: WriterProxy, value: u32) CodecError!void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, value, .little);
            return self.writeAll(&b);
        }

        pub fn writeU64(self: WriterProxy, value: u64) CodecError!void {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, value, .little);
            return self.writeAll(&b);
        }

        pub fn writeF32(self: WriterProxy, value: f32) CodecError!void {
            return self.writeU32(@bitCast(value));
        }

        pub fn writeF64(self: WriterProxy, value: f64) CodecError!void {
            return self.writeU64(@bitCast(value));
        }

        pub fn writeI32(self: WriterProxy, value: i32) CodecError!void {
            return self.writeU32(@bitCast(value));
        }

        pub fn writeI64(self: WriterProxy, value: i64) CodecError!void {
            return self.writeU64(@bitCast(value));
        }

        pub fn writeVarint(self: WriterProxy, value: u64) CodecError!void {
            var v = value;
            while (v >= 0x80) {
                try self.writeByte(@as(u8, @truncate(v)) | 0x80);
                v >>= 7;
            }
            return self.writeByte(@as(u8, @truncate(v)));
        }

        pub fn writeLengthPrefixed(self: WriterProxy, value: []const u8) CodecError!void {
            try self.writeVarint(value.len);
            return self.writeAll(value);
        }
    };
};

pub fn readFileFully(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > limit) return CodecError.InvalidLength;
    return file.readToEndAlloc(allocator, limit);
}

pub fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .read = true });
        defer file.close();
        try file.writeAll(data);
        try file.sync();
    }
    try std.fs.cwd().rename(tmp, path);
    _ = allocator;
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    dir.sync() catch {};
}
