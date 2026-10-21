const std = @import("std");
pub const Node = struct { node_id: u64, address: []const u8, port: u16, root_path: []const u8, executable_path: []const u8, settings_path: []const u8 };
pub const Peer = struct { node_id: u64, endpoint: []const u8, local: bool, settings_path: []const u8, data_path: []const u8 };
pub const Cluster = struct { protocol_version: u16, nodes: []const Peer, readiness_timeout_ms: u32, shutdown_timeout_ms: u32, readiness_poll_ms: u32 };
pub const Shards = struct { format_version: u16, shard_count: u32, replication_factor: u16, placement: enum { rendezvous }, hash_seed: u64 };
pub const Storage = struct { data_path: []const u8, spool_path: []const u8, checkpoint_path: []const u8, frontier_path: []const u8, minimum_available_bytes: u64 };
pub const Gpu = struct { protocol_version: u16, platform: enum { modal }, production_gpu: enum { B300 }, production_gpu_count: u8, cuda_major: u16, cuda_minor: u16, dimensions: u16, retained_dimensions: u16, request_bytes: u32, timeout_ms: u32, gateway_environment: []const u8, alternate_profile: struct { gpu: enum { H200 }, gpu_count: u16 } };
pub const Worker = struct { api_endpoint: []const u8, spool_path: []const u8, frontier_path: []const u8, poll_ms: u32, refresh_ms: u32, response_bytes: u32, timeout_ms: u32, discover_links: bool };
pub const Configuration = struct {
    node: Node, cluster: Cluster, shards: Shards, storage: Storage, gpu: Gpu, worker: Worker,
    pub fn validate(self: Configuration) !void {
        if (self.node.node_id == 0 or self.node.port == 0 or !std.fs.path.isAbsolute(self.node.root_path) or !std.fs.path.isAbsolute(self.node.executable_path)) return error.InvalidNodeConfiguration;
        _ = try std.net.Address.parseIp(self.node.address, self.node.port);
        if (self.cluster.protocol_version != 1 or self.cluster.nodes.len == 0 or self.cluster.readiness_timeout_ms == 0 or self.cluster.shutdown_timeout_ms == 0 or self.cluster.readiness_poll_ms == 0) return error.InvalidClusterConfiguration;
        for (self.cluster.nodes, 0..) |peer, i| {
            if (peer.node_id == 0 or peer.settings_path.len == 0 or peer.data_path.len == 0) return error.InvalidPeerConfiguration;
            try endpoint(peer.endpoint);
            for (self.cluster.nodes[0..i]) |prior| if (prior.node_id == peer.node_id or std.mem.eql(u8, prior.endpoint, peer.endpoint) or (prior.local and peer.local and std.mem.eql(u8, prior.data_path, peer.data_path))) return error.DuplicateClusterNode;
        }
        if (self.shards.format_version != 1 or self.shards.shard_count == 0 or self.shards.replication_factor == 0 or self.shards.replication_factor > self.cluster.nodes.len) return error.InvalidShardConfiguration;
        inline for (.{ self.storage.data_path, self.storage.spool_path, self.storage.checkpoint_path, self.storage.frontier_path }) |path| if (!std.fs.path.isAbsolute(path)) return error.InvalidStoragePath;
        if (self.gpu.protocol_version != 1 or self.gpu.production_gpu_count != 1 or self.gpu.cuda_major < 13 or (self.gpu.cuda_major == 13 and self.gpu.cuda_minor < 1) or self.gpu.dimensions != 4096 or self.gpu.retained_dimensions != 256 or self.gpu.request_bytes < 65536 or self.gpu.timeout_ms == 0 or self.gpu.alternate_profile.gpu_count != 144 or self.gpu.gateway_environment.len == 0) return error.InvalidGpuConfiguration;
        try endpoint(self.worker.api_endpoint);
        if (self.worker.poll_ms == 0 or self.worker.refresh_ms == 0 or self.worker.timeout_ms == 0 or self.worker.response_bytes < 16384) return error.InvalidWorkerConfiguration;
    }
};

fn endpoint(value: []const u8) !void {
    const uri = try std.Uri.parse(value);
    if (uri.host == null or (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https"))) return error.InvalidEndpoint;
}

pub fn read(comptime T: type, allocator: std.mem.Allocator, directory: []const u8, name: []const u8) !T {
    const path = try std.fs.path.join(allocator, &.{ directory, name }); defer allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024); defer allocator.free(bytes);
    const source = try allocator.dupeZ(u8, bytes); defer allocator.free(source);
    return std.zon.parse.fromSlice(T, allocator, source, null, .{});
}

pub fn load(allocator: std.mem.Allocator, directory: []const u8) !Configuration {
    const value = Configuration{ .node = try read(Node, allocator, directory, "node_config.zon"), .cluster = try read(Cluster, allocator, directory, "cluster_config.zon"), .shards = try read(Shards, allocator, directory, "shard_config.zon"), .storage = try read(Storage, allocator, directory, "storage_config.zon"), .gpu = try read(Gpu, allocator, directory, "gpu_config.zon"), .worker = try read(Worker, allocator, directory, "worker_config.zon") };
    try value.validate();
    return value;
}

pub fn replicas(allocator: std.mem.Allocator, config: Configuration, shard: u32) ![]u64 {
    if (shard >= config.shards.shard_count) return error.InvalidShardIdentifier;
    const Candidate = struct { id: u64, score: u64 };
    const candidates = try allocator.alloc(Candidate, config.cluster.nodes.len); defer allocator.free(candidates);
    for (config.cluster.nodes, candidates) |node, *candidate| {
        var key: [12]u8 = undefined;
        std.mem.writeInt(u32, key[0..4], shard, .little);
        std.mem.writeInt(u64, key[4..12], node.node_id, .little);
        candidate.* = .{ .id = node.node_id, .score = std.hash.Wyhash.hash(config.shards.hash_seed, &key) };
    }
    std.mem.sort(Candidate, candidates, {}, struct { fn less(_: void, a: Candidate, b: Candidate) bool { return a.score > b.score or (a.score == b.score and a.id < b.id); } }.less);
    const result = try allocator.alloc(u64, config.shards.replication_factor);
    for (result, candidates[0..result.len]) |*id, candidate| id.* = candidate.id;
    return result;
}
