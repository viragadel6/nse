const std = @import("std");
const deployment = @import("deployment");
const configuration = @import("configuration.zig");
const http = @import("../network/http_client.zig");
const artifacts = @import("artifacts");
const signals = @import("signals.zig");
const c = @cImport({ @cInclude("sys/statvfs.h"); });

pub fn prepare(allocator: std.mem.Allocator, config: deployment.Configuration) !void {
    inline for (.{ config.storage.data_path, config.storage.spool_path, config.storage.checkpoint_path, config.storage.frontier_path }) |path| {
        try std.fs.cwd().makePath(path);
        var statistics: c.struct_statvfs = undefined;
        const z = try allocator.dupeZ(u8, path); defer allocator.free(z);
        if (c.statvfs(z.ptr, &statistics) != 0) return error.StorageStatisticsUnavailable;
        const available = try std.math.mul(u64, statistics.f_bavail, statistics.f_frsize);
        if (available < config.storage.minimum_available_bytes) return error.InsufficientStorageCapacity;
        const probe = try std.fmt.allocPrint(allocator, "{s}/.write-{s}", .{ path, try @import("workload").requestId(allocator) });
        defer allocator.free(probe);
        defer std.fs.cwd().deleteFile(probe) catch {};
        try artifacts.atomicWrite(allocator, probe, "storage-ready\n");
    }
    const Assignment = struct { shard: u32, replicas: []const u64 };
    const assignments = try allocator.alloc(Assignment, config.shards.shard_count);
    defer allocator.free(assignments);
    var populated: usize = 0;
    defer for (assignments[0..populated]) |assignment| allocator.free(assignment.replicas);
    for (assignments, 0..) |*assignment, shard| {
        assignment.* = .{ .shard = @intCast(shard), .replicas = try deployment.replicas(allocator, config, @intCast(shard)) };
        populated += 1;
    }
    const bytes = try std.json.stringifyAlloc(allocator, .{ .format_version = config.shards.format_version, .placement = config.shards.placement, .assignments = assignments }, .{}); defer allocator.free(bytes);
    const path = try std.fs.path.join(allocator, &.{ config.storage.data_path, "shard_assignments.json" }); defer allocator.free(path);
    try artifacts.atomicWrite(allocator, path, bytes);
}

fn readiness(allocator: std.mem.Allocator, endpoint: []const u8, timeout_ms: u32) !bool {
    const url = try std.fmt.allocPrint(allocator, "{s}/health", .{std.mem.trimRight(u8, endpoint, "/")}); defer allocator.free(url);
    var client = http.Client.init(allocator, .{
        .connect_timeout_ms = timeout_ms,
        .read_timeout_ms = timeout_ms,
        .write_timeout_ms = timeout_ms,
        .max_response_bytes = 65536,
    });
    defer client.deinit();
    var response = try client.get(url);
    defer response.deinit();
    if (!response.isSuccess()) return false;
    const parsed = try std.json.parseFromSlice(struct { ready: bool }, allocator, response.body, .{ .ignore_unknown_fields = true }); defer parsed.deinit();
    return parsed.value.ready;
}

fn stop(children: []std.process.Child, shutdown_ms: u32) void {
    for (children) |*child| if (child.id > 0) { std.posix.kill(child.id, std.posix.SIG.TERM) catch {}; };
    var timer = std.time.Timer.start() catch {
        for (children) |*child| if (child.id > 0) { _ = child.kill() catch {}; };
        return;
    };
    while (true) {
        var remaining: usize = 0;
        for (children) |*child| {
            if (child.id <= 0) continue;
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) child.id = -1 else remaining += 1;
        }
        if (remaining == 0) return;
        if (timer.read() / std.time.ns_per_ms >= shutdown_ms) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    for (children) |*child| if (child.id > 0) { std.posix.kill(child.id, std.posix.SIG.KILL) catch {}; _ = std.posix.waitpid(child.id, 0); child.id = -1; };
}

pub fn run(allocator: std.mem.Allocator, directory: []const u8, launch: bool) !void {
    const config = try deployment.load(allocator, directory);
    try prepare(allocator, config);
    if (!launch) {
        try std.json.stringify(.{ .valid = true, .nodes = config.cluster.nodes.len, .shards = config.shards.shard_count, .gpu = config.gpu.production_gpu }, .{}, std.io.getStdOut().writer());
        try std.io.getStdOut().writer().writeByte('\n');
        return;
    }
    signals.install();
    var children = std.ArrayList(std.process.Child).init(allocator);
    defer children.deinit();
    defer stop(children.items, config.cluster.shutdown_timeout_ms);
    for (config.cluster.nodes) |node| {
        if (!node.local) continue;
        const settings = try configuration.load(allocator, node.settings_path);
        if (!std.mem.eql(u8, settings.runtime.data_dir, node.data_path)) return error.NodeStorageConfigurationMismatch;
        const executable = try std.fs.path.join(allocator, &.{ config.node.executable_path, "search-node" });
        const argv = try allocator.dupe([]const u8, &.{ executable, "serve", node.settings_path });
        var child = std.process.Child.init(argv, allocator);
        child.cwd = config.node.root_path;
        child.stdin_behavior = .Ignore;
        try child.spawn();
        children.append(child) catch |err| { _ = child.kill() catch {}; return err; };
    }
    var timer = try std.time.Timer.start();
    for (config.cluster.nodes) |node| {
        while (!signals.stopping()) {
            if (readiness(allocator, node.endpoint, @min(1000, config.cluster.readiness_timeout_ms)) catch false) break;
            if (timer.read() / std.time.ns_per_ms >= config.cluster.readiness_timeout_ms) return error.ClusterReadinessDeadlineExceeded;
            std.Thread.sleep(@as(u64, config.cluster.readiness_poll_ms) * std.time.ns_per_ms);
        }
    }
    if (signals.stopping()) return;
    const worker_executable = try std.fs.path.join(allocator, &.{ config.node.executable_path, "deployment-worker" });
    for ([_][]const u8{ "crawl", "ingestion", "indexer" }) |mode| {
        const argv = try allocator.dupe([]const u8, &.{ worker_executable, "worker", mode, directory });
        var child = std.process.Child.init(argv, allocator);
        child.cwd = config.node.root_path;
        child.stdin_behavior = .Ignore;
        try child.spawn();
        children.append(child) catch |err| { _ = child.kill() catch {}; return err; };
    }
    try std.json.stringify(.{ .ready = true, .children = children.items.len, .nodes = config.cluster.nodes.len }, .{}, std.io.getStdOut().writer());
    try std.io.getStdOut().writer().writeByte('\n');
    while (!signals.stopping()) {
        for (children.items) |*child| {
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) { child.id = -1; return error.ClusterServiceExited; }
        }
        std.Thread.sleep(@as(u64, config.cluster.readiness_poll_ms) * std.time.ns_per_ms);
    }
}
