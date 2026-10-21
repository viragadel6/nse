const std = @import("std");
const checksums = @import("../util/checksums.zig");
const compression = @import("../util/compression.zig");
const hashing = @import("../util/hashing.zig");
const codec = @import("../util/binary_codec.zig");
const time = @import("../util/time.zig");

pub const StoreError = error{
    NotFound,
    CorruptSegment,
    ChecksumMismatch,
    VersionMismatch,
    SegmentFull,
    InvalidRecord,
    DiskFull,
    AlreadyExists,
};

pub const segment_magic = "NDOC";
pub const segment_version: u32 = 4;
pub const segment_header_bytes = 48;

pub const DocumentRecord = struct {
    document_id: u64,
    canonical_hash: u64,
    content_hash: u64,
    domain_hash: u64,
    canonical_url: []const u8,
    title: []const u8,
    language: []const u8,
    text: []const u8,
    headings: []const u8,
    links: []const u8,
    metadata: []const u8,
    fetch_time_ms: i64,
    publish_time_ms: i64,
    modified_time_ms: i64,
    http_status: u16,
    quality_score: f32,
    spam_score: f32,
    originality_score: f32,
    token_count: u32,
    flags: u32,

    pub fn release(self: *DocumentRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.title);
        allocator.free(self.language);
        allocator.free(self.text);
        allocator.free(self.headings);
        allocator.free(self.links);
        allocator.free(self.metadata);
    }

    pub fn encode(self: DocumentRecord, allocator: std.mem.Allocator) ![]u8 {
        var out = codec.SliceWriter.init(allocator);
        errdefer out.deinit();
        var writer = out.writer();
        try writer.writeU64(self.document_id);
        try writer.writeU64(self.canonical_hash);
        try writer.writeU64(self.content_hash);
        try writer.writeU64(self.domain_hash);
        try writeString(&writer, self.canonical_url);
        try writeString(&writer, self.title);
        try writeString(&writer, self.language);
        try writeString(&writer, self.text);
        try writeString(&writer, self.headings);
        try writeString(&writer, self.links);
        try writeString(&writer, self.metadata);
        try writer.writeI64(self.fetch_time_ms);
        try writer.writeI64(self.publish_time_ms);
        try writer.writeI64(self.modified_time_ms);
        try writer.writeU16(self.http_status);
        try writer.writeF32(self.quality_score);
        try writer.writeF32(self.spam_score);
        try writer.writeF32(self.originality_score);
        try writer.writeU32(self.token_count);
        try writer.writeU32(self.flags);
        return out.items.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !DocumentRecord {
        if (payload.len < 80) return StoreError.InvalidRecord;
        var position: usize = 0;
        const document_id = std.mem.readInt(u64, payload[0..8], .little);
        const canonical_hash = std.mem.readInt(u64, payload[8..16], .little);
        const content_hash = std.mem.readInt(u64, payload[16..24], .little);
        const domain_hash = std.mem.readInt(u64, payload[24..32], .little);
        position = 32;
        var canonical_url: []const u8 = undefined;
        var title: []const u8 = undefined;
        var language: []const u8 = undefined;
        var text: []const u8 = undefined;
        var headings: []const u8 = undefined;
        var links: []const u8 = undefined;
        var metadata: []const u8 = undefined;
        inline for (.{ &canonical_url, &title, &language, &text, &headings, &links, &metadata }) |target| {
            if (position + 4 > payload.len) return StoreError.InvalidRecord;
            const length = std.mem.readInt(u32, payload[position..][0..4], .little);
            position += 4;
            if (position + length > payload.len) return StoreError.InvalidRecord;
            target.* = try allocator.dupe(u8, payload[position .. position + length]);
            position += length;
        }
        if (position + 42 > payload.len) return StoreError.InvalidRecord;
        return .{
            .document_id = document_id,
            .canonical_hash = canonical_hash,
            .content_hash = content_hash,
            .domain_hash = domain_hash,
            .canonical_url = canonical_url,
            .title = title,
            .language = language,
            .text = text,
            .headings = headings,
            .links = links,
            .metadata = metadata,
            .fetch_time_ms = std.mem.readInt(i64, payload[position..][0..8], .little),
            .publish_time_ms = std.mem.readInt(i64, payload[position + 8 ..][0..8], .little),
            .modified_time_ms = std.mem.readInt(i64, payload[position + 16 ..][0..8], .little),
            .http_status = std.mem.readInt(u16, payload[position + 24 ..][0..2], .little),
            .quality_score = @bitCast(std.mem.readInt(u32, payload[position + 26 ..][0..4], .little)),
            .spam_score = @bitCast(std.mem.readInt(u32, payload[position + 30 ..][0..4], .little)),
            .originality_score = @bitCast(std.mem.readInt(u32, payload[position + 34 ..][0..4], .little)),
            .token_count = std.mem.readInt(u32, payload[position + 38 ..][0..4], .little),
            .flags = std.mem.readInt(u32, payload[position + 42 ..][0..4], .little),
        };
    }
};

fn writeString(writer: *codec.SliceWriter.WriterProxy, value: []const u8) !void {
    try writer.writeU32(@intCast(value.len));
    try writer.writeAll(value);
}

const Location = struct {
    segment: u32,
    offset: u64,
    length: u32,
};

pub const Options = struct {
    dir: []const u8 = "data/documents",
    segment_target_bytes: u64 = 1073741824,
    compression_enabled: bool = true,
    sync_on_write: bool = false,
    verify_checksums_on_read: bool = true,
    max_open_segments: u32 = 64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    options: Options,
    index: std.AutoHashMapUnmanaged(u64, Location) = .{},
    segments: std.ArrayListUnmanaged(Segment) = .{},
    active: u32 = 0,
    mutex: std.Thread.Mutex = .{},
    documents: u64 = 0,
    bytes_stored: u64 = 0,
    reads: u64 = 0,
    cache_hits: u64 = 0,

    const Segment = struct {
        file: std.fs.File,
        path: []const u8,
        size: u64,
        id: u32,
        compressed: bool,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Store {
        std.fs.cwd().makePath(options.dir) catch {};
        var store = Store{ .allocator = allocator, .options = options };
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
    }

    fn openSegment(self: *Store, id: u32) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/documents-{d}.seg", .{ self.options.dir, id });
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        var header: [segment_header_bytes]u8 = @splat(0);
        @memcpy(header[0..4], segment_magic);
        std.mem.writeInt(u32, header[4..8], segment_version, .little);
        std.mem.writeInt(u32, header[8..12], id, .little);
        std.mem.writeInt(u64, header[12..20], @as(u64, @bitCast(time.nowMs())), .little);
        std.mem.writeInt(u32, header[20..24], if (self.options.compression_enabled) 1 else 0, .little);
        try file.writeAll(&header);
        try self.segments.append(self.allocator, .{ .file = file, .path = path, .size = segment_header_bytes, .id = id, .compressed = self.options.compression_enabled });
        self.active = @intCast(self.segments.items.len - 1);
    }

    fn ensureCapacity(self: *Store, needed: u64) !void {
        if (self.segments.items.len == 0) try self.openSegment(0);
        const segment = &self.segments.items[self.active];
        if (segment.size + needed > self.options.segment_target_bytes) {
            const next_id = segment.id + 1;
            try self.openSegment(next_id);
        }
    }

    pub fn put(self: *Store, record: DocumentRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const encoded = try record.encode(self.allocator);
        defer self.allocator.free(encoded);
        var stored = encoded;
        var compressed: ?[]u8 = null;
        defer if (compressed) |value| self.allocator.free(value);
        var flags = record.flags;
        if (self.options.compression_enabled and encoded.len > 512) {
            const bound = compression.compressBound(encoded.len);
            const buffer = try self.allocator.alloc(u8, bound);
            if (compression.compress(encoded, buffer)) |size| {
                compressed = buffer;
                stored = buffer[0..size];
                flags |= 1;
            } else |_| {
                self.allocator.free(buffer);
            }
        }
        try self.ensureCapacity(stored.len + 16);
        const segment = &self.segments.items[self.active];
        var frame: [16]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], @intCast(stored.len), .little);
        std.mem.writeInt(u32, frame[4..8], flags, .little);
        std.mem.writeInt(u64, frame[8..16], record.document_id, .little);
        try segment.file.seekTo(segment.size);
        try segment.file.writeAll(&frame);
        try segment.file.writeAll(stored);
        const crc = checksums.crc32c(stored, 0);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc, .little);
        try segment.file.writeAll(&crc_bytes);
        const location = Location{ .segment = segment.id, .offset = segment.size, .length = @intCast(stored.len + 20) };
        try self.index.put(self.allocator, record.document_id, location);
        segment.size += stored.len + 20;
        self.documents += 1;
        self.bytes_stored += stored.len;
        if (self.options.sync_on_write) try segment.file.sync();
    }

    pub fn get(self: *Store, allocator: std.mem.Allocator, document_id: u64) !?DocumentRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.reads += 1;
        const location = self.index.get(document_id) orelse return null;
        self.cache_hits += 1;
        const segment = for (self.segments.items) |candidate| {
            if (candidate.id == location.segment) break candidate;
        } else return null;
        const buffer = try allocator.alloc(u8, location.length);
        defer allocator.free(buffer);
        _ = try segment.file.preadAll(buffer, location.offset);
        const stored_length = std.mem.readInt(u32, buffer[0..4], .little);
        const flags = std.mem.readInt(u32, buffer[4..8], .little);
        if (stored_length + 20 > buffer.len) return StoreError.CorruptSegment;
        const stored = buffer[16 .. 16 + stored_length];
        const expected_crc = std.mem.readInt(u32, buffer[16 + stored_length ..][0..4], .little);
        if (self.options.verify_checksums_on_read and checksums.crc32c(stored, 0) != expected_crc) {
            return StoreError.ChecksumMismatch;
        }
        if (flags & 1 != 0) {
            const raw = try compression.decompressAlloc(allocator, stored);
            defer allocator.free(raw);
            return try DocumentRecord.decode(allocator, raw);
        }
        return try DocumentRecord.decode(allocator, stored);
    }

    pub fn contains(self: *Store, document_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.index.contains(document_id);
    }

    pub fn documentCount(self: *Store) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.documents;
    }

    pub fn recover(self: *Store) !void {
        var dir = try std.fs.cwd().openDir(self.options.dir, .{ .iterate = true });
        defer dir.close();
        var names = std.ArrayList(u32).init(self.allocator);
        defer names.deinit();
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "documents-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
            const inner = entry.name["documents-".len .. entry.name.len - 4];
            const id = std.fmt.parseInt(u32, inner, 10) catch continue;
            try names.append(id);
        }
        std.sort.block(u32, names.items, {}, struct {
            fn lt(_: void, a: u32, b: u32) bool {
                return a < b;
            }
        }.lt);
        for (names.items) |id| {
            try self.loadSegment(id);
        }
        if (self.segments.items.len == 0) try self.openSegment(0);
        self.active = @intCast(self.segments.items.len - 1);
    }

    fn loadSegment(self: *Store, id: u32) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/documents-{d}.seg", .{ self.options.dir, id });
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
        if (!std.mem.eql(u8, header[0..4], segment_magic)) return StoreError.CorruptSegment;
        const version = std.mem.readInt(u32, header[4..8], .little);
        if (version != segment_version) return StoreError.VersionMismatch;
        try self.segments.append(self.allocator, .{
            .file = file,
            .path = path,
            .size = @intCast(stat.size),
            .id = id,
            .compressed = std.mem.readInt(u32, header[20..24], .little) == 1,
        });
        try self.scanSegment(@intCast(self.segments.items.len - 1));
    }

    fn scanSegment(self: *Store, slot: usize) !void {
        const segment = &self.segments.items[slot];
        const data = try segment.file.readToEndAlloc(self.allocator, @intCast(@min(segment.size, 1 << 30)));
        defer self.allocator.free(data);
        var position: usize = segment_header_bytes;
        while (position + 20 <= data.len) {
            const stored_length = std.mem.readInt(u32, data[position..][0..4], .little);
            if (stored_length == 0 or position + 20 + stored_length > data.len) break;
            const document_id = std.mem.readInt(u64, data[position + 8 ..][0..8], .little);
            try self.index.put(self.allocator, document_id, .{
                .segment = segment.id,
                .offset = position,
                .length = @intCast(stored_length + 20),
            });
            self.documents += 1;
            position += stored_length + 20;
        }
    }

    pub fn snapshot(self: *Store, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var writer = std.io.bufferedWriter(file.writer());
        try writer.writer().writeAll("{\"documents\":[");
        var first = true;
        var iterator = self.index.iterator();
        while (iterator.next()) |entry| {
            if (!first) try writer.writer().writeAll(",");
            first = false;
            try writer.writer().print("{{\"document_id\":{d},\"segment\":{d},\"offset\":{d},\"length\":{d}}}", .{
                entry.key_ptr.*, entry.value_ptr.segment, entry.value_ptr.offset, entry.value_ptr.length,
            });
        }
        try writer.writer().writeAll("]}");
        try writer.flush();
    }

    pub fn stats(self: *Store) StoreStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .documents = self.documents,
            .segments = self.segments.items.len,
            .bytes_stored = self.bytes_stored,
            .reads = self.reads,
            .hits = self.cache_hits,
        };
    }
};

pub const StoreStats = struct {
    documents: u64,
    segments: usize,
    bytes_stored: u64,
    reads: u64,
    hits: u64,
};

pub fn documentIdFor(canonical_url: []const u8, content_hash: u64) u64 {
    return hashing.hash64(0x517CC1B727220A95, canonical_url) ^ hashing.mix64(content_hash | 1);
}
