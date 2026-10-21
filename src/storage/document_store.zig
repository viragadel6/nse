const std = @import("std");
const documents = @import("document.zig");
const binary = @import("../util/binary_codec.zig");
const wal = @import("../ingestion/write_ahead_log.zig");
const checksums = @import("../util/checksums.zig");

pub const Mutation = struct { id: u64, sequence: u64, created: bool, changed: bool };

pub const Store = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    lock_file: std.fs.File,
    log: wal.Log,
    entries: std.AutoHashMap(u64, *documents.Document),
    sequence: u64 = 0,
    recovered_records: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, maximum_record_bytes: u32) !Store {
        try std.fs.cwd().makePath(path);
        var directory = try std.fs.cwd().openDir(path, .{ .iterate = true });
        errdefer directory.close();
        const lock_file = try directory.createFile("writer.lock", .{ .truncate = false });
        errdefer lock_file.close();
        try std.posix.flock(lock_file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
        var log = try wal.Log.open(directory, "events.wal", maximum_record_bytes, false);
        errdefer log.close();
        var result = Store{ .allocator = allocator, .directory = directory, .lock_file = lock_file, .log = log, .entries = std.AutoHashMap(u64, *documents.Document).init(allocator) };
        errdefer {
            var iterator = result.entries.valueIterator();
            while (iterator.next()) |entry| entry.*.destroy(allocator);
            result.entries.deinit();
        }
        const snapshot_file = directory.openFile("documents.snapshot", .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (snapshot_file) |file| {
            var snapshot_reader = wal.Log{ .file = file, .offset = 32, .maximum_record_bytes = maximum_record_bytes };
            defer snapshot_reader.close();
            var header: [32]u8 = undefined;
            if (try file.preadAll(&header, 0) != 32) return error.InvalidSnapshotHeader;
            if (!std.mem.eql(u8, header[0..8], "VSNP0001") or checksums.crc32(header[0..28]) != std.mem.readInt(u32, header[28..32], .little)) return error.InvalidSnapshotHeader;
            const watermark = std.mem.readInt(u64, header[8..16], .little);
            const document_count = std.mem.readInt(u64, header[16..24], .little);
            while (try snapshot_reader.next(allocator, false)) |record| {
                defer allocator.free(record.payload);
                if (record.sequence > watermark or record.kind != .document) return error.InvalidSnapshotRecord;
                try result.replay(record);
            }
            if (result.entries.count() != document_count) return error.InvalidSnapshotDocumentCount;
            result.sequence = watermark;
        }
        while (try result.log.next(allocator, true)) |record| {
            defer allocator.free(record.payload);
            if (record.sequence > result.sequence) try result.replay(record);
        }
        result.log.sequence = result.sequence;
        return result;
    }

    pub fn close(self: *Store) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| entry.*.destroy(self.allocator);
        self.entries.deinit();
        self.log.close();
        self.lock_file.close();
        self.directory.close();
    }

    fn apply(self: *Store, document: *documents.Document) !void {
        const result = try self.entries.getOrPut(document.id);
        if (result.found_existing) {
            const previous = result.value_ptr.*;
            if (!std.mem.eql(u8, previous.url, document.url)) return error.DocumentIdentifierCollision;
            previous.destroy(self.allocator);
        }
        result.value_ptr.* = document;
    }

    fn replay(self: *Store, record: wal.Record) !void {
        switch (record.kind) {
            .document => {
                const document = try documents.Document.decode(self.allocator, record.payload, record.sequence);
                errdefer document.destroy(self.allocator);
                try self.apply(document);
            },
            .deletion => {
                var decoder = binary.Decoder{ .bytes = record.payload };
                const id = try decoder.integer(u64);
                try decoder.finish();
                if (self.entries.fetchRemove(id)) |removed| removed.value.destroy(self.allocator);
            },
        }
        self.sequence = record.sequence;
        self.recovered_records += 1;
    }

    pub fn upsert(self: *Store, input: documents.Input) !Mutation {
        const sequence = try std.math.add(u64, self.sequence, 1);
        const document = try documents.Document.create(self.allocator, input, sequence);
        errdefer document.destroy(self.allocator);
        const previous = self.entries.get(document.id);
        if (previous) |existing| {
            if (!std.mem.eql(u8, existing.url, document.url)) return error.DocumentIdentifierCollision;
            if (existing.equivalent(document)) {
                const result = Mutation{ .id = existing.id, .sequence = existing.sequence, .created = false, .changed = false };
                document.destroy(self.allocator);
                return result;
            }
        }
        try self.entries.ensureUnusedCapacity(1);
        const payload = try document.encode(self.allocator);
        defer self.allocator.free(payload);
        try self.log.appendAt(.document, payload, sequence);
        self.entries.putAssumeCapacity(document.id, document);
        if (previous) |existing| existing.destroy(self.allocator);
        self.sequence = sequence;
        return .{ .id = document.id, .sequence = sequence, .created = previous == null, .changed = true };
    }

    pub fn delete(self: *Store, id: u64) !bool {
        if (!self.entries.contains(id)) return false;
        const sequence = try std.math.add(u64, self.sequence, 1);
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, id, .little);
        try self.log.appendAt(.deletion, &payload, sequence);
        const removed = self.entries.fetchRemove(id).?;
        removed.value.destroy(self.allocator);
        self.sequence = sequence;
        return true;
    }

    fn earlier(_: void, left: *documents.Document, right: *documents.Document) bool {
        return left.sequence < right.sequence;
    }

    pub fn snapshot(self: *Store) !void {
        var list = std.ArrayList(*documents.Document).init(self.allocator);
        defer list.deinit();
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| try list.append(entry.*);
        std.mem.sort(*documents.Document, list.items, {}, earlier);
        const file = try self.directory.createFile("documents.snapshot.next", .{ .read = true });
        var snapshot_log = wal.Log{ .file = file, .offset = 32, .maximum_record_bytes = self.log.maximum_record_bytes };
        defer snapshot_log.close();
        var header: [32]u8 = @splat(0);
        @memcpy(header[0..8], "VSNP0001");
        std.mem.writeInt(u64, header[8..16], self.sequence, .little);
        std.mem.writeInt(u64, header[16..24], list.items.len, .little);
        std.mem.writeInt(u32, header[28..32], checksums.crc32(header[0..28]), .little);
        try file.pwriteAll(&header, 0);
        for (list.items) |document| {
            const payload = try document.encode(self.allocator);
            defer self.allocator.free(payload);
            try snapshot_log.appendAt(.document, payload, document.sequence);
        }
        try snapshot_log.file.sync();
        try self.directory.rename("documents.snapshot.next", "documents.snapshot");
        try std.posix.fsync(self.directory.fd);
        try self.log.reset(self.sequence);
    }
};
