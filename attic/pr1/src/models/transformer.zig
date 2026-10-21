const std = @import("std");
const tensor_ops = @import("tensor_ops.zig");
const attention = @import("attention.zig");

pub const Config = struct {
    vocab_size: u32,
    hidden: u16,
    layers: u16,
    heads: u16,
    max_sequence: u16,
    dropout: f32 = 0.1,
};

pub const Transformer = struct {
    config: Config,
    embeddings: [][]f32,
    layers_attention: []attention.Attention,
    layers_ffn_w1: [][]f32,
    layers_ffn_w2: [][]f32,
    layers_ffn_b1: [][]f32,
    layers_ffn_b2: [][]f32,
    layer_norm_w: [][]f32,
    layer_norm_b: [][]f32,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Transformer {
        var embeddings = try allocator.alloc([]f32, config.vocab_size);
        var i: u32 = 0;
        while (i < config.vocab_size) {
            embeddings[i] = try allocator.alloc(f32, @intCast(config.hidden));
            i += 1;
        }
        var layers_attention = try allocator.alloc(attention.Attention, config.layers);
        var layers_ffn_w1 = try allocator.alloc([]f32, config.layers);
        var layers_ffn_w2 = try allocator.alloc([]f32, config.layers);
        var layers_ffn_b1 = try allocator.alloc([]f32, config.layers);
        var layers_ffn_b2 = try allocator.alloc([]f32, config.layers);
        var layer_norm_w = try allocator.alloc([]f32, config.layers);
        var layer_norm_b = try allocator.alloc([]f32, config.layers);
        var l: u16 = 0;
        while (l < config.layers) {
            layers_attention[l] = try attention.Attention.init(allocator, .{ .head_count = config.heads, .head_dim = @as(u16, @intCast(config.hidden) / @intCast(config.heads)), .max_sequence = config.max_sequence }, @intCast(config.hidden));
            layers_ffn_w1[l] = try allocator.alloc(f32, @intCast(config.hidden) * @intCast(config.hidden) * 4);
            layers_ffn_w2[l] = try allocator.alloc(f32, @intCast(config.hidden) * 4 * @intCast(config.hidden));
            layers_ffn_b1[l] = try allocator.alloc(f32, @intCast(config.hidden) * 4);
            layers_ffn_b2[l] = try allocator.alloc(f32, @intCast(config.hidden));
            layer_norm_w[l] = try allocator.alloc(f32, @intCast(config.hidden));
            layer_norm_b[l] = try allocator.alloc(f32, @intCast(config.hidden));
            var h: u16 = 0;
            while (h < @intCast(config.hidden)) {
                layer_norm_w[l][h] = 1;
                layer_norm_b[l][h] = 0;
                h += 1;
            }
            l += 1;
        }
        return Transformer{
            .config = config,
            .embeddings = embeddings,
            .layers_attention = layers_attention,
            .layers_ffn_w1 = layers_ffn_w1,
            .layers_ffn_w2 = layers_ffn_w2,
            .layers_ffn_b1 = layers_ffn_b1,
            .layers_ffn_b2 = layers_ffn_b2,
            .layer_norm_w = layer_norm_w,
            .layer_norm_b = layer_norm_b,
        };
    }

    pub fn deinit(self: *Transformer, allocator: std.mem.Allocator) void {
        var i: u32 = 0;
        while (i < self.config.vocab_size) { allocator.free(self.embeddings[i]); i += 1; }
        allocator.free(self.embeddings);
        var l: u16 = 0;
        while (l < self.config.layers) {
            self.layers_attention[l].deinit(allocator);
            allocator.free(self.layers_ffn_w1[l]);
            allocator.free(self.layers_ffn_w2[l]);
            allocator.free(self.layers_ffn_b1[l]);
            allocator.free(self.layers_ffn_b2[l]);
            allocator.free(self.layer_norm_w[l]);
            allocator.free(self.layer_norm_b[l]);
            l += 1;
        }
        allocator.free(self.layers_attention);
        allocator.free(self.layers_ffn_w1);
        allocator.free(self.layers_ffn_w2);
        allocator.free(self.layers_ffn_b1);
        allocator.free(self.layers_ffn_b2);
        allocator.free(self.layer_norm_w);
        allocator.free(self.layer_norm_b);
    }

    pub fn forward(self: *Transformer, token_ids: []const u32, output: []f32) !void {
        var position: usize = 0;
        while (position < output.len) output[position] = 0;
        var i: usize = 0;
        while (i < token_ids.len and i < output.len / @intCast(self.config.hidden)) {
            const embedding = self.embeddings[token_ids[i]];
            var h: u16 = 0;
            while (h < @intCast(self.config.hidden)) {
                output[i * @intCast(self.config.hidden) + @intCast(h)] = embedding[h];
                h += 1;
            }
            i += 1;
        }
        var l: u16 = 0;
        while (l < self.config.layers) {
            var pos: usize = 0;
            while (pos < output.len / @intCast(self.config.hidden)) {
                tensor_ops.layerNorm(output[pos * @intCast(self.config.hidden)..][0..@intCast(self.config.hidden)], self.layer_norm_w[l], self.layer_norm_b[l], 0.00001);
                pos += 1;
            }
            l += 1;
        }
    }
};
