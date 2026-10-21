const std = @import("std");
const json = std.json;
const time = @import("../util/time.zig");
const hashing = @import("../util/hashing.zig");

pub const BrowserError = error{
    HandshakeFailed,
    ConnectionClosed,
    ProtocolError,
    CommandFailed,
    Timeout,
    LaunchFailed,
    TargetUnavailable,
    FrameTooLarge,
    InvalidResponse,
};

pub const Options = struct {
    executable: []const u8 = "chromium",
    host: []const u8 = "127.0.0.1",
    port: u16 = 9222,
    user_data_dir: []const u8 = "/tmp/nse-browser",
    headless: bool = true,
    window_width: u32 = 1280,
    window_height: u32 = 1024,
    user_agent: []const u8 = "distributed-search-engine/1.0",
    startup_timeout_ms: u64 = 30000,
    command_timeout_ms: u64 = 30000,
    max_message_bytes: u32 = 67108864,
    block_images: bool = true,
    extra_arguments: []const []const u8 = &.{},
};

pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(buffer: []u8, input: []const u8) []u8 {
    var position: usize = 0;
    var index: usize = 0;
    while (index + 2 < input.len) : (index += 3) {
        const triplet = @as(u32, input[index]) << 16 | @as(u32, input[index + 1]) << 8 | @as(u32, input[index + 2]);
        buffer[position] = base64_alphabet[(triplet >> 18) & 63];
        buffer[position + 1] = base64_alphabet[(triplet >> 12) & 63];
        buffer[position + 2] = base64_alphabet[(triplet >> 6) & 63];
        buffer[position + 3] = base64_alphabet[triplet & 63];
        position += 4;
    }
    const remaining = input.len - index;
    if (remaining == 1) {
        const value = @as(u32, input[index]) << 16;
        buffer[position] = base64_alphabet[(value >> 18) & 63];
        buffer[position + 1] = base64_alphabet[(value >> 12) & 63];
        buffer[position + 2] = '=';
        buffer[position + 3] = '=';
        position += 4;
    } else if (remaining == 2) {
        const value = @as(u32, input[index]) << 16 | @as(u32, input[index + 1]) << 8;
        buffer[position] = base64_alphabet[(value >> 18) & 63];
        buffer[position + 1] = base64_alphabet[(value >> 12) & 63];
        buffer[position + 2] = base64_alphabet[(value >> 6) & 63];
        buffer[position + 3] = '=';
        position += 4;
    }
    return buffer[0..position];
}

pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    read_buffer: []u8,
    read_start: usize = 0,
    read_end: usize = 0,
    write_buffer: std.ArrayList(u8),
    timeout_ms: u64,
    next_mask_seed: u64,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8, timeout_ms: u64) !WebSocket {
        const address = try std.net.Address.resolveIp(host, port);
        const socket = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(socket);
        try std.posix.connect(socket, &address.any, address.getOsSockLen());
        try setSocketTimeout(socket, timeout_ms);
        var random = std.Random.DefaultPrng.init(@bitCast(time.monotonicNs()));
        var key_material: [16]u8 = undefined;
        random.fill(&key_material);
        var key_buffer: [32]u8 = undefined;
        const key = base64Encode(&key_buffer, &key_material);
        var request = std.ArrayList(u8).init(allocator);
        defer request.deinit();
        try request.writer().print(
            "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, port, key },
        );
        var stream = std.net.Stream{ .handle = socket };
        try stream.writer().writeAll(request.items);
        var accumulated = std.ArrayList(u8).init(allocator);
        defer accumulated.deinit();
        var probe: [1024]u8 = undefined;
        var deadline = time.Deadline.fromTimeout(timeout_ms);
        while (!deadline.expired()) {
            const received = std.posix.recv(socket, &probe, 0) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(2 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            if (received == 0) return BrowserError.ConnectionClosed;
            try accumulated.appendSlice(probe[0..received]);
            if (std.mem.indexOf(u8, accumulated.items, "\r\n\r\n")) |header_end| {
                const head = accumulated.items[0..header_end];
                if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return BrowserError.HandshakeFailed;
                return .{
                    .allocator = allocator,
                    .socket = socket,
                    .read_buffer = try allocator.alloc(u8, 1 << 16),
                    .read_start = 0,
                    .read_end = received - (header_end + 4),
                    .write_buffer = std.ArrayList(u8).init(allocator),
                    .timeout_ms = timeout_ms,
                    .next_mask_seed = hashing.hash64(0x9E3779B97F4A7C15, key),
                };
            }
        }
        return BrowserError.Timeout;
    }

    pub fn deinit(self: *WebSocket) void {
        self.close() catch {};
        std.posix.close(self.socket);
        self.allocator.free(self.read_buffer);
        self.write_buffer.deinit();
    }

    fn ensureBuffered(self: *WebSocket, wanted: usize) !void {
        while (self.read_end - self.read_start < wanted) {
            if (self.read_start > 0 and self.read_buffer.len - self.read_end < wanted) {
                std.mem.copyForwards(u8, self.read_buffer, self.read_buffer[self.read_start..self.read_end]);
                self.read_end -= self.read_start;
                self.read_start = 0;
            }
            if (self.read_end == self.read_buffer.len) {
                const grown = try self.allocator.realloc(self.read_buffer, self.read_buffer.len * 2);
                self.read_buffer = grown;
            }
            const received = std.posix.recv(self.socket, self.read_buffer[self.read_end..], 0) catch |err| switch (err) {
                error.WouldBlock => return BrowserError.Timeout,
                else => return err,
            };
            if (received == 0) return BrowserError.ConnectionClosed;
            self.read_end += received;
        }
    }

    pub fn sendText(self: *WebSocket, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        var header_length: usize = 2;
        header[0] = 0x80 | @intFromEnum(Opcode.text);
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xFFFF) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_length = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
            header_length = 10;
        }
        var random = std.Random.DefaultPrng.init(self.next_mask_seed);
        self.next_mask_seed = random.next();
        var mask: [4]u8 = undefined;
        random.fill(&mask);
        @memcpy(header[header_length..][0..4], &mask);
        header_length += 4;
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        try out.appendSlice(header[0..header_length]);
        var masked = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(masked);
        for (payload, 0..) |byte, index| masked[index] = byte ^ mask[index % 4];
        try out.appendSlice(masked);
        var stream = std.net.Stream{ .handle = self.socket };
        try stream.writer().writeAll(out.items);
    }

    pub fn receiveText(self: *WebSocket, payload: *std.ArrayList(u8)) !Opcode {
        payload.clearRetainingCapacity();
        while (true) {
            try self.ensureBuffered(2);
            const first = self.read_buffer[self.read_start];
            const second = self.read_buffer[self.read_start + 1];
            const opcode: Opcode = @enumFromInt(first & 0x0F);
            const masked = (second & 0x80) != 0;
            var length: u64 = @intCast(second & 0x7F);
            var offset: usize = 2;
            if (length == 126) {
                try self.ensureBuffered(4);
                length = std.mem.readInt(u16, self.read_buffer[self.read_start + 2 ..][0..2], .big);
                offset = 4;
            } else if (length == 127) {
                try self.ensureBuffered(10);
                length = std.mem.readInt(u64, self.read_buffer[self.read_start + 2 ..][0..8], .big);
                offset = 10;
            }
            if (length > (1 << 30)) return BrowserError.FrameTooLarge;
            var mask_key: [4]u8 = @splat(0);
            if (masked) {
                try self.ensureBuffered(offset + 4);
                @memcpy(&mask_key, self.read_buffer[self.read_start + offset ..][0..4]);
                offset += 4;
            }
            try self.ensureBuffered(offset + @as(usize, @intCast(length)));
            const frame = self.read_buffer[self.read_start + offset ..][0..@as(usize, @intCast(length))];
            if (masked) {
                for (frame, 0..) |byte, index| payload.appendAssumeCapacity(byte ^ mask_key[index % 4]);
                payload.items.len = payload.items.len;
            } else {
                try payload.appendSlice(frame);
            }
            self.read_start += offset + @as(usize, @intCast(length));
            const fin = (first & 0x80) != 0;
            if (fin) return opcode;
        }
    }

    pub fn close(self: *WebSocket) !void {
        var header: [6]u8 = @splat(0);
        header[0] = 0x80 | @intFromEnum(Opcode.close);
        header[1] = 0x80;
        var stream = std.net.Stream{ .handle = self.socket };
        stream.writer().writeAll(header[0..6]) catch {};
    }
};

fn setSocketTimeout(socket: std.posix.socket_t, timeout_ms: u64) !void {
    var timeout = std.posix.timeval{
        .sec = @intCast(@divFloor(timeout_ms, 1000)),
        .usec = @intCast(@mod(timeout_ms, 1000) * 1000),
    };
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
}

pub const Target = struct {
    id: []const u8,
    title: []const u8,
    url: []const u8,
    kind: []const u8,
    web_socket_debugger_url: []const u8,

    pub fn release(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.kind);
        allocator.free(self.web_socket_debugger_url);
    }
};

pub const Browser = struct {
    allocator: std.mem.Allocator,
    options: Options,
    child: ?std.process.Child,
    next_command_id: u64 = 1,

    pub fn launch(allocator: std.mem.Allocator, options: Options) !Browser {
        std.fs.cwd().makePath(options.user_data_dir) catch {};
        var arguments = std.ArrayList([]const u8).init(allocator);
        defer arguments.deinit();
        try arguments.append(options.executable);
        if (options.headless) try arguments.append("--headless=new");
        try arguments.append("--disable-gpu");
        try arguments.append("--no-first-run");
        try arguments.append("--no-default-browser-check");
        try arguments.append("--disable-dev-shm-usage");
        try arguments.append("--disable-extensions");
        try arguments.append("--mute-audio");
        try arguments.append(try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{options.port}));
        try arguments.append(try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{options.user_data_dir}));
        try arguments.append(try std.fmt.allocPrint(allocator, "--window-size={d},{d}", .{ options.window_width, options.window_height }));
        try arguments.append(try std.fmt.allocPrint(allocator, "--user-agent={s}", .{ options.user_agent }));
        if (options.block_images) try arguments.append("--blink-settings=imagesEnabled=false");
        for (options.extra_arguments) |argument| try arguments.append(argument);
        try arguments.append("about:blank");
        var child = std.process.Child.init(try arguments.toOwnedSlice(), allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return BrowserError.LaunchFailed;
        var browser = Browser{ .allocator = allocator, .options = options, .child = child };
        try browser.waitForDevtools();
        return browser;
    }

    pub fn attach(allocator: std.mem.Allocator, options: Options) !Browser {
        var browser = Browser{ .allocator = allocator, .options = options, .child = null };
        try browser.waitForDevtools();
        return browser;
    }

    fn waitForDevtools(self: *Browser) !void {
        var deadline = time.Deadline.fromTimeout(self.options.startup_timeout_ms);
        while (!deadline.expired()) {
            if (self.fetchVersion()) |_| return;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return BrowserError.LaunchFailed;
    }

    fn fetchVersion(self: *Browser) ?[]const u8 {
        const address = std.net.Address.resolveIp(self.options.host, self.options.port) catch return null;
        const socket = std.posix.socket(address.any.family, std.posix.SOCK.STREAM, 0) catch return null;
        defer std.posix.close(socket);
        std.posix.connect(socket, &address.any, address.getOsSockLen()) catch return null;
        _ = setSocketTimeout(socket, 2000) catch {};
        var stream = std.net.Stream{ .handle = socket };
        const request = "GET /json/version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        stream.writer().writeAll(request) catch return null;
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        var probe: [4096]u8 = undefined;
        while (true) {
            const received = std.posix.recv(socket, &probe, 0) catch break;
            if (received == 0) break;
            body.appendSlice(probe[0..received]) catch return null;
        }
        const separator = std.mem.indexOf(u8, body.items, "\r\n\r\n") orelse return null;
        return body.items[separator + 4 ..];
    }

    pub fn listTargets(self: *Browser) ![]Target {
        const body = self.fetchJson("/json/list") orelse return BrowserError.TargetUnavailable;
        defer self.allocator.free(body);
        const parsed = try json.parseFromSlice(json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        const items = parsed.value.array;
        var targets = try self.allocator.alloc(Target, items.items.len);
        var index: usize = 0;
        for (items.items) |item| {
            targets[index] = .{
                .id = try self.allocator.dupe(u8, stringField(item, "id")),
                .title = try self.allocator.dupe(u8, stringField(item, "title")),
                .url = try self.allocator.dupe(u8, stringField(item, "url")),
                .kind = try self.allocator.dupe(u8, stringField(item, "type")),
                .web_socket_debugger_url = try self.allocator.dupe(u8, stringField(item, "webSocketDebuggerUrl")),
            };
            index += 1;
        }
        return targets;
    }

    pub fn newTarget(self: *Browser, url: []const u8) !Target {
        const encoded = try urlEncode(self.allocator, url);
        defer self.allocator.free(encoded);
        const path = try std.fmt.allocPrint(self.allocator, "/json/new?{s}", .{encoded});
        defer self.allocator.free(path);
        const body = self.fetchJsonWithMethod("PUT", path) orelse return BrowserError.TargetUnavailable;
        defer self.allocator.free(body);
        const parsed = try json.parseFromSlice(json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        return .{
            .id = try self.allocator.dupe(u8, stringField(parsed.value, "id")),
            .title = try self.allocator.dupe(u8, stringField(parsed.value, "title")),
            .url = try self.allocator.dupe(u8, stringField(parsed.value, "url")),
            .kind = try self.allocator.dupe(u8, stringField(parsed.value, "type")),
            .web_socket_debugger_url = try self.allocator.dupe(u8, stringField(parsed.value, "webSocketDebuggerUrl")),
        };
    }

    pub fn closeTarget(self: *Browser, target_id: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/json/close/{s}", .{target_id});
        defer self.allocator.free(path);
        _ = self.fetchJsonWithMethod("GET", path) orelse return BrowserError.TargetUnavailable;
    }

    fn fetchJson(self: *Browser, path: []const u8) ?[]const u8 {
        return self.fetchJsonWithMethod("GET", path);
    }

    fn fetchJsonWithMethod(self: *Browser, method: []const u8, path: []const u8) ?[]const u8 {
        const address = std.net.Address.resolveIp(self.options.host, self.options.port) catch return null;
        const socket = std.posix.socket(address.any.family, std.posix.SOCK.STREAM, 0) catch return null;
        defer std.posix.close(socket);
        std.posix.connect(socket, &address.any, address.getOsSockLen()) catch return null;
        _ = setSocketTimeout(socket, self.options.command_timeout_ms) catch {};
        var stream = std.net.Stream{ .handle = socket };
        const request = std.fmt.allocPrint(self.allocator, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ method, path, self.options.host, self.options.port }) catch return null;
        defer self.allocator.free(request);
        stream.writer().writeAll(request) catch return null;
        var body = std.ArrayList(u8).init(self.allocator);
        var probe: [4096]u8 = undefined;
        while (true) {
            const received = std.posix.recv(socket, &probe, 0) catch break;
            if (received == 0) break;
            body.appendSlice(probe[0..received]) catch return null;
        }
        const separator = std.mem.indexOf(u8, body.items, "\r\n\r\n") orelse {
            body.deinit();
            return null;
        };
        const payload = body.items[separator + 4 ..];
        if (payload.len == 0) {
            body.deinit();
            return null;
        }
        const result = self.allocator.dupe(u8, payload) catch null;
        body.deinit();
        return result;
    }

    pub fn allocateCommandId(self: *Browser) u64 {
        const id = self.next_command_id;
        self.next_command_id += 1;
        return id;
    }

    pub fn shutdown(self: *Browser) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
        }
        self.child = null;
    }

    pub fn deinit(self: *Browser) void {
        self.shutdown();
    }

    pub fn version(self: *Browser) ?[]const u8 {
        return self.fetchVersion();
    }
};

fn stringField(value: json.Value, key: []const u8) []const u8 {
    const field = value.object.get(key) orelse return "";
    return switch (field) {
        .string => field.string,
        else => "",
    };
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    for (input) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try out.append(byte);
        } else {
            try out.writer().print("%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice();
}

pub const CommandResponse = struct {
    id: u64,
    result: ?json.Value,
    error_message: []const u8,
    error_code: i64,
    allocator: std.mem.Allocator,

    pub fn failed(self: *const CommandResponse) bool {
        return self.error_message.len > 0;
    }

    pub fn release(self: *CommandResponse) void {
        if (self.error_message.len > 0) self.allocator.free(self.error_message);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    socket: WebSocket,
    session_id: []const u8,
    target_id: []const u8,
    next_id: u64 = 1,
    events: std.ArrayList(Event),
    timeout_ms: u64,

    pub const Event = struct {
        method: []const u8,
        params: json.Value,
        session_id: []const u8,
        allocator: std.mem.Allocator,

        pub fn release(self: *Event) void {
            self.allocator.free(self.method);
            self.allocator.free(self.session_id);
        }
    };

    pub fn connect(allocator: std.mem.Allocator, web_socket_url: []const u8, target_id: []const u8, timeout_ms: u64) !Session {
        const parsed = try parseWebSocketUrl(web_socket_url);
        const socket = try WebSocket.connect(allocator, parsed.host, parsed.port, parsed.path, timeout_ms);
        return .{
            .allocator = allocator,
            .socket = socket,
            .session_id = try allocator.dupe(u8, ""),
            .target_id = try allocator.dupe(u8, target_id),
            .events = std.ArrayList(Event).init(allocator),
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *Session) void {
        self.socket.deinit();
        self.allocator.free(self.session_id);
        self.allocator.free(self.target_id);
        for (self.events.items) |*event| event.release();
        self.events.deinit();
    }

    pub fn allocateId(self: *Session) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn sendRaw(self: *Session, payload: []const u8) !void {
        try self.socket.sendText(payload);
    }

    pub fn send(self: *Session, id: u64, method: []const u8, params: ?[]const u8) !void {
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        try out.writer().print("{{\"id\":{d},\"method\":\"{s}\"", .{ id, method });
        if (params) |body| {
            try out.appendSlice(",\"params\":");
            try out.appendSlice(body);
        }
        if (self.session_id.len > 0) {
            try out.writer().print(",\"sessionId\":\"{s}\"", .{self.session_id});
        }
        try out.append('}');
        try self.socket.sendText(out.items);
    }

    pub fn command(self: *Session, method: []const u8, params: ?[]const u8) !CommandResponse {
        const id = self.allocateId();
        try self.send(id, method, params);
        return try self.awaitResponse(id);
    }

    pub fn awaitResponse(self: *Session, id: u64) !CommandResponse {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        var deadline = time.Deadline.fromTimeout(self.timeout_ms);
        while (!deadline.expired()) {
            const opcode = try self.socket.receiveText(&payload);
            if (opcode == .close) return BrowserError.ConnectionClosed;
            if (opcode == .ping or opcode == .pong) continue;
            const parsed = json.parseFromSlice(json.Value, self.allocator, payload.items, .{}) catch return BrowserError.ProtocolError;
            defer parsed.deinit();
            const message_id = if (parsed.value.object.get("id")) |field| switch (field) {
                .integer => @as(u64, @intCast(field.integer)),
                else => 0,
            } else 0;
            if (message_id == 0) {
                const method = stringField(parsed.value, "method");
                if (method.len > 0) {
                    try self.events.append(.{
                        .method = try self.allocator.dupe(u8, method),
                        .params = parsed.value.object.get("params") orelse .{ .object = .{} },
                        .session_id = try self.allocator.dupe(u8, stringField(parsed.value, "sessionId")),
                        .allocator = self.allocator,
                    });
                }
                continue;
            }
            if (message_id != id) continue;
            if (parsed.value.object.get("error")) |failure| {
                return .{
                    .id = id,
                    .result = null,
                    .error_message = try self.allocator.dupe(u8, stringField(failure, "message")),
                    .error_code = if (failure.object.get("code")) |code| switch (code) {
                        .integer => code.integer,
                        else => 0,
                    } else 0,
                    .allocator = self.allocator,
                };
            }
            return .{
                .id = id,
                .result = parsed.value.object.get("result"),
                .error_message = "",
                .error_code = 0,
                .allocator = self.allocator,
            };
        }
        return BrowserError.Timeout;
    }

    pub fn waitForEvent(self: *Session, method: []const u8, timeout_ms: u64) !bool {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        var deadline = time.Deadline.fromTimeout(timeout_ms);
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.method, method)) return true;
        }
        while (!deadline.expired()) {
            const opcode = try self.socket.receiveText(&payload);
            if (opcode == .close) return BrowserError.ConnectionClosed;
            if (opcode == .ping or opcode == .pong) continue;
            const parsed = json.parseFromSlice(json.Value, self.allocator, payload.items, .{}) catch return BrowserError.ProtocolError;
            defer parsed.deinit();
            const event_method = stringField(parsed.value, "method");
            if (event_method.len == 0) continue;
            if (std.mem.eql(u8, event_method, method)) return true;
            try self.events.append(.{
                .method = try self.allocator.dupe(u8, event_method),
                .params = parsed.value.object.get("params") orelse .{ .object = .{} },
                .session_id = try self.allocator.dupe(u8, stringField(parsed.value, "sessionId")),
                .allocator = self.allocator,
            });
        }
        return false;
    }

    pub fn drainEvents(self: *Session, budget_ms: u64) !void {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        var deadline = time.Deadline.fromTimeout(budget_ms);
        while (!deadline.expired()) {
            const opcode = self.socket.receiveText(&payload) catch |err| switch (err) {
                error.Timeout => return,
                else => return err,
            };
            if (opcode == .close) return;
            if (opcode == .ping or opcode == .pong) continue;
            const parsed = json.parseFromSlice(json.Value, self.allocator, payload.items, .{}) catch return BrowserError.ProtocolError;
            defer parsed.deinit();
            const method = stringField(parsed.value, "method");
            if (method.len == 0) continue;
            try self.events.append(.{
                .method = try self.allocator.dupe(u8, method),
                .params = parsed.value.object.get("params") orelse .{ .object = .{} },
                .session_id = try self.allocator.dupe(u8, stringField(parsed.value, "sessionId")),
                .allocator = self.allocator,
            });
        }
    }

    pub fn clearEvents(self: *Session) void {
        for (self.events.items) |*event| event.release();
        self.events.clearRetainingCapacity();
    }
};

const WebSocketTarget = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseWebSocketUrl(raw: []const u8) !WebSocketTarget {
    var rest = raw;
    if (std.mem.startsWith(u8, rest, "ws://")) rest = rest["ws://".len..];
    if (std.mem.indexOf(u8, rest, "wss://")) |_| return BrowserError.InvalidResponse;
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var authority = rest[0..path_start];
    const path = rest[path_start..];
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch 80;
        authority = authority[0..colon];
    }
    if (std.mem.indexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    return .{ .host = authority, .port = port, .path = if (path.len == 0) "/" else path };
}
