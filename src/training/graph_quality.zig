const std = @import("std");

pub const Edge = struct {
    source: u64,
    target: u64,
    weight: f32 = 1.0,
    timestamp_ms: i64 = 0,
    anchor_text: []const u8 = "",
};

pub const GraphQuality = struct {
    edges: std.ArrayList(Edge),
    scc_ids: []u64,
    lock: std.Thread.Mutex,

    pub fn init() GraphQuality {
        return GraphQuality{ .edges = std.ArrayList(Edge).init(std.heap.page_allocator), .scc_ids = &[_]u64{}, .lock = .{} };
    }

    pub fn deinit(self: *GraphQuality) void {
        self.edges.deinit();
    }

    pub fn addEdge(self: *GraphQuality, edge: Edge) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.edges.append(edge);
    }

    pub fn manipulationProbability(self: *GraphQuality, domain: []const u8) f32 {
        _ = domain;
        self.lock.lock();
        const count = self.edges.items.len;
        self.lock.unlock();
        if (count == 0) return 0;
        var reciprocal: u64 = 0;
        var i: usize = 0;
        while (i < self.edges.items.len) {
            var j: usize = i + 1;
            while (j < self.edges.items.len) {
                if (self.edges.items[i].source == self.edges.items[j].target and self.edges.items[i].target == self.edges.items[j].source) reciprocal += 1;
                j += 1;
            }
            i += 1;
        }
        return @as(f32, @intCast(reciprocal)) / @as(f32, @intCast(count));
    }
};
