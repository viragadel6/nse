const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: snapshot-manager <create|list> <path>\n") catch {};
        return error.InvalidArguments;
    }
    const command = args[1];
    if (std.mem.eql(u8, command, "create")) {
        if (args.len < 3) {
            std.io.getStdErr().writeAll("usage: snapshot-manager create <data-path>\n") catch {};
            return error.InvalidArguments;
        }
        const data_path = args[2];
        const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/documents.snapshot", .{ data_path });
        defer allocator.free(snapshot_path);
        const file = try std.fs.cwd().createFile(snapshot_path, .{});
        defer file.close();
        try file.writeAll("VSNP0001");
        try file.sync();
        try std.io.getStdOut().print("snapshot created at {s}\n", .{ snapshot_path });
    } else if (std.mem.eql(u8, command, "list")) {
        if (args.len < 3) {
            std.io.getStdErr().writeAll("usage: snapshot-manager list <data-path>\n") catch {};
            return error.InvalidArguments;
        }
        const dir = try std.fs.cwd().openDir(args[2], .{ .iterate = true });
        defer dir.close();
        var iterator = dir.iterate();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.name, "documents.snapshot")) {
                try std.io.getStdOut().print("{s}\n", .{entry.name});
            }
        }
    } else {
        std.io.getStdErr().writeAll("unknown command\n") catch {};
        return error.InvalidArguments;
    }
}
