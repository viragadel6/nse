const std = @import("std");

pub fn main() !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.io.getStdErr().writeAll("usage: index-builder <data-path>\n") catch {};
        return error.InvalidArguments;
    }
    const data_path = args[1];
    const store_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer store_dir.close();
    var document_count: u64 = 0;
    var iterator = store_dir.iterate();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "documents.snapshot")) document_count += 1;
    }
    std.io.getStdOut().writeAll("index built: ") catch {};
    try std.io.getStdOut().writeAll(std.fmt.allocPrint(allocator, "{d}\n", .{document_count}));
    _ = allocator;
}
