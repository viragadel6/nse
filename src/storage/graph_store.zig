const std = @import("std");
const checksums = @import("../util/checksums.zig");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");
const codec = @import("../util/binary_codec.zig");

pub const GraphError = error{
    NotFound,
    CorruptSegment,
    VersionMismatch,
    InvalidRecord,
    ChecksumMismatch,
};

pub const segment_magic = "NGRF";
pub const segment_version: u32 = 3;

pub const Edge = struct {
    source: u64,
    destination: u64,
    anchor_hash: u64,
    discovered_ms: i64,
    flags: u32,

    pub const encoded_size = 36;

    pub fn encode(self: Edge, buffer: []u8) ![]u8 {
        var writer = codec.Writer.init(buffer);
        try writer.writeU64(self.source);
        try writer.writeU64(self.destination);
        try writer.writeU64(self.anchor_hash);
        try writer.writeI64(self.discovered_ms);
        try writer.writeU32(self.flags);
        return writer.written();
    }

    pub fn decode(buffer: []const u8) !Edge {
        var reader = codec.Reader.init(buffer);
        return .{
            .source = try reader.readU64(),
            .destination = try reader.readU64(),
            .anchor_hash = try reader.readU64(),
            .discovered_ms = try reader.readI64(),
            .flags = try reader.readU32(),
        };
    }
};

const Adjacency = struct {
    outgoing: std.ArrayListUnmanaged(u64) = .{},
    incoming: std.ArrayListUnmanaged(u64) = .{},
};

pub const Options = struct {
    dir: []const u8 = "data/graph",
    segment_target_bytes: u64 = 268435456,
    verify_checksums_on_read: bool = true,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    options: Options,
    nodes: std.AutoHashMapUnmanaged(u64, Adjacency) = .{},
    edge_file: ?std.fs.File = null,
    edge_path: []const u8,
    edge_bytes: u64 = 0,
    mutex: std.Thread.Mutex = .{},
    edges: u64 = 0,
    anchor_counts: std.AutoHashMapUnmanaged(u64, u32) = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) !Store {
        std.fs.cwd().makePath(options.dir) catch {};
        var store = Store{
            .allocator = allocator,
            .options = options,
            .edge_path = try std.fmt.allocPrint(allocator, "{s}/edges-{d}.seg", .{ options.dir, time.nowMs() }),
        };
        store.edge_file = try std.fs.cwd().createFile(store.edge_path, .{ .read = true, .truncate = true });
        var header: [32]u8 = @splat(0);
        @memcpy(header[0..4], segment_magic);
        std.mem.writeInt(u32, header[4..8], segment_version, .little);
        try store.edge_file.?.writeAll(&header);
        store.edge_bytes = 32;
        try store.recover();
        return store;
    }

    pub fn deinit(self: *Store) void {
        var iterator = self.nodes.valueIterator();
        while (iterator.next()) |adjacency| {
            adjacency.outgoing.deinit(self.allocator);
            adjacency.incoming.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.anchor_counts.deinit(self.allocator);
        if (self.edge_file) |file| file.close();
        self.allocator.free(self.edge_path);
    }

    pub fn addEdge(self: *Store, edge: Edge) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = try self.nodes.getOrPut(self.allocator, edge.source);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        try entry.value_ptr.outgoing.append(self.allocator, edge.destination);
        const reverse = try self.nodes.getOrPut(self.allocator, edge.destination);
        if (!reverse.found_existing) reverse.value_ptr.* = .{};
        try reverse.value_ptr.incoming.append(self.allocator, edge.source);
        const anchor_entry = try self.anchor_counts.getOrPut(self.allocator, edge.anchor_hash);
        if (!anchor_entry.found_existing) anchor_entry.value_ptr.* = 0;
        anchor_entry.value_ptr.* += 1;
        var buffer: [Edge.encoded_size]u8 = undefined;
        const encoded = try edge.encode(&buffer);
        const file = self.edge_file orelse return GraphError.NotFound;
        try file.seekTo(self.edge_bytes);
        try file.writeAll(encoded);
        const crc = checksums.crc32c(encoded, 0);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc, .little);
        try file.writeAll(&crc_bytes);
        self.edge_bytes += encoded.len + 4;
        self.edges += 1;
    }

    pub fn outDegree(self: *Store, node: u64) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const adjacency = self.nodes.get(node) orelse return 0;
        return @intCast(adjacency.outgoing.items.len);
    }

    pub fn inDegree(self: *Store, node: u64) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const adjacency = self.nodes.get(node) orelse return 0;
        return @intCast(adjacency.incoming.items.len);
    }

    pub fn outgoing(self: *Store, allocator: std.mem.Allocator, node: u64) ![]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const adjacency = self.nodes.get(node) orelse return &.{};
        return allocator.dupe(u64, adjacency.outgoing.items);
    }

    pub fn incoming(self: *Store, allocator: std.mem.Allocator, node: u64) ![]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const adjacency = self.nodes.get(node) orelse return &.{};
        return allocator.dupe(u64, adjacency.incoming.items);
    }

    pub fn reciprocity(self: *Store, node: u64) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const adjacency = self.nodes.get(node) orelse return 0.0;
        if (adjacency.outgoing.items.len == 0) return 0.0;
        var reciprocal: usize = 0;
        for (adjacency.outgoing.items) |target| {
            if (self.nodes.get(target)) |target_adjacency| {
                for (target_adjacency.outgoing.items) |back| {
                    if (back == node) {
                        reciprocal += 1;
                        break;
                    }
                }
            }
        }
        return @as(f32, @floatFromInt(reciprocal)) / @as(f32, @floatFromInt(adjacency.outgoing.items.len));
    }

    pub fn anchorRepetition(self: *Store, anchor_hash: u64) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.anchor_counts.get(anchor_hash) orelse 0;
    }

    pub fn domainDiversity(self: *Store, node: u64, domain_of: *const fn (u64) u64) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const adjacency = self.nodes.get(node) orelse return 0.0;
        if (adjacency.incoming.items.len == 0) return 0.0;
        var domains = std.AutoHashMap(u64, void).init(self.allocator);
        defer domains.deinit();
        for (adjacency.incoming.items) |source| {
            domains.put(domain_of(source), {}) catch {};
        }
        return @as(f32, @floatFromInt(domains.count())) / @as(f32, @floatFromInt(adjacency.incoming.items.len));
    }

    pub const PageRankResult = struct {
        node_ids: []u64,
        scores: []f32,
        iterations: u32,

        pub fn deinit(self: *PageRankResult, allocator: std.mem.Allocator) void {
            allocator.free(self.node_ids);
            allocator.free(self.scores);
        }
    };

    pub fn pageRank(self: *Store, allocator: std.mem.Allocator, damping: f64, iterations: u32, tolerance: f64) !PageRankResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.nodes.count();
        if (count == 0) return .{ .node_ids = &.{}, .scores = &.{}, .iterations = 0 };
        const node_ids = try allocator.alloc(u64, count);
        const position = try allocator.alloc(u32, count);
        defer allocator.free(position);
        var slot: std.AutoHashMapUnmanaged(u64, u32) = .{};
        defer slot.deinit(allocator);
        var iterator = self.nodes.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| {
            node_ids[index] = key.*;
            try slot.put(allocator, key.*, @intCast(index));
            index += 1;
        }
        const scores = try allocator.alloc(f64, count);
        defer allocator.free(scores);
        var next = try allocator.alloc(f64, count);
        defer allocator.free(next);
        const initial = 1.0 / @as(f64, @floatFromInt(count));
        for (scores) |*value| value.* = initial;
        var completed: u32 = 0;
        var iteration: u32 = 0;
        while (iteration < iterations) : (iteration += 1) {
            const dangling_mass = blk: {
                var total: f64 = 0;
                for (node_ids, 0..) |node, slot_index| {
                    const adjacency = self.nodes.get(node) orelse continue;
                    if (adjacency.outgoing.items.len == 0) total += scores[slot_index];
                }
                break :blk total;
            };
            for (next) |*value| value.* = (1.0 - damping) / @as(f64, @floatFromInt(count)) + damping * dangling_mass / @as(f64, @floatFromInt(count));
            for (node_ids, 0..) |node, slot_index| {
                const adjacency = self.nodes.get(node) orelse continue;
                if (adjacency.outgoing.items.len == 0) continue;
                const share = damping * scores[slot_index] / @as(f64, @floatFromInt(adjacency.outgoing.items.len));
                for (adjacency.outgoing.items) |target| {
                    const target_index = slot.get(target) orelse continue;
                    next[target_index] += share;
                }
            }
            var delta: f64 = 0;
            for (scores, next) |previous, current| delta += @abs(current - previous);
            @memcpy(scores, next);
            completed = iteration + 1;
            if (delta < tolerance) break;
        }
        const out = try allocator.alloc(f32, count);
        for (scores, 0..) |value, slot_index| out[slot_index] = @floatCast(value);
        return .{ .node_ids = node_ids, .scores = out, .iterations = completed };
    }

    pub const Components = struct {
        component_of: []u32,
        node_ids: []u64,
        largest: u32,

        pub fn deinit(self: *Components, allocator: std.mem.Allocator) void {
            allocator.free(self.component_of);
            allocator.free(self.node_ids);
        }
    };

    pub fn stronglyConnectedComponents(self: *Store, allocator: std.mem.Allocator) !Components {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.nodes.count();
        if (count == 0) return .{ .component_of = &.{}, .node_ids = &.{}, .largest = 0 };
        const node_ids = try allocator.alloc(u64, count);
        const slot = try allocator.alloc(u32, count);
        defer allocator.free(slot);
        var map: std.AutoHashMapUnmanaged(u64, u32) = .{};
        defer map.deinit(allocator);
        var iterator = self.nodes.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| {
            node_ids[index] = key.*;
            try map.put(allocator, key.*, @intCast(index));
            index += 1;
        }
        var component_of = try allocator.alloc(u32, count);
        @memset(component_of, std.math.maxInt(u32));
        var component_count: u32 = 0;
        var largest: u32 = 0;
        var sizes = std.ArrayList(u32).init(allocator);
        defer sizes.deinit();
        for (node_ids, 0..) |node, node_index| {
            if (component_of[node_index] != std.math.maxInt(u32)) continue;
            var stack = std.ArrayList(u64).init(allocator);
            defer stack.deinit();
            try stack.append(node);
            var positions = std.ArrayList(usize).init(allocator);
            defer positions.deinit();
            try positions.append(0);
            while (stack.items.len > 0) {
                const current = stack.items[stack.items.len - 1];
                const position_index = positions.items[positions.items.len - 1];
                const current_index = map.get(current) orelse {
                    _ = stack.pop();
                    _ = positions.pop();
                    continue;
                };
                component_of[current_index] = component_count;
                const adjacency = self.nodes.get(current) orelse {
                    _ = stack.pop();
                    _ = positions.pop();
                    continue;
                };
                if (position_index >= adjacency.outgoing.items.len) {
                    _ = stack.pop();
                    _ = positions.pop();
                    continue;
                }
                positions.items[positions.items.len - 1] += 1;
                const target = adjacency.outgoing.items[position_index];
                const target_index = map.get(target) orelse continue;
                if (component_of[target_index] != std.math.maxInt(u32)) continue;
                try stack.append(target);
                try positions.append(0);
            }
            var size: u32 = 0;
            for (component_of) |value| {
                if (value == component_count) size += 1;
            }
            try sizes.append(size);
            if (size > largest) largest = size;
            component_count += 1;
        }
        return .{ .component_of = component_of, .node_ids = node_ids, .largest = largest };
    }

    pub fn recover(self: *Store) !void {
        var dir = try std.fs.cwd().openDir(self.options.dir, .{ .iterate = true });
        defer dir.close();
        var names = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit();
        }
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "edges-")) continue;
            try names.append(try self.allocator.dupe(u8, entry.name));
        }
        std.sort.block([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            if (std.mem.eql(u8, name, std.fs.path.basename(self.edge_path))) continue;
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.options.dir, name });
            defer self.allocator.free(path);
            if (self.edge_path.len > 0 and std.mem.eql(u8, name, self.edge_path[self.options.dir.len + 1 ..])) continue;
            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            const stat = try file.stat();
            if (stat.size < 36) continue;
            const data = try file.readToEndAlloc(self.allocator, @intCast(stat.size));
            defer self.allocator.free(data);
            if (!std.mem.eql(u8, data[0..4], segment_magic)) return GraphError.CorruptSegment;
            var position: usize = 32;
            while (position + Edge.encoded_size + 4 <= data.len) {
                const edge = Edge.decode(data[position .. position + Edge.encoded_size]) catch break;
                const crc = std.mem.readInt(u32, data[position + Edge.encoded_size ..][0..4], .little);
                if (self.options.verify_checksums_on_read and checksums.crc32c(data[position .. position + Edge.encoded_size], 0) != crc) {
                    return GraphError.ChecksumMismatch;
                }
                const entry = try self.nodes.getOrPut(self.allocator, edge.source);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try entry.value_ptr.outgoing.append(self.allocator, edge.destination);
                const reverse = try self.nodes.getOrPut(self.allocator, edge.destination);
                if (!reverse.found_existing) reverse.value_ptr.* = .{};
                try reverse.value_ptr.incoming.append(self.allocator, edge.source);
                self.edges += 1;
                position += Edge.encoded_size + 4;
            }
        }
    }

    pub fn edgeCount(self: *Store) u64 {
        return self.edges;
    }

    pub fn nodeCount(self: *Store) usize {
        return self.nodes.count();
    }

    pub fn anchorHash(anchor_text: []const u8) u64 {
        const normalized = std.ascii.allocLowerString(std.heap.page_allocator, anchor_text) catch return 0;
        defer std.heap.page_allocator.free(normalized);
        return hashing.hash64(0x3B9ACA07, normalized);
    }
};
