const std = @import("std");

pub fn compress_gzip(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    const writer = compressed.writer();
    var gzip = std.compress.Gzip.compressWriter(writer, .{});
    try gzip.writeAll(input);
    try gzip.writeFinish();
    try gzip.deinit();
    return compressed.toOwnedSlice();
}

pub fn decompress_gzip(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();
    const writer = decompressed.writer();
    var gzip = std.compress.Gzip.decompressWriter(writer);
    try gzip.writeAll(input);
    try gzip.finish();
    try gzip.deinit();
    return decompressed.toOwnedSlice();
}

pub fn compress_zstd(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    const writer = compressed.writer();
    var zstd = std.compress.Zstd.compressWriter(writer, 17);
    try zstd.writeAll(input);
    try zstd.finish();
    try zstd.deinit();
    return compressed.toOwnedSlice();
}

pub fn decompress_zstd(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();
    const writer = decompressed.writer();
    var zstd = std.compress.Zstd.decompressWriter(writer);
    try zstd.writeAll(input);
    try zstd.finish();
    try zstd.deinit();
    return decompressed.toOwnedSlice();
}
