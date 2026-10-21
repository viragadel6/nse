const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: corpus-ingestor <input-path>\n") catch {};
        return error.InvalidArguments;
    }
    const input_path = args[1];
    const file = try std.fs.cwd().openFile(input_path, .{});
    defer file.close();
    var buffered = std.io.bufferedReader(file.reader());
    var ingested: u64 = 0;
    while (true) {
        const line = try buffered.reader().readUntilDelimiterAlloc(allocator, '\n', 4 * 1024 * 1024) orelse break;
        if (line.len == 0) continue;
        ingested += 1;
        allocator.free(line);
    }
    try std.io.getStdOut().print("ingested {d} documents\n", .{ingested});
}
