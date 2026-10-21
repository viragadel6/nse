const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: training-coordinator <submit|status> <args>\n") catch {};
        return error.InvalidArguments;
    }
    const command = args[1];
    if (std.mem.eql(u8, command, "submit")) {
        if (args.len < 3) {
            std.io.getStdErr().writeAll("usage: training-coordinator submit <request-path>\n") catch {};
            return error.InvalidArguments;
        }
        const request_path = args[2];
        const bytes = try std.fs.cwd().readFileAlloc(allocator, request_path, 64 * 1024 * 1024);
        defer allocator.free(bytes);
        try std.io.getStdOut().print("training submitted: {d} bytes\n", .{bytes.len});
    } else if (std.mem.eql(u8, command, "status")) {
        try std.io.getStdOut().writeAll("training status: running\n");
    } else {
        std.io.getStdErr().writeAll("unknown command\n") catch {};
        return error.InvalidArguments;
    }
}
