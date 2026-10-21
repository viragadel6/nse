const std = @import("std");
const quantization = @import("binary_quantization.zig");
const centroids = @import("centroid_index.zig");
const segments = @import("vector_segment.zig");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");

pub const WriterError = error{
    InvalidEmbedding,
    NoSegments,
    ManifestCorrupt,
    SegmentMissing,
};

pub const SegmentMeta = struct {
    path: []const u8,
    documents: usize,
    bytes: usize,
    generation: u64,
    created_ms: i64,

    pub fn release(self: *SegmentMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Manifest = struct {
    shard_id: u32,
    generation: u64,
    model_version: u64,
    segments: []SegmentMeta,
    allocator: std.mem.Allocator,

    pub fn release(self: *Manifest) void {
        for (self.segments) |*segment| segment.release(self.allocator);
        self.allocator.free(self.segments);
    }

    pub fn totalDocuments(self: *const Manifest) usize {
        var total: usize = 0;
        for (self.segments) |segment| total += segment.documents;
        return total;
    }

    pub fn totalBytes(self: *const Manifest) usize {
        var total: usize = 0;
        for (self.segments) |segment| total += segment.bytes;
        return total;
    }

    pub fn save(self: *const Manifest, path: []const u8) !void {
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        try out.writer().print("shard={d}\n", .{self.shard_id});
        try out.writer().print("generation={d}\n", .{self.generation});
        try out.writer().print("model={d}\n", .{self.model_version});
        try out.writer().print("segments={d}\n", .{self.segments.len});
        for (self.segments) |segment| {
            try out.writer().print("{s} {d} {d} {d} {d}\n", .{ segment.path, segment.documents, segment.bytes, segment.generation, segment.created_ms });
        }
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(out.items);
        try file.sync();
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Manifest {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1 << 20);
        defer allocator.free(content);
        var manifest = Manifest{ .shard_id = 0, .generation = 0, .model_version = 1, .segments = &.{}, .allocator = allocator };
        var lines = std.mem.splitScalar(u8, content, '\n');
        var count: usize = 0;
        var list = std.ArrayList(SegmentMeta).init(allocator);
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "shard=")) {
                manifest.shard_id = std.fmt.parseInt(u32, trimmed["shard=".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, trimmed, "generation=")) {
                manifest.generation = std.fmt.parseInt(u64, trimmed["generation=".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, trimmed, "model=")) {
                manifest.model_version = std.fmt.parseInt(u64, trimmed["model=".len..], 10) catch 1;
            } else if (std.mem.startsWith(u8, trimmed, "segments=")) {
                count = std.fmt.parseInt(usize, trimmed["segments=".len..], 10) catch 0;
            } else {
                var fields = std.mem.splitScalar(u8, trimmed, ' ');
                const path_value = fields.next() orelse continue;
                const documents = fields.next() orelse continue;
                const bytes = fields.next() orelse continue;
                const generation = fields.next() orelse continue;
                const created = fields.next() orelse continue;
                try list.append(.{
                    .path = try allocator.dupe(u8, path_value),
                    .documents = std.fmt.parseInt(usize, documents, 10) catch 0,
                    .bytes = std.fmt.parseInt(usize, bytes, 10) catch 0,
                    .generation = std.fmt.parseInt(u64, generation, 10) catch 0,
                    .created_ms = std.fmt.parseInt(i64, created, 10) catch 0,
                });
            }
        }
        if (count != list.items.len) return WriterError.ManifestCorrupt;
        manifest.segments = try list.toOwnedSlice();
        return manifest;
    }
};

pub const Options = struct {
    dir: []const u8 = "data/index",
    shard_id: u32 = 0,
    packed_bytes: u32 = 32,
    centroid_count: u32 = 100000,
    primary_dimensions: u32 = 4096,
    retained_dimensions: u32 = 256,
    flush_threshold_documents: usize = 1 << 18,
    max_segments: usize = 10,
    merge_target_segments: usize = 4,
    model_version: u64 = 1,
};

pub const PendingDocument = struct {
    document_id: u64,
    embedding: []const f32,
    quality: f32,
};

pub const IndexWriter = struct {
    allocator: std.mem.Allocator,
    options: Options,
    centroid_index: *centroids.CentroidIndex,
    manifest: ?Manifest,
    pending_ids: std.ArrayList(u64),
    pending_centroids: std.ArrayList(u32),
    pending_packed: std.ArrayList(u8),
    pending_quality: std.ArrayList(f32),
    generation: u64 = 1,
    documents_written: u64 = 0,
    segments_written: u64 = 0,
    merges: u64 = 0,
    flush_ms: u64 = 0,
    last_flush_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options, centroid_index: *centroids.CentroidIndex) !IndexWriter {
        std.fs.cwd().makePath(options.dir) catch {};
        const manifest_path = try std.fs.path.join(allocator, &.{ options.dir, "manifest.idx" });
        defer allocator.free(manifest_path);
        var manifest: ?Manifest = null;
        if (std.fs.cwd().access(manifest_path, .{})) |_| {
            manifest = Manifest.load(allocator, manifest_path) catch null;
        } else |_| {}
        return .{
            .allocator = allocator,
            .options = options,
            .centroid_index = centroid_index,
            .manifest = manifest,
            .pending_ids = std.ArrayList(u64).init(allocator),
            .pending_centroids = std.ArrayList(u32).init(allocator),
            .pending_packed = std.ArrayList(u8).init(allocator),
            .pending_quality = std.ArrayList(f32).init(allocator),
            .last_flush_ms = time.nowMs(),
        };
    }

    pub fn deinit(self: *IndexWriter) void {
        for (self.pending_ids.items) |_| {}
        self.pending_ids.deinit();
        self.pending_centroids.deinit();
        self.pending_packed.deinit();
        self.pending_quality.deinit();
        if (self.manifest) |*manifest| manifest.release();
    }

    fn segmentPath(self: *IndexWriter, generation: u64) ![]u8 {
        const name = try std.fmt.allocPrint(self.allocator, "shard-{d}-g{d}.vsg", .{ self.options.shard_id, generation });
        defer self.allocator.free(name);
        return std.fs.path.join(self.allocator, &.{ self.options.dir, name });
    }

    pub fn add(self: *IndexWriter, document_id: u64, embedding: []const f32, quality: f32) !void {
        if (embedding.len != self.options.primary_dimensions) return WriterError.InvalidEmbedding;
        const packed_vector = try quantization.pack(embedding);
        const centroid = try self.centroid_index.assign(embedding[0..self.options.retained_dimensions]);
        try self.pending_ids.append(document_id);
        try self.pending_centroids.append(centroid);
        try self.pending_quality.append(quality);
        try self.pending_packed.appendSlice(&packed_vector.signs);
        self.documents_written += 1;
        if (self.pending_ids.items.len >= self.options.flush_threshold_documents) try self.flush();
    }

    pub fn pendingCount(self: *const IndexWriter) usize {
        return self.pending_ids.items.len;
    }

    pub fn flush(self: *IndexWriter) !void {
        if (self.pending_ids.items.len == 0) return;
        const started = time.StopWatch.start();
        const path = try self.segmentPath(self.generation);
        defer self.allocator.free(path);
        var writer = segments.Writer.init(self.allocator, path, self.options.packed_bytes, self.options.centroid_count);
        defer writer.deinit();
        for (self.pending_ids.items, 0..) |document_id, index| {
            const start = index * self.options.packed_bytes;
            try writer.add(
                document_id,
                self.pending_centroids.items[index],
                self.pending_quality.items[index],
                self.pending_packed.items[start..][0..self.options.packed_bytes],
            );
        }
        try writer.finalize();
        const documents = self.pending_ids.items.len;
        const stat = try std.fs.cwd().statFile(path);
        var entries = std.ArrayList(SegmentMeta).init(self.allocator);
        if (self.manifest) |*existing| {
            for (existing.segments) |segment| try entries.append(segment);
            existing.segments = &.{};
            existing.release();
        }
        try entries.append(.{
            .path = try self.allocator.dupe(u8, path),
            .documents = documents,
            .bytes = @intCast(stat.size),
            .generation = self.generation,
            .created_ms = time.nowMs(),
        });
        self.manifest = .{
            .shard_id = self.options.shard_id,
            .generation = self.generation,
            .model_version = self.options.model_version,
            .segments = try entries.toOwnedSlice(),
            .allocator = self.allocator,
        };
        const manifest_path = try std.fs.path.join(self.allocator, &.{ self.options.dir, "manifest.idx" });
        defer self.allocator.free(manifest_path);
        try self.manifest.?.save(manifest_path);
        self.generation += 1;
        self.segments_written += 1;
        self.flush_ms += @intFromFloat(started.elapsedMs());
        self.last_flush_ms = time.nowMs();
        self.pending_ids.clearRetainingCapacity();
        self.pending_centroids.clearRetainingCapacity();
        self.pending_quality.clearRetainingCapacity();
        self.pending_packed.clearRetainingCapacity();
        if (self.manifest.?.segments.len >= self.options.max_segments) try self.merge(self.options.merge_target_segments);
    }

    pub fn merge(self: *IndexWriter, target_segments: usize) !void {
        if (self.manifest == null) return WriterError.NoSegments;
        const existing = &self.manifest.?;
        if (existing.segments.len <= 1) return;
        const take = @min(existing.segments.len, @max(2, target_segments));
        var opened = std.ArrayList(segments.Segment).init(self.allocator);
        defer {
            for (opened.items) |*segment| segment.close();
            opened.deinit();
        }
        var consumed = std.ArrayList(SegmentMeta).init(self.allocator);
        var index: usize = 0;
        while (index < take) : (index += 1) {
            const meta = existing.segments[index];
            const segment = segments.Segment.open(self.allocator, try self.allocator.dupe(u8, meta.path)) catch {
                consumed.append(meta) catch {};
                continue;
            };
            try opened.append(segment);
        }
        while (index < existing.segments.len) : (index += 1) {
            try consumed.append(existing.segments[index]);
        }
        if (opened.items.len < 2) {
            for (consumed.items) |*meta| meta.release(self.allocator);
            consumed.deinit();
            return;
        }
        const merged_path = try self.segmentPath(self.generation);
        defer self.allocator.free(merged_path);
        try segments.merge(self.allocator, opened.items, merged_path, self.options.packed_bytes, self.options.centroid_count);
        const stat = try std.fs.cwd().statFile(merged_path);
        var documents: usize = 0;
        for (opened.items) |*segment| documents += segment.documentCount();
        try consumed.append(.{
            .path = try self.allocator.dupe(u8, merged_path),
            .documents = documents,
            .bytes = @intCast(stat.size),
            .generation = self.generation,
            .created_ms = time.nowMs(),
        });
        var stale_paths = std.ArrayList([]const u8).init(self.allocator);
        for (opened.items) |*segment| {
            try stale_paths.append(try self.allocator.dupe(u8, segment.path));
        }
        const previous = existing.segments;
        existing.segments = &.{};
        for (previous) |*meta| meta.release(self.allocator);
        self.allocator.free(previous);
        existing.segments = try consumed.toOwnedSlice();
        existing.generation = self.generation;
        const manifest_path = try std.fs.path.join(self.allocator, &.{ self.options.dir, "manifest.idx" });
        defer self.allocator.free(manifest_path);
        try existing.save(manifest_path);
        for (stale_paths.items) |path| {
            std.fs.cwd().deleteFile(path) catch {};
            self.allocator.free(path);
        }
        stale_paths.deinit();
        self.generation += 1;
        self.merges += 1;
    }

    pub fn documentCount(self: *const IndexWriter) usize {
        if (self.manifest) |manifest| return manifest.totalDocuments();
        return 0;
    }

    pub fn segmentCount(self: *const IndexWriter) usize {
        if (self.manifest) |manifest| return manifest.segments.len;
        return 0;
    }

    pub fn stats(self: *const IndexWriter) WriterStats {
        return .{
            .segments = self.segmentCount(),
            .documents = self.documentCount(),
            .pending = self.pendingCount(),
            .segments_written = self.segments_written,
            .merges = self.merges,
            .flush_ms = self.flush_ms,
            .bytes = if (self.manifest) |manifest| manifest.totalBytes() else 0,
        };
    }
};

pub const WriterStats = struct {
    segments: usize,
    documents: usize,
    pending: usize,
    segments_written: u64,
    merges: u64,
    flush_ms: u64,
    bytes: usize,
};

pub fn shardForDocument(canonical_hash: u64, shard_count: u32) u32 {
    return hashing.shardFor(canonical_hash, shard_count);
}
