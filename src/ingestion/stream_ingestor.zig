const std = @import("std");
const codec = @import("../util/binary_codec.zig");
const hashing = @import("../util/hashing.zig");
const bloom = @import("../util/bloom_filter.zig");
const time = @import("../util/time.zig");
const wal = @import("write_ahead_log.zig");
const partitioner = @import("partitioner.zig");
const pressure = @import("backpressure.zig");

pub const IngestKind = enum(u8) {
    upsert = 0,
    delete = 1,
};

pub const IngestRecord = struct {
    kind: IngestKind = .upsert,
    document_id: u64 = 0,
    canonical_hash: u64 = 0,
    domain_hash: u64 = 0,
    content_hash: u64 = 0,
    url: []const u8 = "",
    title: []const u8 = "",
    text: []const u8 = "",
    language: []const u8 = "",
    quality: f32 = 1.0,
    published_at: i64 = 0,
    indexed_at: i64 = 0,
    shard: u32 = 0,
    model_version: u64 = 1,
    flags: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn release(self: IngestRecord) void {
        if (self.url.len > 0) self.allocator.free(self.url);
        if (self.title.len > 0) self.allocator.free(self.title);
        if (self.text.len > 0) self.allocator.free(self.text);
        if (self.language.len > 0) self.allocator.free(self.language);
    }

    pub fn encodedSize(self: *const IngestRecord) usize {
        return 1 + 8 * 5 + 4 + 4 + 8 + 4 + (4 + self.url.len) + (4 + self.title.len) + (4 + self.text.len) + (4 + self.language.len);
    }

    pub fn encode(self: *const IngestRecord, allocator: std.mem.Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, self.encodedSize());
        var writer = codec.Writer.init(buffer);
        try writer.writeByte(@intFromEnum(self.kind));
        try writer.writeU64(self.document_id);
        try writer.writeU64(self.canonical_hash);
        try writer.writeU64(self.domain_hash);
        try writer.writeU64(self.content_hash);
        try writer.writeU64(self.model_version);
        try writer.writeU32(@bitCast(self.quality));
        try writer.writeU32(self.shard);
        try writer.writeI64(self.published_at);
        try writer.writeU32(self.flags);
        try writer.writeLengthPrefixed(self.url);
        try writer.writeLengthPrefixed(self.title);
        try writer.writeLengthPrefixed(self.text);
        try writer.writeLengthPrefixed(self.language);
        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !IngestRecord {
        var reader = codec.Reader.init(payload);
        var record = IngestRecord{ .allocator = allocator };
        record.kind = @enumFromInt(try reader.readByte());
        record.document_id = try reader.readU64();
        record.canonical_hash = try reader.readU64();
        record.domain_hash = try reader.readU64();
        record.content_hash = try reader.readU64();
        record.model_version = try reader.readU64();
        record.quality = @bitCast(try reader.readU32());
        record.shard = try reader.readU32();
        record.published_at = try reader.readI64();
        record.flags = try reader.readU32();
        record.url = try allocator.dupe(u8, try reader.readLengthPrefixed(1 << 16));
        errdefer allocator.free(record.url);
        record.title = try allocator.dupe(u8, try reader.readLengthPrefixed(1 << 16));
        errdefer allocator.free(record.title);
        record.text = try allocator.dupe(u8, try reader.readLengthPrefixed(1 << 24));
        errdefer allocator.free(record.text);
        record.language = try allocator.dupe(u8, try reader.readLengthPrefixed(64));
        return record;
    }

    pub fn fingerprint(self: *const IngestRecord) u64 {
        return hashing.hash64(self.content_hash, self.text);
    }
};

pub const Sink = struct {
    context: *anyopaque,
    deliver: *const fn (context: *anyopaque, records: []const IngestRecord) anyerror!void,
    flush: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn deliverBatch(self: *const Sink, records: []const IngestRecord) !void {
        try self.deliver(self.context, records);
    }

    pub fn sync(self: *const Sink) !void {
        if (self.flush) |flush| try flush(self.context);
    }
};

pub const Options = struct {
    wal_dir: []const u8 = "data/ingestion",
    wal_name: []const u8 = "ingest.wal",
    max_record_bytes: u32 = 1 << 24,
    sync_on_write: bool = true,
    dedup_capacity: u64 = 1 << 24,
    dedup_false_positive_rate: f64 = 0.001,
    shard_count: u32 = 64,
    replica_count: u32 = 2,
    rate_per_second: f64 = 50000,
    burst: f64 = 20000,
    high_watermark: usize = 8192,
    limit: usize = 65536,
    max_bytes_in_flight: usize = 1 << 30,
    batch_bytes: usize = 4 << 20,
    flush_interval_ms: u64 = 100,
    restore_from_wal: bool = true,
};

pub const IngestOutcome = enum(u8) {
    admitted,
    duplicate,
    deferred,
    rejected,
};

pub const Ingestor = struct {
    allocator: std.mem.Allocator,
    options: Options,
    log: wal.Log,
    directory: std.fs.Dir,
    seen: bloom.BloomFilter,
    shards: partitioner.Partitioner,
    controller: pressure.Controller,
    sink: Sink,
    pending: std.ArrayList(IngestRecord),
    pending_bytes: usize = 0,
    mutex: std.Thread.Mutex = .{},
    sequence: u64 = 0,
    next_document_id: u64 = 1,
    admitted: u64 = 0,
    duplicates: u64 = 0,
    deferred: u64 = 0,
    rejected: u64 = 0,
    batches: u64 = 0,
    bytes_written: u64 = 0,
    last_flush_ms: i64 = 0,
    replayed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options, sink: Sink) !Ingestor {
        std.fs.cwd().makePath(options.wal_dir) catch {};
        var directory = try std.fs.cwd().openDir(options.wal_dir, .{ .iterate = true });
        errdefer directory.close();
        const log = try wal.Log.open(directory, options.wal_name, options.max_record_bytes, true);
        var ingestor = Ingestor{
            .allocator = allocator,
            .options = options,
            .log = log,
            .directory = directory,
            .seen = try bloom.BloomFilter.init(allocator, options.dedup_capacity, options.dedup_false_positive_rate),
            .shards = try partitioner.Partitioner.init(allocator, options.shard_count, options.replica_count),
            .controller = pressure.Controller.init(
                options.rate_per_second,
                options.burst,
                .{ .low = options.high_watermark / 4, .high = options.high_watermark, .limit = options.limit },
                options.max_bytes_in_flight,
            ),
            .sink = sink,
            .pending = std.ArrayList(IngestRecord).init(allocator),
            .last_flush_ms = time.nowMs(),
        };
        if (options.restore_from_wal) {
            ingestor.replayed = ingestor.replayInternal() catch 0;
        }
        return ingestor;
    }

    pub fn deinit(self: *Ingestor) void {
        self.flush() catch {};
        for (self.pending.items) |record| record.release();
        self.pending.deinit();
        self.seen.deinit();
        self.shards.deinit();
        self.log.close();
        self.directory.close();
    }

    fn replayInternal(self: *Ingestor) !u64 {
        var count: u64 = 0;
        self.log.rewind();
        while (try self.log.next(self.allocator, true)) |record| {
            defer self.allocator.free(record.payload);
            const decoded = try IngestRecord.decode(self.allocator, record.payload);
            defer decoded.release();
            if (decoded.kind == .upsert) self.seen.add(decoded.fingerprint());
            if (decoded.document_id + 1 > self.next_document_id) self.next_document_id = decoded.document_id + 1;
            self.sequence = @max(self.sequence, record.sequence);
            count += 1;
        }
        return count;
    }

    pub fn replay(self: *Ingestor, context: *anyopaque, visitor: *const fn (context: *anyopaque, record: IngestRecord, sequence: u64) anyerror!void) !u64 {
        var count: u64 = 0;
        self.log.rewind();
        while (try self.log.next(self.allocator, false)) |record| {
            const decoded = try IngestRecord.decode(self.allocator, record.payload);
            self.allocator.free(record.payload);
            defer decoded.release();
            try visitor(context, decoded, record.sequence);
            count += 1;
        }
        return count;
    }

    pub fn allocateDocumentId(self: *Ingestor) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_document_id;
        self.next_document_id += 1;
        return id;
    }

    pub fn submit(self: *Ingestor, record: IngestRecord) !IngestOutcome {
        const fingerprint = record.fingerprint();
        if (record.kind == .upsert and self.seen.mayContain(fingerprint) and self.isDuplicate(fingerprint, record.content_hash)) {
            self.duplicates += 1;
            return .duplicate;
        }
        const weight: f64 = @as(f64, @floatFromInt(@max(1, record.text.len / 1024)));
        const decision = self.controller.admit(weight, record.text.len);
        switch (decision) {
            .reject => {
                self.rejected += 1;
                return .rejected;
            },
            .defer_admission => {
                self.deferred += 1;
                return .deferred;
            },
            .admit => {},
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sequence += 1;
        const payload = try record.encode(self.allocator);
        defer self.allocator.free(payload);
        try self.log.appendAt(if (record.kind == .delete) wal.Kind.deletion else wal.Kind.document, payload, self.sequence);
        self.bytes_written += payload.len;
        self.seen.add(fingerprint);
        try self.pending.append(record);
        self.pending_bytes += record.text.len;
        self.admitted += 1;
        if (self.pending_bytes >= self.options.batch_bytes) try self.flushLocked();
        return .admitted;
    }

    fn isDuplicate(self: *Ingestor, fingerprint: u64, content_hash: u64) bool {
        _ = content_hash;
        return self.seen.mayContain(fingerprint);
    }

    pub fn flush(self: *Ingestor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushLocked();
    }

    fn flushLocked(self: *Ingestor) !void {
        if (self.pending.items.len == 0) return;
        try self.sink.deliverBatch(self.pending.items);
        try self.sink.sync();
        for (self.pending.items) |record| {
            self.controller.complete(record.text.len, 1.0);
            record.release();
        }
        self.pending.clearRetainingCapacity();
        self.pending_bytes = 0;
        self.batches += 1;
        self.last_flush_ms = time.nowMs();
    }

    pub fn maybeFlush(self: *Ingestor) !usize {
        if (time.nowMs() - self.last_flush_ms < @as(i64, @intCast(self.options.flush_interval_ms))) return 0;
        const count = self.pending.items.len;
        try self.flush();
        return count;
    }

    pub fn assignShard(self: *Ingestor, canonical_hash: u64) !u32 {
        return self.shards.assign(canonical_hash);
    }

    pub fn replicas(self: *Ingestor, canonical_hash: u64) ![]u32 {
        return self.shards.replicasFor(canonical_hash);
    }

    pub fn truncateThrough(self: *Ingestor, sequence: u64) !void {
        try self.log.reset(sequence);
        self.log.rewind();
        self.log.sequence = sequence;
    }

    pub fn stats(self: *Ingestor) IngestorStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .sequence = self.sequence,
            .admitted = self.admitted,
            .duplicates = self.duplicates,
            .deferred = self.deferred,
            .rejected = self.rejected,
            .batches = self.batches,
            .pending = self.pending.items.len,
            .pending_bytes = self.pending_bytes,
            .bytes_written = self.bytes_written,
            .replayed = self.replayed,
            .bloom_fill = self.seen.fillRatio(),
            .shards = self.shards.stats().shards,
            .depth = self.controller.stats().depth,
        };
    }
};

pub const IngestorStats = struct {
    sequence: u64,
    admitted: u64,
    duplicates: u64,
    deferred: u64,
    rejected: u64,
    batches: u64,
    pending: usize,
    pending_bytes: usize,
    bytes_written: u64,
    replayed: u64,
    bloom_fill: f64,
    shards: usize,
    depth: usize,
};
