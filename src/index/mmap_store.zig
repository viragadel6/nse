const std = @import("std");

pub const MmapStore = struct {
    fd: std.posix.fd_t,
    size: usize,
    mapping: []u8,
    lock: std.Thread.Mutex,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !MmapStore {
        const file = try std.fs.cwd().openFile(path, .{ .read = true, .write = true });
        const stat = try file.getStat();
        const mapping = try file.mmap(allocator, .{ .size = @intCast(stat.size), .writable = true });
        defer file.close();
        return MmapStore{ .fd = file.handle, .size = @intCast(stat.size), .mapping = mapping, .lock = .{} };
    }

    pub fn deinit(self: *MmapStore, allocator: std.mem.Allocator) void {
        std.posix.munmap(self.mapping);
    }

    pub fn read(self: *MmapStore, offset: usize, length: usize) []const u8 {
        return self.mapping[offset..][0..length];
    }

    pub fn write(self: *MmapStore, offset: usize, data: []const u8) !void {
        var slice = self.mapping[offset..][0..data.len];
        std.mem.copy(u8, slice, data);
    }
};
