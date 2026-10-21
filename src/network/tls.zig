const std = @import("std");

pub const Config = struct {
    min_version: std.tls.ProtocolVersion = .tls12,
    max_version: std.tls.ProtocolVersion = .tls13,
    verify_peer: bool = true,
    server_name: ?[]const u8 = null,
    client_cert: ?[]const u8 = null,
    client_key: ?[]const u8 = null,
    ca_path: ?[]const u8 = null,
};

pub fn context(config: Config) !std.tls.Context {
    var tls_config = std.tls.Config{};
    tls_config.min_version = config.min_version;
    tls_config.max_version = config.max_version;
    tls_config.verify_peer = config.verify_peer;
    if (config.server_name) |name| tls_config.server_name = name;
    const context = try std.tls.Context.init(.server, tls_config);
    return context;
}

pub fn loadCertificateChain(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
}

pub fn loadPrivateKey(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
}
