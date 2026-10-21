const std = @import("std");

fn component(value: std.Uri.Component) []const u8 {
    return switch (value) { .raw, .percent_encoded => |bytes| bytes };
}

fn tracking(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "utm_") or std.ascii.eqlIgnoreCase(name, "gclid") or std.ascii.eqlIgnoreCase(name, "fbclid") or std.ascii.eqlIgnoreCase(name, "msclkid");
}

fn encodeNormalized(output: *std.ArrayList(u8), input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    var offset: usize = 0;
    while (offset < input.len) : (offset += 1) {
        const byte = input[offset];
        if (byte == '%' and input.len - offset >= 3) {
            const decoded = std.fmt.parseInt(u8, input[offset + 1 ..][0..2], 16) catch return error.InvalidUrlEscape;
            if (std.ascii.isAlphanumeric(decoded) or std.mem.indexOfScalar(u8, "-._~", decoded) != null) {
                try output.append(decoded);
            } else {
                try output.appendSlice(&.{ '%', hex[decoded >> 4], hex[decoded & 15] });
            }
            offset += 2;
        } else {
            if (byte <= 32 or byte == 127 or byte == '%') return error.InvalidUrlCharacter;
            try output.append(byte);
        }
    }
}

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const uri = try std.Uri.parse(input);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUrlScheme;
    if (uri.user != null or uri.password != null) return error.InvalidUrlUserInfo;
    const host = component(uri.host orelse return error.MissingUrlHost);
    if (host.len == 0) return error.MissingUrlHost;
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    for (uri.scheme) |byte| try output.append(std.ascii.toLower(byte));
    try output.appendSlice("://");
    for (host) |byte| {
        if (byte <= 32 or byte == '/' or byte == '\\' or byte == 127) return error.InvalidUrlHost;
        try output.append(std.ascii.toLower(byte));
    }
    if (uri.port) |port| {
        if (port == 0) return error.InvalidUrlPort;
        if (!(port == 80 and std.ascii.eqlIgnoreCase(uri.scheme, "http")) and !(port == 443 and std.ascii.eqlIgnoreCase(uri.scheme, "https"))) try output.writer().print(":{d}", .{port});
    }
    var normalized = std.ArrayList(u8).init(allocator);
    defer normalized.deinit();
    try encodeNormalized(&normalized, component(uri.path));
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();
    var paths = std.mem.splitScalar(u8, normalized.items, '/');
    while (paths.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        if (part.len > 0) try parts.append(part);
    }
    try output.append('/');
    for (parts.items, 0..) |part, i| {
        if (i > 0) try output.append('/');
        try output.appendSlice(part);
    }
    if (normalized.items.len > 1 and normalized.items[normalized.items.len - 1] == '/' and parts.items.len > 0) try output.append('/');
    if (uri.query) |query| {
        var fields = std.mem.splitScalar(u8, component(query), '&');
        var first = true;
        while (fields.next()) |field| {
            const name = field[0 .. std.mem.indexOfScalar(u8, field, '=') orelse field.len];
            if (field.len == 0 or tracking(name)) continue;
            try output.append(if (first) '?' else '&');
            first = false;
            try encodeNormalized(&output, field);
        }
    }
    return output.toOwnedSlice();
}

pub fn domain(url: []const u8) ![]const u8 {
    return component((try std.Uri.parse(url)).host orelse return error.MissingUrlHost);
}

pub fn resolve(allocator: std.mem.Allocator, base: []const u8, reference: []const u8) ![]u8 {
    const length = try std.math.add(usize, try std.math.add(usize, base.len, reference.len), 1024);
    const buffer = try allocator.alloc(u8, length);
    defer allocator.free(buffer);
    var available = buffer;
    const uri = try std.Uri.resolve_inplace(try std.Uri.parse(base), reference, &available);
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    try output.writer().print("{}", .{uri});
    return normalize(allocator, output.items);
}
