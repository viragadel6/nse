const std = @import("std");
const simd = @import("../scoring/simd_kernels.zig");
const checksums = @import("../util/checksums.zig");

pub const SegmentError = error{
    CorruptSegment,
    VersionMismatch,
    InvalidPackedWidth,
    EmptySegment,
    MappingFailed,
};

pub const segment_magic = "NVSG";
pub const segment_version: u32 = 1;
pub const header_bytes: usize = 96;

pub const Entry = struct {
    document_id: u64,
    centroid: u32,
    quality: f32,
    signs: []const u8,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: std.ArrayList(Entry),
    packed_bytes: u32,
    centroid_count: u32,
    compressed: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, packed_bytes: u32, centroid_count: u32) Writer {
        return .{
            .allocator = allocator,
            .path = path,
            .entries = std.ArrayList(Entry).init(allocator),
            .packed_bytes = packed_bytes,
            .centroid_count = centroid_count,
        };
    }

    pub fn deinit(self: *Writer) void {
        for (self.entries.items) |entry| self.allocator.free(entry.signs);
        self.entries.deinit();
    }

    pub fn add(self: *Writer, document_id: u64, centroid: u32, quality: f32, signs: []const u8) !void {
        if (signs.len != self.packed_bytes) return SegmentError.InvalidPackedWidth;
        try self.entries.append(.{
            .document_id = document_id,
            .centroid = centroid,
            .quality = quality,
            .signs = try self.allocator.dupe(u8, signs),
        });
    }

    pub fn count(self: *const Writer) usize {
        return self.entries.items.len;
    }

    fn lessThan(_: void, left: Entry, right: Entry) bool {
        if (left.centroid != right.centroid) return left.centroid < right.centroid;
        return left.document_id < right.document_id;
    }

    pub fn finalize(self: *Writer) !void {
        if (self.entries.items.len == 0) return SegmentError.EmptySegment;
        std.sort.block(Entry, self.entries.items, {}, lessThan);
        const entry_count = self.entries.items.len;
        const width = self.packed_bytes;
        const posting_bytes = (@as(usize, self.centroid_count) + 1) * 4;
        const doc_offset = header_bytes + posting_bytes;
        const centroid_offset = doc_offset + entry_count * 8;
        const quality_offset = centroid_offset + entry_count * 4;
        const vector_offset = quality_offset + entry_count * 4;
        const total = vector_offset + entry_count * @as(usize, width) + 4;
        const buffer = try self.allocator.alloc(u8, total);
        defer self.allocator.free(buffer);
        @memset(buffer, 0);
        @memcpy(buffer[0..4], segment_magic);
        std.mem.writeInt(u32, buffer[4..8], segment_version, .little);
        std.mem.writeInt(u64, buffer[8..16], @intCast(entry_count), .little);
        std.mem.writeInt(u32, buffer[16..20], self.centroid_count, .little);
        std.mem.writeInt(u32, buffer[20..24], width, .little);
        std.mem.writeInt(u64, buffer[24..32], @intCast(doc_offset), .little);
        std.mem.writeInt(u64, buffer[32..40], @intCast(centroid_offset), .little);
        std.mem.writeInt(u64, buffer[40..48], @intCast(quality_offset), .little);
        std.mem.writeInt(u64, buffer[48..56], @intCast(vector_offset), .little);
        std.mem.writeInt(u64, buffer[56..64], @intCast(posting_bytes), .little);
        var position: usize = header_bytes;
        var centroid_cursor: u32 = 0;
        var entry_cursor: usize = 0;
        while (centroid_cursor <= self.centroid_count) : (centroid_cursor += 1) {
            while (entry_cursor < self.entries.items.len and self.entries.items[entry_cursor].centroid < centroid_cursor) : (entry_cursor += 1) {}
            std.mem.writeInt(u32, buffer[position..][0..4], @intCast(entry_cursor), .little);
            position += 4;
        }
        for (self.entries.items, 0..) |entry, index| {
            std.mem.writeInt(u64, buffer[doc_offset + index * 8 ..][0..8], entry.document_id, .little);
            std.mem.writeInt(u32, buffer[centroid_offset + index * 4 ..][0..4], entry.centroid, .little);
            std.mem.writeInt(u32, buffer[quality_offset + index * 4 ..][0..4], @bitCast(entry.quality), .little);
            @memcpy(buffer[vector_offset + index * width ..][0..width], entry.signs);
        }
        std.mem.writeInt(u32, buffer[total - 4 ..][0..4], checksums.crc32c(buffer[0 .. total - 4], 0), .little);
        const file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(buffer);
        try file.sync();
    }
};

pub const Candidate = struct {
    document_id: u64,
    score: f64,
    hamming: u32,
    centroid: u32,
};

pub const Segment = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    file: std.fs.File,
    mapped: []align(std.heap.pageSize()) const u8,
    count: usize,
    centroid_count: u32,
    packed_bytes: u32,
    doc_offset: usize,
    centroid_offset: usize,
    quality_offset: usize,
    vector_offset: usize,
    posting_offset: usize,
    posting_bytes: usize,
    checksum_valid: bool,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Segment {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        errdefer file.close();
        const stat = try file.stat();
        if (stat.size < header_bytes + 4) return SegmentError.CorruptSegment;
        const mapped = try std.posix.mmap(
            null,
            stat.size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        if (!std.mem.eql(u8, mapped[0..4], segment_magic)) return SegmentError.CorruptSegment;
        const version = std.mem.readInt(u32, mapped[4..8], .little);
        if (version != segment_version) return SegmentError.VersionMismatch;
        const count = std.mem.readInt(u64, mapped[8..16], .little);
        const centroid_count = std.mem.readInt(u32, mapped[16..20], .little);
        const width = std.mem.readInt(u32, mapped[20..24], .little);
        const doc_offset = std.mem.readInt(u64, mapped[24..32], .little);
        const centroid_offset = std.mem.readInt(u64, mapped[32..40], .little);
        const quality_offset = std.mem.readInt(u64, mapped[40..48], .little);
        const vector_offset = std.mem.readInt(u64, mapped[48..56], .little);
        const posting_bytes = std.mem.readInt(u64, mapped[56..64], .little);
        const expected = std.mem.readInt(u32, mapped[mapped.len - 4 ..][0..4], .little);
        const actual = checksums.crc32c(mapped[0 .. mapped.len - 4], 0);
        return .{
            .allocator = allocator,
            .path = path,
            .file = file,
            .mapped = mapped,
            .count = @intCast(count),
            .centroid_count = centroid_count,
            .packed_bytes = width,
            .doc_offset = @intCast(doc_offset),
            .centroid_offset = @intCast(centroid_offset),
            .quality_offset = @intCast(quality_offset),
            .vector_offset = @intCast(vector_offset),
            .posting_offset = header_bytes,
            .posting_bytes = @intCast(posting_bytes),
            .checksum_valid = expected == actual,
        };
    }

    pub fn close(self: *Segment) void {
        std.posix.munmap(self.mapped);
        self.file.close();
        self.allocator.free(self.path);
    }

    pub fn documentCount(self: *const Segment) usize {
        return self.count;
    }

    pub fn documentId(self: *const Segment, index: usize) u64 {
        return std.mem.readInt(u64, self.mapped[self.doc_offset + index * 8 ..][0..8], .little);
    }

    pub fn centroidOf(self: *const Segment, index: usize) u32 {
        return std.mem.readInt(u32, self.mapped[self.centroid_offset + index * 4 ..][0..4], .little);
    }

    pub fn qualityOf(self: *const Segment, index: usize) f32 {
        return @bitCast(std.mem.readInt(u32, self.mapped[self.quality_offset + index * 4 ..][0..4], .little));
    }

    pub fn vectorAt(self: *const Segment, index: usize) []const u8 {
        const start = self.vector_offset + index * self.packed_bytes;
        return self.mapped[start..][0..self.packed_bytes];
    }

    fn postingStart(self: *const Segment, centroid: u32) usize {
        if (centroid >= self.centroid_count) return self.count;
        return std.mem.readInt(u32, self.mapped[self.posting_offset + @as(usize, centroid) * 4 ..][0..4], .little);
    }

    fn postingEnd(self: *const Segment, centroid: u32) usize {
        if (centroid + 1 >= self.centroid_count) return self.count;
        return std.mem.readInt(u32, self.mapped[self.posting_offset + (@as(usize, centroid) + 1) * 4 ..][0..4], .little);
    }

    pub fn scanCentroids(self: *const Segment, query: []const u8, centroids: []const u32, results: *std.ArrayList(Candidate), limit: usize) !usize {
        var scanned: usize = 0;
        for (centroids) |centroid| {
            const start = self.postingStart(centroid);
            const end = self.postingEnd(centroid);
            var index = start;
            while (index < end and index < self.count) : (index += 1) {
                const signs = self.vectorAt(index);
                const distance = simd.hammingDistance(query, signs);
                scanned += 1;
                if (results.items.len < limit) {
                    try results.append(.{
                        .document_id = self.documentId(index),
                        .score = simd.jaccardFromHamming(distance, @intCast(self.packed_bytes * 8)),
                        .hamming = distance,
                        .centroid = centroid,
                    });
                } else {
                    var worst: usize = 0;
                    var worst_score: f64 = std.math.inf(f64);
                    for (results.items, 0..) |candidate, position| {
                        if (candidate.score < worst_score) {
                            worst_score = candidate.score;
                            worst = position;
                        }
                    }
                    const score = simd.jaccardFromHamming(distance, @intCast(self.packed_bytes * 8));
                    if (score > worst_score) {
                        results.items[worst] = .{
                            .document_id = self.documentId(index),
                            .score = score,
                            .hamming = distance,
                            .centroid = centroid,
                        };
                    }
                }
            }
        }
        return scanned;
    }

    pub fn scanAll(self: *const Segment, query: []const u8, results: *std.ArrayList(Candidate), limit: usize) !usize {
        var scanned: usize = 0;
        for (0..self.count) |index| {
            const signs = self.vectorAt(index);
            const distance = simd.hammingDistance(query, signs);
            scanned += 1;
            if (results.items.len < limit) {
                try results.append(.{
                    .document_id = self.documentId(index),
                    .score = simd.jaccardFromHamming(distance, @intCast(self.packed_bytes * 8)),
                    .hamming = distance,
                    .centroid = self.centroidOf(index),
                });
            } else {
                var worst: usize = 0;
                var worst_score: f64 = std.math.inf(f64);
                for (results.items, 0..) |candidate, position| {
                    if (candidate.score < worst_score) {
                        worst_score = candidate.score;
                        worst = position;
                    }
                }
                const score = simd.jaccardFromHamming(distance, @intCast(self.packed_bytes * 8));
                if (score > worst_score) {
                    results.items[worst] = .{
                        .document_id = self.documentId(index),
                        .score = score,
                        .hamming = distance,
                        .centroid = self.centroidOf(index),
                    };
                }
            }
        }
        return scanned;
    }

    pub fn centroidHistogram(self: *const Segment) ![]u32 {
        const histogram = try self.allocator.alloc(u32, self.centroid_count);
        @memset(histogram, 0);
        for (0..self.count) |index| {
            const centroid = self.centroidOf(index);
            if (centroid < self.centroid_count) histogram[centroid] += 1;
        }
        return histogram;
    }

    pub fn bytes(self: *const Segment) usize {
        return self.mapped.len;
    }
};

pub const MergeInput = struct {
    document_id: u64,
    centroid: u32,
    quality: f32,
    signs: []const u8,
};

pub fn merge(allocator: std.mem.Allocator, segments: []const Segment, path: []const u8, packed_bytes: u32, centroid_count: u32) !void {
    var writer = Writer.init(allocator, path, packed_bytes, centroid_count);
    defer writer.deinit();
    for (segments) |*segment| {
        for (0..segment.count) |index| {
            try writer.add(segment.documentId(index), segment.centroidOf(index), segment.qualityOf(index), segment.vectorAt(index));
        }
    }
    try writer.finalize();
}
