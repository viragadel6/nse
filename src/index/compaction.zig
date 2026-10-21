const std = @import("std");

pub const Compaction = struct {
    threshold_dead_ratio: f32 = 0.3,
    segment_bytes: u64 = 256 * 1024 * 1024,

    pub fn shouldCompact(self: *const Compaction, live_bytes: u64, total_bytes: u64) bool {
        if (total_bytes == 0) return false;
        return @as(f32, @intCast(total_bytes - live_bytes)) / @as(f32, @intCast(total_bytes)) >= self.threshold_dead_ratio;
    }

    pub fn run(self: *const Compaction, allocator: std.mem.Allocator, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const temp_path = try std.fmt.allocPrint(allocator, "{s}.compact", .{path});
        defer allocator.free(temp_path);
        const temp = try std.fs.cwd().createFile(temp_path, .{});
        defer temp.close();
        try temp.writeAll("compacted");
        try temp.sync();
        try std.fs.cwd().renameFile(temp_path, path);
    }
};
