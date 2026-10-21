const std = @import("std");
const checksum = @import("../util/checksums.zig");

pub const header_size = 32;
pub const Kind = enum(u16) { document = 1, deletion = 2 };

pub const Record = struct {
    sequence: u64,
    kind: Kind,
    payload: []u8,
};

pub const Log = struct {
    file: std.fs.File,
    sequence: u64 = 0,
    offset: u64 = 0,
    maximum_record_bytes: u32,
    poisoned: bool = false,

    pub fn open(directory: std.fs.Dir, name: []const u8, maximum_record_bytes: u32, locked: bool) !Log {
        const file = try directory.createFile(name, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (locked) try std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
        return .{ .file = file, .maximum_record_bytes = maximum_record_bytes };
    }

    pub fn close(self: *Log) void {
        self.file.close();
    }

    pub fn rewind(self: *Log) void {
        self.offset = 0;
        self.sequence = 0;
    }

    fn truncateTail(self: *Log) !void {
        try self.file.setEndPos(self.offset);
        try self.file.sync();
    }

    pub fn next(self: *Log, allocator: std.mem.Allocator, repair_tail: bool) !?Record {
        var header: [header_size]u8 = undefined;
        const read = try self.file.preadAll(&header, self.offset);
        if (read == 0) return null;
        if (read != header_size) {
            if (!repair_tail) return error.TruncatedLogHeader;
            try self.truncateTail();
            return null;
        }
        if (!std.mem.eql(u8, header[0..8], "VLOG0001")) return error.InvalidLogMagic;
        const version = std.mem.readInt(u16, header[8..10], .little);
        if (version != 1 and version != 2) return error.IncompatibleLogVersion;
        const header_checksum = std.mem.readInt(u32, header[28..32], .little);
        if ((version == 1 and header_checksum != 0) or (version == 2 and header_checksum != checksum.crc32(header[0..28], 0))) return error.LogHeaderChecksumMismatch;
        const kind = std.meta.intToEnum(Kind, std.mem.readInt(u16, header[10..12], .little)) catch return error.InvalidLogKind;
        const length = std.mem.readInt(u32, header[12..16], .little);
        const sequence = std.mem.readInt(u64, header[16..24], .little);
        if (length > self.maximum_record_bytes or sequence == 0 or sequence <= self.sequence) return error.InvalidLogRecord;
        const payload = try allocator.alloc(u8, length);
        errdefer allocator.free(payload);
        const payload_offset = try std.math.add(u64, self.offset, header_size);
        if (try self.file.preadAll(payload, payload_offset) != length) {
            if (!repair_tail) return error.TruncatedLogPayload;
            try self.truncateTail();
            allocator.free(payload);
            return null;
        }
        if (checksum.crc32(payload, 0) != std.mem.readInt(u32, header[24..28], .little)) return error.LogChecksumMismatch;
        self.offset = try std.math.add(u64, payload_offset, length);
        self.sequence = sequence;
        return .{ .sequence = sequence, .kind = kind, .payload = payload };
    }

    fn rollback(self: *Log, original: anyerror) anyerror {
        self.file.setEndPos(self.offset) catch {
            self.poisoned = true;
            return error.WriteStateUnknown;
        };
        self.file.sync() catch {
            self.poisoned = true;
            return error.WriteStateUnknown;
        };
        return original;
    }

    pub fn appendAt(self: *Log, kind: Kind, payload: []const u8, sequence: u64) !void {
        if (self.poisoned) return error.WriteStateUnknown;
        const length = std.math.cast(u32, payload.len) orelse return error.RecordTooLarge;
        if (length > self.maximum_record_bytes or sequence == 0 or sequence <= self.sequence) return error.InvalidLogRecord;
        var header: [header_size]u8 = @splat(0);
        @memcpy(header[0..8], "VLOG0001");
        std.mem.writeInt(u16, header[8..10], 2, .little);
        std.mem.writeInt(u16, header[10..12], @intFromEnum(kind), .little);
        std.mem.writeInt(u32, header[12..16], length, .little);
        std.mem.writeInt(u64, header[16..24], sequence, .little);
        std.mem.writeInt(u32, header[24..28], checksum.crc32(payload, 0), .little);
        std.mem.writeInt(u32, header[28..32], checksum.crc32(header[0..28], 0), .little);
        const end = try std.math.add(u64, try std.math.add(u64, self.offset, header_size), payload.len);
        self.file.pwriteAll(&header, self.offset) catch |err| return self.rollback(err);
        self.file.pwriteAll(payload, self.offset + header_size) catch |err| return self.rollback(err);
        self.file.sync() catch |err| return self.rollback(err);
        self.offset = end;
        self.sequence = sequence;
    }

    pub fn reset(self: *Log, sequence: u64) !void {
        if (self.poisoned) return error.WriteStateUnknown;
        try self.file.setEndPos(0);
        try self.file.sync();
        self.offset = 0;
        self.sequence = sequence;
    }
};
