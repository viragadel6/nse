const std = @import("std");
const checksums = @import("../util/checksums.zig");
const time = @import("../util/time.zig");

pub const LogError = error{
    CorruptRecord,
    TruncatedRecord,
    ChecksumMismatch,
    InvalidHeader,
    VersionMismatch,
    DiskFull,
    InvalidSequence,
    NotOpen,
};

pub const log_magic = "NTXL";
pub const log_version: u32 = 2;
pub const header_bytes = 32;
pub const record_overhead = 1 + 8 + 2 + 4 + 4 + 1;

pub const RecordKind = enum(u16) {
    document_upsert = 1,
    document_delete = 2,
    frontier_transition = 3,
    index_mutation = 4,
    index_generation_commit = 5,
    model_registration = 6,
    research_checkpoint = 7,
    shard_assignment = 8,
    replication_ack = 9,
    compaction_marker = 10,
    checkpoint_transfer = 11,
};

pub const Record = struct {
    sequence: u64,
    kind: RecordKind,
    timestamp_ms: i64,
    payload: []const u8,
    crc: u32,
};

pub const Options = struct {
    dir: []const u8 = "data/txlog",
    max_file_bytes: u64 = 1073741824,
    sync_on_write: bool = false,
    buffer_bytes: usize = 1048576,
    verify_on_replay: bool = true,
};

pub const RecordWriter = struct {
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn writeByte(self: *RecordWriter, value: u8) !void {
        try self.out.append(self.allocator, value);
    }

    pub fn writeBytes(self: *RecordWriter, value: []const u8) !void {
        try self.out.appendSlice(self.allocator, value);
    }

    pub fn writeU16(self: *RecordWriter, value: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, value, .little);
        try self.writeBytes(&b);
    }

    pub fn writeU32(self: *RecordWriter, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .little);
        try self.writeBytes(&b);
    }

    pub fn writeU64(self: *RecordWriter, value: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .little);
        try self.writeBytes(&b);
    }

    pub fn writeI64(self: *RecordWriter, value: i64) !void {
        try self.writeU64(@bitCast(value));
    }
};

pub const Log = struct {
    allocator: std.mem.Allocator,
    options: Options,
    file: ?std.fs.File = null,
    path: []u8,
    sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    offset: u64 = 0,
    buffer: std.ArrayListUnmanaged(u8) = .{},
    segments: std.ArrayListUnmanaged(u64) = .{},
    mutex: std.Thread.Mutex = .{},
    appended: u64 = 0,
    bytes_written: u64 = 0,
    fsync_count: u64 = 0,
    corrupt_records: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Log {
        std.fs.cwd().makePath(options.dir) catch {};
        var log = Log{
            .allocator = allocator,
            .options = options,
            .path = try std.fmt.allocPrint(allocator, "{s}/tx-{d}.log", .{ options.dir, time.nowMs() }),
            .buffer = .{},
            .segments = .{},
        };
        try log.openSegment(std.fs.cwd().createFile(log.path, .{ .read = true, .truncate = true }));
        return log;
    }

    pub fn deinit(self: *Log) void {
        self.flush() catch {};
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
        self.buffer.deinit(self.allocator);
        self.segments.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    fn openSegment(self: *Log, file: anytype) !void {
        const opened = file catch return LogError.NotOpen;
        var header: [header_bytes]u8 = @splat(0);
        @memcpy(header[0..4], log_magic);
        std.mem.writeInt(u32, header[4..8], log_version, .little);
        std.mem.writeInt(u64, header[8..16], @as(u64, @bitCast(time.nowMs())), .little);
        std.mem.writeInt(u32, header[16..20], @intCast(record_overhead), .little);
        try opened.writeAll(&header);
        self.file = opened;
        self.offset = header_bytes;
    }

    pub fn append(self: *Log, kind: RecordKind, payload: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sequence = self.sequence.fetchAdd(1, .acq_rel);
        const timestamp = time.nowMs();
        const crc = checksums.crc32c(payload, 0);
        var writer = RecordWriter{ .out = &self.buffer, .allocator = self.allocator };
        try writer.writeByte(0xAA);
        try writer.writeU64(sequence);
        try writer.writeU16(@intFromEnum(kind));
        try writer.writeI64(timestamp);
        try writer.writeU32(@intCast(payload.len));
        try writer.writeBytes(payload);
        try writer.writeU32(crc);
        try writer.writeByte(0x55);
        self.appended += 1;
        if (self.buffer.items.len >= self.options.buffer_bytes) try self.flushLocked();
        return sequence;
    }

    pub fn flush(self: *Log) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushLocked();
    }

    fn flushLocked(self: *Log) !void {
        if (self.buffer.items.len == 0) return;
        const file = self.file orelse return LogError.NotOpen;
        try file.writeAll(self.buffer.items);
        self.bytes_written += self.buffer.items.len;
        self.offset += self.buffer.items.len;
        self.buffer.clearRetainingCapacity();
        if (self.options.sync_on_write) {
            try file.sync();
            self.fsync_count += 1;
        }
        if (self.offset >= self.options.max_file_bytes) try self.rollSegment();
    }

    fn rollSegment(self: *Log) !void {
        if (self.file) |file| {
            try file.sync();
            file.close();
        }
        self.allocator.free(self.path);
        self.path = try std.fmt.allocPrint(self.allocator, "{s}/tx-{d}.log", .{ self.options.dir, time.nowMs() });
        try self.openSegment(std.fs.cwd().createFile(self.path, .{ .read = true, .truncate = true }));
    }

    pub const Visitor = *const fn (context: *anyopaque, record: Record) anyerror!void;

    pub fn replay(self: *Log, context: *anyopaque, visitor: Visitor) !usize {
        var dir = try std.fs.cwd().openDir(self.options.dir, .{ .iterate = true });
        defer dir.close();
        var files = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (files.items) |name| self.allocator.free(name);
            files.deinit();
        }
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "tx-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
            try files.append(try self.allocator.dupe(u8, entry.name));
        }
        std.sort.block([]const u8, files.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var count: usize = 0;
        for (files.items) |name| {
            count += try self.replayFile(name, context, visitor);
        }
        return count;
    }

    fn replayFile(self: *Log, name: []const u8, context: *anyopaque, visitor: Visitor) !usize {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.options.dir, name });
        defer self.allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch return 0;
        defer file.close();
        const stat = try file.stat();
        if (stat.size < header_bytes) return 0;
        const data = try file.readToEndAlloc(self.allocator, @intCast(stat.size));
        defer self.allocator.free(data);
        if (!std.mem.eql(u8, data[0..4], log_magic)) return LogError.InvalidHeader;
        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != log_version) return LogError.VersionMismatch;
        var position: usize = header_bytes;
        var count: usize = 0;
        var last_sequence: u64 = 0;
        while (position + record_overhead <= data.len) {
            if (data[position] != 0xAA) {
                self.corrupt_records += 1;
                break;
            }
            const sequence = std.mem.readInt(u64, data[position + 1 ..][0..8], .little);
            const kind_value = std.mem.readInt(u16, data[position + 9 ..][0..2], .little);
            const timestamp = std.mem.readInt(i64, data[position + 11 ..][0..8], .little);
            const length = std.mem.readInt(u32, data[position + 19 ..][0..4], .little);
            const payload_start = position + 23;
            const payload_end = payload_start + length;
            if (payload_end + 5 > data.len) {
                self.corrupt_records += 1;
                break;
            }
            const crc = std.mem.readInt(u32, data[payload_end..][0..4], .little);
            const terminator = data[payload_end + 4];
            if (terminator != 0x55) {
                self.corrupt_records += 1;
                break;
            }
            const payload = data[payload_start..payload_end];
            if (self.options.verify_on_replay and checksums.crc32c(payload, 0) != crc) {
                self.corrupt_records += 1;
                return LogError.ChecksumMismatch;
            }
            try visitor(context, .{
                .sequence = sequence,
                .kind = @enumFromInt(kind_value),
                .timestamp_ms = timestamp,
                .payload = payload,
                .crc = crc,
            });
            last_sequence = sequence;
            position = payload_end + 5;
            count += 1;
        }
        if (last_sequence + 1 > self.sequence.load(.monotonic)) {
            self.sequence.store(last_sequence + 1, .release);
        }
        return count;
    }

    pub fn currentSequence(self: *Log) u64 {
        return self.sequence.load(.monotonic);
    }

    pub fn stats(self: *Log) LogStats {
        return .{
            .appended = self.appended,
            .bytes_written = self.bytes_written,
            .fsync_count = self.fsync_count,
            .corrupt_records = self.corrupt_records,
            .buffered_bytes = self.buffer.items.len,
        };
    }
};

pub const LogStats = struct {
    appended: u64,
    bytes_written: u64,
    fsync_count: u64,
    corrupt_records: u64,
    buffered_bytes: usize,
};

pub fn encodeMutationTarget(allocator: std.mem.Allocator, shard: u32, document_id: u64, generation: u64) ![]u8 {
    const out = try allocator.alloc(u8, 20);
    std.mem.writeInt(u32, out[0..4], shard, .little);
    std.mem.writeInt(u64, out[4..12], document_id, .little);
    std.mem.writeInt(u64, out[12..20], generation, .little);
    return out;
}

pub fn decodeMutationTarget(payload: []const u8) !struct { shard: u32, document_id: u64, generation: u64 } {
    if (payload.len < 20) return LogError.TruncatedRecord;
    return .{
        .shard = std.mem.readInt(u32, payload[0..4], .little),
        .document_id = std.mem.readInt(u64, payload[4..12], .little),
        .generation = std.mem.readInt(u64, payload[12..20], .little),
    };
}
