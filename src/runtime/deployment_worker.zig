const std = @import("std");
const deployment = @import("deployment");
const http = @import("../network/http_client.zig");
const artifacts = @import("artifacts");
const signals = @import("signals.zig");

fn report(mode: []const u8, path: []const u8, err: anyerror) void {
    std.json.stringify(.{ .worker = mode, .path = path, .@"error" = @errorName(err) }, .{}, std.io.getStdErr().writer()) catch return;
    std.io.getStdErr().writer().writeByte('\n') catch {};
}

fn post(allocator: std.mem.Allocator, config: deployment.Worker, route: []const u8, payload: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimRight(u8, config.api_endpoint, "/"), route });
    defer allocator.free(url);
    var client = http.Client.init(allocator, .{
        .connect_timeout_ms = config.timeout_ms,
        .read_timeout_ms = config.timeout_ms,
        .write_timeout_ms = config.timeout_ms,
        .max_response_bytes = config.response_bytes,
    });
    defer client.deinit();
    var response = try client.post(url, &.{ .{ .name = "content-type", .value = "application/json" } }, payload);
    defer response.deinit();
    if (!response.isSuccess()) return error.WorkerApiOperationFailed;
    return allocator.dupe(u8, response.body);
}

fn discover(allocator: std.mem.Allocator, path: []const u8, url: []const u8) !void {
    if (url.len == 0 or !std.unicode.utf8ValidateSlice(url)) return error.InvalidDiscoveredUrl;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const filename = try std.fmt.allocPrint(allocator, "{s}.url", .{std.fmt.bytesToHex(digest, .lower)});
    defer allocator.free(filename);
    const destination = try std.fs.path.join(allocator, &.{ path, filename }); defer allocator.free(destination);
    const completed = try std.fs.path.join(allocator, &.{ path, "completed", filename }); defer allocator.free(completed);
    for ([_][]const u8{ destination, completed }) |candidate| {
        if (std.fs.cwd().readFileAlloc(allocator, candidate, 65536)) |bytes| {
            defer allocator.free(bytes);
            if (!std.mem.eql(u8, std.mem.trim(u8, bytes, " \r\n\t"), url)) return error.FrontierIdentifierCollision;
            return;
        } else |err| switch (err) { error.FileNotFound => {}, else => return err }
    }
    try artifacts.atomicWrite(allocator, destination, url);
}

fn process(allocator: std.mem.Allocator, config: deployment.Worker, mode: []const u8, path: []const u8, name: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, config.response_bytes); defer allocator.free(bytes);
    if (std.mem.eql(u8, mode, "ingestion")) {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}); defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidIngestionRecord;
        const response = try post(allocator, config, "/ingest", bytes); defer allocator.free(response);
    } else {
        const url = std.mem.trim(u8, bytes, " \r\n\t");
        const payload = try std.json.stringifyAlloc(allocator, .{ .url = url }, .{}); defer allocator.free(payload);
        const response = try post(allocator, config, "/crawl", payload); defer allocator.free(response);
        if (config.discover_links) {
            const Result = struct { discovered_links: []const []const u8 };
            const parsed = try std.json.parseFromSlice(Result, allocator, response, .{ .ignore_unknown_fields = true }); defer parsed.deinit();
            for (parsed.value.discovered_links) |link| try discover(allocator, config.frontier_path, link);
        }
    }
    const directory = if (std.mem.eql(u8, mode, "ingestion")) config.spool_path else config.frontier_path;
    const destination = try std.fs.path.join(allocator, &.{ directory, "completed", name }); defer allocator.free(destination);
    try std.fs.cwd().rename(path, destination);
    var parent = try std.fs.cwd().openDir(directory, .{ .iterate = true }); defer parent.close();
}

pub fn run(allocator: std.mem.Allocator, mode: []const u8, directory: []const u8) !void {
    const config = try deployment.load(allocator, directory);
    if (!std.mem.eql(u8, mode, "crawl") and !std.mem.eql(u8, mode, "ingestion") and !std.mem.eql(u8, mode, "indexer")) return error.InvalidWorkerMode;
    signals.install();
    const path = if (std.mem.eql(u8, mode, "ingestion")) config.worker.spool_path else config.worker.frontier_path;
    try std.fs.cwd().makePath(path);
    const completed = try std.fs.path.join(allocator, &.{ path, "completed" }); defer allocator.free(completed);
    try std.fs.cwd().makePath(completed);
    var timer = try std.time.Timer.start();
    var first = true;
    while (!signals.stopping()) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        if (std.mem.eql(u8, mode, "indexer")) {
            if (first or timer.read() / std.time.ns_per_ms >= config.worker.refresh_ms) {
                const response = post(temporary, config.worker, "/index/refresh", "{}") catch |err| {
                    report(mode, config.worker.api_endpoint, err);
                    std.Thread.sleep(@as(u64, config.worker.poll_ms) * std.time.ns_per_ms);
                    continue;
                };
                _ = response;
                first = false;
                timer.reset();
            }
        } else {
            var folder = try std.fs.cwd().openDir(path, .{ .iterate = true });
            defer folder.close();
            var iterator = folder.iterate();
            while (!signals.stopping()) {
                const entry = try iterator.next() orelse break;
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, if (std.mem.eql(u8, mode, "ingestion")) ".json" else ".url")) continue;
                var record = std.heap.ArenaAllocator.init(allocator);
                defer record.deinit();
                const full = try std.fs.path.join(record.allocator(), &.{ path, entry.name });
                process(record.allocator(), config.worker, mode, full, entry.name) catch |err| report(mode, full, err);
            }
        }
        var slept: u64 = 0;
        while (!signals.stopping() and slept < config.worker.poll_ms) {
            const pause: u64 = @min(100, @as(u64, config.worker.poll_ms) - slept);
            std.Thread.sleep(pause * std.time.ns_per_ms);
            slept += pause;
        }
    }
}
