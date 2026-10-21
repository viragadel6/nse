const std = @import("std");
const transport = @import("transport.zig");
const time = @import("../util/time.zig");

pub const ServerError = error{
    BindFailed,
    AlreadyRunning,
    NotRunning,
    RequestTooLarge,
    TooManyConnections,
    ProtocolError,
    HeaderTooLarge,
};

pub const Verb = enum(u8) {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    OPTIONS,
    PATCH,

    pub fn parse(value: []const u8) ?Verb {
        inline for (.{ .GET, .HEAD, .POST, .PUT, .DELETE, .OPTIONS, .PATCH }) |verb| {
            if (std.mem.eql(u8, value, @tagName(verb))) return verb;
        }
        return null;
    }

    pub fn text(self: Verb) []const u8 {
        return @tagName(self);
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    verb: Verb,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    version: []const u8,
    headers: std.ArrayListUnmanaged(Header) = .{},
    body: []u8,
    remote: std.net.Address,
    received_ms: i64,

    pub fn deinit(self: *Request) void {
        for (self.headers.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.headers.deinit(self.allocator);
        self.allocator.free(self.target);
        self.allocator.free(self.version);
        self.allocator.free(self.body);
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers.items) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate.value;
        }
        return null;
    }

    pub fn queryParam(self: *const Request, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        var pairs = std.mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..separator], key)) {
                const raw = pair[separator + 1 ..];
                const out = try allocator.alloc(u8, raw.len);
                return std.Uri.percentDecodeInPlace(out[0..std.Uri.percentDecodeBackwards(out, raw).len]);
            }
        }
        return null;
    }

    pub fn keepAlive(self: *const Request) bool {
        const value = self.header("connection") orelse return true;
        if (std.ascii.eqlIgnoreCase(value, "close")) return false;
        return std.ascii.eqlIgnoreCase(value, "keep-alive");
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    reason: []const u8 = "OK",
    headers: std.ArrayListUnmanaged(Header) = .{},
    body: std.ArrayListUnmanaged(u8) = .{},
    keep_alive: bool = true,
    content_type: []const u8 = "application/json",
    bytes_written: usize = 0,

    pub fn deinit(self: *Response) void {
        for (self.headers.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
    }

    pub fn setStatus(self: *Response, status: u16, reason: []const u8) void {
        self.status = status;
        self.reason = reason;
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .value = try self.allocator.dupe(u8, value) });
    }

    pub fn setContentType(self: *Response, value: []const u8) void {
        self.content_type = value;
    }

    pub fn writeBody(self: *Response, data: []const u8) !void {
        try self.body.appendSlice(self.allocator, data);
    }

    pub fn writeJson(self: *Response, value: anytype) !void {
        try std.json.stringify(value, .{}, self.body.writer(self.allocator));
    }

    pub fn reset(self: *Response) void {
        for (self.headers.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.headers.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        self.status = 200;
        self.reason = "OK";
        self.content_type = "application/json";
    }

    fn serialize(self: *const Response, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        var writer = out.writer(allocator);
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ self.status, self.reason });
        try writer.print("Content-Type: {s}\r\n", .{self.content_type});
        try writer.print("Content-Length: {d}\r\n", .{self.body.items.len});
        var date_buffer: [64]u8 = undefined;
        const date = time.formatUtc(time.nowMs(), &date_buffer) catch "0";
        try writer.print("Date: {s}\r\n", .{date});
        for (self.headers.items) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        try writer.writeAll(if (self.keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n");
        try writer.writeAll("\r\n");
        try out.appendSlice(allocator, self.body.items);
    }
};

pub const Options = struct {
    max_request_bytes: u32 = 1048576,
    max_response_bytes: u32 = 8388608,
    max_connections: u32 = 4096,
    read_timeout_ms: u32 = 5000,
    write_timeout_ms: u32 = 5000,
    keep_alive_timeout_ms: u32 = 15000,
    max_requests_per_connection: u32 = 1000,
    server_header: []const u8 = "distributed-search-engine",
};

pub const Handler = *const fn (context: *anyopaque, request: *Request, response: *Response) anyerror!void;

pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: transport.Listener,
    options: Options,
    handler: Handler,
    context: *anyopaque,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    requests_served: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connection_group: std.Thread.WaitGroup = .{},

    pub fn init(allocator: std.mem.Allocator, host: []const u8, listen_port: u16, handler: Handler, context: *anyopaque, options: Options) !Server {
        const listener = transport.Listener.bind(host, listen_port, .{
            .read_timeout_ms = options.read_timeout_ms,
            .write_timeout_ms = options.write_timeout_ms,
        }) catch return ServerError.BindFailed;
        return .{ .allocator = allocator, .listener = listener, .options = options, .handler = handler, .context = context };
    }

    pub fn port(self: *Server) u16 {
        return self.listener.port();
    }

    pub fn start(self: *Server) !void {
        if (self.running.load(.acquire)) return ServerError.AlreadyRunning;
        self.running.store(true, .release);
        self.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch {
            self.running.store(false, .release);
            return ServerError.BindFailed;
        };
    }

    pub fn stop(self: *Server) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        const wakeup_port = self.listener.port();
        std.posix.shutdown(self.listener.handle, .both) catch {};
        self.listener.close();
        if (std.Thread.spawn(.{}, wakeupConnection, .{wakeup_port})) |thread| {
            thread.detach();
        } else |_| {}
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        self.connection_group.wait();
    }

    pub fn deinit(self: *Server) void {
        self.stop();
    }

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            var connection = self.listener.accept() catch |err| switch (err) {
                error.ReadTimeout => continue,
                else => break,
            };
            if (self.active_connections.load(.acquire) >= self.options.max_connections) {
                connection.close();
                continue;
            }
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{}, connectionMain, .{ self, connection }) catch {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                connection.close();
                continue;
            };
            thread.detach();
        }
    }

    fn connectionMain(self: *Server, connection: transport.Connection) void {
        defer {
            _ = self.active_connections.fetchSub(1, .acq_rel);
        }
        var mutable = connection;
        defer mutable.close();
        var handled: u32 = 0;
        while (self.running.load(.acquire) and handled < self.options.max_requests_per_connection) {
            const request = self.readRequest(&mutable) catch |err| {
                if (err == ServerError.ProtocolError or err == ServerError.RequestTooLarge or err == ServerError.HeaderTooLarge) {
                    _ = self.errors.fetchAdd(1, .monotonic);
                }
                return;
            };
            handled += 1;
            self.serveRequest(&mutable, request);
            if (!request.keepAlive()) {
                request.deinit();
                return;
            }
            request.deinit();
        }
    }

    fn serveRequest(self: *Server, connection: *transport.Connection, request: *Request) void {
        var response = Response{ .allocator = self.allocator };
        defer response.deinit();
        response.keep_alive = request.keepAlive();
        self.handler(self.context, request, &response) catch |err| {
            response.reset();
            response.setStatus(500, "Internal Server Error");
            response.body.clearRetainingCapacity();
            const message = std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"InternalError\"}";
            defer self.allocator.free(message);
            response.writeBody(message) catch {};
            _ = self.errors.fetchAdd(1, .monotonic);
        };
        if (response.body.items.len > self.options.max_response_bytes) {
            response.reset();
            response.setStatus(500, "Response Too Large");
            response.writeBody("{\"error\":\"ResponseTooLarge\"}") catch {};
        }
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        response.serialize(self.allocator, &out) catch return;
        connection.writeAll(out.items) catch {
            _ = self.errors.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.bytes_written.fetchAdd(out.items.len, .monotonic);
        _ = self.requests_served.fetchAdd(1, .monotonic);
    }

    fn readRequest(self: *Server, connection: *transport.Connection) !*Request {
        var buffer: std.ArrayListUnmanaged(u8) = .{};
        errdefer buffer.deinit(self.allocator);
        var scratch: [8192]u8 = undefined;
        var header_end: ?usize = null;
        while (header_end == null) {
            if (buffer.items.len > 65536) return ServerError.HeaderTooLarge;
            const read = connection.readSome(&scratch) catch return ServerError.ProtocolError;
            if (read == 0) return ServerError.ProtocolError;
            try buffer.appendSlice(self.allocator, scratch[0..read]);
            header_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n");
        }
        const end = header_end.?;
        const head = buffer.items[0..end];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const request_line = lines.next() orelse return ServerError.ProtocolError;
        var parts = std.mem.tokenizeAny(u8, request_line, " ");
        const verb_text = parts.next() orelse return ServerError.ProtocolError;
        const target_text = parts.next() orelse return ServerError.ProtocolError;
        const version_text = parts.next() orelse "HTTP/1.1";
        const verb = Verb.parse(verb_text) orelse return ServerError.ProtocolError;
        var request = try self.allocator.create(Request);
        errdefer {
            request.deinit();
            self.allocator.destroy(request);
        }
        request.* = .{
            .allocator = self.allocator,
            .verb = verb,
            .target = try self.allocator.dupe(u8, target_text),
            .path = undefined,
            .query = undefined,
            .version = try self.allocator.dupe(u8, version_text),
            .headers = .{},
            .body = &.{},
            .remote = connection.address,
            .received_ms = time.nowMs(),
        };
        const target = request.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |mark| {
            request.path = target[0..mark];
            request.query = target[mark + 1 ..];
        } else {
            request.path = target;
            request.query = "";
        }
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = try self.allocator.dupe(u8, std.mem.trim(u8, line[0..separator], " "));
            const value = try self.allocator.dupe(u8, std.mem.trim(u8, line[separator + 1 ..], " "));
            try request.headers.append(self.allocator, .{ .name = name, .value = value });
        }
        var body_offset: usize = end + 4;
        if (request.header("transfer-encoding")) |encoding| {
            if (std.ascii.indexOfIgnoreCase(encoding, "chunked") != null) {
                request.body = try readChunkedBody(self.allocator, connection, buffer.items[body_offset..], self.options.max_request_bytes);
                return request;
            }
        }
        if (request.header("content-length")) |value| {
            const expected = std.fmt.parseInt(usize, value, 10) catch return ServerError.ProtocolError;
            if (expected > self.options.max_request_bytes) return ServerError.RequestTooLarge;
            var body: std.ArrayListUnmanaged(u8) = .{};
            errdefer body.deinit(self.allocator);
            try body.appendSlice(self.allocator, buffer.items[body_offset..]);
            while (body.items.len < expected) {
                const read = connection.readSome(&scratch) catch return ServerError.ProtocolError;
                if (read == 0) break;
                try body.appendSlice(self.allocator, scratch[0..read]);
            }
            request.body = try body.toOwnedSlice(self.allocator);
        } else {
            body_offset = buffer.items.len;
            request.body = &.{};
        }
        return request;
    }
};

fn wakeupConnection(port: u16) void {
    var connection = transport.Connection.connect("127.0.0.1", port, .{ .connect_timeout_ms = 200, .read_timeout_ms = 200 }) catch return;
    connection.close();
}

fn readChunkedBody(allocator: std.mem.Allocator, connection: *transport.Connection, initial: []const u8, limit: u32) ![]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    errdefer buffer.deinit(allocator);
    var pending = initial;
    while (true) {
        var size_line: [64]u8 = undefined;
        var length: usize = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            if (pending.len > 0) {
                byte[0] = pending[0];
                pending = pending[1..];
            } else {
                const read = connection.readAtLeast(&byte, 1) catch return ServerError.ProtocolError;
                _ = read;
            }
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') {
                if (length >= size_line.len) return ServerError.ProtocolError;
                size_line[length] = byte[0];
                length += 1;
            }
        }
        const chunk_size = std.fmt.parseInt(usize, size_line[0..length], 16) catch return ServerError.ProtocolError;
        if (chunk_size == 0) break;
        var remaining = chunk_size;
        while (remaining > 0) {
            var chunk: [65536]u8 = undefined;
            const want = @min(chunk.len, remaining);
            if (pending.len >= want) {
                try buffer.appendSlice(allocator, pending[0..want]);
                pending = pending[want..];
                remaining -= want;
            } else {
                if (pending.len > 0) {
                    try buffer.appendSlice(allocator, pending);
                    remaining -= pending.len;
                    pending = &.{};
                }
                const read = connection.readAtLeast(chunk[0..want], 1) catch return ServerError.ProtocolError;
                try buffer.appendSlice(allocator, chunk[0..read]);
                remaining -= read;
            }
            if (buffer.items.len > limit) return ServerError.RequestTooLarge;
        }
        var terminator: [2]u8 = undefined;
        if (pending.len >= 2) {
            pending = pending[2..];
        } else {
            _ = connection.readAtLeast(&terminator, 1) catch {};
        }
    }
    return buffer.toOwnedSlice(allocator);
}

pub fn statusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Status",
    };
}
