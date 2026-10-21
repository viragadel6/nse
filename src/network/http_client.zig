const std = @import("std");
const transport = @import("transport.zig");
const compression = @import("../util/compression.zig");
const time = @import("../util/time.zig");

pub const HttpError = error{
    InvalidUrl,
    UnsupportedScheme,
    ConnectionFailed,
    ReadTimeout,
    WriteTimeout,
    ResponseTooLarge,
    ProtocolError,
    ChunkedEncodingError,
    DecompressionFailed,
    TlsUnavailable,
    Closed,
};

pub const Verb = enum(u8) {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    OPTIONS,

    pub fn text(self: Verb) []const u8 {
        return @tagName(self);
    }
};

pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    query: []const u8,
    secure: bool,

    pub fn parse(raw: []const u8) HttpError!Url {
        var rest = raw;
        var scheme: []const u8 = "http";
        if (std.mem.startsWith(u8, rest, "https://")) {
            scheme = "https";
            rest = rest["https://".len..];
        } else if (std.mem.startsWith(u8, rest, "http://")) {
            scheme = "http";
            rest = rest["http://".len..];
        } else {
            return HttpError.InvalidUrl;
        }
        const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var authority = rest[0..authority_end];
        var port: u16 = if (std.mem.eql(u8, scheme, "https")) 443 else 80;
        var host = authority;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            const after = authority[colon + 1 ..];
            if (after.len > 0 and std.mem.indexOfNone(u8, after, "0123456789") == null) {
                port = std.fmt.parseInt(u16, after, 10) catch return HttpError.InvalidUrl;
                host = authority[0..colon];
            }
        }
        if (std.mem.indexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
        if (host.len == 0) return HttpError.InvalidUrl;
        var path: []const u8 = "/";
        var query: []const u8 = "";
        if (authority_end < rest.len) {
            var tail = rest[authority_end..];
            if (std.mem.indexOfScalar(u8, tail, '?')) |mark| {
                path = tail[0..mark];
                query = tail[mark + 1 ..];
            } else if (std.mem.indexOfScalar(u8, tail, '#')) |hash| {
                path = tail[0..hash];
            } else {
                path = tail;
            }
        }
        if (path.len == 0) path = "/";
        return .{ .scheme = scheme, .host = host, .port = port, .path = path, .query = query, .secure = scheme.len == 5 };
    }

    pub fn requestPath(self: Url, allocator: std.mem.Allocator) ![]u8 {
        if (self.query.len == 0) return allocator.dupe(u8, self.path);
        return std.fmt.allocPrint(allocator, "{s}?{s}", .{ self.path, self.query });
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const RequestOptions = struct {
    connect_timeout_ms: u32 = 3000,
    read_timeout_ms: u32 = 10000,
    write_timeout_ms: u32 = 5000,
    max_response_bytes: u32 = 8388608,
    follow_redirects: bool = false,
    max_redirects: u8 = 5,
    user_agent: []const u8 = "distributed-search-engine/1.0",
    accept_encoding: []const u8 = "gzip, deflate",
    conditional_etag: []const u8 = "",
    conditional_modified_since: []const u8 = "",
    extra_headers: []const Header = &.{},
};

pub const Response = struct {
    status: u16 = 0,
    reason: []const u8 = "",
    headers: std.ArrayListUnmanaged(Header) = .{},
    body: []u8 = &.{},
    allocator: std.mem.Allocator,
    content_encoding: []const u8 = "",
    content_type: []const u8 = "",
    content_length: usize = 0,
    elapsed_ms: f64 = 0,
    bytes_received: usize = 0,
    keep_alive: bool = false,
    decompressed: bool = false,

    pub fn deinit(self: *Response) void {
        for (self.headers.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.headers.deinit(self.allocator);
        if (self.body.len > 0) self.allocator.free(self.body);
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate.value;
        }
        return null;
    }

    pub fn isRedirect(self: *const Response) bool {
        return switch (self.status) {
            301, 302, 303, 307, 308 => true,
            else => false,
        };
    }

    pub fn isSuccess(self: *const Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    pool: transport.ConnectionPool,
    options: RequestOptions,
    requests: u64 = 0,
    failures: u64 = 0,
    redirects_followed: u64 = 0,
    bytes_received: u64 = 0,
    gzip_decoded: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: RequestOptions) Client {
        return .{
            .allocator = allocator,
            .pool = transport.ConnectionPool.init(allocator, .{
                .connect_timeout_ms = options.connect_timeout_ms,
                .read_timeout_ms = options.read_timeout_ms,
                .write_timeout_ms = options.write_timeout_ms,
            }, 4),
            .options = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pool.deinit();
    }

    pub fn get(self: *Client, url: []const u8) !Response {
        return self.exchange(Verb.GET, url, &.{}, "");
    }

    pub fn post(self: *Client, url: []const u8, headers: []const Header, body: []const u8) !Response {
        return self.exchange(Verb.POST, url, headers, body);
    }

    pub fn delete(self: *Client, url: []const u8, headers: []const Header, body: []const u8) !Response {
        return self.exchange(Verb.DELETE, url, headers, body);
    }

    pub fn put(self: *Client, url: []const u8, headers: []const Header, body: []const u8) !Response {
        return self.exchange(Verb.PUT, url, headers, body);
    }

    pub fn exchange(self: *Client, verb: Verb, url: []const u8, headers: []const Header, body: []const u8) !Response {
        var current = try Url.parse(url);
        var visited: usize = 0;
        while (true) {
            var response = try self.requestOnce(verb, current, headers, body);
            if (self.options.follow_redirects and response.isRedirect() and visited < self.options.max_redirects) {
                const location = response.header("location") orelse return response;
                const resolved = try resolveReference(self.allocator, current, location);
                response.deinit();
                current = resolved;
                visited += 1;
                self.redirects_followed += 1;
                continue;
            }
            return response;
        }
    }

    fn requestOnce(self: *Client, verb: Verb, url: Url, headers: []const Header, body: []const u8) !Response {
        const started = time.StopWatch.start();
        var response = Response{ .allocator = self.allocator };
        errdefer response.deinit();
        if (url.secure) return HttpError.TlsUnavailable;
        var connection = self.pool.acquire(url.host, url.port) catch |err| {
            self.failures += 1;
            return mapError(err);
        };
        var request: std.ArrayListUnmanaged(u8) = .{};
        defer request.deinit(self.allocator);
        const target = try url.requestPath(self.allocator);
        defer self.allocator.free(target);
        try request.writer(self.allocator).print("{s} {s} HTTP/1.1\r\n", .{ verb.text(), target });
        try request.writer(self.allocator).print("Host: {s}:{d}\r\n", .{ url.host, url.port });
        try request.writer(self.allocator).print("User-Agent: {s}\r\n", .{self.options.user_agent});
        try request.writer(self.allocator).print("Accept-Encoding: {s}\r\n", .{self.options.accept_encoding});
        try request.writer(self.allocator).writeAll("Connection: keep-alive\r\n");
        if (self.options.conditional_etag.len > 0) {
            try request.writer(self.allocator).print("If-None-Match: {s}\r\n", .{self.options.conditional_etag});
        }
        if (self.options.conditional_modified_since.len > 0) {
            try request.writer(self.allocator).print("If-Modified-Since: {s}\r\n", .{self.options.conditional_modified_since});
        }
        for (headers) |header| {
            try request.writer(self.allocator).print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        if (body.len > 0) {
            try request.writer(self.allocator).print("Content-Length: {d}\r\n", .{body.len});
        }
        try request.writer(self.allocator).writeAll("\r\n");
        if (body.len > 0) try request.appendSlice(self.allocator, body);
        connection.writeAll(request.items) catch |err| {
            self.failures += 1;
            return mapError(err);
        };
        var buffer: std.ArrayListUnmanaged(u8) = .{};
        defer buffer.deinit(self.allocator);
        var head: [65536]u8 = undefined;
        var offset: usize = 0;
        while (true) {
            const found = if (offset >= 4) std.mem.indexOf(u8, head[0..offset], "\r\n\r\n") else null;
            if (found) |end| {
                try buffer.appendSlice(self.allocator, head[0 .. end + 4]);
                const extra = offset - (end + 4);
                if (extra > 0) {
                    try buffer.appendSlice(self.allocator, head[end + 4 .. offset]);
                }
                break;
            }
            if (offset >= head.len) return HttpError.ProtocolError;
            const read = connection.readSome(head[offset..]) catch |err| return mapError(err);
            if (read == 0) return HttpError.Closed;
            offset += read;
        }
        const header_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n") orelse return HttpError.ProtocolError;
        const head_text = buffer.items[0..header_end];
        var lines = std.mem.splitSequence(u8, head_text, "\r\n");
        const status_line = lines.next() orelse return HttpError.ProtocolError;
        var status_parts = std.mem.tokenizeAny(u8, status_line, " ");
        _ = status_parts.next();
        const status_text = status_parts.next() orelse return HttpError.ProtocolError;
        response.status = std.fmt.parseInt(u16, status_text, 10) catch return HttpError.ProtocolError;
        response.reason = try self.allocator.dupe(u8, status_parts.rest());
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = try self.allocator.dupe(u8, std.mem.trim(u8, line[0..separator], " "));
            const value = try self.allocator.dupe(u8, std.mem.trim(u8, line[separator + 1 ..], " "));
            try response.headers.append(self.allocator, .{ .name = name, .value = value });
        }
        var body_start = header_end + 4;
        var chunked = false;
        var content_length: ?usize = null;
        if (response.header("transfer-encoding")) |encoding| {
            chunked = std.ascii.indexOfIgnoreCase(encoding, "chunked") != null;
        }
        if (response.header("content-length")) |value| {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
        if (response.header("content-encoding")) |value| response.content_encoding = value;
        if (response.header("content-type")) |value| response.content_type = value;
        response.keep_alive = if (response.header("connection")) |value| std.ascii.eqlIgnoreCase(value, "keep-alive") else false;
        if (verb == .HEAD or response.status == 304 or response.status == 204) {
            body_start = buffer.items.len;
            content_length = 0;
            chunked = false;
        }
        var payload: std.ArrayListUnmanaged(u8) = .{};
        defer payload.deinit(self.allocator);
        try payload.appendSlice(self.allocator, buffer.items[body_start..]);
        if (chunked) {
            try readChunked(&connection, &payload, self.options.max_response_bytes, self.allocator);
        } else if (content_length) |expected| {
            if (expected > self.options.max_response_bytes) return HttpError.ResponseTooLarge;
            while (payload.items.len < expected) {
                var chunk: [65536]u8 = undefined;
                const read = connection.readSome(&chunk) catch |err| return mapError(err);
                if (read == 0) break;
                try payload.appendSlice(self.allocator, chunk[0..read]);
                if (payload.items.len > self.options.max_response_bytes) return HttpError.ResponseTooLarge;
            }
        } else {
            while (true) {
                var chunk: [65536]u8 = undefined;
                const read = connection.readSome(&chunk) catch break;
                if (read == 0) break;
                try payload.appendSlice(self.allocator, chunk[0..read]);
                if (payload.items.len > self.options.max_response_bytes) return HttpError.ResponseTooLarge;
            }
        }
        response.body = try payload.toOwnedSlice(self.allocator);
        response.content_length = response.body.len;
        response.bytes_received = response.body.len;
        response.elapsed_ms = started.elapsedMs();
        self.bytes_received += response.body.len;
        self.requests += 1;
        if (response.content_encoding.len > 0) {
            if (std.ascii.indexOfIgnoreCase(response.content_encoding, "gzip") != null) {
                const decoded = compression.gzipDecompress(self.allocator, response.body, self.options.max_response_bytes * 4) catch return HttpError.DecompressionFailed;
                self.allocator.free(response.body);
                response.body = decoded;
                response.content_length = decoded.len;
                response.decompressed = true;
                self.gzip_decoded += 1;
            } else if (std.ascii.indexOfIgnoreCase(response.content_encoding, "deflate") != null) {
                const decoded = compression.zlibDecompress(self.allocator, response.body, self.options.max_response_bytes * 4) catch return HttpError.DecompressionFailed;
                self.allocator.free(response.body);
                response.body = decoded;
                response.content_length = decoded.len;
                response.decompressed = true;
            }
        }
        self.pool.release(connection);
        return response;
    }
};

fn readChunked(connection: *transport.Connection, payload: *std.ArrayListUnmanaged(u8), limit: u32, allocator: std.mem.Allocator) !void {
    while (true) {
        var size_line: [64]u8 = undefined;
        var length: usize = 0;
        while (length < size_line.len) {
            var byte: [1]u8 = undefined;
            const read = connection.readAtLeast(&byte, 1) catch return HttpError.ChunkedEncodingError;
            _ = read;
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') {
                size_line[length] = byte[0];
                length += 1;
            }
        }
        const chunk_size = std.fmt.parseInt(usize, size_line[0..length], 16) catch return HttpError.ChunkedEncodingError;
        if (chunk_size == 0) {
            var terminator: [2]u8 = undefined;
            _ = connection.readAtLeast(&terminator, 2) catch {};
            return;
        }
        var remaining = chunk_size;
        while (remaining > 0) {
            var chunk: [65536]u8 = undefined;
            const want = @min(chunk.len, remaining);
            const read = connection.readAtLeast(chunk[0..want], 1) catch return HttpError.ChunkedEncodingError;
            try payload.appendSlice(allocator, chunk[0..read]);
            remaining -= read;
            if (payload.items.len > limit) return HttpError.ResponseTooLarge;
        }
        var terminator: [2]u8 = undefined;
        _ = connection.readAtLeast(&terminator, 2) catch {};
    }
}

fn resolveReference(allocator: std.mem.Allocator, base: Url, reference: []const u8) !Url {
    if (std.mem.startsWith(u8, reference, "http://") or std.mem.startsWith(u8, reference, "https://")) {
        return Url.parse(reference);
    }
    var joined = std.ArrayListUnmanaged(u8){};
    defer joined.deinit(allocator);
    try joined.writer(allocator).print("{s}://{s}:{d}", .{ base.scheme, base.host, base.port });
    if (std.mem.startsWith(u8, reference, "/")) {
        try joined.appendSlice(allocator, reference);
    } else {
        const directory_end = std.mem.lastIndexOfScalar(u8, base.path, '/') orelse 0;
        try joined.appendSlice(allocator, base.path[0..@max(1, directory_end)]);
        try joined.appendSlice(allocator, reference);
    }
    const text = try joined.toOwnedSlice(allocator);
    defer allocator.free(text);
    return Url.parse(text);
}

fn mapError(err: anyerror) HttpError {
    return switch (err) {
        error.ConnectionFailed => HttpError.ConnectionFailed,
        error.ConnectionClosed => HttpError.Closed,
        error.ReadTimeout => HttpError.ReadTimeout,
        error.WriteTimeout => HttpError.WriteTimeout,
        error.InvalidAddress => HttpError.InvalidUrl,
        else => HttpError.ProtocolError,
    };
}
