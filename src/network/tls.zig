const std = @import("std");
const backend_options = @import("tls_backend.zig");
const transport = @import("transport.zig");

pub const TlsError = error{
    TlsUnavailable,
    HandshakeFailed,
    PeerVerificationFailed,
    ProtocolError,
    WriteFailed,
    ReadFailed,
    Closed,
    UnsupportedBackend,
    CertificateLoadFailed,
};

pub const Backend = enum(u8) {
    none,
    openssl,
    terminator,
};

pub const Config = struct {
    backend: Backend = .none,
    verify_peers: bool = true,
    certificate_authority_path: []const u8 = "",
    certificate_path: []const u8 = "",
    private_key_path: []const u8 = "",
    server_name_indication: bool = true,
    minimum_version: []const u8 = "1.2",
    terminator_command: []const u8 = "openssl",
    terminator_arguments: [6][]const u8 = .{ "s_client", "-quiet", "-connect", "", "-servername", "" },
    terminator_argument_count: u8 = 4,
    handshake_timeout_ms: u32 = 5000,
};

pub fn backendAvailable(backend: Backend) bool {
    return switch (backend) {
        .none => true,
        .openssl => backend_options.openssl,
        .terminator => true,
    };
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    config: Config,
    plaintext: ?transport.Connection = null,
    openssl_state: ?OpenSslState = null,
    terminator_state: ?*Terminator = null,
    host: []const u8,
    port: u16,
    handshake_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config, host: []const u8, port: u16) Session {
        return .{ .allocator = allocator, .config = config, .host = host, .port = port };
    }

    pub fn handshake(self: *Session) TlsError!void {
        const start = std.time.milliTimestamp();
        switch (self.config.backend) {
            .none => return TlsError.TlsUnavailable,
            .openssl => {
                if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
                var state = try OpenSslState.connect(self.allocator, self.config, self.host, self.port);
                self.openssl_state = state;
            },
            .terminator => {
                var terminator = try self.allocator.create(Terminator);
                terminator.* = Terminator{ .allocator = self.allocator, .config = self.config };
                try terminator.start(self.host, self.port);
                self.terminator_state = terminator;
            },
        }
        self.handshake_ms = std.time.milliTimestamp() - start;
    }

    pub fn write(self: *Session, data: []const u8) TlsError!usize {
        if (self.openssl_state) |*state| {
            if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
            return state.write(data);
        }
        if (self.terminator_state) |terminator| {
            terminator.write(data) catch return TlsError.WriteFailed;
            return data.len;
        }
        return TlsError.Closed;
    }

    pub fn read(self: *Session, buffer: []u8) TlsError!usize {
        if (self.openssl_state) |*state| {
            if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
            return state.read(buffer);
        }
        if (self.terminator_state) |terminator| {
            const count = terminator.read(buffer) catch return TlsError.ReadFailed;
            return count;
        }
        return TlsError.Closed;
    }

    pub fn close(self: *Session) void {
        if (self.openssl_state) |*state| {
            if (comptime backend_options.openssl) state.deinit();
        }
        if (self.terminator_state) |terminator| {
            terminator.stop();
            self.allocator.destroy(terminator);
        }
        self.openssl_state = null;
        self.terminator_state = null;
    }
};

pub const Terminator = struct {
    allocator: std.mem.Allocator,
    config: Config,
    child: ?std.process.Child = null,
    stdin_file: ?std.fs.File = null,
    stdout_file: ?std.fs.File = null,
    running: bool = false,

    pub fn start(self: *Terminator, host: []const u8, port: u16) TlsError!void {
        var endpoint: [64]u8 = undefined;
        const target = std.fmt.bufPrint(&endpoint, "{s}:{d}", .{ host, port }) catch return TlsError.ProtocolError;
        var arguments: [8][]const u8 = undefined;
        var count: usize = 0;
        const configured = self.config.terminator_arguments[0..@min(self.config.terminator_argument_count, 6)];
        for (configured) |argument| {
            if (argument.len == 0) continue;
            arguments[count] = argument;
            count += 1;
        }
        var connect_index: ?usize = null;
        for (arguments[0..count], 0..) |argument, index| {
            if (std.mem.eql(u8, argument, "-connect")) connect_index = index;
        }
        if (connect_index) |index| {
            const target_copy = self.allocator.dupe(u8, target) catch return TlsError.ProtocolError;
            arguments[index + 1] = target_copy;
            if (index + 1 >= count) count = index + 2;
        } else {
            arguments[count] = "-connect";
            arguments[count + 1] = self.allocator.dupe(u8, target) catch return TlsError.ProtocolError;
            count += 2;
        }
        var child = std.process.Child.init(arguments[0..count], self.allocator);
        child.argv[0] = self.config.terminator_command;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return TlsError.HandshakeFailed;
        self.stdin_file = child.stdin;
        self.stdout_file = child.stdout;
        self.child = child;
        self.running = true;
    }

    pub fn write(self: *Terminator, data: []const u8) !void {
        const file = self.stdin_file orelse return TlsError.Closed;
        try file.writeAll(data);
    }

    pub fn read(self: *Terminator, buffer: []u8) !usize {
        const file = self.stdout_file orelse return TlsError.Closed;
        return file.read(buffer);
    }

    pub fn stop(self: *Terminator) void {
        if (self.child) |*child| {
            if (self.stdin_file) |file| file.close();
            if (self.stdout_file) |file| file.close();
            _ = child.kill() catch {};
        }
        self.running = false;
    }
};

pub const OpenSslState = struct {
    context: *anyopaque,
    handle: *anyopaque,
    allocator: std.mem.Allocator,
    owns_fd: bool,

    pub fn connect(allocator: std.mem.Allocator, config: Config, host: []const u8, port: u16) TlsError!OpenSslState {
        if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
        const connection = transport.Connection.connect(host, port, .{}) catch return TlsError.HandshakeFailed;
        return initOnConnection(allocator, config, host, connection);
    }

    pub fn initOnConnection(allocator: std.mem.Allocator, config: Config, host: []const u8, connection: transport.Connection) TlsError!OpenSslState {
        if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
        const context = openssl.TLS_client_method.newContext() orelse return TlsError.HandshakeFailed;
        errdefer openssl.destroyContext(context);
        if (config.verify_peers) {
            openssl.setDefaultVerifyPaths(context);
            openssl.setVerifyDepth(context, 6);
        }
        if (config.certificate_path.len > 0) {
            if (openssl.useCertificateFile(context, config.certificate_path) != 1) return TlsError.CertificateLoadFailed;
        }
        if (config.private_key_path.len > 0) {
            if (openssl.usePrivateKeyFile(context, config.private_key_path) != 1) return TlsError.CertificateLoadFailed;
        }
        const handle = openssl.newHandle(context) orelse return TlsError.HandshakeFailed;
        errdefer openssl.destroyHandle(handle);
        if (openssl.setHandleFd(handle, connection.handle) != 1) return TlsError.HandshakeFailed;
        if (config.server_name_indication) {
            const host_z = allocator.dupeZ(u8, host) catch return TlsError.HandshakeFailed;
            defer allocator.free(host_z);
            if (openssl.setServerName(handle, host_z.ptr) != 1) return TlsError.HandshakeFailed;
        }
        var attempts: u32 = 0;
        while (attempts < 3) : (attempts += 1) {
            const result = openssl.connectHandle(handle);
            if (result == 1) {
                return .{ .context = context, .handle = handle, .allocator = allocator, .owns_fd = true };
            }
            const code = openssl.getError(handle, result);
            if (code != openssl.error_want_read and code != openssl.error_want_write) {
                if (config.verify_peers) {
                    if (openssl.getVerifyResult(handle) != 0) return TlsError.PeerVerificationFailed;
                }
                return TlsError.HandshakeFailed;
            }
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
        return TlsError.HandshakeFailed;
    }

    pub fn write(self: *OpenSslState, data: []const u8) TlsError!usize {
        if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
        const written = openssl.write(self.handle, data.ptr, @intCast(data.len));
        if (written <= 0) return TlsError.WriteFailed;
        return @intCast(written);
    }

    pub fn read(self: *OpenSslState, buffer: []u8) TlsError!usize {
        if (comptime !backend_options.openssl) return TlsError.TlsUnavailable;
        const count = openssl.read(self.handle, buffer.ptr, @intCast(buffer.len));
        if (count == 0) return TlsError.Closed;
        if (count < 0) return TlsError.ReadFailed;
        return @intCast(count);
    }

    pub fn deinit(self: *OpenSslState) void {
        if (comptime backend_options.openssl) {
            _ = openssl.shutdownHandle(self.handle);
            openssl.destroyHandle(self.handle);
            openssl.destroyContext(self.context);
        }
        _ = self.allocator;
        _ = self.owns_fd;
    }
};

const openssl = struct {
    const error_want_read: c_int = 2;
    const error_want_write: c_int = 3;

    extern fn TLS_client_method() ?*anyopaque;
    extern fn SSL_CTX_new(method: *anyopaque) ?*anyopaque;
    extern fn SSL_CTX_free(context: *anyopaque) void;
    extern fn SSL_CTX_set_default_verify_paths(context: *anyopaque) c_int;
    extern fn SSL_CTX_set_verify_depth(context: *anyopaque, depth: c_int) void;
    extern fn SSL_CTX_use_certificate_file(context: *anyopaque, file: [*:0]const u8, kind: c_int) c_int;
    extern fn SSL_CTX_use_PrivateKey_file(context: *anyopaque, file: [*:0]const u8, kind: c_int) c_int;
    extern fn SSL_new(context: *anyopaque) ?*anyopaque;
    extern fn SSL_free(handle: *anyopaque) void;
    extern fn SSL_set_fd(handle: *anyopaque, fd: c_int) c_int;
    extern fn SSL_set_tlsext_host_name(handle: *anyopaque, name: [*:0]const u8) c_int;
    extern fn SSL_connect(handle: *anyopaque) c_int;
    extern fn SSL_read(handle: *anyopaque, buffer: *anyopaque, length: c_int) c_int;
    extern fn SSL_write(handle: *anyopaque, buffer: *const anyopaque, length: c_int) c_int;
    extern fn SSL_shutdown(handle: *anyopaque) c_int;
    extern fn SSL_get_error(handle: *anyopaque, result: c_int) c_int;
    extern fn SSL_get_verify_result(handle: *anyopaque) c_long;

    pub fn newContext() ?*anyopaque {
        const method = TLS_client_method() orelse return null;
        return SSL_CTX_new(method);
    }

    pub fn destroyContext(context: *anyopaque) void {
        SSL_CTX_free(context);
    }

    pub fn setDefaultVerifyPaths(context: *anyopaque) void {
        _ = SSL_CTX_set_default_verify_paths(context);
    }

    pub fn setVerifyDepth(context: *anyopaque, depth: c_int) void {
        SSL_CTX_set_verify_depth(context, depth);
    }

    pub fn useCertificateFile(context: *anyopaque, path: []const u8) c_int {
        const z = std.heap.page_allocator.dupeZ(u8, path) catch return 0;
        defer std.heap.page_allocator.free(z);
        return SSL_CTX_use_certificate_file(context, z.ptr, 1);
    }

    pub fn usePrivateKeyFile(context: *anyopaque, path: []const u8) c_int {
        const z = std.heap.page_allocator.dupeZ(u8, path) catch return 0;
        defer std.heap.page_allocator.free(z);
        return SSL_CTX_use_PrivateKey_file(context, z.ptr, 1);
    }

    pub fn newHandle(context: *anyopaque) ?*anyopaque {
        return SSL_new(context);
    }

    pub fn destroyHandle(handle: *anyopaque) void {
        SSL_free(handle);
    }

    pub fn setHandleFd(handle: *anyopaque, fd: std.posix.fd_t) c_int {
        return SSL_set_fd(handle, @intCast(fd));
    }

    pub fn setServerName(handle: *anyopaque, name: [*:0]const u8) c_int {
        return SSL_set_tlsext_host_name(handle, name);
    }

    pub fn connectHandle(handle: *anyopaque) c_int {
        return SSL_connect(handle);
    }

    pub fn read(handle: *anyopaque, buffer: *anyopaque, length: c_int) c_int {
        return SSL_read(handle, buffer, length);
    }

    pub fn write(handle: *anyopaque, buffer: *const anyopaque, length: c_int) c_int {
        return SSL_write(handle, buffer, length);
    }

    pub fn shutdownHandle(handle: *anyopaque) c_int {
        return SSL_shutdown(handle);
    }

    pub fn getError(handle: *anyopaque, result: c_int) c_int {
        return SSL_get_error(handle, result);
    }

    pub fn getVerifyResult(handle: *anyopaque) c_long {
        return SSL_get_verify_result(handle);
    }
};

pub const Alert = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    handshake_failure = 40,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    decode_error = 50,
    protocol_version = 70,
    internal_error = 80,
};

pub fn classifyAlert(code: u8) []const u8 {
    return switch (code) {
        0 => "close_notify",
        10 => "unexpected_message",
        20 => "bad_record_mac",
        40 => "handshake_failure",
        42 => "bad_certificate",
        45 => "certificate_expired",
        46 => "certificate_unknown",
        50 => "decode_error",
        70 => "protocol_version",
        80 => "internal_error",
        else => "unknown_alert",
    };
}

pub const RecordHeader = struct {
    content_type: u8,
    version: u16,
    length: u16,

    pub fn decode(bytes: []const u8) TlsError!RecordHeader {
        if (bytes.len < 5) return TlsError.ProtocolError;
        return .{
            .content_type = bytes[0],
            .version = std.mem.readInt(u16, bytes[1..3], .big),
            .length = std.mem.readInt(u16, bytes[3..5], .big),
        };
    }
};

pub fn describeBackend(config: Config) []const u8 {
    return switch (config.backend) {
        .none => "none",
        .openssl => if (backend_options.openssl) "openssl" else "openssl-unavailable",
        .terminator => "terminator",
    };
}
