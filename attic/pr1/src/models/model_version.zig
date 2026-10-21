const std = @import("std");

pub const Compatibility = enum { compatible, incompatible, requires_reindex };

pub fn check(model_version: u64, index_version: u64, dimensions: u16, index_dimensions: u16) Compatibility {
    if (model_version != index_version) return .requires_reindex;
    if (dimensions != index_dimensions) return .incompatible;
    return .compatible;
}

pub fn format(version: u64) []const u8 {
    return "v" ++ @intToString(version);
}
