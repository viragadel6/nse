const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: cluster-launcher <config-dir>\n") catch {};
        return error.InvalidArguments;
    }
    const config_dir = args[1];
    const dir = try std.fs.cwd().openDir(config_dir, .{ .iterate = true });
    defer dir.close();
    var node_count: usize = 0;
    var iterator = dir.iterate();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "node_config.zon") or std.mem.eql(u8, entry.name, "cluster_config.zon") or std.mem.eql(u8, entry.name, "shard_config.zon") or std.mem.eql(u8, entry.name, "storage_config.zon") or std.mem.eql(u8, entry.name, "gpu_config.zon")) node_count += 1;
    }
    try std.io.getStdOut().print("cluster initialized with {d} configuration files\n", .{node_count});
}
