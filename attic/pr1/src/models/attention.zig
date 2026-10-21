const std = @import("std");
const tensor_ops = @import("tensor_ops.zig");

pub const Config = struct {
    head_count: u16,
    head_dim: u16,
    max_sequence: u16,
    dropout: f32 = 0,
};

pub const Attention = struct {
    config: Config,
    w_q: [][]f32,
    w_k: [][]f32,
    w_v: [][]f32,
    w_o: [][]f32,

    pub fn init(allocator: std.mem.Allocator, config: Config, dim: usize) !Attention {
        var w_q = try allocator.alloc([]f32, config.head_count);
        var w_k = try allocator.alloc([]f32, config.head_count);
        var w_v = try allocator.alloc([]f32, config.head_count);
        var w_o = try allocator.alloc([]f32, config.head_count);
        var h: u16 = 0;
        while (h < config.head_count) {
            w_q[h] = try allocator.alloc(f32, dim * @intCast(config.head_dim));
            w_k[h] = try allocator.alloc(f32, dim * @intCast(config.head_dim));
            w_v[h] = try allocator.alloc(f32, dim * @intCast(config.head_dim));
            w_o[h] = try allocator.alloc(f32, @intCast(config.head_dim) * dim);
            h += 1;
        }
        return Attention{ .config = config, .w_q = w_q, .w_k = w_k, .w_v = w_v, .w_o = w_o };
    }

    pub fn deinit(self: *Attention, allocator: std.mem.Allocator) void {
        var h: u16 = 0;
        while (h < self.config.head_count) {
            allocator.free(self.w_q[h]);
            allocator.free(self.w_k[h]);
            allocator.free(self.w_v[h]);
            allocator.free(self.w_o[h]);
            h += 1;
        }
        allocator.free(self.w_q);
        allocator.free(self.w_k);
        allocator.free(self.w_v);
        allocator.free(self.w_o);
    }

    pub fn forward(self: *Attention, query: [][]const f32, key: [][]const f32, value: [][]const f32, output: [][]f32) void {
        var i: usize = 0;
        while (i < query.len) {
            var j: usize = 0;
            while (j < query[i].len) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < key.len) {
                    sum += query[i][j] * key[k][j] * value[k][j];
                    k += 1;
                }
                output[i][j] = sum;
                j += 1;
            }
            i += 1;
        }
    }
};
