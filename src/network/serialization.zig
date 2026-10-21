const std = @import("std");
const binary_codec = @import("../util/binary_codec.zig");
const checksums = @import("../util/checksums.zig");

pub const SerializationVersion: u16 = 1;

pub fn serializeDocument(doc: anytype, allocator: std.mem.Allocator) ![]u8 {
    var encoder = binary_codec.Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.integer(u16, SerializationVersion);
    try encoder.integer(u64, doc.id);
    try encoder.string(doc.url);
    try encoder.string(doc.text);
    try encoder.integer(u64, doc.timestamp);
    if (doc.embedding) |emb| {
        try encoder.integer(u16, emb.len);
        for (emb) |value| try encoder.float(value);
    } else {
        try encoder.integer(u16, 0);
    }
    var bytes = encoder.bytes.toOwnedSlice() catch |err| { encoder.deinit(); return err; };
    encoder.deinit();
    const hash = checksums.content(bytes);
    var result = try allocator.alloc(u8, bytes.len + 32);
    var i: usize = 0;
    while (i < 32) { result[i] = hash[i]; i += 1; }
    var j: usize = 0;
    while (j < bytes.len) { result[32 + j] = bytes[j]; j += 1; }
    return result;
}

pub fn deserializeDocument(allocator: std.mem.Allocator, data: []const u8) !struct {
    id: u64,
    url: []const u8,
    text: []const u8,
    timestamp: i64,
} {
    if (data.len < 32) return error.TruncatedRecord;
    const payload = data[32..];
    var decoder = binary_codec.Decoder{ .bytes = payload };
    const version = try decoder.integer(u16);
    if (version != SerializationVersion) return error.UnsupportedVersion;
    const id = try decoder.integer(u64);
    const url = try decoder.string();
    const text = try decoder.string();
    const timestamp = try @bitCast(i64, decoder.integer(u64));
    try decoder.finish();
    return .{ .id = id, .url = url, .text = text, .timestamp = timestamp };
}
