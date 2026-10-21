const std = @import("std");
const cancellation = @import("../runtime/cancellation.zig");

pub const NodeId = u32;

pub const NodeType = enum { router, sparse, dense, filter, vertical, fuse, rerank, verify, extract, highlight };

pub const Node = struct {
    id: NodeId,
    type: NodeType,
    dependencies: []NodeId,
    deadline_ms: u32,
    complete: bool = false,
    cancelled: bool = false,
};

pub const Dag = struct {
    nodes: std.ArrayList(Node),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dag {
        return Dag{ .nodes = std.ArrayList(Node).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Dag) void {
        for (self.nodes.items) |*node| self.allocator.free(node.dependencies);
        self.nodes.deinit();
    }

    pub fn add(self: *Dag, type: NodeType, dependencies: []const NodeId, deadline_ms: u32) !NodeId {
        const id = @as(NodeId, @intCast(self.nodes.items.len));
        const deps_copy = try self.allocator.dup(NodeId, dependencies);
        _ = try self.nodes.append(Node{ .id = id, .type = type, .dependencies = deps_copy, .deadline_ms = deadline_ms });
        return id;
    }

    pub fn ready(self: *Dag, id: NodeId, completed: std.HashMap(NodeId, void)) bool {
        const node = self.nodes.items[@intCast(id)];
        var i: usize = 0;
        while (i < node.dependencies.len) {
            if (!completed.contains(node.dependencies[i])) return false;
            i += 1;
        }
        return true;
    }

    pub fn cancelBranch(self: *Dag, id: NodeId) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.nodes.items[@intCast(id)].cancelled = true;
    }

    pub fn count(self: *Dag) usize {
        return self.nodes.items.len;
    }
};
