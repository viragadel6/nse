const std = @import("std");
const cuda = @import("cuda_runtime.zig");
const artifacts = @import("artifacts");
const protocol = @import("workload");
const Op = enum { parameter, lookup, matmul, add, gelu, layer_norm, l2_norm, softmax, pool };
pub const Node = struct { data: u64, gradient: u64, rows: i32, cols: i32, op: Op, a: usize = 0, b: usize = 0, c: usize = 0, tokens: u64 = 0, features: u64 = 0, transpose: i32 = 0, scale: f32 = 1 };

pub const Model = struct {
    runtime: *cuda.Runtime,
    metadata: artifacts.Metadata,
    parameters: u64,
    gradient: u64,
    first: u64,
    second: u64,
    norm: u64,
    pub fn init(runtime: *cuda.Runtime, metadata: artifacts.Metadata, values: []const f32, first: []const f32, second: []const f32) !Model {
        try artifacts.validate(metadata);
        if (values.len != metadata.parameter_count or first.len != values.len or second.len != values.len) return error.InvalidParameterCount;
        const bytes = try std.math.mul(usize, values.len, 4);
        const parameters = try runtime.allocate(bytes);
        errdefer runtime.free(parameters);
        const gradient = try runtime.allocate(bytes);
        errdefer runtime.free(gradient);
        const m = try runtime.allocate(bytes);
        errdefer runtime.free(m);
        const v = try runtime.allocate(bytes);
        errdefer runtime.free(v);
        const norm = try runtime.allocate(4);
        errdefer runtime.free(norm);
        try runtime.upload(parameters, std.mem.sliceAsBytes(values));
        try runtime.upload(m, std.mem.sliceAsBytes(first));
        try runtime.upload(v, std.mem.sliceAsBytes(second));
        try runtime.zero(gradient, bytes);
        return .{ .runtime = runtime, .metadata = metadata, .parameters = parameters, .gradient = gradient, .first = m, .second = v, .norm = norm };
    }
    pub fn deinit(self: *Model) void {
        self.runtime.free(self.norm);
        self.runtime.free(self.second);
        self.runtime.free(self.first);
        self.runtime.free(self.gradient);
        self.runtime.free(self.parameters);
    }
    pub fn clearGradient(self: *Model) !void { try self.runtime.zero(self.gradient, try std.math.mul(usize, @intCast(self.metadata.parameter_count), 4)); }
    pub fn temperature(self: *const Model) u64 { return self.parameters + (self.metadata.parameter_count - 1) * 4; }
    pub fn temperatureGradient(self: *const Model) u64 { return self.gradient + (self.metadata.parameter_count - 1) * 4; }
    pub fn optimize(self: *Model, learning_rate: f32, decay: f32, clip: f32) !f32 {
        const count = std.math.cast(i32, self.metadata.parameter_count) orelse return error.ModelTooLarge;
        try self.runtime.launch("gradient_norm", 1, .{ self.gradient, self.norm, count });
        var norm: [1]f32 = undefined;
        try self.runtime.download(std.mem.sliceAsBytes(&norm), self.norm);
        if (!std.math.isFinite(norm[0])) return error.NonFiniteGradient;
        const step = try std.math.add(u64, self.metadata.step, 1);
        const exponent: f32 = @floatFromInt(step);
        const c1: f32 = 1 - std.math.pow(f32, 0.9, exponent);
        const c2: f32 = 1 - std.math.pow(f32, 0.999, exponent);
        try self.runtime.launch("adam_update", @intCast(count), .{ self.parameters, self.gradient, self.first, self.second, self.norm, count, learning_rate, decay, clip, c1, c2 });
        try self.runtime.synchronize();
        self.metadata.step = step;
        return norm[0];
    }
    pub fn save(self: *Model, allocator: std.mem.Allocator, path: []const u8) ![32]u8 {
        const count: usize = @intCast(self.metadata.parameter_count);
        const p = try allocator.alloc(f32, count);
        defer allocator.free(p);
        const m = try allocator.alloc(f32, count);
        defer allocator.free(m);
        const v = try allocator.alloc(f32, count);
        defer allocator.free(v);
        try self.runtime.download(std.mem.sliceAsBytes(p), self.parameters);
        try self.runtime.download(std.mem.sliceAsBytes(m), self.first);
        try self.runtime.download(std.mem.sliceAsBytes(v), self.second);
        return artifacts.save(allocator, path, self.metadata, p, m, v);
    }
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    model: *Model,
    nodes: std.ArrayList(Node),
    resources: std.ArrayList(u64),
    pub fn init(allocator: std.mem.Allocator, model: *Model) Graph { return .{ .allocator = allocator, .model = model, .nodes = std.ArrayList(Node).init(allocator), .resources = std.ArrayList(u64).init(allocator) }; }
    pub fn deinit(self: *Graph) void {
        for (self.resources.items) |pointer| self.model.runtime.free(pointer);
        self.resources.deinit();
        self.nodes.deinit();
    }
    fn allocate(self: *Graph, bytes: usize) !u64 {
        const pointer = try self.model.runtime.allocate(bytes);
        errdefer self.model.runtime.free(pointer);
        try self.resources.append(pointer);
        return pointer;
    }
    fn create(self: *Graph, op: Op, rows: i32, cols: i32) !Node {
        if (rows <= 0 or cols <= 0) return error.InvalidTensorShape;
        const count = try std.math.mul(usize, @intCast(rows), @intCast(cols));
        const bytes = try std.math.mul(usize, count, 4);
        const data = try self.allocate(bytes);
        const gradient = try self.allocate(bytes);
        try self.model.runtime.zero(gradient, bytes);
        return .{ .data = data, .gradient = gradient, .rows = rows, .cols = cols, .op = op };
    }
    fn append(self: *Graph, node: Node) !usize { const id = self.nodes.items.len; try self.nodes.append(node); return id; }
    fn parameter(self: *Graph, offset: *usize, rows: i32, cols: i32) !usize {
        const count = try std.math.mul(usize, @intCast(rows), @intCast(cols));
        const end = try std.math.add(usize, offset.*, count);
        if (end > self.model.metadata.parameter_count - 1) return error.InvalidParameterLayout;
        const node = Node{ .op = .parameter, .data = self.model.parameters + offset.* * 4, .gradient = self.model.gradient + offset.* * 4, .rows = rows, .cols = cols };
        offset.* = end;
        return self.append(node);
    }
    pub fn matmul(self: *Graph, a_id: usize, b_id: usize, transpose: bool, scale: f32) !usize {
        const a = self.nodes.items[a_id];
        const b = self.nodes.items[b_id];
        const n = if (transpose) b.rows else b.cols;
        if (a.cols != (if (transpose) b.cols else b.rows)) return error.InvalidTensorShape;
        var y = try self.create(.matmul, a.rows, n);
        y.a = a_id; y.b = b_id; y.transpose = @intFromBool(transpose); y.scale = scale;
        try self.model.runtime.launch("matmul_forward", @as(usize, @intCast(y.rows)) * @as(usize, @intCast(y.cols)), .{ a.data, b.data, y.data, y.rows, y.cols, a.cols, y.transpose, scale });
        return self.append(y);
    }
    fn add(self: *Graph, a_id: usize, b_id: usize) !usize {
        const a = self.nodes.items[a_id]; const b = self.nodes.items[b_id];
        if (a.rows != b.rows or a.cols != b.cols) return error.InvalidTensorShape;
        var y = try self.create(.add, a.rows, a.cols); y.a = a_id; y.b = b_id;
        const count = try std.math.mul(i32, a.rows, a.cols);
        try self.model.runtime.launch("add_forward", @intCast(count), .{ a.data, b.data, y.data, count });
        return self.append(y);
    }
    fn unary(self: *Graph, op: Op, a_id: usize) !usize {
        const a = self.nodes.items[a_id];
        var y = try self.create(op, if (op == .pool) 1 else a.rows, a.cols); y.a = a_id;
        switch (op) {
            .gelu => { const count = try std.math.mul(i32, a.rows, a.cols); try self.model.runtime.launch("gelu_forward", @intCast(count), .{ a.data, y.data, count }); },
            .layer_norm, .l2_norm => try self.model.runtime.launch("norm_forward", @intCast(a.rows), .{ a.data, y.data, a.rows, a.cols, @as(i32, if (op == .l2_norm) 1 else 0) }),
            .softmax => try self.model.runtime.launch("softmax_forward", @intCast(a.rows), .{ a.data, y.data, a.rows, a.cols }),
            .pool => try self.model.runtime.launch("pool_forward", @intCast(a.cols), .{ a.data, y.data, a.rows, a.cols }),
            else => return error.InvalidTensorOperation,
        }
        return self.append(y);
    }
    fn lookup(self: *Graph, words: usize, positions: usize, structure: usize, item: protocol.Item) !usize {
        const length = @min(item.text.len, self.model.metadata.max_tokens);
        if (length == 0) return error.InvalidText;
        const token_values = try self.allocator.alloc(u32, length);
        defer self.allocator.free(token_values);
        const feature_values = try self.allocator.alloc(f32, length * 6);
        defer self.allocator.free(feature_values);
        @memset(feature_values, 0);
        var paragraph: f32 = 0;
        for (item.text[0..length], 0..) |byte, i| {
            token_values[i] = @as(u32, byte) + 1;
            if (byte == '\n') paragraph += 1;
            feature_values[i * 6 + 4] = paragraph / @as(f32, @floatFromInt(length));
            for (item.structure) |span| if (i >= span.start and i < span.end) {
                const values = [6]f32{ span.depth, span.heading, span.element, span.prominence, span.paragraph, span.link };
                for (values, 0..) |value, f| feature_values[i * 6 + f] = value / (1 + value);
                break;
            };
        }
        const tokens = try self.allocate(length * 4);
        const features = try self.allocate(length * 6 * 4);
        try self.model.runtime.upload(tokens, std.mem.sliceAsBytes(token_values));
        try self.model.runtime.upload(features, std.mem.sliceAsBytes(feature_values));
        const w = self.nodes.items[words]; const p = self.nodes.items[positions]; const s = self.nodes.items[structure];
        var y = try self.create(.lookup, @intCast(length), w.cols);
        y.a = words; y.b = positions; y.c = structure; y.tokens = tokens; y.features = features;
        const count = try std.math.mul(i32, y.rows, y.cols);
        try self.model.runtime.launch("lookup_forward", @intCast(count), .{ w.data, p.data, s.data, tokens, features, y.data, y.rows, y.cols });
        return self.append(y);
    }
    pub fn encode(self: *Graph, item: protocol.Item) !usize {
        try protocol.validateItem(item);
        const h: i32 = self.model.metadata.hidden;
        const half = (self.model.metadata.parameter_count - 1) / 2;
        var offset: usize = if (item.kind == .query) 0 else @intCast(half);
        const words = try self.parameter(&offset, 257, h);
        const positions = try self.parameter(&offset, self.model.metadata.max_tokens, h);
        const structure = try self.parameter(&offset, 6, h);
        var x = try self.lookup(words, positions, structure, item);
        for (0..self.model.metadata.layers) |_| {
            const wq = try self.parameter(&offset, h, h); const wk = try self.parameter(&offset, h, h);
            const wv = try self.parameter(&offset, h, h); const wo = try self.parameter(&offset, h, h);
            const w1 = try self.parameter(&offset, h, h * 4); const w2 = try self.parameter(&offset, h * 4, h);
            const normalized = try self.unary(.layer_norm, x);
            const q = try self.matmul(normalized, wq, false, 1); const k = try self.matmul(normalized, wk, false, 1); const v = try self.matmul(normalized, wv, false, 1);
            const scores = try self.matmul(q, k, true, 1 / @sqrt(@as(f32, @floatFromInt(h))));
            const attention = try self.unary(.softmax, scores);
            const context = try self.matmul(attention, v, false, 1);
            x = try self.add(x, try self.matmul(context, wo, false, 1));
            const residual = x;
            const norm = try self.unary(.layer_norm, x);
            const activated = try self.unary(.gelu, try self.matmul(norm, w1, false, 1));
            x = try self.add(residual, try self.matmul(activated, w2, false, 1));
        }
        const projection = try self.parameter(&offset, h, 4096);
        const normalized = try self.unary(.layer_norm, x);
        const pooled = try self.unary(.pool, normalized);
        return self.unary(.l2_norm, try self.matmul(pooled, projection, false, 1));
    }
    pub fn backward(self: *Graph) !void {
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const y = self.nodes.items[i];
            if (y.op == .parameter) continue;
            const a = self.nodes.items[y.a]; const b = self.nodes.items[y.b];
            const count = try std.math.mul(i32, y.rows, y.cols);
            switch (y.op) {
                .parameter => unreachable,
                .matmul => {
                    try self.model.runtime.launch("matmul_backward_a", @intCast(try std.math.mul(i32, a.rows, a.cols)), .{ b.data, y.gradient, a.gradient, y.rows, y.cols, a.cols, y.transpose, y.scale });
                    try self.model.runtime.launch("matmul_backward_b", @intCast(try std.math.mul(i32, b.rows, b.cols)), .{ a.data, y.gradient, b.gradient, y.rows, y.cols, a.cols, y.transpose, y.scale });
                },
                .add => try self.model.runtime.launch("add_backward", @intCast(count), .{ y.gradient, a.gradient, b.gradient, count }),
                .gelu => try self.model.runtime.launch("gelu_backward", @intCast(count), .{ a.data, y.gradient, a.gradient, count }),
                .layer_norm, .l2_norm => try self.model.runtime.launch("norm_backward", @intCast(y.rows), .{ a.data, y.data, y.gradient, a.gradient, y.rows, y.cols, @as(i32, if (y.op == .l2_norm) 1 else 0) }),
                .softmax => try self.model.runtime.launch("softmax_backward", @intCast(y.rows), .{ y.data, y.gradient, a.gradient, y.rows, y.cols }),
                .pool => try self.model.runtime.launch("pool_backward", @intCast(try std.math.mul(i32, a.rows, a.cols)), .{ y.gradient, a.gradient, a.rows, a.cols }),
                .lookup => {
                    const c = self.nodes.items[y.c];
                    try self.model.runtime.launch("lookup_backward", @intCast(count), .{ y.gradient, y.tokens, y.features, a.gradient, b.gradient, c.gradient, y.rows, y.cols });
                },
            }
        }
        try self.model.runtime.synchronize();
    }
    pub fn read(self: *Graph, id: usize) ![]f32 {
        const node = self.nodes.items[id];
        const values = try self.allocator.alloc(f32, @as(usize, @intCast(node.rows)) * @as(usize, @intCast(node.cols)));
        errdefer self.allocator.free(values);
        try self.model.runtime.download(std.mem.sliceAsBytes(values), node.data);
        var norm: f64 = 0;
        for (values) |value| { if (!std.math.isFinite(value)) return error.InvalidEmbedding; norm += @as(f64, value) * value; }
        if (!std.math.isFinite(norm) or norm < 0.000001) return error.InvalidEmbedding;
        return values;
    }
};
