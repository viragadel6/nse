const std = @import("std");
const hashing = @import("../util/hashing.zig");
const bloom = @import("../util/bloom_filter.zig");
const checksums = @import("../util/checksums.zig");
const state = @import("crawl_state.zig");

pub const PartitionError = error{
    PartitionFull,
    NotFound,
    CorruptPartition,
    VersionMismatch,
    ChecksumMismatch,
    CapacityExceeded,
};

pub const partition_magic = "NFRT";
pub const partition_version: u32 = 3;
pub const slot_bytes = 32;

pub const Slot = struct {
    hash: u64,
    offset: u64,
    length: u32,
    state: u8,
    reserved: u8,

    pub fn encode(self: Slot, buffer: []u8) !void {
        var writer = std.io.fixedBufferStream(buffer[0..slot_bytes]);
        const w = writer.writer();
        try w.writeInt(u64, self.hash, .little);
        try w.writeInt(u64, self.offset, .little);
        try w.writeInt(u32, self.length, .little);
        try w.writeByte(self.state);
        try w.writeByte(self.reserved);
        try w.writeInt(u64, 0, .little);
    }

    pub fn decode(buffer: []const u8) !Slot {
        if (buffer.len < slot_bytes) return PartitionError.CorruptPartition;
        return .{
            .hash = std.mem.readInt(u64, buffer[0..8], .little),
            .offset = std.mem.readInt(u64, buffer[8..16], .little),
            .length = std.mem.readInt(u32, buffer[16..20], .little),
            .state = buffer[20],
            .reserved = buffer[21],
        };
    }
};

pub const Options = struct {
    slot_count: u64 = 1 << 20,
    data_flush_threshold: u64 = 1 << 22,
    bloom_false_positive_rate: f64 = 0.01,
};

pub const Partition = struct {
    allocator: std.mem.Allocator,
    id: u32,
    options: Options,
    dir: []const u8,
    slot_file: std.fs.File,
    data_file: std.fs.File,
    slot_path: []u8,
    data_path: []u8,
    filter: bloom.BloomFilter,
    data_offset: u64,
    record_count: u64,
    live_count: u64,
    probe_count: u64,
    collision_count: u64,
    bytes_written: u64,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8, id: u32, options: Options) !Partition {
        std.fs.cwd().makePath(dir) catch {};
        const slot_path = try std.fmt.allocPrint(allocator, "{s}/frontier-{d}.slots", .{ dir, id });
        errdefer allocator.free(slot_path);
        const data_path = try std.fmt.allocPrint(allocator, "{s}/frontier-{d}.data", .{ dir, id });
        errdefer allocator.free(data_path);
        var slot_file = try std.fs.cwd().createFile(slot_path, .{ .read = true, .truncate = false });
        errdefer slot_file.close();
        var data_file = try std.fs.cwd().createFile(data_path, .{ .read = true, .truncate = false });
        errdefer data_file.close();
        var filter = try bloom.BloomFilter.init(allocator, @max(1024, options.slot_count), options.bloom_false_positive_rate);
        errdefer filter.deinit();
        var partition = Partition{
            .allocator = allocator,
            .id = id,
            .options = options,
            .dir = dir,
            .slot_file = slot_file,
            .data_file = data_file,
            .slot_path = slot_path,
            .data_path = data_path,
            .filter = filter,
            .data_offset = 0,
            .record_count = 0,
            .live_count = 0,
            .probe_count = 0,
            .collision_count = 0,
            .bytes_written = 0,
        };
        try partition.recover();
        return partition;
    }

    pub fn deinit(self: *Partition) void {
        self.slot_file.close();
        self.data_file.close();
        self.filter.deinit();
        self.allocator.free(self.slot_path);
        self.allocator.free(self.data_path);
    }

    fn slotOffset(index: u64) u64 {
        return 64 + index * slot_bytes;
    }

    fn recover(self: *Partition) !void {
        const stat = try self.slot_file.stat();
        if (stat.size < 64) {
            var header: [64]u8 = @splat(0);
            @memcpy(header[0..4], partition_magic);
            std.mem.writeInt(u32, header[4..8], partition_version, .little);
            std.mem.writeInt(u32, header[8..12], self.id, .little);
            std.mem.writeInt(u64, header[12..20], self.options.slot_count, .little);
            try self.slot_file.writeAll(&header);
            try self.slot_file.setEndPos(slotOffset(self.options.slot_count));
            try self.slot_file.sync();
            self.data_offset = 0;
            return;
        }
        var header: [64]u8 = undefined;
        _ = try self.slot_file.preadAll(&header, 0);
        if (!std.mem.eql(u8, header[0..4], partition_magic)) return PartitionError.CorruptPartition;
        const version = std.mem.readInt(u32, header[4..8], .little);
        if (version != partition_version) return PartitionError.VersionMismatch;
        const needed = slotOffset(self.options.slot_count);
        if (stat.size < needed) try self.slot_file.setEndPos(needed);
        const data_stat = try self.data_file.stat();
        self.data_offset = @intCast(data_stat.size);
        var index: u64 = 0;
        var buffer: [slot_bytes]u8 = undefined;
        while (index < self.options.slot_count) {
            const read = try self.slot_file.preadAll(&buffer, slotOffset(index));
            if (read < slot_bytes) break;
            const slot = try Slot.decode(&buffer);
            if (slot.hash != 0) {
                self.record_count += 1;
                self.live_count += 1;
                self.filter.add(slot.hash);
            }
            index += 1;
        }
    }

    fn indexFor(self: *const Partition, hash_value: u64) u64 {
        return hashing.bucketFor(hash_value, self.options.slot_count);
    }

    pub fn lookup(self: *Partition, hash_value: u64) !?state.UrlRecord {
        if (!self.filter.mayContain(hash_value)) return null;
        var index = self.indexFor(hash_value);
        var probes: u64 = 0;
        var buffer: [slot_bytes]u8 = undefined;
        while (probes < 64) : (probes += 1) {
            const read = try self.slot_file.preadAll(&buffer, slotOffset(index));
            if (read < slot_bytes) return null;
            const slot = try Slot.decode(&buffer);
            if (slot.hash == 0) return null;
            if (slot.hash == hash_value) {
                const payload = try self.allocator.alloc(u8, slot.length);
                defer self.allocator.free(payload);
                _ = try self.data_file.preadAll(payload, slot.offset);
                const expected = std.mem.readInt(u32, payload[payload.len - 4 ..][0..4], .little);
                if (checksums.crc32c(payload[0 .. payload.len - 4], 0) != expected) return PartitionError.ChecksumMismatch;
                return try state.UrlRecord.decode(self.allocator, payload[0 .. payload.len - 4]);
            }
            self.collision_count += 1;
            index = (index + 1) % self.options.slot_count;
        }
        self.probe_count += probes;
        return null;
    }

    pub fn contains(self: *Partition, hash_value: u64) !bool {
        if (!self.filter.mayContain(hash_value)) return false;
        var index = self.indexFor(hash_value);
        var probes: u64 = 0;
        var buffer: [slot_bytes]u8 = undefined;
        while (probes < 64) : (probes += 1) {
            const read = try self.slot_file.preadAll(&buffer, slotOffset(index));
            if (read < slot_bytes) return false;
            const slot = try Slot.decode(&buffer);
            if (slot.hash == 0) return false;
            if (slot.hash == hash_value) return true;
            index = (index + 1) % self.options.slot_count;
        }
        return false;
    }

    pub fn upsert(self: *Partition, record: *const state.UrlRecord) !void {
        const payload = try record.encode(self.allocator);
        defer self.allocator.free(payload);
        const framed = try self.allocator.alloc(u8, payload.len + 4);
        defer self.allocator.free(framed);
        @memcpy(framed[0..payload.len], payload);
        const crc = checksums.crc32c(payload, 0);
        std.mem.writeInt(u32, framed[payload.len..][0..4], crc, .little);
        var index = self.indexFor(record.canonical_hash);
        var probes: u64 = 0;
        var buffer: [slot_bytes]u8 = undefined;
        while (probes < 64) : (probes += 1) {
            const read = try self.slot_file.preadAll(&buffer, slotOffset(index));
            if (read < slot_bytes) return PartitionError.PartitionFull;
            const slot = try Slot.decode(&buffer);
            if (slot.hash == record.canonical_hash) {
                try self.data_file.seekTo(self.data_offset);
                try self.data_file.writeAll(framed);
                const slot_value = Slot{ .hash = record.canonical_hash, .offset = self.data_offset, .length = @intCast(framed.len), .state = @intFromEnum(record.state), .reserved = 0 };
                try slot_value.encode(&buffer);
                try self.slot_file.pwriteAll(&buffer, slotOffset(index));
                self.data_offset += framed.len;
                self.bytes_written += framed.len;
                self.filter.add(record.canonical_hash);
                return;
            }
            if (slot.hash == 0) {
                try self.data_file.seekTo(self.data_offset);
                try self.data_file.writeAll(framed);
                const slot_value = Slot{ .hash = record.canonical_hash, .offset = self.data_offset, .length = @intCast(framed.len), .state = @intFromEnum(record.state), .reserved = 0 };
                try slot_value.encode(&buffer);
                try self.slot_file.pwriteAll(&buffer, slotOffset(index));
                self.data_offset += framed.len;
                self.bytes_written += framed.len;
                self.record_count += 1;
                self.live_count += 1;
                self.filter.add(record.canonical_hash);
                return;
            }
            self.collision_count += 1;
            index = (index + 1) % self.options.slot_count;
        }
        return PartitionError.PartitionFull;
    }

    pub fn readSlotRange(self: *Partition, buffer: []u8, start: u64, count: u64) !usize {
        if (start >= self.options.slot_count or count == 0) return 0;
        const available = @min(count, self.options.slot_count - start);
        if (buffer.len < available * slot_bytes) return PartitionError.CorruptPartition;
        const bytes = try self.slot_file.preadAll(buffer[0 .. available * slot_bytes], slotOffset(start));
        return bytes / slot_bytes;
    }

    pub fn scan(self: *Partition, allocator: std.mem.Allocator, visitor: *const fn (context: *anyopaque, record: state.UrlRecord) anyerror!void, context: *anyopaque) !usize {
        var index: u64 = 0;
        var visited: usize = 0;
        var buffer: [slot_bytes]u8 = undefined;
        while (index < self.options.slot_count) {
            const read = try self.slot_file.preadAll(&buffer, slotOffset(index));
            if (read < slot_bytes) break;
            const slot = try Slot.decode(&buffer);
            index += 1;
            if (slot.hash == 0) continue;
            const payload = try allocator.alloc(u8, slot.length);
            defer allocator.free(payload);
            _ = try self.data_file.preadAll(payload, slot.offset);
            if (payload.len < 4) continue;
            const expected = std.mem.readInt(u32, payload[payload.len - 4 ..][0..4], .little);
            if (checksums.crc32c(payload[0 .. payload.len - 4], 0) != expected) continue;
            const record = state.UrlRecord.decode(allocator, payload[0 .. payload.len - 4]) catch continue;
            defer record.release(allocator);
            try visitor(context, record);
            visited += 1;
        }
        return visited;
    }

    pub fn loadFactor(self: *const Partition) f64 {
        return @as(f64, @floatFromInt(self.live_count)) / @as(f64, @floatFromInt(self.options.slot_count));
    }

    pub fn stats(self: *Partition) PartitionStats {
        return .{
            .id = self.id,
            .records = self.record_count,
            .live = self.live_count,
            .load_factor = self.loadFactor(),
            .bytes_written = self.bytes_written,
            .collisions = self.collision_count,
            .bloom_fill = self.filter.fillRatio(),
        };
    }
};

pub const PartitionStats = struct {
    id: u32,
    records: u64,
    live: u64,
    load_factor: f64,
    bytes_written: u64,
    collisions: u64,
    bloom_fill: f64,
};

pub fn partitionFor(hash_value: u64, partition_count: u32) u32 {
    return hashing.shardFor(hash_value, @max(1, partition_count));
}

pub const RebalancePlan = struct {
    moves: []Move,

    pub const Move = struct {
        from_partition: u32,
        to_partition: u32,
        hash_prefix: u64,
        estimated_records: u64,
    };

    pub fn deinit(self: *RebalancePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.moves);
    }
};

pub fn planRebalance(allocator: std.mem.Allocator, stats: []PartitionStats, threshold: f64) !RebalancePlan {
    if (stats.len < 2) return .{ .moves = &.{} };
    var total: u64 = 0;
    for (stats) |entry| total += entry.live;
    const average = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(stats.len));
    var moves = std.ArrayList(RebalancePlan.Move).init(allocator);
    var target_index: usize = 0;
    for (stats) |entry| {
        const deviation = if (average > 0) (@as(f64, @floatFromInt(entry.live)) - average) / average else 0.0;
        if (deviation <= threshold) continue;
        const excess: u64 = @intFromFloat(@as(f64, @floatFromInt(entry.live)) - average);
        while (target_index < stats.len) : (target_index += 1) {
            const target = stats[target_index];
            if (@as(f64, @floatFromInt(target.live)) < average) break;
        }
        if (target_index >= stats.len) break;
        try moves.append(.{
            .from_partition = entry.id,
            .to_partition = stats[target_index].id,
            .hash_prefix = hashing.mix64(entry.id),
            .estimated_records = excess,
        });
    }
    return .{ .moves = try moves.toOwnedSlice() };
}
