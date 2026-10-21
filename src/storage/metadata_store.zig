const std = @import("std");
const checksums = @import("../util/checksums.zig");
const bloom = @import("../util/bloom_filter.zig");
const time = @import("../util/time.zig");
const codec = @import("../util/binary_codec.zig");

pub const MetadataError = error{
    NotFound,
    CorruptSegment,
    ChecksumMismatch,
    VersionMismatch,
    InvalidRecord,
    SegmentFull,
};

pub const segment_magic = "NMET";
pub const segment_version: u32 = 3;
pub const segment_header_bytes = 40;

pub const Field = enum(u16) {
    domain = 1,
    language = 2,
    content_type = 3,
    source_type = 4,
    publish_date = 5,
    fetch_date = 6,
    schema_category = 7,
    document_type = 8,
    quality_score = 9,
    freshness_score = 10,
    source_quality = 11,
    originality = 12,
    graph_quality = 13,
    corpus_frequency = 14,
    custom_index = 15,
};

pub const Record = struct {
    key: u64,
    field: Field,
    numeric_value: i64,
    text_value: []const u8,
    updated_ms: i64,
};

const Location = struct {
    segment: u32,
    offset: u64,
    length: u32,
};

pub const Options = struct {
    dir: []const u8 = "data/metadata",
    segment_target_bytes: u64 = 268435456,
    bloom_items: u64 = 10000000,
    bloom_false_positive_rate: f64 = 0.01,
    verify_checksums_on_read: bool = true,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    options: Options,
    index: std.AutoHashMapUnmanaged(u64, Location) = .{},
    filter: bloom.BloomFilter,
    segments: std.ArrayListUnmanaged(Segment) = .{},
    active: usize = 0,
    mutex: std.Thread.Mutex = .{},
    records: u64 = 0,
    tombstones: u64 = 0,

    const Segment = struct {
        file: std.fs.File,
        path: []const u8,
        size: u64,
        id: u32,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Store {
        std.fs.cwd().makePath(options.dir) catch {};
        const filter = try bloom.BloomFilter.init(allocator, @max(1024, options.bloom_items), options.bloom_false_positive_rate);
        var store = Store{ .allocator = allocator, .options = options, .filter = filter };
        errdefer store.filter.deinit();
        try store.recover();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.segments.items) |*segment| {
            segment.file.close();
            self.allocator.free(segment.path);
        }
        self.segments.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.filter.deinit();
    }

    fn openSegment(self: *Store, id: u32) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/metadata-{d}.seg", .{ self.options.dir, id });
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        var header: [segment_header_bytes]u8 = @splat(0);
        @memcpy(header[0..4], segment_magic);
        std.mem.writeInt(u32, header[4..8], segment_version, .little);
        std.mem.writeInt(u32, header[8..12], id, .little);
        std.mem.writeInt(u64, header[12..20], @as(u64, @bitCast(time.nowMs())), .little);
        try file.writeAll(&header);
        try self.segments.append(self.allocator, .{ .file = file, .path = path, .size = segment_header_bytes, .id = id });
        self.active = self.segments.items.len - 1;
    }

    pub fn put(self: *Store, record: Record) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.segments.items.len == 0) try self.openSegment(0);
        const payload = try self.encodeRecord(record);
        defer self.allocator.free(payload);
        var segment = &self.segments.items[self.active];
        if (segment.size + payload.len + 12 > self.options.segment_target_bytes) {
            try self.openSegment(segment.id + 1);
            segment = &self.segments.items[self.active];
        }
        var frame: [12]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], @intCast(payload.len), .little);
        std.mem.writeInt(u64, frame[4..12], record.key, .little);
        try segment.file.seekTo(segment.size);
        try segment.file.writeAll(&frame);
        try segment.file.writeAll(payload);
        const crc = checksums.crc32c(payload, 0);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc, .little);
        try segment.file.writeAll(&crc_bytes);
        try self.index.put(self.allocator, record.key, .{ .segment = segment.id, .offset = segment.size, .length = @intCast(payload.len + 16) });
        self.filter.add(record.key);
        segment.size += payload.len + 16;
        self.records += 1;
    }

    fn encodeRecord(self: *Store, record: Record) ![]u8 {
        var out = codec.SliceWriter.init(self.allocator);
        errdefer out.deinit();
        var writer = out.writer();
        try writer.writeU64(record.key);
        try writer.writeU16(@intFromEnum(record.field));
        try writer.writeU64(@bitCast(record.numeric_value));
        try writer.writeU32(@intCast(record.text_value.len));
        try writer.writeAll(record.text_value);
        try writer.writeU64(@bitCast(record.updated_ms));
        try writer.writeByte(0);
        return out.items.toOwnedSlice(self.allocator);
    }

    pub fn get(self: *Store, allocator: std.mem.Allocator, key: u64) !?Record {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.filter.mayContain(key)) return null;
        const location = self.index.get(key) orelse return null;
        const segment = for (self.segments.items) |candidate| {
            if (candidate.id == location.segment) break candidate;
        } else return null;
        const buffer = try allocator.alloc(u8, location.length);
        defer allocator.free(buffer);
        _ = try segment.file.preadAll(buffer, location.offset);
        const payload_length = std.mem.readInt(u32, buffer[0..4], .little);
        if (payload_length + 16 > buffer.len) return MetadataError.CorruptSegment;
        const payload = buffer[12 .. 12 + payload_length];
        const expected = std.mem.readInt(u32, buffer[12 + payload_length ..][0..4], .little);
        if (self.options.verify_checksums_on_read and checksums.crc32c(payload, 0) != expected) return MetadataError.ChecksumMismatch;
        return try self.decodeRecord(allocator, payload);
    }

    fn decodeRecord(_: *Store, allocator: std.mem.Allocator, payload: []const u8) !Record {
        if (payload.len < 31) return MetadataError.InvalidRecord;
        const length = std.mem.readInt(u32, payload[18..22], .little);
        if (22 + length + 9 > payload.len) return MetadataError.InvalidRecord;
        return .{
            .key = std.mem.readInt(u64, payload[0..8], .little),
            .field = @enumFromInt(std.mem.readInt(u16, payload[8..10], .little)),
            .numeric_value = std.mem.readInt(i64, payload[10..18], .little),
            .text_value = try allocator.dupe(u8, payload[22 .. 22 + length]),
            .updated_ms = std.mem.readInt(i64, payload[22 + length ..][0..8], .little),
        };
    }

    pub fn delete(self: *Store, key: u64) !void {
        try self.put(.{ .key = key, .field = .custom_index, .numeric_value = 0, .text_value = "", .updated_ms = time.nowMs() });
        self.mutex.lock();
        _ = self.index.remove(key);
        self.tombstones += 1;
        self.mutex.unlock();
    }

    pub fn recover(self: *Store) !void {
        var dir = try std.fs.cwd().openDir(self.options.dir, .{ .iterate = true });
        defer dir.close();
        var ids = std.ArrayList(u32).init(self.allocator);
        defer ids.deinit();
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "metadata-")) continue;
            const inner = entry.name["metadata-".len .. entry.name.len - 4];
            const id = std.fmt.parseInt(u32, inner, 10) catch continue;
            try ids.append(id);
        }
        std.sort.block(u32, ids.items, {}, struct {
            fn lt(_: void, a: u32, b: u32) bool {
                return a < b;
            }
        }.lt);
        for (ids.items) |id| try self.loadSegment(id);
        if (self.segments.items.len == 0) try self.openSegment(0);
        self.active = self.segments.items.len - 1;
    }

    fn loadSegment(self: *Store, id: u32) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/metadata-{d}.seg", .{ self.options.dir, id });
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
            self.allocator.free(path);
            return err;
        };
        const stat = try file.stat();
        if (stat.size < segment_header_bytes) {
            file.close();
            self.allocator.free(path);
            return;
        }
        var header: [segment_header_bytes]u8 = undefined;
        _ = try file.preadAll(&header, 0);
        if (!std.mem.eql(u8, header[0..4], segment_magic)) return MetadataError.CorruptSegment;
        const version = std.mem.readInt(u32, header[4..8], .little);
        if (version != segment_version) return MetadataError.VersionMismatch;
        try self.segments.append(self.allocator, .{ .file = file, .path = path, .size = @intCast(stat.size), .id = id });
        const data = try file.readToEndAlloc(self.allocator, @intCast(@min(stat.size, 1 << 30)));
        defer self.allocator.free(data);
        var position: usize = segment_header_bytes;
        while (position + 16 <= data.len) {
            const length = std.mem.readInt(u32, data[position..][0..4], .little);
            if (length == 0 or position + 16 + length > data.len) break;
            const key = std.mem.readInt(u64, data[position + 4 ..][0..8], .little);
            try self.index.put(self.allocator, key, .{ .segment = id, .offset = position, .length = @intCast(length + 16) });
            self.filter.add(key);
            self.records += 1;
            position += length + 16;
        }
    }

    pub fn compact(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.segments.items.len < 2) return;
        const target_id = self.segments.items[self.segments.items.len - 1].id + 1;
        const path = try std.fmt.allocPrint(self.allocator, "{s}/metadata-{d}.seg", .{ self.options.dir, target_id });
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        var header: [segment_header_bytes]u8 = @splat(0);
        @memcpy(header[0..4], segment_magic);
        std.mem.writeInt(u32, header[4..8], segment_version, .little);
        std.mem.writeInt(u32, header[8..12], target_id, .little);
        std.mem.writeInt(u64, header[12..20], @as(u64, @bitCast(time.nowMs())), .little);
        try file.writeAll(&header);
        var size: u64 = segment_header_bytes;
        var new_index: std.AutoHashMapUnmanaged(u64, Location) = .{};
        errdefer new_index.deinit(self.allocator);
        var iterator = self.index.iterator();
        while (iterator.next()) |entry| {
            for (self.segments.items) |segment| {
                if (segment.id != entry.value_ptr.segment) continue;
                const buffer = try self.allocator.alloc(u8, entry.value_ptr.length);
                defer self.allocator.free(buffer);
                segment.file.preadAll(buffer, entry.value_ptr.offset) catch continue;
                const length = std.mem.readInt(u32, buffer[0..4], .little);
                if (length + 16 > buffer.len) continue;
                try file.seekTo(size);
                try file.writeAll(buffer[0 .. length + 16]);
                try new_index.put(self.allocator, entry.key_ptr.*, .{ .segment = target_id, .offset = size, .length = @intCast(length + 16) });
                size += length + 16;
                break;
            }
        }
        try file.sync();
        for (self.segments.items) |*segment| {
            segment.file.close();
            std.fs.cwd().deleteFile(segment.path) catch {};
            self.allocator.free(segment.path);
        }
        self.segments.clearRetainingCapacity();
        self.index.deinit(self.allocator);
        self.index = new_index;
        try self.segments.append(self.allocator, .{ .file = file, .path = path, .size = size, .id = target_id });
        self.active = 0;
    }

    pub fn stats(self: *Store) MetadataStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .records = self.records,
            .segments = self.segments.items.len,
            .tombstones = self.tombstones,
            .bloom_fill = self.filter.fillRatio(),
        };
    }
};

pub const MetadataStats = struct {
    records: u64,
    segments: usize,
    tombstones: u64,
    bloom_fill: f64,
};
