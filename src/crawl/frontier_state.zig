const std = @import("std");
const hashing = @import("../../util/hashing.zig");

pub const FetchState = enum(u8) {
    undiscovered = 0,
    discovered = 1,
    leased = 2,
    fetched = 3,
    failed = 4,
    redirected = 5,
    expired = 6,
    recrawl_pending = 7,
};

pub const FrontierRecord = struct {
    url_hash: u64,
    canonical_url: []const u8,
    discovery_url: []const u8,
    domain_id: u64,
    fetch_state: FetchState = .undiscovered,
    discovery_timestamp: i64 = 0,
    previous_fetch_timestamp: ?i64 = null,
    next_fetch_timestamp: i64 = 0,
    content_fingerprint: [32]u8 = undefined,
    http_status: u16 = 0,
    redirect_target: ?[]const u8 = null,
    retry_count: u16 = 0,
    priority: u32 = 1,
    provenance: []const u8 = "",
};

pub fn encode(record: *const FrontierRecord, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try buffer.appendSlice(std.mem.asBytes(&record.url_hash));
    const canonical_len = @as(u32, @intCast(record.canonical_url.len));
    try buffer.appendSlice(std.mem.asBytes(&canonical_len));
    try buffer.appendSlice(record.canonical_url);
    try buffer.appendSlice(std.mem.asBytes(&record.domain_id));
    try buffer.appendSlice(&{ @enumToInt(record.fetch_state) });
    try buffer.appendSlice(std.mem.asBytes(&record.discovery_timestamp));
    if (record.previous_fetch_timestamp) |ts| {
        try buffer.appendSlice(&{1});
        try buffer.appendSlice(std.mem.asBytes(&ts));
    } else {
        try buffer.appendSlice(&{0});
    }
    try buffer.appendSlice(std.mem.asBytes(&record.next_fetch_timestamp));
    try buffer.appendSlice(&record.content_fingerprint);
    try buffer.appendSlice(std.mem.asBytes(&record.http_status));
    if (record.redirect_target) |target| {
        try buffer.appendSlice(&{1});
        try buffer.appendSlice(std.mem.asBytes(&@as(u16, @intCast(target.len))));
        try buffer.appendSlice(target);
    } else {
        try buffer.appendSlice(&{0});
    }
    try buffer.appendSlice(std.mem.asBytes(&record.retry_count));
    try buffer.appendSlice(std.mem.asBytes(&record.priority));
    try buffer.appendSlice(std.mem.asBytes(&@as(u16, @intCast(record.provenance.len))));
    try buffer.appendSlice(record.provenance);
    return buffer.toOwnedSlice();
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !FrontierRecord {
    var decoder = std.ArrayList(u8).init(allocator);
    _ = decoder;
    var offset: usize = 0;
    const take = fn (n: usize) ![]const u8 {
        if (offset + n > bytes.len) return error.TruncatedRecord;
        const slice = bytes[offset..][0..n];
        offset += n;
        return slice;
    };
    const url_hash = std.mem.readInt(u64, try take(8), .little);
    const canonical_len = std.mem.readInt(u32, try take(4), .little);
    const canonical_url = try take(@intCast(canonical_len));
    const domain_id = std.mem.readInt(u64, try take(8), .little);
    const state_byte = try take(1);
    const fetch_state = switch (@enumFromInt(FetchState, state_byte[0]) catch 0) {
        0 => .undiscovered, 1 => .discovered, 2 => .leased, 3 => .fetched, 4 => .failed, 5 => .redirected, 6 => .expired, else => .recrawl_pending,
    };
    const discovery_timestamp = std.mem.readInt(i64, try take(8), .little);
    const has_prev = try take(1);
    var previous_fetch_timestamp: ?i64 = null;
    if (has_prev[0] == 1) previous_fetch_timestamp = std.mem.readInt(i64, try take(8), .little);
    const next_fetch_timestamp = std.mem.readInt(i64, try take(8), .little);
    var content_fingerprint: [32]u8 = undefined;
    const fingerprint = try take(32);
    var i: usize = 0;
    while (i < 32) { content_fingerprint[i] = fingerprint[i]; i += 1; }
    const http_status = std.mem.readInt(u16, try take(2), .little);
    const has_redirect = try take(1);
    var redirect_target: ?[]const u8 = null;
    if (has_redirect[0] == 1) {
        const target_len = std.mem.readInt(u16, try take(2), .little);
        redirect_target = try take(@intCast(target_len));
    }
    const retry_count = std.mem.readInt(u16, try take(2), .little);
    const priority = std.mem.readInt(u32, try take(4), .little);
    const provenance_len = std.mem.readInt(u16, try take(2), .little);
    const provenance = try take(@intCast(provenance_len));
    return FrontierRecord{
        .url_hash = url_hash,
        .canonical_url = canonical_url,
        .discovery_url = canonical_url,
        .domain_id = domain_id,
        .fetch_state = fetch_state,
        .discovery_timestamp = discovery_timestamp,
        .previous_fetch_timestamp = previous_fetch_timestamp,
        .next_fetch_timestamp = next_fetch_timestamp,
        .content_fingerprint = content_fingerprint,
        .http_status = http_status,
        .redirect_target = redirect_target,
        .retry_count = retry_count,
        .priority = priority,
        .provenance = provenance,
    };
}
