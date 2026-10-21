const std = @import("std");

pub const crc32c_poly: u32 = 0x82F63B78;
pub const crc32_poly: u32 = 0xEDB88320;

const crc32c_table = buildTable(crc32c_poly);
const crc32_table = buildTable(crc32_poly);

fn buildTable(poly: u32) [256]u32 {
    @setEvalBranchQuota(5000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            if (c & 1 != 0) {
                c = (c >> 1) ^ poly;
            } else {
                c >>= 1;
            }
        }
        table[i] = c;
    }
    return table;
}

pub fn crc32c(data: []const u8, seed: u32) u32 {
    var crc: u32 = seed ^ 0xFFFFFFFF;
    for (data) |b| {
        crc = (crc >> 8) ^ crc32c_table[@intCast((crc ^ @as(u32, b)) & 0xFF)];
    }
    return crc ^ 0xFFFFFFFF;
}

pub fn crc32(data: []const u8, seed: u32) u32 {
    var crc: u32 = seed ^ 0xFFFFFFFF;
    for (data) |b| {
        crc = (crc >> 8) ^ crc32_table[@intCast((crc ^ @as(u32, b)) & 0xFF)];
    }
    return crc ^ 0xFFFFFFFF;
}

pub fn fnv1a64(data: []const u8, seed: u64) u64 {
    var h: u64 = if (seed == 0) 0xcbf29ce484222325 else seed;
    for (data) |b| {
        h ^= @as(u64, b);
        h *% 0x100000001b3;
    }
    return h;
}

pub fn verifyCrc32c(data: []const u8, expected: u32) bool {
    return crc32c(data, 0) == expected;
}

pub const Integrity = struct {
    length: u64,
    crc: u32,
    fingerprint: u64,

    pub fn compute(data: []const u8, fingerprint: u64) Integrity {
        return .{ .length = data.len, .crc = crc32c(data, 0), .fingerprint = fingerprint };
    }

    pub fn matches(self: Integrity, data: []const u8, fingerprint: u64) bool {
        return self.length == data.len and self.fingerprint == fingerprint and self.crc == crc32c(data, 0);
    }

    pub fn encode(self: Integrity, buf: []u8) ![]u8 {
        if (buf.len < 20) return error.BufferTooSmall;
        std.mem.writeInt(u64, buf[0..8], self.length, .little);
        std.mem.writeInt(u32, buf[8..12], self.crc, .little);
        std.mem.writeInt(u64, buf[12..20], self.fingerprint, .little);
        return buf[0..20];
    }

    pub fn decode(buf: []const u8) !Integrity {
        if (buf.len < 20) return error.TruncatedRecord;
        return .{
            .length = std.mem.readInt(u64, buf[0..8], .little),
            .crc = std.mem.readInt(u32, buf[8..12], .little),
            .fingerprint = std.mem.readInt(u64, buf[12..20], .little),
        };
    }
};

pub const RollingChecksum = struct {
    a: u32 = 0,
    b: u32 = 0,
    window: usize = 0,

    pub fn init() RollingChecksum {
        return .{};
    }

    pub fn add(self: *RollingChecksum, byte: u8) void {
        self.a +%= @as(u32, byte);
        self.b +%= self.a;
        self.window += 1;
    }

    pub fn remove(self: *RollingChecksum, byte: u8, window_size: u16) void {
        self.a -%= @as(u32, byte);
        self.b -%= @as(u32, window_size) * @as(u32, byte);
        self.window -= 1;
    }

    pub fn value(self: RollingChecksum) u32 {
        return (self.b << 16) | self.a;
    }
};

pub const CrcStream = struct {
    crc: u32 = 0,
    length: u64 = 0,

    pub fn update(self: *CrcStream, data: []const u8) void {
        var c = self.crc ^ 0xFFFFFFFF;
        for (data) |b| {
            c = (c >> 8) ^ crc32c_table[@intCast((c ^ @as(u32, b)) & 0xFF)];
        }
        self.crc = c ^ 0xFFFFFFFF;
        self.length += data.len;
    }

    pub fn final(self: CrcStream) u32 {
        return self.crc;
    }
};
