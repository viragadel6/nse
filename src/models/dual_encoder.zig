const std = @import("std");
const transformer = @import("transformer.zig");
const tensor_ops = @import("tensor_ops.zig");

pub const Config = struct {
    query_transformer: transformer.Config,
    document_transformer: transformer.Config,
    projection_dim: u16 = 4096,
    retained_dim: u16 = 256,
};

pub const DualEncoder = struct {
    config: Config,
    query_model: transformer.Transformer,
    document_model: transformer.Transformer,
    query_projection: [][]f32,
    document_projection: [][]f32,
    temperature: f32 = 0.07,

    pub fn init(allocator: std.mem.Allocator, config: Config) !DualEncoder {
        const query_model = try transformer.Transformer.init(allocator, config.query_transformer);
        const document_model = try transformer.Transformer.init(allocator, config.document_transformer);
        var query_projection = try allocator.alloc([]f32, config.projection_dim);
        var document_projection = try allocator.alloc([]f32, config.projection_dim);
        var i: u16 = 0;
        while (i < config.projection_dim) {
            query_projection[i] = try allocator.alloc(f32, @intCast(config.query_transformer.hidden));
            document_projection[i] = try allocator.alloc(f32, @intCast(config.document_transformer.hidden));
            i += 1;
        }
        return DualEncoder{ .config = config, .query_model = query_model, .document_model = document_model, .query_projection = query_projection, .document_projection = document_projection };
    }

    pub fn deinit(self: *DualEncoder, allocator: std.mem.Allocator) void {
        self.query_model.deinit(allocator);
        self.document_model.deinit(allocator);
        var i: u16 = 0;
        while (i < self.config.projection_dim) {
            allocator.free(self.query_projection[i]);
            allocator.free(self.document_projection[i]);
            i += 1;
        }
        allocator.free(self.query_projection);
        allocator.free(self.document_projection);
    }

    pub fn encodeQuery(self: *DualEncoder, allocator: std.mem.Allocator, token_ids: []const u32, output: []f32) !void {
        var hidden = try allocator.alloc(f32, token_ids.len * @intCast(self.config.query_transformer.hidden));
        defer allocator.free(hidden);
        try self.query_model.forward(token_ids, hidden);
        var i: usize = 0;
        while (i < output.len) {
            var sum: f32 = 0;
            var j: usize = 0;
            while (j < @intCast(self.config.query_transformer.hidden)) {
                sum += hidden[j] * self.query_projection[i][j];
                j += 1;
            }
            output[i] = sum;
            i += 1;
        }
        tensor_ops.l2Normalize(output);
    }

    pub fn encodeDocument(self: *DualEncoder, allocator: std.mem.Allocator, token_ids: []const u32, output: []f32) !void {
        var hidden = try allocator.alloc(f32, token_ids.len * @intCast(self.config.document_transformer.hidden));
        defer allocator.free(hidden);
        try self.document_model.forward(token_ids, hidden);
        var i: usize = 0;
        while (i < output.len) {
            var sum: f32 = 0;
            var j: usize = 0;
            while (j < @intCast(self.config.document_transformer.hidden)) {
                sum += hidden[j] * self.document_projection[i][j];
                j += 1;
            }
            output[i] = sum;
            i += 1;
        }
        tensor_ops.l2Normalize(output);
    }
};
