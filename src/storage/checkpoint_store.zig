const std = @import("std");
const checksums = @import("../util/checksums.zig");
const time = @import("../util/time.zig");

pub const CheckpointError = error{
    NotFound,
    CorruptCheckpoint,
    VersionMismatch,
    ChecksumMismatch,
    IncompatibleDimension,
    AlreadyExists,
};

pub const checkpoint_magic = "NCKP";
pub const checkpoint_version: u32 = 4;
pub const header_bytes = 128;

pub const Entry = struct {
    model_id: []const u8,
    version: u64,
    dimension: u32,
    layers: u16,
    heads: u16,
    parameter_count: u64,
    created_ms: i64,
    crc: u32,
    size: u64,
    path: []const u8,
    metrics: []const u8,
    stage: []const u8,
    accelerator: []const u8,
    promoted: bool,

    pub fn release(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.model_id);
        allocator.free(self.path);
        allocator.free(self.metrics);
        allocator.free(self.stage);
        allocator.free(self.accelerator);
    }
};

pub const Options = struct {
    dir: []const u8 = "data/checkpoints",
    keep: u32 = 5,
    verify_on_load: bool = true,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    options: Options,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    mutex: std.Thread.Mutex = .{},
    next_version: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Store {
        std.fs.cwd().makePath(options.dir) catch {};
        var store = Store{ .allocator = allocator, .options = options };
        try store.recover();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| entry.release(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn write(self: *Store, model_id: []const u8, stage: []const u8, accelerator: []const u8, dimension: u32, layers: u16, heads: u16, parameter_count: u64, payload: []const u8, metrics: []const u8, promoted: bool) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const version = self.next_version;
        self.next_version += 1;
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{d}.ckpt", .{ self.options.dir, model_id, version });
        errdefer self.allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(path) catch {};
        }
        const crc = checksums.crc32c(payload, 0);
        var header: [header_bytes]u8 = @splat(0);
        @memcpy(header[0..4], checkpoint_magic);
        std.mem.writeInt(u32, header[4..8], checkpoint_version, .little);
        std.mem.writeInt(u64, header[8..16], version, .little);
        std.mem.writeInt(u32, header[16..20], dimension, .little);
        std.mem.writeInt(u16, header[20..22], layers, .little);
        std.mem.writeInt(u16, header[22..24], heads, .little);
        std.mem.writeInt(u64, header[24..32], parameter_count, .little);
        std.mem.writeInt(u64, header[32..40], @as(u64, @bitCast(time.nowMs())), .little);
        std.mem.writeInt(u32, header[40..44], crc, .little);
        std.mem.writeInt(u64, header[44..52], payload.len, .little);
        std.mem.writeInt(u32, header[52..56], @intCast(model_id.len), .little);
        std.mem.writeInt(u32, header[56..60], @intCast(stage.len), .little);
        std.mem.writeInt(u32, header[60..64], @intCast(accelerator.len), .little);
        std.mem.writeInt(u32, header[64..68], @intCast(metrics.len), .little);
        header[68] = if (promoted) 1 else 0;
        try file.writeAll(&header);
        if (model_id.len > 0) try file.writeAll(model_id);
        if (stage.len > 0) try file.writeAll(stage);
        if (accelerator.len > 0) try file.writeAll(accelerator);
        if (metrics.len > 0) try file.writeAll(metrics);
        try file.writeAll(payload);
        try file.sync();
        file.close();
        try self.entries.append(self.allocator, .{
            .model_id = try self.allocator.dupe(u8, model_id),
            .version = version,
            .dimension = dimension,
            .layers = layers,
            .heads = heads,
            .parameter_count = parameter_count,
            .created_ms = time.nowMs(),
            .crc = crc,
            .size = payload.len + header_bytes,
            .path = path,
            .metrics = try self.allocator.dupe(u8, metrics),
            .stage = try self.allocator.dupe(u8, stage),
            .accelerator = try self.allocator.dupe(u8, accelerator),
            .promoted = promoted,
        });
        if (self.entries.items.len > self.options.keep) try this_gc(self);
        return version;
    }

    pub fn latest(self: *Store, model_id: []const u8) ?*Entry {
        var best: ?*Entry = null;
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.model_id, model_id)) continue;
            if (best == null or entry.version > best.?.version) best = entry;
        }
        return best;
    }

    pub fn find(self: *Store, model_id: []const u8, version: u64) ?*Entry {
        for (self.entries.items) |*entry| {
            if (entry.version == version and std.mem.eql(u8, entry.model_id, model_id)) return entry;
        }
        return null;
    }

    pub fn read(self: *Store, allocator: std.mem.Allocator, model_id: []const u8, version: u64) ![]u8 {
        self.mutex.lock();
        const entry = self.find(model_id, version) orelse {
            self.mutex.unlock();
            return CheckpointError.NotFound;
        };
        const path = try self.allocator.dupe(u8, entry.path);
        const expected_crc = entry.crc;
        const expected_size = entry.size - header_bytes;
        self.mutex.unlock();
        defer self.allocator.free(path);
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        if (stat.size < header_bytes) return CheckpointError.CorruptCheckpoint;
        var header: [header_bytes]u8 = undefined;
        _ = try file.preadAll(&header, 0);
        if (!std.mem.eql(u8, header[0..4], checkpoint_magic)) return CheckpointError.CorruptCheckpoint;
        if (std.mem.readInt(u32, header[4..8], .little) != checkpoint_version) return CheckpointError.VersionMismatch;
        const payload_length = std.mem.readInt(u64, header[44..52], .little);
        const model_length = std.mem.readInt(u32, header[52..56], .little);
        const stage_length = std.mem.readInt(u32, header[56..60], .little);
        const accelerator_length = std.mem.readInt(u32, header[60..64], .little);
        const metrics_length = std.mem.readInt(u32, header[64..68], .little);
        const payload_offset = header_bytes + model_length + stage_length + accelerator_length + metrics_length;
        if (payload_length != expected_size) return CheckpointError.CorruptCheckpoint;
        const payload = try allocator.alloc(u8, payload_length);
        errdefer allocator.free(payload);
        _ = try file.preadAll(payload, payload_offset);
        if (self.options.verify_on_load and checksums.crc32c(payload, 0) != expected_crc) {
            return CheckpointError.ChecksumMismatch;
        }
        return payload;
    }

    pub fn promote(self: *Store, model_id: []const u8, version: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var found = false;
        for (self.entries.items) |*entry| {
            if (entry.version == version and std.mem.eql(u8, entry.model_id, model_id)) {
                entry.promoted = true;
                found = true;
            } else if (std.mem.eql(u8, entry.model_id, model_id)) {
                entry.promoted = false;
            }
        }
        if (!found) return CheckpointError.NotFound;
    }

    pub fn collectGarbage(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try this_gc(self);
    }

    pub fn list(self: *Store, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = try allocator.alloc([]const u8, self.entries.items.len);
        for (self.entries.items, 0..) |entry, index| {
            out[index] = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"version\":{d},\"stage\":\"{s}\",\"dimension\":{d},\"size\":{d},\"promoted\":{s}}}", .{
                entry.model_id, entry.version, entry.stage, entry.dimension, entry.size, if (entry.promoted) "true" else "false",
            });
        }
        return out;
    }

    fn recover(self: *Store) !void {
        var dir = try std.fs.cwd().openDir(self.options.dir, .{ .iterate = true });
        defer dir.close();
        var names = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit();
        }
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".ckpt")) continue;
            try names.append(try self.allocator.dupe(u8, entry.name));
        }
        std.sort.block([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.options.dir, name });
            const file = std.fs.cwd().openFile(path, .{}) catch {
                self.allocator.free(path);
                continue;
            };
            defer file.close();
            const stat = try file.stat();
            if (stat.size < header_bytes) {
                self.allocator.free(path);
                continue;
            }
            var header: [header_bytes]u8 = undefined;
            _ = try file.preadAll(&header, 0);
            if (!std.mem.eql(u8, header[0..4], checkpoint_magic)) {
                self.allocator.free(path);
                continue;
            }
            const version = std.mem.readInt(u64, header[8..16], .little);
            const dimension = std.mem.readInt(u32, header[16..20], .little);
            const layers = std.mem.readInt(u16, header[20..22], .little);
            const heads = std.mem.readInt(u16, header[22..24], .little);
            const parameter_count = std.mem.readInt(u64, header[24..32], .little);
            const created = std.mem.readInt(i64, header[32..40], .little);
            const crc = std.mem.readInt(u32, header[40..44], .little);
            const payload_length = std.mem.readInt(u64, header[44..52], .little);
            const model_length = std.mem.readInt(u32, header[52..56], .little);
            const stage_length = std.mem.readInt(u32, header[56..60], .little);
            const accelerator_length = std.mem.readInt(u32, header[60..64], .little);
            const metrics_length = std.mem.readInt(u32, header[64..68], .little);
            var offset: usize = header_bytes;
            const model_id = try self.readString(file, &offset, model_length);
            const stage = try self.readString(file, &offset, stage_length);
            const accelerator = try self.readString(file, &offset, accelerator_length);
            const metrics = try self.readString(file, &offset, metrics_length);
            try self.entries.append(self.allocator, .{
                .model_id = model_id,
                .version = version,
                .dimension = dimension,
                .layers = layers,
                .heads = heads,
                .parameter_count = parameter_count,
                .created_ms = created,
                .crc = crc,
                .size = payload_length + header_bytes,
                .path = path,
                .metrics = metrics,
                .stage = stage,
                .accelerator = accelerator,
                .promoted = header[68] == 1,
            });
            if (version + 1 > self.next_version) self.next_version = version + 1;
        }
    }

    fn readString(self: *Store, file: std.fs.File, offset: *usize, length: u32) ![]u8 {
        if (length == 0) return self.allocator.dupe(u8, "");
        const buffer = try self.allocator.alloc(u8, length);
        defer self.allocator.free(buffer);
        _ = try file.preadAll(buffer, offset.*);
        offset.* += length;
        return self.allocator.dupe(u8, buffer);
    }

    pub fn entryCount(self: *Store) usize {
        return self.entries.items.len;
    }
};

fn this_gc(self: *Store) !void {
    const keep = @max(1, self.options.keep);
    var by_model = std.StringHashMap(usize).init(self.allocator);
    defer by_model.deinit();
    for (self.entries.items) |entry| {
        const slot = try by_model.getOrPut(entry.model_id);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
    }
    var iterator = by_model.iterator();
    while (iterator.next()) |pair| {
        var versions = std.ArrayList(u64).init(self.allocator);
        defer versions.deinit();
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.model_id, pair.key_ptr.*)) continue;
            if (entry.promoted) continue;
            try versions.append(entry.version);
        }
        if (versions.items.len <= keep) continue;
        std.sort.block(u64, versions.items, {}, struct {
            fn lt(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lt);
        const removable = versions.items[0 .. versions.items.len - keep];
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            var should_remove = false;
            if (!entry.promoted and std.mem.eql(u8, entry.model_id, pair.key_ptr.*)) {
                for (removable) |version| {
                    if (version == entry.version) should_remove = true;
                }
            }
            if (should_remove) {
                std.fs.cwd().deleteFile(entry.path) catch {};
                var removed = self.entries.orderedRemove(index);
                removed.release(self.allocator);
            } else {
                index += 1;
            }
        }
    }
}
