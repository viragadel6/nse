const std = @import("std");
const documents = @import("document.zig");
const checksums = @import("../util/checksums.zig");
const time = @import("../util/time.zig");

pub const snapshot_magic = "NSDC";
pub const snapshot_version: u32 = 1;
pub const snapshot_header_bytes: usize = 20;

pub const CollectionError = error{
    CorruptSnapshot,
    VersionMismatch,
    ChecksumMismatch,
    DocumentTooLarge,
    InvalidSnapshotLength,
};

pub const Mutation = struct {
    id: u64,
    sequence: u64,
    inserted: bool,
    changed: bool,
    removed: bool,
};

pub const Stats = struct {
    documents: usize,
    sequence: u64,
    embedded: usize,
    bytes: u64,
    mutations: u64,
    snapshots: u64,
    recovered_records: u64,
    last_snapshot_ms: i64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: std.AutoHashMapUnmanaged(u64, documents.Document) = .{},
    sequence: u64 = 0,
    recovered_records: u64 = 0,
    max_record_bytes: u32,
    mutations: u64 = 0,
    snapshots: u64 = 0,
    dirty: bool = false,
    last_snapshot_ms: i64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn open(allocator: std.mem.Allocator, dir: []const u8, max_record_bytes: u32) !Store {
        std.fs.cwd().makePath(dir) catch {};
        const path = try std.fmt.allocPrint(allocator, "{s}/documents.snapshot", .{dir});
        errdefer allocator.free(path);
        var result = Store{
            .allocator = allocator,
            .path = path,
            .max_record_bytes = max_record_bytes,
        };
        try result.recover();
        return result;
    }

    pub fn close(self: *Store) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |document| releaseDocument(self.allocator, document);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    pub fn recover(self: *Store) !void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, 1 << 30) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (bytes.len < snapshot_header_bytes + 4) return CollectionError.CorruptSnapshot;
        if (!std.mem.eql(u8, bytes[0..4], snapshot_magic)) return CollectionError.CorruptSnapshot;
        const version = std.mem.readInt(u32, bytes[4..8], .little);
        if (version != snapshot_version) return CollectionError.VersionMismatch;
        const record_count = std.mem.readInt(u64, bytes[8..16], .little);
        const payload_length = std.mem.readInt(u32, bytes[16..20], .little);
        if (payload_length != bytes.len - snapshot_header_bytes - 4) return CollectionError.InvalidSnapshotLength;
        const expected = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
        if (!checksums.verifyCrc32c(bytes[0 .. bytes.len - 4], expected)) return CollectionError.ChecksumMismatch;
        var position: usize = snapshot_header_bytes;
        var loaded: u64 = 0;
        while (loaded < record_count) : (loaded += 1) {
            if (position + 4 > bytes.len - 4) return CollectionError.CorruptSnapshot;
            const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
            position += 4;
            if (position + length > bytes.len - 4) return CollectionError.CorruptSnapshot;
            const document = try documents.Document.decode(self.allocator, bytes[position..][0..length], self.sequence + 1);
            position += length;
            const value = document.*;
            self.allocator.destroy(document);
            if (self.entries.fetchRemove(value.id)) |previous| {
                var stale = previous.value;
                releaseDocument(self.allocator, &stale);
            }
            try self.entries.put(self.allocator, value.id, value);
            self.sequence += 1;
            self.recovered_records += 1;
        }
    }

    pub fn upsert(self: *Store, input: documents.Input) !Mutation {
        const created = try documents.Document.create(self.allocator, input, self.sequence + 1);
        errdefer created.destroy(self.allocator);
        const encoded = try created.encode(self.allocator);
        defer self.allocator.free(encoded);
        if (encoded.len > self.max_record_bytes) return CollectionError.DocumentTooLarge;
        self.mutex.lock();
        defer self.mutex.unlock();
        var value = created.*;
        self.allocator.destroy(created);
        if (self.entries.getPtr(value.id)) |previous| {
            if (previous.equivalent(&value)) {
                releaseDocument(self.allocator, &value);
                return .{ .id = value.id, .sequence = previous.sequence, .inserted = false, .changed = false, .removed = false };
            }
            var stale = previous.*;
            previous.* = value;
            releaseDocument(self.allocator, &stale);
            self.sequence += 1;
            previous.sequence = self.sequence;
            self.mutations += 1;
            self.dirty = true;
            return .{ .id = previous.id, .sequence = self.sequence, .inserted = false, .changed = true, .removed = false };
        }
        self.sequence += 1;
        value.sequence = self.sequence;
        try self.entries.put(self.allocator, value.id, value);
        self.mutations += 1;
        self.dirty = true;
        return .{ .id = value.id, .sequence = self.sequence, .inserted = true, .changed = true, .removed = false };
    }

    pub fn delete(self: *Store, id: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(id)) |removed| {
            var stale = removed.value;
            releaseDocument(self.allocator, &stale);
            self.mutations += 1;
            self.dirty = true;
            return true;
        }
        return false;
    }

    pub fn put(self: *Store, document: documents.Document) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(document.id)) |previous| {
            var stale = previous.value;
            releaseDocument(self.allocator, &stale);
        }
        try self.entries.put(self.allocator, document.id, document);
        if (document.sequence > self.sequence) self.sequence = document.sequence;
    }

    pub fn remove(self: *Store, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(id)) |previous| {
            var stale = previous.value;
            releaseDocument(self.allocator, &stale);
            return true;
        }
        return false;
    }

    pub fn get(self: *const Store, id: u64) ?*documents.Document {
        return self.entries.getPtr(id);
    }

    pub fn contains(self: *const Store, id: u64) bool {
        return self.entries.contains(id);
    }

    pub fn count(self: *const Store) usize {
        return self.entries.count();
    }

    pub fn embeddedCount(self: *const Store) usize {
        var total: usize = 0;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |document| {
            if (document.binary_vector != null) total += 1;
        }
        return total;
    }

    pub fn snapshot(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.appendSlice(snapshot_magic);
        try buffer.writer().writeInt(u32, snapshot_version, .little);
        try buffer.writer().writeInt(u64, @intCast(self.entries.count()), .little);
        try buffer.writer().writeInt(u32, 0, .little);
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |document| {
            const encoded = try document.encode(self.allocator);
            defer self.allocator.free(encoded);
            if (encoded.len > self.max_record_bytes) return CollectionError.DocumentTooLarge;
            try buffer.writer().writeInt(u32, @intCast(encoded.len), .little);
            try buffer.appendSlice(encoded);
        }
        const payload_length: u32 = @intCast(buffer.items.len - snapshot_header_bytes);
        std.mem.writeInt(u32, buffer.items[16..20], payload_length, .little);
        const digest = checksums.crc32c(buffer.items, 0);
        try buffer.writer().writeInt(u32, digest, .little);
        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{d}", .{ self.path, std.time.milliTimestamp() });
        defer self.allocator.free(temporary);
        var file = try std.fs.cwd().createFile(temporary, .{ .truncate = true });
        try file.writeAll(buffer.items);
        try file.sync();
        file.close();
        try std.fs.cwd().rename(temporary, self.path);
        if (std.fs.path.dirname(self.path)) |parent| {
            var directory = try std.fs.cwd().openDir(parent, .{});
            defer directory.close();
        }
        self.dirty = false;
        self.snapshots += 1;
        self.last_snapshot_ms = time.nowMs();
    }

    pub fn stats(self: *const Store) Stats {
        var bytes: u64 = 0;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |document| {
            bytes += document.url.len + document.title.len + document.text.len + document.language.len;
            if (document.embedding) |vector| bytes += vector.len * 4;
        }
        return .{
            .documents = self.entries.count(),
            .sequence = self.sequence,
            .embedded = self.embeddedCount(),
            .bytes = bytes,
            .mutations = self.mutations,
            .snapshots = self.snapshots,
            .recovered_records = self.recovered_records,
            .last_snapshot_ms = self.last_snapshot_ms,
        };
    }
};

fn releaseDocument(allocator: std.mem.Allocator, document: *documents.Document) void {
    allocator.free(document.url);
    allocator.free(document.title);
    allocator.free(document.text);
    allocator.free(document.language);
    if (document.embedding) |vector| allocator.free(vector);
}
