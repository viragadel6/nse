const std = @import("std");
const binary = @import("../util/binary_codec.zig");
const checksums = @import("../util/checksums.zig");
const urls = @import("../crawl/url_normalization.zig");
const quantization = @import("../index/binary_quantization.zig");

pub const Input = struct {
    url: []const u8,
    title: []const u8 = "",
    text: []const u8,
    language: []const u8 = "",
    quality: f32 = 1.0,
    published_at: i64 = 0,
    embedding: ?[]const f32 = null,
    model_version: u64 = 1,
};

pub const Document = struct {
    id: u64,
    sequence: u64,
    url: []u8,
    title: []u8,
    text: []u8,
    language: []u8,
    quality: f32,
    published_at: i64,
    indexed_at: i64,
    model_version: u64,
    embedding: ?[]f32,
    binary_vector: ?quantization.Packed,
    fingerprint: [32]u8,

    pub fn create(allocator: std.mem.Allocator, input: Input, sequence: u64) !*Document {
        if (input.text.len == 0 or !std.unicode.utf8ValidateSlice(input.text) or !std.unicode.utf8ValidateSlice(input.title) or !std.unicode.utf8ValidateSlice(input.language)) return error.InvalidDocumentText;
        if (!std.math.isFinite(input.quality) or input.quality < 0 or input.quality > 1 or input.published_at < 0) return error.InvalidDocumentMetadata;
        const url = try urls.normalize(allocator, input.url);
        errdefer allocator.free(url);
        const title = try allocator.dupe(u8, input.title);
        errdefer allocator.free(title);
        const text = try allocator.dupe(u8, input.text);
        errdefer allocator.free(text);
        const language = try allocator.dupe(u8, input.language);
        errdefer allocator.free(language);
        const embedding = if (input.embedding) |vector| try quantization.normalize(allocator, vector) else null;
        errdefer if (embedding) |vector| allocator.free(vector);
        const binary_vector = if (embedding) |vector| try quantization.pack(vector) else null;
        const hash = checksums.content(url);
        const result = try allocator.create(Document);
        result.* = .{
            .id = std.mem.readInt(u64, hash[0..8], .little),
            .sequence = sequence,
            .url = url,
            .title = title,
            .text = text,
            .language = language,
            .quality = input.quality,
            .published_at = input.published_at,
            .indexed_at = std.time.timestamp(),
            .model_version = input.model_version,
            .embedding = embedding,
            .binary_vector = binary_vector,
            .fingerprint = checksums.content(text),
        };
        return result;
    }

    pub fn destroy(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.title);
        allocator.free(self.text);
        allocator.free(self.language);
        if (self.embedding) |vector| allocator.free(vector);
        allocator.destroy(self);
    }

    pub fn equivalent(self: *const Document, other: *const Document) bool {
        if (!std.mem.eql(u8, self.url, other.url) or !std.mem.eql(u8, self.title, other.title) or !std.mem.eql(u8, self.text, other.text) or !std.mem.eql(u8, self.language, other.language)) return false;
        if (self.quality != other.quality or self.published_at != other.published_at or self.model_version != other.model_version) return false;
        if ((self.embedding == null) != (other.embedding == null)) return false;
        if (self.embedding) |vector| if (!std.mem.eql(f32, vector, other.embedding.?)) return false;
        return true;
    }

    pub fn encode(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
        var encoder = binary.Encoder.init(allocator);
        errdefer encoder.deinit();
        try encoder.integer(u16, 1);
        try encoder.integer(u16, quantization.dimensions);
        try encoder.integer(u64, self.id);
        try encoder.integer(i64, self.indexed_at);
        try encoder.integer(i64, self.published_at);
        try encoder.integer(u64, self.model_version);
        try encoder.float(self.quality);
        try encoder.string(self.url);
        try encoder.string(self.title);
        try encoder.string(self.text);
        try encoder.string(self.language);
        try encoder.integer(u8, if (self.embedding != null) 1 else 0);
        if (self.embedding) |vector| for (vector) |coordinate| try encoder.float(coordinate);
        return encoder.bytes.toOwnedSlice();
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, sequence: u64) !*Document {
        var decoder = binary.Decoder{ .bytes = bytes };
        if (try decoder.integer(u16) != 1 or try decoder.integer(u16) != quantization.dimensions) return error.IncompatibleDocumentFormat;
        const id = try decoder.integer(u64);
        const indexed_at = try decoder.integer(i64);
        const published_at = try decoder.integer(i64);
        const model_version = try decoder.integer(u64);
        const quality = try decoder.float();
        const url = try decoder.string();
        const title = try decoder.string();
        const text = try decoder.string();
        const language = try decoder.string();
        const flag = try decoder.integer(u8);
        if (flag > 1) return error.InvalidEmbeddingFlag;
        var vector: [quantization.dimensions]f32 = undefined;
        if (flag == 1) for (&vector) |*coordinate| { coordinate.* = try decoder.float(); };
        try decoder.finish();
        const result = try create(allocator, .{ .url = url, .title = title, .text = text, .language = language, .quality = quality, .published_at = published_at, .model_version = model_version }, sequence);
        errdefer result.destroy(allocator);
        if (result.id != id or indexed_at < 0) return error.InvalidDocumentIdentity;
        result.indexed_at = indexed_at;
        if (flag == 1) {
            var squared: f64 = 0;
            for (vector) |coordinate| squared += @as(f64, coordinate) * coordinate;
            if (@abs(squared - 1.0) > 0.001) return error.UnnormalizedEmbedding;
            result.embedding = try allocator.dupe(f32, &vector);
            result.binary_vector = try quantization.pack(result.embedding.?);
        }
        return result;
    }
};
