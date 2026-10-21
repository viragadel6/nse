const std = @import("std");
const protocol = @import("workload");

pub const Runtime = struct {
    data_path: []const u8,
    worker_threads: u16,
    queue_capacity: u32,
    connection_timeout_ms: u32,
};

pub const Api = struct {
    address: []const u8,
    port: u16,
    header_bytes: u32,
    body_bytes: u32,
    default_deadline_ms: u32,
};

pub const VectorIndex = struct {
    dimensions: u16,
    retained_dimensions: u16,
    format_version: u16,
    model_version: u64,
    candidate_pool: u32,
};

pub const Ranking = struct {
    bm25_k1: f64,
    bm25_b: f64,
    title_weight: f64,
    url_weight: f64,
    rrf_constant: f64,
    lexical_weight: f64,
    semantic_weight: f64,
};

pub const Model = struct {
    embedding_endpoint: []const u8,
    health_endpoint: []const u8,
    workload_endpoint: []const u8 = "",
    dimensions: u16,
    model_version: u64,
    response_bytes: u32,
};

pub const Training = struct {
    protocol_version: u16 = 1,
    hidden: u16 = 64,
    layers: u16 = 2,
    max_tokens: u16 = 256,
    batch_size: u16 = 8,
    steps: u32 = 1000,
    learning_rate: f32 = 0.0003,
    weight_decay: f32 = 0.01,
    gradient_clip: f32 = 1,
    warmup_steps: u32 = 100,
    checkpoint_interval: u32 = 100,
    seed: u64 = 1,
    deadline_ms: u32 = 86400000,
    objective: enum { matryoshka_infonce } = .matryoshka_infonce,
    optimizer: enum { adamw } = .adamw,
    temperature_min: f32 = 0.01,
    temperature_max: f32 = 0.2,
    retained_dimensions: u16 = 256,
    dimensions: u16 = 4096,

    pub fn validate(self: Training) !void {
        if (self.protocol_version != 1 or self.hidden < 16 or self.hidden > 1024 or self.layers == 0 or self.layers > 24 or self.max_tokens == 0 or self.max_tokens > 4096 or self.batch_size < 2 or self.steps == 0 or self.checkpoint_interval == 0 or self.deadline_ms == 0) return error.InvalidTrainingConfiguration;
        if (self.retained_dimensions != 256 or self.dimensions != 4096 or self.temperature_min != 0.01 or self.temperature_max != 0.2) return error.IncompatibleTrainingConfiguration;
        inline for (.{ self.learning_rate, self.gradient_clip }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidTrainingConfiguration;
        if (!std.math.isFinite(self.weight_decay) or self.weight_decay < 0) return error.InvalidTrainingConfiguration;
    }

    pub fn defaults(self: Training, request: *protocol.TrainingRequest, supplied: std.json.Value) !void {
        if (supplied != .object) return error.InvalidTrainingRequest;
        inline for (.{ "protocol_version", "hidden", "layers", "max_tokens", "batch_size", "steps", "learning_rate", "weight_decay", "gradient_clip", "warmup_steps", "checkpoint_interval", "seed", "deadline_ms" }) |name| {
            if (!supplied.object.contains(name)) @field(request, name) = @field(self, name);
        }
        try protocol.validateTraining(request.*);
    }
};

pub const Configuration = struct {
    runtime: Runtime,
    api: Api,
    vector_index: VectorIndex,
    ranking: Ranking,
    model: Model,
    training: Training = .{},

    pub fn validate(self: Configuration) !void {
        try self.training.validate();
        if (self.runtime.data_path.len == 0 or self.runtime.worker_threads == 0 or self.runtime.queue_capacity == 0) return error.InvalidRuntimeConfiguration;
        if (self.runtime.connection_timeout_ms == 0) return error.InvalidRuntimeConfiguration;
        _ = try std.net.Address.parseIp(self.api.address, self.api.port);
        if (self.api.port == 0 or self.api.header_bytes < 1024 or self.api.body_bytes < 16384 or self.api.default_deadline_ms == 0) return error.InvalidApiConfiguration;
        if (self.vector_index.dimensions != 4096 or self.vector_index.retained_dimensions != 256 or self.vector_index.format_version != 1 or self.vector_index.model_version == 0 or self.vector_index.candidate_pool == 0) return error.IncompatibleIndexConfiguration;
        if (self.model.dimensions != self.vector_index.dimensions or self.model.model_version != self.vector_index.model_version or self.model.response_bytes < 16384) return error.IncompatibleModelConfiguration;
        if (self.model.embedding_endpoint.len > 0) try validateEndpoint(self.model.embedding_endpoint);
        if (self.model.health_endpoint.len > 0) try validateEndpoint(self.model.health_endpoint);
        if (self.model.workload_endpoint.len > 0) try validateEndpoint(self.model.workload_endpoint);
        const r = self.ranking;
        if (!std.math.isFinite(r.bm25_k1) or r.bm25_k1 <= 0 or !std.math.isFinite(r.bm25_b) or r.bm25_b < 0 or r.bm25_b > 1) return error.InvalidRankingConfiguration;
        inline for (.{ r.title_weight, r.url_weight, r.rrf_constant, r.lexical_weight, r.semantic_weight }) |value| {
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidRankingConfiguration;
        }
    }
};

fn validateEndpoint(endpoint: []const u8) !void {
    const uri = try std.Uri.parse(endpoint);
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidEndpoint;
    if (uri.host == null) return error.InvalidEndpoint;
}

fn readTyped(comptime T: type, allocator: std.mem.Allocator, directory: []const u8, name: []const u8) !T {
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);
    const source = try allocator.dupeZ(u8, bytes);
    defer allocator.free(source);
    return try std.zon.parse.fromSlice(T, allocator, source, null, .{});
}

pub fn load(allocator: std.mem.Allocator, directory: []const u8) !Configuration {
    var result = Configuration{
        .runtime = try readTyped(Runtime, allocator, directory, "runtime.zon"),
        .api = try readTyped(Api, allocator, directory, "api.zon"),
        .vector_index = try readTyped(VectorIndex, allocator, directory, "vector_index.zon"),
        .ranking = try readTyped(Ranking, allocator, directory, "ranking.zon"),
        .model = try readTyped(Model, allocator, directory, "model.zon"),
        .training = readTyped(Training, allocator, directory, "training.zon") catch |err| switch (err) { error.FileNotFound => .{}, else => return err },
    };
    const gateway = std.process.getEnvVarOwned(allocator, "MODAL_GATEWAY_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (gateway) |base| {
        try validateEndpoint(base);
        result.model.workload_endpoint = base;
        result.model.embedding_endpoint = try std.fmt.allocPrint(allocator, "{s}/embed", .{std.mem.trimRight(u8, base, "/")});
        result.model.health_endpoint = try std.fmt.allocPrint(allocator, "{s}/health", .{std.mem.trimRight(u8, base, "/")});
    }
    try result.validate();
    return result;
}
