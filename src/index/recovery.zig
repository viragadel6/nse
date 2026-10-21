const std = @import("std");

pub fn recoverIndex(allocator: std.mem.Allocator, path: []const u8) !struct { generation: u64, document_count: u64 } {
    const file = try std.fs.cwd().openFile(path, .{ .read = true });
    defer file.close();
    const stat = try file.getStat();
    if (stat.size == 0) return .{ .generation = 0, .document_count = 0 };
    const header = try allocator.alloc(u8, 32);
    defer allocator.free(header);
    try file.preadAll(header, 0);
    const magic = header[0..4];
    if (!std.mem.eql(u8, magic, "IDXV")) return error.InvalidIndexFormat;
    const generation = std.mem.readInt(u64, header[8..16], .little);
    const document_count = std.mem.readInt(u64, header[16..24], .little);
    return .{ .generation = generation, .document_count = document_count };
}
