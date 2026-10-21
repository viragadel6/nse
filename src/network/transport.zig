const std = @import("std");
const http_client = @import("http_client.zig");

pub const Peer = struct {
    address: []const u8,
    port: u16,
    failure_count: u32 = 0,
    last_failure_ms: i64 = 0,
};

pub fn isHealthy(peer: *const Peer) bool {
    return peer.failure_count < 3;
}

pub fn recordFailure(peer: *Peer) void {
    peer.failure_count += 1;
    peer.last_failure_ms = std.time.milliTimestamp(std.time.Clock.wall()) catch 0;
}

pub fn recordSuccess(peer: *Peer) void {
    peer.failure_count = 0;
}

pub fn postJson(allocator: std.mem.Allocator, peer: Peer, path: []const u8, body: []const u8, timeout_ms: u32) !http_client.Response {
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ peer.address, peer.port, path });
    defer allocator.free(url);
    const response = try http_client.request(allocator, .POST, url, body, 4 * 1024 * 1024, timeout_ms);
    if (response.status >= 400) {
        recordFailure(&peer);
        return error.RemoteFailure;
    }
    recordSuccess(&peer);
    return response;
}
