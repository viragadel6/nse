const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: checkpoint-manager <list|register> <path>\n") catch {};
        return error.InvalidArguments;
    }
    const command = args[1];
    if (std.mem.eql(u8, command, "list")) {
        if (args.len < 3) {
            std.io.getStdErr().writeAll("usage: checkpoint-manager list <checkpoint-dir>\n") catch {};
            return error.InvalidArguments;
        }
        const dir = try std.fs.cwd().openDir(args[2], .{ .iterate = true });
        defer dir.close();
        var iterator = dir.iterate();
        while (iterator.next()) |entry| {
            try std.io.getStdOut().print("{s}\n", .{entry.name});
        }
    } else if (std.mem.eql(u8, command, "register")) {
        if (args.len < 4) {
            std.io.getStdErr().writeAll("usage: checkpoint-manager register <version> <path>\n") catch {};
            return error.InvalidArguments;
        }
        const version = try std.fmt.parseInt(u64, args[2], 10);
        const path = args[3];
        const file = try std.fs.cwd().openFile(path, .{ .read = true });
        defer file.close();
        try std.io.getStdOut().print("registered checkpoint version {d} from {s}\n", .{ version, path });
        _ = file;
    } else {
        std.io.getStdErr().writeAll("unknown command\n") catch {};
        return error.InvalidArguments;
    }
}
