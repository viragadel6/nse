const std = @import("std");
const http = @import("../src/network/http_client.zig");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.io.getStdErr().writeAll("usage: embedding-client <endpoint> <text>\n") catch {};
        return error.InvalidArguments;
    }
    const endpoint = args[1];
    const text = args[2];
    const response = try http.request(allocator, .POST, endpoint, try std.json.stringifyAlloc(allocator, .{ .text = text }, .{}), 4 * 1024 * 1024, 60000);
    defer allocator.free(response.body);
    try std.io.getStdOut().writeAll(response.body);
    try std.io.getStdOut().writeByte('\n');
}
