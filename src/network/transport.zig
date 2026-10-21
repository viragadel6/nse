const std = @import("std");
const serialization = @import("serialization.zig");
const time = @import("../util/time.zig");

pub const TransportError = error{
    ConnectionFailed,
    ConnectionClosed,
    ReadTimeout,
    WriteTimeout,
    InvalidAddress,
    SocketError,
    WouldBlock,
    FrameTooLarge,
    InvalidFrame,
    PoolExhausted,
};

pub const Options = struct {
    connect_timeout_ms: u32 = 3000,
    read_timeout_ms: u32 = 5000,
    write_timeout_ms: u32 = 5000,
    keep_alive: bool = true,
    no_delay: bool = true,
    receive_buffer_bytes: u32 = 262144,
    send_buffer_bytes: u32 = 262144,
};

pub const Connection = struct {
    handle: std.posix.fd_t,
    address: std.net.Address,
    options: Options,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    last_used_ms: i64 = 0,
    in_use: bool = false,

    pub fn connect(host: []const u8, port: u16, options: Options) TransportError!Connection {
        const parsed = AddressBook.resolve(host, port) catch return TransportError.InvalidAddress;
        const socket = std.posix.socket(parsed.any.family, std.posix.SOCK.STREAM, 0) catch return TransportError.SocketError;
        errdefer std.posix.close(socket);
        applySocketOptions(socket, options);
        const timeout = std.posix.timeval{ .sec = @intCast(options.connect_timeout_ms / 1000), .usec = @intCast((options.connect_timeout_ms % 1000) * 1000) };
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.connect(socket, &parsed.any, parsed.getOsSockLen()) catch {
            return TransportError.ConnectionFailed;
        };
        return .{ .handle = socket, .address = parsed, .options = options, .last_used_ms = time.nowMs() };
    }

    pub fn fromHandle(handle: std.posix.fd_t, address: std.net.Address, options: Options) Connection {
        applySocketOptions(handle, options);
        return .{ .handle = handle, .address = address, .options = options, .last_used_ms = time.nowMs() };
    }

    pub fn close(self: *Connection) void {
        std.posix.shutdown(self.handle, .both) catch {};
        std.posix.close(self.handle);
        self.handle = -1;
    }

    pub fn writeAll(self: *Connection, data: []const u8) TransportError!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const written = std.posix.write(self.handle, data[offset..]) catch |err| return mapWriteError(err);
            if (written == 0) return TransportError.ConnectionClosed;
            offset += written;
            self.bytes_sent += written;
        }
        self.last_used_ms = time.nowMs();
    }

    pub fn readAtLeast(self: *Connection, buffer: []u8, minimum: usize) TransportError!usize {
        var total: usize = 0;
        while (total < minimum) {
            const read = std.posix.read(self.handle, buffer[total..]) catch |err| return mapReadError(err);
            if (read == 0) return TransportError.ConnectionClosed;
            total += read;
        }
        self.bytes_received += total;
        self.last_used_ms = time.nowMs();
        return total;
    }

    pub fn readSome(self: *Connection, buffer: []u8) TransportError!usize {
        const read = std.posix.read(self.handle, buffer) catch |err| return mapReadError(err);
        if (read == 0) return TransportError.ConnectionClosed;
        self.bytes_received += read;
        self.last_used_ms = time.nowMs();
        return read;
    }

    pub fn sendFrame(self: *Connection, writer: *serialization.PayloadWriter, method: u16, request_id: u64, shard: u32, flags: serialization.Flags) TransportError!void {
        const frame = serialization.Frame.init(method, request_id, shard, writer.bytes(), flags);
        const size = frame.encodedSize();
        const buffer = std.heap.page_allocator.alloc(u8, size) catch return TransportError.FrameTooLarge;
        defer std.heap.page_allocator.free(buffer);
        const encoded = frame.encode(buffer) catch return TransportError.InvalidFrame;
        try self.writeAll(encoded);
    }

    pub fn receiveFrame(self: *Connection, reader: *serialization.FrameReader) TransportError!serialization.Frame {
        while (true) {
            const attempt = reader.take() catch return TransportError.InvalidFrame;
            if (attempt) |frame| {
                reader.consume(frame.encodedSize());
                return frame;
            }
            var chunk: [65536]u8 = undefined;
            const read = try self.readSome(&chunk);
            reader.push(chunk[0..read]) catch return TransportError.FrameTooLarge;
        }
    }

    pub fn idleMs(self: *const Connection) i64 {
        return time.nowMs() - self.last_used_ms;
    }
};

fn mapReadError(err: anyerror) TransportError {
    return switch (err) {
        error.WouldBlock => TransportError.ReadTimeout,
        error.TimedOut => TransportError.ReadTimeout,
        error.ConnectionResetByPeer => TransportError.ConnectionClosed,
        error.ConnectionTimedOut => TransportError.ReadTimeout,
        else => TransportError.SocketError,
    };
}

fn mapWriteError(err: anyerror) TransportError {
    return switch (err) {
        error.WouldBlock => TransportError.WriteTimeout,
        error.TimedOut => TransportError.WriteTimeout,
        error.BrokenPipe => TransportError.ConnectionClosed,
        else => TransportError.SocketError,
    };
}

fn applySocketOptions(handle: std.posix.fd_t, options: Options) void {
    var receive_timeout = std.posix.timeval{ .sec = @intCast(options.read_timeout_ms / 1000), .usec = @intCast((options.read_timeout_ms % 1000) * 1000) };
    var send_timeout = std.posix.timeval{ .sec = @intCast(options.write_timeout_ms / 1000), .usec = @intCast((options.write_timeout_ms % 1000) * 1000) };
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&receive_timeout)) catch {};
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&send_timeout)) catch {};
    if (options.keep_alive) {
        const enable: i32 = 1;
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};
    }
    if (options.no_delay) {
        const enable: i32 = 1;
        std.posix.setsockopt(handle, 6, std.posix.TCP.NODELAY, std.mem.asBytes(&enable)) catch {};
    }
    const receive_buffer: i32 = @intCast(options.receive_buffer_bytes);
    const send_buffer: i32 = @intCast(options.send_buffer_bytes);
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&receive_buffer)) catch {};
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&send_buffer)) catch {};
}

pub const AddressBook = struct {
    pub fn resolve(host: []const u8, port: u16) !std.net.Address {
        if (std.mem.indexOfScalar(u8, host, ':') != null) {
            return std.net.Address.parseIp(host, port);
        }
        return std.net.Address.parseIp4(host, port) catch std.net.Address.parseIp6(host, port) catch resolveName(host, port);
    }

    fn resolveName(host: []const u8, port: u16) !std.net.Address {
        var list = try std.net.getAddressList(std.heap.page_allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return TransportError.InvalidAddress;
        return list.addrs[0];
    }
};

pub const Listener = struct {
    handle: std.posix.fd_t,
    address: std.net.Address,
    options: Options,

    pub fn bind(host: []const u8, listen_port: u16, options: Options) TransportError!Listener {
        const address = AddressBook.resolve(host, listen_port) catch return TransportError.InvalidAddress;
        const socket = std.posix.socket(address.any.family, std.posix.SOCK.STREAM, 0) catch return TransportError.SocketError;
        errdefer std.posix.close(socket);
        const reuse: i32 = 1;
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse)) catch {};
        std.posix.bind(socket, &address.any, address.getOsSockLen()) catch return TransportError.SocketError;
        std.posix.listen(socket, 512) catch return TransportError.SocketError;
        var accept_timeout = std.posix.timeval{ .sec = @intCast(options.read_timeout_ms / 1000), .usec = @intCast((options.read_timeout_ms % 1000) * 1000) };
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&accept_timeout)) catch {};
        var bound = address;
        var length: std.posix.socklen_t = @sizeOf(std.net.Address);
        std.posix.getsockname(socket, &bound.any, &length) catch {};
        return .{ .handle = socket, .address = bound, .options = options };
    }

    pub fn accept(self: *Listener) TransportError!Connection {
        var accepted: std.net.Address = undefined;
        var length: std.posix.socklen_t = @sizeOf(std.net.Address);
        const handle = std.posix.accept(self.handle, &accepted.any, &length, 0) catch |err| {
            return switch (err) {
                error.WouldBlock => TransportError.ReadTimeout,
                else => TransportError.SocketError,
            };
        };
        return Connection.fromHandle(handle, accepted, self.options);
    }

    pub fn close(self: *Listener) void {
        std.posix.close(self.handle);
        self.handle = -1;
    }

    pub fn port(self: *Listener) u16 {
        return self.address.getPort();
    }
};

pub const PoolKey = struct {
    host: []const u8,
    port: u16,

    pub fn eql(self: PoolKey, other: PoolKey) bool {
        return self.port == other.port and std.mem.eql(u8, self.host, other.host);
    }
};

pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    free: std.ArrayListUnmanaged(Connection) = .{},
    options: Options,
    max_per_key: usize,
    created: u64 = 0,
    reused: u64 = 0,
    closed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options, max_per_key: usize) ConnectionPool {
        return .{ .allocator = allocator, .options = options, .max_per_key = @max(1, max_per_key) };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        for (self.free.items) |*connection| {
            connection.close();
        }
        self.free.deinit(self.allocator);
        self.mutex.unlock();
    }

    pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) TransportError!Connection {
        self.mutex.lock();
        var index: usize = 0;
        while (index < self.free.items.len) {
            const candidate = self.free.items[index];
            const key = endpointKey(self.allocator, candidate.address);
            if (key.port == port and std.mem.eql(u8, key.host, host)) {
                var connection = self.free.orderedRemove(index);
                self.allocator.free(key.host);
                self.mutex.unlock();
                self.reused += 1;
                connection.in_use = true;
                return connection;
            }
            self.allocator.free(key.host);
            index += 1;
        }
        self.mutex.unlock();
        const connection = Connection.connect(host, port, self.options) catch return TransportError.ConnectionFailed;
        self.created += 1;
        return connection;
    }

    pub fn release(self: *ConnectionPool, connection: Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.free.items.len >= self.max_per_key * 16 or connection.idleMs() > 30000) {
            var mutable = connection;
            mutable.close();
            self.closed += 1;
            return;
        }
        var mutable = connection;
        mutable.in_use = false;
        mutable.last_used_ms = time.nowMs();
        self.free.append(self.allocator, mutable) catch {
            mutable.close();
            self.closed += 1;
        };
    }

    pub fn depth(self: *ConnectionPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free.items.len;
    }
};

fn endpointKey(allocator: std.mem.Allocator, address: std.net.Address) PoolKey {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{}", .{address}) catch "unknown";
    return .{ .host = allocator.dupe(u8, text) catch "", .port = address.getPort() };
}

pub const TransportStats = struct {
    connections_created: u64,
    connections_reused: u64,
    connections_closed: u64,
    pool_depth: usize,
    bytes_sent: u64,
    bytes_received: u64,
};
