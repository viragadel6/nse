const std = @import("std");
const urls = @import("url_normalization.zig");

pub const CanonicalKey = [32]u8;

pub fn compute(url: []const u8) CanonicalKey {
    var result: CanonicalKey = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &result, .{});
    return result;
}

pub fn sameDocument(a: []const u8, b: []const u8) bool {
    const na = urls.normalize(std.heap.page_allocator, a) catch return false;
    defer std.heap.page_allocator.free(na);
    const nb = urls.normalize(std.heap.page_allocator, b) catch return false;
    defer std.heap.page_allocator.free(nb);
    return std.mem.eql(u8, na, nb);
}
