const std = @import("std");
const urls = @import("url_normalization.zig");
const hashing = @import("../util/hashing.zig");

pub const CanonicalError = error{
    InvalidUrl,
    OutOfMemory,
    UnsupportedScheme,
    RedirectLoop,
    TooManyRedirects,
};

pub const RedirectHop = struct {
    from: []const u8,
    to: []const u8,
    status: u16,
};

pub const CanonicalResult = struct {
    canonical: []const u8,
    original: []const u8,
    host: []const u8,
    domain: []const u8,
    canonical_hash: u64,
    host_hash: u64,
    domain_hash: u64,
    redirect_hops: []RedirectHop,
    was_normalized: bool,
    is_pagination: bool,
    has_session_identifier: bool,

    pub fn release(self: *CanonicalResult, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical);
        allocator.free(self.original);
        allocator.free(self.host);
        allocator.free(self.domain);
        for (self.redirect_hops) |*hop| {
            allocator.free(hop.from);
            allocator.free(hop.to);
        }
        allocator.free(self.redirect_hops);
    }
};

pub fn resolveReference(allocator: std.mem.Allocator, base: []const u8, reference: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, reference, "http://") or std.mem.startsWith(u8, reference, "https://")) {
        return allocator.dupe(u8, reference);
    }
    if (std.mem.startsWith(u8, reference, "//")) {
        const components = urls.parse(base) catch return error.InvalidUrl;
        return std.fmt.allocPrint(allocator, "{s}://{s}", .{ components.scheme, reference["//".len..] });
    }
    const components = urls.parse(base) catch return error.InvalidUrl;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (std.mem.startsWith(u8, reference, "/")) {
        try out.writer().print("{s}://{s}{s}", .{ components.scheme, components.host, reference });
        return out.toOwnedSlice();
    }
    const directory_end = std.mem.lastIndexOfScalar(u8, components.path, '/') orelse 0;
    const prefix = components.path[0..@max(1, directory_end)];
    try out.writer().print("{s}://{s}{s}{s}", .{ components.scheme, components.host, prefix, reference });
    return out.toOwnedSlice();
}

pub const Options = struct {
    max_redirect_hops: u8 = 8,
    follow_meta_refresh: bool = true,
    honor_declared_canonical: bool = true,
    cross_domain_canonical_allowed: bool = false,
};

pub fn canonicalize(allocator: std.mem.Allocator, raw: []const u8, declared: []const u8, hops: []const RedirectHop, options: Options) !CanonicalResult {
    const original = try allocator.dupe(u8, raw);
    errdefer allocator.free(original);
    var working = try urls.normalize(allocator, raw);
    defer allocator.free(working);
    var was_normalized = !std.mem.eql(u8, working, raw);
    var hop_list = try allocator.alloc(RedirectHop, hops.len);
    for (hops, 0..) |hop, index| {
        hop_list[index] = .{
            .from = try allocator.dupe(u8, hop.from),
            .to = try allocator.dupe(u8, hop.to),
            .status = hop.status,
        };
    }
    if (hops.len > 0) {
        var visited = std.ArrayList(u64).init(allocator);
        defer visited.deinit();
        for (hops) |hop| {
            const hash_value = hashing.hash64(0xA5A5A5A5, hop.from);
            for (visited.items) |seen| {
                if (seen == hash_value) return CanonicalError.RedirectLoop;
            }
            try visited.append(hash_value);
        }
        const final_target = hops[hops.len - 1].to;
        const resolved = if (std.mem.startsWith(u8, final_target, "http")) try allocator.dupe(u8, final_target) else try resolveReference(allocator, working, final_target);
        defer allocator.free(resolved);
        const normalized_target = try urls.normalize(allocator, resolved);
        allocator.free(working);
        working = normalized_target;
        was_normalized = true;
        if (hops.len > options.max_redirect_hops) return CanonicalError.TooManyRedirects;
    }
    if (options.honor_declared_canonical and declared.len > 0) {
        const resolved = if (std.mem.startsWith(u8, declared, "http")) try allocator.dupe(u8, declared) else try resolveReference(allocator, working, declared);
        defer allocator.free(resolved);
        const normalized_declared = try urls.normalize(allocator, resolved);
        defer allocator.free(normalized_declared);
        const base_components = try urls.parse(working);
        const declared_components = try urls.parse(normalized_declared);
        if (options.cross_domain_canonical_allowed or std.mem.eql(u8, base_components.host, declared_components.host)) {
            allocator.free(working);
            working = try allocator.dupe(u8, normalized_declared);
            was_normalized = true;
        }
    }
    const components = try urls.parse(working);
    const host = try allocator.dupe(u8, components.host);
    errdefer allocator.free(host);
    const domain = try urls.registrableDomain(allocator, host);
    return .{
        .canonical = try allocator.dupe(u8, working),
        .original = original,
        .host = host,
        .domain = domain,
        .canonical_hash = hashing.hash64(0x9E3779B97F4A7C15, working),
        .host_hash = hashing.hash64(0x13198A2E03707344, host),
        .domain_hash = hashing.hash64(0x243F6A8885A308D3, domain),
        .redirect_hops = hop_list,
        .was_normalized = was_normalized,
        .is_pagination = urls.isPagination(components.path),
        .has_session_identifier = urls.looksLikeSessionPath(components.path),
    };
}

pub fn canonicalKey(allocator: std.mem.Allocator, raw: []const u8) !u64 {
    const normalized = try urls.normalize(allocator, raw);
    defer allocator.free(normalized);
    return hashing.hash64(0x9E3779B97F4A7C15, normalized);
}

pub const DuplicateClass = enum(u8) {
    unique,
    parameter_variant,
    session_variant,
    pagination_variant,
    tracking_variant,
    scheme_variant,
    host_variant,
    exact_duplicate,
};

pub fn classifyVariant(allocator: std.mem.Allocator, left: []const u8, right: []const u8) DuplicateClass {
    const left_key = urls.normalize(allocator, left) catch return .unique;
    defer allocator.free(left_key);
    const right_key = urls.normalize(allocator, right) catch return .unique;
    defer allocator.free(right_key);
    if (std.mem.eql(u8, left_key, right_key)) return .exact_duplicate;
    const left_components = urls.parse(left_key) catch return .unique;
    const right_components = urls.parse(right_key) catch return .unique;
    if (!std.mem.eql(u8, left_components.host, right_components.host)) return .host_variant;
    if (!std.mem.eql(u8, left_components.scheme, right_components.scheme)) return .scheme_variant;
    if (!std.mem.eql(u8, left_components.path, right_components.path)) return .parameter_variant;
    if (urls.isPagination(left_components.path) != urls.isPagination(right_components.path)) return .pagination_variant;
    if (urls.looksLikeSessionPath(left_key) or urls.looksLikeSessionPath(right_key)) return .session_variant;
    return .tracking_variant;
}

pub fn stripTrackingParameters(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return urls.normalize(allocator, raw);
}

pub fn mirrorsEquivalent(allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const left_components = urls.parse(left) catch return false;
    const right_components = urls.parse(right) catch return false;
    if (!std.mem.eql(u8, left_components.path, right_components.path)) return false;
    if (!std.mem.eql(u8, left_components.query, right_components.query)) return false;
    const left_domain = urls.registrableDomain(allocator, left_components.host) catch return false;
    defer allocator.free(left_domain);
    const right_domain = urls.registrableDomain(allocator, right_components.host) catch return false;
    defer allocator.free(right_domain);
    return !std.mem.eql(u8, left_domain, right_domain);
}
