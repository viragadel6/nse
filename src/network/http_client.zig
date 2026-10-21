const std = @import("std");

pub const Response = struct { status: std.http.Status, body: []u8 };

pub fn request(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, maximum_bytes: usize, timeout_ms: u32) !Response {
    if (timeout_ms == 0) return error.DeadlineExceeded;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var headers: [16384]u8 = undefined;
    var outgoing = try client.open(method, try std.Uri.parse(url), .{
        .server_header_buffer = &headers,
        .redirect_behavior = if (payload == null) @enumFromInt(3) else .unhandled,
        .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default, .user_agent = .{ .override = "document-crawler/0.1" } },
    });
    defer outgoing.deinit();
    const connection = outgoing.connection orelse return error.ConnectionUnavailable;
    const timeout = std.posix.timeval{ .sec = @intCast(timeout_ms / 1000), .usec = @intCast((timeout_ms % 1000) * 1000) };
    try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
    if (payload) |bytes| outgoing.transfer_encoding = .{ .content_length = bytes.len };
    try outgoing.send();
    if (payload) |bytes| try outgoing.writeAll(bytes);
    try outgoing.finish();
    try outgoing.wait();
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try outgoing.reader().readAllArrayList(&output, maximum_bytes);
    return .{ .status = outgoing.response.status, .body = try output.toOwnedSlice() };
}
