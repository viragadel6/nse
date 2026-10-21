const std = @import("std");

pub const NvmeStore = struct {
    path: []const u8,
    block_bytes: u64 = 4096,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) NvmeStore {
        return NvmeStore{ .path = path, .allocator = allocator };
    }

    pub fn writeBlock(self: *NvmeStore, block_id: u64, data: []const u8) !void {
        const file = try std.fs.cwd().openFile(self.path, .{ .read = true, .write = true });
        defer file.close();
        const offset = block_id * self.block_bytes;
        try file.seekTo(offset);
        try file.writeAll(data);
        try file.sync();
    }

    pub fn readBlock(self: *NvmeStore, block_id: u64, buffer: []u8) !void {
        const file = try std.fs.cwd().openFile(self.path, .{ .read = true });
        defer file.close();
        const offset = block_id * self.block_bytes;
        try file.seekTo(offset);
        try file.readAll(buffer);
    }
};
