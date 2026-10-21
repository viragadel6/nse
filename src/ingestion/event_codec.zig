const std = @import("std");
const binary_codec = @import("../util/binary_codec.zig");
const checksums = @import("../util/checksums.zig");

pub const EventKind = enum(u8) {
    document = 1,
    deletion = 2,
    refresh = 3,
    tombstone = 4,
};

pub const Event = struct {
    kind: EventKind,
    sequence: u64,
    document_id: u64,
    url: []const u8,
    timestamp: i64,
    payload: []const u8,
};

pub const EventVersion: u16 = 1;

pub fn encode(allocator: std.mem.Allocator, event: *const Event) ![]u8 {
    var encoder = binary_codec.Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.integer(u16, EventVersion);
    try encoder.integer(u8, @enumToInt(event.kind));
    try encoder.integer(u64, event.sequence);
    try encoder.integer(u64, event.document_id);
    try encoder.integer(i64, event.timestamp);
    try encoder.string(event.url);
    try encoder.integer(u32, @as(u32, @intCast(event.payload.len)));
    try encoder.appendSlice(event.payload);
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

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Event {
    if (data.len < 32) return error.TruncatedRecord;
    const payload = data[32..];
    var decoder = binary_codec.Decoder{ .bytes = payload };
    const version = try decoder.integer(u16);
    if (version != EventVersion) return error.UnsupportedVersion;
    const kind = try @enumFromInt(EventKind, try decoder.integer(u8));
    const sequence = try decoder.integer(u64);
    const document_id = try decoder.integer(u64);
    const timestamp = try decoder.integer(i64);
    const url = try decoder.string();
    const payload_len = try decoder.integer(u32);
    const payload = try decoder.take(@intCast(payload_len));
    try decoder.finish();
    return Event{ .kind = kind, .sequence = sequence, .document_id = document_id, .url = url, .timestamp = timestamp, .payload = payload };
}
