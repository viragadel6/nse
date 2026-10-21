const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: deployment-worker <node-id> <role>\n") catch {};
        return error.InvalidArguments;
    }
    const node_id = args[1];
    const role = args[2];
    try std.io.getStdOut().print("deployment worker {s} role {s} started\n", .{ node_id, role });
}
