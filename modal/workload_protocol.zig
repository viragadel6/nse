const std = @import("std");

pub const version: u16 = 1;
pub const dimensions: u16 = 4096;
pub const retained_dimensions: u16 = 256;
pub const Kind = enum { query, document };
pub const Span = struct { start: u32, end: u32, depth: f32 = 0, heading: f32 = 0, element: f32 = 0, prominence: f32 = 0, paragraph: f32 = 0, link: f32 = 0 };
pub const Item = struct { id: u64 = 0, text: []const u8, kind: Kind = .document, structure: []const Span = &.{} };
pub const EmbeddingRequest = struct { protocol_version: u16 = version, model_version: u64, dimensions: u16 = dimensions, items: []const Item, deadline_ms: u32 = 60000 };
pub const SingleRequest = struct { protocol_version: u16 = version, model_version: u64, dimensions: u16 = dimensions, text: []const u8, kind: Kind, deadline_ms: u32 = 60000, structure: []const Span = &.{} };
pub const Embedding = struct { id: u64, embedding: []const f32, retained: []const f32, binary: []const u16 };
pub const EmbeddingResponse = struct { protocol_version: u16 = version, model_version: u64, dimensions: u16 = dimensions, embeddings: []const Embedding, elapsed_ms: f64, gpu: []const u8 };
pub const Pair = struct { query: []const u8, document: []const u8, query_structure: []const Span = &.{}, document_structure: []const Span = &.{} };
pub const TrainingRequest = struct {
    protocol_version: u16 = version,
    job_id: []const u8,
    model_version: u64,
    @"resume": bool = true,
    pairs: []const Pair = &.{},
    dataset_path: ?[]const u8 = null,
    steps: u32 = 1000,
    batch_size: u16 = 8,
    hidden: u16 = 64,
    layers: u16 = 2,
    max_tokens: u16 = 256,
    learning_rate: f32 = 0.0003,
    weight_decay: f32 = 0.01,
    gradient_clip: f32 = 1,
    warmup_steps: u32 = 100,
    checkpoint_interval: u32 = 100,
    seed: u64 = 1,
    deadline_ms: u32 = 86400000,
};
pub const TrainingResponse = struct { protocol_version: u16 = version, job_id: []const u8, model_version: u64, step: u64, loss: ?f32, checkpoint: []const u8, sha256: []const u8, completed: bool, elapsed_ms: f64, gpu: []const u8 };
pub const RegistryRequest = struct { protocol_version: u16 = version, model_version: u64, expected_current_version: ?u64 = null };
pub const Health = struct { protocol_version: u16 = version, ready: bool, model_version: u64, dimensions: u16 = dimensions, retained_dimensions: u16 = retained_dimensions, gpu: []const u8 = "", checkpoint_sha256: ?[]const u8 = null };

pub fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

pub fn validateItem(item: Item) !void {
    if (item.text.len == 0 or !std.unicode.utf8ValidateSlice(item.text)) return error.InvalidText;
    var previous: u32 = 0;
    for (item.structure) |span| {
        if (span.start < previous or span.end <= span.start or span.end > item.text.len) return error.InvalidStructureSpan;
        previous = span.end;
        inline for (.{ span.depth, span.heading, span.element, span.prominence, span.paragraph, span.link }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidStructureFeature;
    }
}

pub fn validateEmbedding(request: EmbeddingRequest) !void {
    if (request.protocol_version != version or request.dimensions != dimensions or request.model_version == 0) return error.IncompatibleWorkload;
    if (request.items.len == 0 or request.deadline_ms == 0) return error.InvalidEmbeddingWorkload;
    for (request.items) |item| try validateItem(item);
}

pub fn validateTraining(request: TrainingRequest) !void {
    if (request.protocol_version != version or request.model_version == 0) return error.IncompatibleWorkload;
    if (!validIdentifier(request.job_id)) return error.InvalidJobIdentifier;
    if (request.steps == 0 or request.batch_size < 2 or request.hidden < 16 or request.hidden > 1024 or request.layers == 0 or request.layers > 24 or request.max_tokens == 0 or request.max_tokens > 4096 or request.checkpoint_interval == 0 or request.deadline_ms == 0) return error.InvalidTrainingConfiguration;
    inline for (.{ request.learning_rate, request.gradient_clip }) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidTrainingConfiguration;
    if (!std.math.isFinite(request.weight_decay) or request.weight_decay < 0) return error.InvalidTrainingConfiguration;
    for (request.pairs) |pair| {
        try validateItem(.{ .text = pair.query, .kind = .query, .structure = pair.query_structure });
        try validateItem(.{ .text = pair.document, .structure = pair.document_structure });
    }
    if (request.dataset_path == null and request.pairs.len < 2) return error.InsufficientTrainingPairs;
}

pub fn parse(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{ .allocate = .alloc_always });
}

pub fn requestId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(bytes, .lower)});
}
