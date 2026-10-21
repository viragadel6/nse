const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const Router = struct {
    partition_count: u32,

    pub fn init(partition_count: u32) Router {
        return Router{ .partition_count = partition_count };
    }

    pub fn route(self: *const Router, key: []const u8) u32 {
        return @as(u32, @intCast(hashing.fnv1a_64(key) % @as(u64, @intCast(self.partition_count))));
    }

    pub fn routeDocumentId(self: *const Router, document_id: u64) u32 {
        return @as(u32, @intCast(document_id % @as(u64, @intCast(self.partition_count))));
    }
};
