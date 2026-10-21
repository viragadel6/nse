const std = @import("std");
const serialization = @import("serialization.zig");

pub const Method = enum(u16) {
    ping = 1,
    status = 2,
    heartbeat = 3,
    gossip = 4,
    shard_search = 10,
    shard_write = 11,
    shard_snapshot = 12,
    shard_replicate = 13,
    shard_recover = 14,
    shard_rebalance = 15,
    embedding_request = 20,
    embedding_response = 21,
    checkpoint_push = 22,
    checkpoint_pull = 23,
    research_submit = 30,
    research_status = 31,
    error_response = 500,
};

pub const StatusCode = enum(u16) {
    ok = 0,
    degraded = 1,
    unavailable = 2,
    invalid_request = 3,
    deadline_exceeded = 4,
    generation_conflict = 5,
    shard_unavailable = 6,
};

pub const ShardSearchRequest = struct {
    index_generation: u64,
    shard: u32,
    probe_count: u16,
    top_k: u32,
    candidate_mode: u8,
    deadline_ms: u32,
    filter_mask: u64,
    min_score: f32,
    query_vector: []const f32,
    cluster_ids: []const u32,

    pub fn encode(self: ShardSearchRequest, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeU64(self.index_generation);
        try writer.writeU32(self.shard);
        try writer.writeU16(self.probe_count);
        try writer.writeU32(self.top_k);
        try writer.writeByte(self.candidate_mode);
        try writer.writeU32(self.deadline_ms);
        try writer.writeU64(self.filter_mask);
        try writer.writeF32(self.min_score);
        try writer.writeFloatSlice(self.query_vector);
        try writer.writeU32Slice(self.cluster_ids);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !ShardSearchRequest {
        var reader = serialization.PayloadReader.init(payload);
        return .{
            .index_generation = try reader.readU64(),
            .shard = try reader.readU32(),
            .probe_count = try reader.readU16(),
            .top_k = try reader.readU32(),
            .candidate_mode = try reader.readByte(),
            .deadline_ms = try reader.readU32(),
            .filter_mask = try reader.readU64(),
            .min_score = try reader.readF32(),
            .query_vector = try reader.readFloatSlice(allocator, 8192),
            .cluster_ids = try reader.readU32Slice(allocator, 65536),
        };
    }

    pub fn release(self: *ShardSearchRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.query_vector);
        allocator.free(self.cluster_ids);
    }
};

pub const CandidateRecord = struct {
    document_id: u64,
    score: f32,
    lexical_score: f32,
    cluster_id: u32,
    generation: u64,

    pub fn write(self: CandidateRecord, writer: *serialization.PayloadWriter) !void {
        try writer.writeU64(self.document_id);
        try writer.writeF32(self.score);
        try writer.writeF32(self.lexical_score);
        try writer.writeU32(self.cluster_id);
        try writer.writeU64(self.generation);
    }

    pub fn read(reader: *serialization.PayloadReader) !CandidateRecord {
        return .{
            .document_id = try reader.readU64(),
            .score = try reader.readF32(),
            .lexical_score = try reader.readF32(),
            .cluster_id = try reader.readU32(),
            .generation = try reader.readU64(),
        };
    }
};

pub const ShardSearchResponse = struct {
    status: StatusCode,
    generation: u64,
    shard: u32,
    scanned: u64,
    complete: bool,
    candidates: []CandidateRecord,

    pub fn encode(self: ShardSearchResponse, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeU16(@intFromEnum(self.status));
        try writer.writeU64(self.generation);
        try writer.writeU32(self.shard);
        try writer.writeU64(self.scanned);
        try writer.writeBool(self.complete);
        try writer.writeVarint(self.candidates.len);
        for (self.candidates) |candidate| try candidate.write(&writer);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !ShardSearchResponse {
        var reader = serialization.PayloadReader.init(payload);
        const status: StatusCode = @enumFromInt(try reader.readU16());
        const generation = try reader.readU64();
        const shard = try reader.readU32();
        const scanned = try reader.readU64();
        const complete = try reader.readBool();
        const count = try reader.readVarint();
        if (count > 100000) return serialization.SerializationError.InvalidEncoding;
        const candidates = try allocator.alloc(CandidateRecord, @intCast(count));
        for (candidates) |*candidate| candidate.* = try CandidateRecord.read(&reader);
        return .{ .status = status, .generation = generation, .shard = shard, .scanned = scanned, .complete = complete, .candidates = candidates };
    }

    pub fn release(self: *ShardSearchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
    }
};

pub const DocumentMutation = struct {
    document_id: u64,
    canonical_hash: u64,
    cluster_id: u32,
    generation: u64,
    flags: u32,
    packed_vector: []const u8,

    pub fn write(self: DocumentMutation, writer: *serialization.PayloadWriter) !void {
        try writer.writeU64(self.document_id);
        try writer.writeU64(self.canonical_hash);
        try writer.writeU32(self.cluster_id);
        try writer.writeU64(self.generation);
        try writer.writeU32(self.flags);
        try writer.writeVarint(self.packed_vector.len);
        try writer.writeBytes(self.packed_vector);
    }

    pub fn read(allocator: std.mem.Allocator, reader: *serialization.PayloadReader) !DocumentMutation {
        const document_id = try reader.readU64();
        const canonical_hash = try reader.readU64();
        const cluster_id = try reader.readU32();
        const generation = try reader.readU64();
        const flags = try reader.readU32();
        const length = try reader.readVarint();
        if (length > 4096) return serialization.SerializationError.InvalidEncoding;
        const vector = try allocator.alloc(u8, @intCast(length));
        @memcpy(vector, try reader.readBytes(@intCast(length)));
        return .{ .document_id = document_id, .canonical_hash = canonical_hash, .cluster_id = cluster_id, .generation = generation, .flags = flags, .packed_vector = vector };
    }

    pub fn release(self: *DocumentMutation, allocator: std.mem.Allocator) void {
        allocator.free(self.packed_vector);
    }
};

pub const ShardWriteRequest = struct {
    generation: u64,
    shard: u32,
    sequence: u64,
    mutations: []DocumentMutation,

    pub fn encode(self: ShardWriteRequest, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeU64(self.generation);
        try writer.writeU32(self.shard);
        try writer.writeU64(self.sequence);
        try writer.writeVarint(self.mutations.len);
        for (self.mutations) |mutation| try mutation.write(&writer);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !ShardWriteRequest {
        var reader = serialization.PayloadReader.init(payload);
        const generation = try reader.readU64();
        const shard = try reader.readU32();
        const sequence = try reader.readU64();
        const count = try reader.readVarint();
        if (count > 100000) return serialization.SerializationError.InvalidEncoding;
        const mutations = try allocator.alloc(DocumentMutation, @intCast(count));
        for (mutations) |*mutation| mutation.* = try DocumentMutation.read(allocator, &reader);
        return .{ .generation = generation, .shard = shard, .sequence = sequence, .mutations = mutations };
    }

    pub fn release(self: *ShardWriteRequest, allocator: std.mem.Allocator) void {
        for (self.mutations) |*mutation| mutation.release(allocator);
        allocator.free(self.mutations);
    }
};

pub const HeartbeatMessage = struct {
    node_id: []const u8,
    generation: u64,
    shard_count: u32,
    document_count: u64,
    load: f32,
    timestamp_ms: i64,

    pub fn encode(self: HeartbeatMessage, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeString(self.node_id);
        try writer.writeU64(self.generation);
        try writer.writeU32(self.shard_count);
        try writer.writeU64(self.document_count);
        try writer.writeF32(self.load);
        try writer.writeI64(self.timestamp_ms);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !HeartbeatMessage {
        var reader = serialization.PayloadReader.init(payload);
        return .{
            .node_id = try allocator.dupe(u8, try reader.readString(256)),
            .generation = try reader.readU64(),
            .shard_count = try reader.readU32(),
            .document_count = try reader.readU64(),
            .load = try reader.readF32(),
            .timestamp_ms = try reader.readI64(),
        };
    }

    pub fn release(self: *HeartbeatMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
    }
};

pub const EmbeddingRequest = struct {
    job_id: u64,
    model_version: []const u8,
    kind: u8,
    texts: [][]const u8,

    pub fn encode(self: EmbeddingRequest, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeU64(self.job_id);
        try writer.writeString(self.model_version);
        try writer.writeByte(self.kind);
        try writer.writeVarint(self.texts.len);
        for (self.texts) |text| try writer.writeString(text);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !EmbeddingRequest {
        var reader = serialization.PayloadReader.init(payload);
        const job_id = try reader.readU64();
        const version = try allocator.dupe(u8, try reader.readString(128));
        const kind = try reader.readByte();
        const count = try reader.readVarint();
        if (count > 4096) return serialization.SerializationError.InvalidEncoding;
        const texts = try allocator.alloc([]const u8, @intCast(count));
        for (texts) |*text| text.* = try allocator.dupe(u8, try reader.readString(1 << 20));
        return .{ .job_id = job_id, .model_version = version, .kind = kind, .texts = texts };
    }

    pub fn release(self: *EmbeddingRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model_version);
        for (self.texts) |text| allocator.free(text);
        allocator.free(self.texts);
    }
};

pub const EmbeddingResponse = struct {
    job_id: u64,
    dimension: u32,
    vectors: []f32,
    latency_ms: f64,
    accelerator: []const u8,

    pub fn encode(self: EmbeddingResponse, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeU64(self.job_id);
        try writer.writeU32(self.dimension);
        try writer.writeFloatSlice(self.vectors);
        try writer.writeF64(self.latency_ms);
        try writer.writeString(self.accelerator);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !EmbeddingResponse {
        var reader = serialization.PayloadReader.init(payload);
        return .{
            .job_id = try reader.readU64(),
            .dimension = try reader.readU32(),
            .vectors = try reader.readFloatSlice(allocator, 1 << 24),
            .latency_ms = try reader.readF64(),
            .accelerator = try allocator.dupe(u8, try reader.readString(64)),
        };
    }

    pub fn release(self: *EmbeddingResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.vectors);
        allocator.free(self.accelerator);
    }
};

pub const ErrorResponse = struct {
    code: []const u8,
    message: []const u8,
    retriable: bool,

    pub fn encode(self: ErrorResponse, allocator: std.mem.Allocator) ![]u8 {
        var writer = serialization.PayloadWriter.init(allocator);
        errdefer writer.deinit();
        try writer.writeString(self.code);
        try writer.writeString(self.message);
        try writer.writeBool(self.retriable);
        const owned = try allocator.dupe(u8, writer.bytes());
        writer.deinit();
        return owned;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !ErrorResponse {
        var reader = serialization.PayloadReader.init(payload);
        return .{
            .code = try allocator.dupe(u8, try reader.readString(128)),
            .message = try allocator.dupe(u8, try reader.readString(1024)),
            .retriable = try reader.readBool(),
        };
    }

    pub fn release(self: *ErrorResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub fn methodName(method: Method) []const u8 {
    return @tagName(method);
}
