const std = @import("std");
const segments = @import("vector_segment.zig");
const centroids = @import("centroid_index.zig");
const writer_module = @import("index_writer.zig");
const quantization = @import("binary_quantization.zig");
const simd = @import("../scoring/simd_kernels.zig");
const time = @import("../util/time.zig");

pub const ShardError = error{
    NotOpen,
    InvalidEmbedding,
    SearchFailed,
};

pub const Options = struct {
    dir: []const u8 = "data/index",
    shard_id: u32 = 0,
    packed_bytes: u32 = 32,
    centroid_count: u32 = 100000,
    primary_dimensions: u32 = 4096,
    retained_dimensions: u32 = 256,
    probe_count: u32 = 16,
    default_top_k: usize = 100,
    model_version: u64 = 1,
    max_segments: usize = 10,
    flush_threshold_documents: usize = 1 << 18,
};

pub const Hit = struct {
    document_id: u64,
    score: f64,
    hamming: u32,
    centroid: u32,
    quality: f32,
};

pub const SearchStats = struct {
    probes: u32,
    segments: usize,
    scanned: usize,
    elapsed_ms: f64,
};

pub const ShardIndex = struct {
    allocator: std.mem.Allocator,
    options: Options,
    centroid_index: *centroids.CentroidIndex,
    writer: writer_module.IndexWriter,
    open_segments: std.ArrayList(segments.Segment),
    segment_generation: u64 = 0,
    searches: u64 = 0,
    scanned_documents: u64 = 0,
    total_search_ms: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options, centroid_index: *centroids.CentroidIndex) !ShardIndex {
        const writer = try writer_module.IndexWriter.init(allocator, .{
            .dir = options.dir,
            .shard_id = options.shard_id,
            .packed_bytes = options.packed_bytes,
            .centroid_count = options.centroid_count,
            .primary_dimensions = options.primary_dimensions,
            .retained_dimensions = options.retained_dimensions,
            .flush_threshold_documents = options.flush_threshold_documents,
            .max_segments = options.max_segments,
            .model_version = options.model_version,
        }, centroid_index);
        return .{
            .allocator = allocator,
            .options = options,
            .centroid_index = centroid_index,
            .writer = writer,
            .open_segments = std.ArrayList(segments.Segment).init(allocator),
        };
    }

    pub fn deinit(self: *ShardIndex) void {
        self.closeSegments();
        self.open_segments.deinit();
        self.writer.deinit();
    }

    fn closeSegments(self: *ShardIndex) void {
        for (self.open_segments.items) |*segment| segment.close();
        self.open_segments.clearRetainingCapacity();
    }

    pub fn addDocument(self: *ShardIndex, document_id: u64, embedding: []const f32, quality: f32) !void {
        if (embedding.len != self.options.primary_dimensions) return ShardError.InvalidEmbedding;
        try self.writer.add(document_id, embedding, quality);
    }

    pub fn flush(self: *ShardIndex) !void {
        try self.writer.flush();
        self.closeSegments();
    }

    pub fn merge(self: *ShardIndex) !void {
        try self.writer.merge(self.options.max_segments / 2 + 1);
        self.closeSegments();
    }

    fn ensureSegments(self: *ShardIndex) !void {
        if (self.writer.manifest == null) return;
        const manifest = &self.writer.manifest.?;
        if (self.open_segments.items.len == manifest.segments.len and self.segment_generation == manifest.generation) return;
        self.closeSegments();
        for (manifest.segments) |meta| {
            const segment = segments.Segment.open(self.allocator, try self.allocator.dupe(u8, meta.path)) catch continue;
            try self.open_segments.append(segment);
        }
        self.segment_generation = manifest.generation;
    }

    pub fn search(self: *ShardIndex, query: []const f32, top_k: usize) ![]Hit {
        return self.searchWithStats(query, top_k, null);
    }

    pub fn searchWithStats(self: *ShardIndex, query: []const f32, top_k: usize, stats_out: ?*SearchStats) ![]Hit {
        if (query.len != self.options.primary_dimensions) return ShardError.InvalidEmbedding;
        const started = time.StopWatch.start();
        try self.ensureSegments();
        const packed_vector = try quantization.pack(query);
        const probes = try self.centroid_index.probesFor(query[0..self.options.retained_dimensions], self.options.probe_count);
        defer self.allocator.free(probes);
        var results = std.ArrayList(segments.Candidate).init(self.allocator);
        defer results.deinit();
        var scanned: usize = 0;
        for (self.open_segments.items) |*segment| {
            scanned += try segment.scanCentroids(&packed_vector.signs, probes, &results, @max(1, top_k));
        }
        std.sort.block(segments.Candidate, results.items, {}, struct {
            fn gt(_: void, a: segments.Candidate, b: segments.Candidate) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.document_id < b.document_id;
            }
        }.gt);
        const limit = @min(top_k, results.items.len);
        const hits = try self.allocator.alloc(Hit, limit);
        for (0..limit) |index| {
            hits[index] = .{
                .document_id = results.items[index].document_id,
                .score = results.items[index].score,
                .hamming = results.items[index].hamming,
                .centroid = results.items[index].centroid,
                .quality = self.qualityFor(results.items[index].document_id),
            };
        }
        const elapsed = started.elapsedMs();
        self.searches += 1;
        self.scanned_documents += scanned;
        self.total_search_ms += elapsed;
        if (stats_out) |out| {
            out.* = .{
                .probes = @intCast(probes.len),
                .segments = self.open_segments.items.len,
                .scanned = scanned,
                .elapsed_ms = elapsed,
            };
        }
        return hits;
    }

    pub fn scanAll(self: *ShardIndex, query: []const f32, top_k: usize) ![]Hit {
        try self.ensureSegments();
        const packed_vector = try quantization.pack(query);
        var results = std.ArrayList(segments.Candidate).init(self.allocator);
        defer results.deinit();
        for (self.open_segments.items) |*segment| {
            _ = try segment.scanAll(&packed_vector.signs, &results, @max(1, top_k));
        }
        std.sort.block(segments.Candidate, results.items, {}, struct {
            fn gt(_: void, a: segments.Candidate, b: segments.Candidate) bool {
                return a.score > b.score;
            }
        }.gt);
        const limit = @min(top_k, results.items.len);
        const hits = try self.allocator.alloc(Hit, limit);
        for (0..limit) |index| {
            hits[index] = .{
                .document_id = results.items[index].document_id,
                .score = results.items[index].score,
                .hamming = results.items[index].hamming,
                .centroid = results.items[index].centroid,
                .quality = self.qualityFor(results.items[index].document_id),
            };
        }
        return hits;
    }

    fn qualityFor(self: *ShardIndex, document_id: u64) f32 {
        for (self.open_segments.items) |*segment| {
            var low: usize = 0;
            var high: usize = segment.documentCount();
            while (low < high) {
                const middle = low + (high - low) / 2;
                const value = segment.documentId(middle);
                if (value == document_id) return segment.qualityOf(middle);
                if (value < document_id) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
        }
        return 1.0;
    }

    pub fn documentCount(self: *ShardIndex) usize {
        return self.writer.documentCount() + self.writer.pendingCount();
    }

    pub fn averageScanned(self: *ShardIndex) f64 {
        if (self.searches == 0) return 0.0;
        return @as(f64, @floatFromInt(self.scanned_documents)) / @as(f64, @floatFromInt(self.searches));
    }

    pub fn averageLatencyMs(self: *ShardIndex) f64 {
        if (self.searches == 0) return 0.0;
        return self.total_search_ms / @as(f64, @floatFromInt(self.searches));
    }

    pub fn stats(self: *ShardIndex) ShardStats {
        const writer_stats = self.writer.stats();
        return .{
            .shard_id = self.options.shard_id,
            .documents = writer_stats.documents + writer_stats.pending,
            .segments = writer_stats.segments,
            .pending = writer_stats.pending,
            .bytes = writer_stats.bytes,
            .merges = writer_stats.merges,
            .searches = self.searches,
            .average_scanned = self.averageScanned(),
            .average_latency_ms = self.averageLatencyMs(),
            .centroids = self.centroid_index.options.centroid_count,
        };
    }
};

pub const ShardStats = struct {
    shard_id: u32,
    documents: usize,
    segments: usize,
    pending: usize,
    bytes: usize,
    merges: u64,
    searches: u64,
    average_scanned: f64,
    average_latency_ms: f64,
    centroids: u32,
};

pub fn rerankByQuality(hits: []Hit, quality_weight: f64) void {
    for (hits) |*hit| {
        hit.score = hit.score * (1.0 - quality_weight) + @as(f64, hit.quality) * quality_weight;
    }
    std.sort.block(Hit, hits, {}, struct {
        fn gt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    }.gt);
}

pub fn packQuery(query: []const f32) !quantization.Packed {
    return quantization.pack(query);
}

pub fn hammingToSimilarity(distance: u32, bits: u32) f64 {
    return simd.jaccardFromHamming(distance, bits);
}
