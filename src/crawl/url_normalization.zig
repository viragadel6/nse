const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const NormalizeError = error{
    InvalidUrl,
    OutOfMemory,
    UnsupportedScheme,
    EmptyHost,
};

const default_ports = [_][]const u8{ ":80", ":443" };

const tracking_prefixes = [_][]const u8{
    "utm_", "gclid", "fbclid", "mc_eid", "igshid", "ref_", "at_", "sc_", "vero_id", "yclid", "msclkid", "_ga", "gclsrc", "wt_mc", "pk_campaign", "hsa_", "mkt_tok",
};

const tracking_exact = [_][]const u8{
    "ref", "referrer", "source", "src", "campaign", "medium", "term", "content", "sid", "sessionid", "session_id", "phpsessid", "jsessionid", "aspsessionid", "aff_id", "affid", "clickid", "trk", "tracking",
};

pub const Components = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    query: []const u8,
    secure: bool,
};

pub fn parse(raw: []const u8) NormalizeError!Components {
    var rest = raw;
    var scheme: []const u8 = "http";
    if (rest.len >= 8 and std.ascii.eqlIgnoreCase(rest[0..8], "https://")) {
        scheme = "https";
        rest = rest[8..];
    } else if (rest.len >= 7 and std.ascii.eqlIgnoreCase(rest[0..7], "http://")) {
        scheme = "http";
        rest = rest[7..];
    } else {
        return NormalizeError.UnsupportedScheme;
    }
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..authority_end];
    var port: u16 = if (std.mem.eql(u8, scheme, "https")) 443 else 80;
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const tail = authority[colon + 1 ..];
        if (tail.len > 0 and std.mem.indexOfNone(u8, tail, "0123456789") == null) {
            port = std.fmt.parseInt(u16, tail, 10) catch return NormalizeError.InvalidUrl;
            host = authority[0..colon];
        }
    }
    if (std.mem.indexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (host.len == 0) return NormalizeError.EmptyHost;
    var path: []const u8 = "/";
    var query: []const u8 = "";
    if (authority_end < rest.len) {
        var tail = rest[authority_end..];
        if (std.mem.indexOfScalar(u8, tail, '?')) |mark| {
            path = tail[0..mark];
            var raw_query = tail[mark + 1 ..];
            if (std.mem.indexOfScalar(u8, raw_query, '#')) |hash_mark| raw_query = raw_query[0..hash_mark];
            query = raw_query;
        } else if (std.mem.indexOfScalar(u8, tail, '#')) |hash| {
            path = tail[0..hash];
        } else {
            path = tail;
        }
    }
    return .{ .scheme = scheme, .host = host, .port = port, .path = path, .query = query, .secure = scheme.len == 5 };
}

fn lowerHost(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    const lowered = try std.ascii.allocLowerString(allocator, host);
    if (std.mem.endsWith(u8, lowered, ".")) {
        const trimmed = try allocator.dupe(u8, std.mem.trimRight(u8, lowered, "."));
        allocator.free(lowered);
        return trimmed;
    }
    return lowered;
}

fn normalizePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    if (raw_path.len == 0) return allocator.dupe(u8, "/");
    var decoded = std.ArrayList(u8).init(allocator);
    errdefer decoded.deinit();
    var index: usize = 0;
    while (index < raw_path.len) {
        const byte = raw_path[index];
        if (byte == '%' and index + 2 < raw_path.len) {
            const value = std.fmt.parseInt(u8, raw_path[index + 1 .. index + 3], 16) catch null;
            if (value) |decoded_byte| {
                try decoded.append(decoded_byte);
                index += 3;
                continue;
            }
        }
        try decoded.append(byte);
        index += 1;
    }
    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();
    var iterator = std.mem.splitScalar(u8, decoded.items, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(segment);
    }
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.append('/');
    for (segments.items, 0..) |segment, position| {
        if (position > 0) try out.append('/');
        try out.appendSlice(segment);
    }
    if (std.mem.endsWith(u8, decoded.items, "/") and segments.items.len > 0) try out.append('/');
    decoded.deinit();
    return out.toOwnedSlice();
}

fn isTrackingKey(key: []const u8) bool {
    for (tracking_exact) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }
    for (tracking_prefixes) |prefix| {
        if (key.len >= prefix.len and std.ascii.eqlIgnoreCase(key[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn lessThanKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const QueryContext = struct {
    keys: [][]const u8,
    values: [][]const u8,
};

pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) NormalizeError![]u8 {
    const components = try parse(raw);
    return normalizeComponents(allocator, components);
}

pub fn normalizeComponents(allocator: std.mem.Allocator, components: Components) NormalizeError![]u8 {
    const host = try lowerHost(allocator, components.host);
    defer allocator.free(host);
    const path = try normalizePath(allocator, components.path);
    defer allocator.free(path);
    var keys = std.ArrayList([]const u8).init(allocator);
    defer keys.deinit();
    var values = std.ArrayList([]const u8).init(allocator);
    defer values.deinit();
    var order = std.ArrayList(u32).init(allocator);
    defer order.deinit();
    var iterator = std.mem.splitScalar(u8, components.query, '&');
    while (iterator.next()) |pair| {
        if (pair.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (!isTrackingKey(pair)) {
                try order.append(@intCast(keys.items.len));
                try keys.append(pair);
                try values.append("");
            }
            continue;
        };
        const key = pair[0..separator];
        if (isTrackingKey(key)) continue;
        try order.append(@intCast(keys.items.len));
        try keys.append(key);
        try values.append(pair[separator + 1 ..]);
    }
    std.sort.block(u32, order.items, QueryContext{ .keys = keys.items, .values = values.items }, struct {
        fn lt(context: QueryContext, a: u32, b: u32) bool {
            const left_key = context.keys[a];
            const right_key = context.keys[b];
            const key_order = std.mem.order(u8, left_key, right_key);
            if (key_order != .eq) return key_order == .lt;
            return std.mem.lessThan(u8, context.values[a], context.values[b]);
        }
    }.lt);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(components.scheme);
    try out.appendSlice("://");
    try out.appendSlice(host);
    if ((components.secure and components.port != 443) or (!components.secure and components.port != 80)) {
        try out.writer().print(":{d}", .{components.port});
    }
    try out.appendSlice(path);
    if (keys.items.len > 0) {
        try out.append('?');
        for (order.items, 0..) |position, index| {
            if (index > 0) try out.append('&');
            try out.appendSlice(keys.items[position]);
            try out.append('=');
            try out.appendSlice(values.items[position]);
        }
    }
    return out.toOwnedSlice();
}

fn hostLabelCount(host: []const u8) usize {
    if (host.len == 0) return 0;
    var count: usize = 1;
    for (host) |byte| {
        if (byte == '.') count += 1;
    }
    return count;
}

const multi_part_suffixes = [_][]const u8{
    "co.uk", "co.jp", "com.au", "co.nz", "com.br", "co.in", "co.za", "com.mx", "co.kr", "com.cn", "org.uk", "ac.uk", "gov.uk", "ne.jp", "or.jp", "com.tr", "com.tw", "com.hk", "com.sg", "com.ar",
};

pub fn registrableDomain(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    const lowered = try lowerHost(allocator, host);
    defer allocator.free(lowered);
    var labels = std.ArrayList([]const u8).init(allocator);
    defer labels.deinit();
    var iterator = std.mem.splitScalar(u8, lowered, '.');
    while (iterator.next()) |label| {
        if (label.len > 0) try labels.append(label);
    }
    if (labels.items.len <= 2) return allocator.dupe(u8, lowered);
    const last_two = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ labels.items[labels.items.len - 2], labels.items[labels.items.len - 1] });
    defer allocator.free(last_two);
    for (multi_part_suffixes) |suffix| {
        if (std.mem.eql(u8, last_two, suffix) and labels.items.len >= 3) {
            return std.fmt.allocPrint(allocator, "{s}.{s}", .{ labels.items[labels.items.len - 3], last_two });
        }
    }
    return allocator.dupe(u8, last_two);
}

pub fn domainHash(allocator: std.mem.Allocator, host: []const u8) !u64 {
    const domain = registrableDomain(allocator, host) catch return hashing.hash64(0x243F6A8885A308D3, host);
    defer allocator.free(domain);
    return hashing.hash64(0x243F6A8885A308D3, domain);
}

pub fn hostHash(host: []const u8) u64 {
    var buffer: [256]u8 = undefined;
    const lowered = std.ascii.lowerString(&buffer, host);
    return hashing.hash64(0x13198A2E03707344, lowered);
}

pub fn stripDefaultPort(allocator: std.mem.Allocator, host_segment: []const u8) ![]u8 {
    for (default_ports) |port| {
        if (std.mem.endsWith(u8, host_segment, port)) {
            return allocator.dupe(u8, host_segment[0 .. host_segment.len - port.len]);
        }
    }
    return allocator.dupe(u8, host_segment);
}

pub fn looksLikeSessionPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "jsessionid=") != null) return true;
    if (std.mem.indexOf(u8, path, "PHPSESSID=") != null) return true;
    if (std.mem.indexOf(u8, path, ";sessionid=") != null) return true;
    return false;
}

pub fn isPagination(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/page/") != null) return true;
    if (std.mem.endsWith(u8, path, "/page/1")) return true;
    return false;
}

pub fn normalizePair(allocator: std.mem.Allocator, raw: []const u8) NormalizeError!struct { canonical: []u8, host: []u8 } {
    const canonical = try normalize(allocator, raw);
    errdefer allocator.free(canonical);
    const components = try parse(canonical);
    const host = try allocator.dupe(u8, components.host);
    return .{ .canonical = canonical, .host = host };
}
