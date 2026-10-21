const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: shard-rebalancer <cluster-config>\n") catch {};
        return;
    }
    const config_path = args[1];
    const config_bytes = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(config_bytes);
    const config = try std.zon.parse.fromSlice(struct {
        shard_count: u32,
        replication_factor: u32,
        rebalance_bandwidth_bps: u64,
    }, allocator, config_bytes, null, .{});
    defer allocator.free(config_bytes);
    std.io.getStdOut().writeAll("rebalancing shards\n") catch {};
    _ = config;
}
