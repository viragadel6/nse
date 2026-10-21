const std = @import("std");
const Engine = @import("../runtime/lifecycle.zig").Engine;
const Metrics = @import("../telemetry/metrics.zig").Metrics;
const Queue = @import("../runtime/worker_pool.zig").Queue(std.net.Server.Connection);
const signals = @import("../runtime/signals.zig");
const errors = @import("../runtime/errors.zig");
const routes = @import("../api/routes.zig");

const Context = struct { engine: *Engine, queue: *Queue };

fn worker(context: *Context) void {
    while (context.queue.pop()) |connection| {
        Metrics.increment(&context.engine.metrics.active);
        handle(context.engine, connection) catch {
            Metrics.increment(&context.engine.metrics.errors);
        };
        _ = context.engine.metrics.active.fetchSub(1, .monotonic);
        connection.stream.close();
    }
}

fn handle(engine: *Engine, connection: std.net.Server.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(engine.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = try allocator.alloc(u8, engine.config.api.header_bytes);
    var server = std.http.Server.init(connection, header);
    var request = try server.receiveHead();
    Metrics.increment(&engine.metrics.requests);
    if (request.head.content_length) |length| {
        if (length > engine.config.api.body_bytes) {
            try request.respond("{\"error\":{\"code\":\"request_body_too_large\"}}", .{ .status = .payload_too_large, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
            return;
        }
    }
    const method = request.head.method;
    const target = try allocator.dupe(u8, request.head.target);
    var body = std.ArrayList(u8).init(allocator);
    const reader = try request.reader();
    reader.readAllArrayList(&body, engine.config.api.body_bytes) catch |err| {
        const message = try std.json.stringifyAlloc(allocator, .{ .@"error" = .{ .code = @errorName(err) } }, .{});
        try request.respond(message, .{ .status = .bad_request, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    };
    const response = routes.dispatch(engine, allocator, method, target, body.items) catch |err| {
        Metrics.increment(&engine.metrics.errors);
        const message = try std.json.stringifyAlloc(allocator, .{ .@"error" = .{ .code = @errorName(err) } }, .{});
        try request.respond(message, .{ .status = errors.status(err), .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    };
    try request.respond(response.body, .{ .status = response.status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = response.content_type }} });
}

pub fn serve(engine: *Engine) !void {
    signals.install();
    const address = try std.net.Address.parseIp(engine.config.api.address, engine.config.api.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    var queue = try Queue.init(engine.allocator, engine.config.runtime.queue_capacity);
    defer queue.deinit();
    var context = Context{ .engine = engine, .queue = &queue };
    var threads = std.ArrayList(std.Thread).init(engine.allocator);
    defer threads.deinit();
    defer {
        queue.close();
        for (threads.items) |thread| thread.join();
    }
    try threads.ensureTotalCapacity(engine.config.runtime.worker_threads);
    for (0..engine.config.runtime.worker_threads) |_| threads.appendAssumeCapacity(try std.Thread.spawn(.{}, worker, .{&context}));
    while (!signals.stopping() and !engine.cancellation.isCancelled()) {
        var descriptors = [_]std.posix.pollfd{.{ .fd = server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&descriptors, 250);
        if (ready == 0) continue;
        const connection = server.accept() catch |err| switch (err) { error.ConnectionAborted => continue, else => return err };
        const milliseconds = engine.config.runtime.connection_timeout_ms;
        const timeout = std.posix.timeval{ .sec = @intCast(milliseconds / 1000), .usec = @intCast((milliseconds % 1000) * 1000) };
        std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            connection.stream.close();
            return err;
        };
        std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            connection.stream.close();
            return err;
        };
        queue.push(connection) catch |err| {
            connection.stream.close();
            if (err != error.QueueFull) return err;
        };
    }
}
