const std = @import("std");

pub const ParseError = error{
    DepthLimitExceeded,
    NodeLimitExceeded,
    AttributeLimitExceeded,
    BufferExhausted,
};

pub const EventKind = enum(u8) {
    start_tag,
    end_tag,
    self_closing,
    text,
    comment,
    doctype,
    script_content,
    style_content,
    cdata,
    eof,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Event = struct {
    kind: EventKind,
    name: []const u8,
    text: []const u8,
    attributes: []const Attribute,
    depth: u32,
    offset: usize,
};

pub const Options = struct {
    max_depth: u32 = 512,
    max_nodes: u32 = 500000,
    max_attribute_bytes: u32 = 65536,
    decode_entities: bool = true,
    emit_script_style_content: bool = false,
    max_attribute_count: u32 = 128,
};

const void_elements = [_][]const u8{
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
};

const optional_close = [_][]const u8{ "li", "p", "td", "tr", "th", "thead", "tbody", "option", "dt", "dd" };

fn isVoidElement(name: []const u8) bool {
    for (void_elements) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn isOptionalClose(name: []const u8) bool {
    for (optional_close) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

pub fn decodeEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, input, '&') == null) return allocator.dupe(u8, input);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '&') {
            try out.append(input[index]);
            index += 1;
            continue;
        }
        const semicolon = std.mem.indexOfScalarPos(u8, input, index, ';') orelse {
            try out.append('&');
            index += 1;
            continue;
        };
        const body = input[index + 1 .. semicolon];
        if (body.len == 0) {
            try out.append('&');
            index += 1;
            continue;
        }
        if (body[0] == '#') {
            const is_hex = body.len > 1 and (body[1] == 'x' or body[1] == 'X');
            const digits = if (is_hex) body[2..] else body[1..];
            const codepoint = std.fmt.parseInt(u32, digits, if (is_hex) 16 else 10) catch {
                try out.appendSlice(input[index..semicolon]);
                index = semicolon;
                continue;
            };
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(@intCast(codepoint), &buffer) catch {
                index = semicolon + 1;
                continue;
            };
            try out.appendSlice(buffer[0..length]);
            index = semicolon + 1;
            continue;
        }
        if (namedEntity(body)) |replacement| {
            try out.appendSlice(replacement);
            index = semicolon + 1;
            continue;
        }
        try out.appendSlice(input[index .. semicolon + 1]);
        index = semicolon + 1;
    }
    return out.toOwnedSlice();
}

fn namedEntity(body: []const u8) ?[]const u8 {
    const table = .{
        .{ "amp", "&" },
        .{ "lt", "<" },
        .{ "gt", ">" },
        .{ "quot", "\"" },
        .{ "apos", "'" },
        .{ "nbsp", " " },
        .{ "copy", "(c)" },
        .{ "reg", "(r)" },
        .{ "trade", "(tm)" },
        .{ "hellip", "..." },
        .{ "mdash", "-" },
        .{ "ndash", "-" },
        .{ "rsquo", "'" },
        .{ "lsquo", "'" },
        .{ "rdquo", "\"" },
        .{ "ldquo", "\"" },
        .{ "euro", "EUR" },
        .{ "deg", "deg" },
        .{ "times", "x" },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(body, entry[0])) return entry[1];
    }
    return null;
}

pub const Visitor = *const fn (context: *anyopaque, event: Event) anyerror!void;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    options: Options,
    stack: std.ArrayList([]const u8),
    depth: u32 = 0,
    nodes: u32 = 0,
    attributes: std.ArrayList(Attribute),
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, options: Options) Parser {
        return .{
            .allocator = allocator,
            .options = options,
            .stack = std.ArrayList([]const u8).init(allocator),
            .attributes = std.ArrayList(Attribute).init(allocator),
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.clearAttributes();
        self.stack.deinit();
        self.attributes.deinit();
        self.buffer.deinit();
    }

    fn clearAttributes(self: *Parser) void {
        for (self.attributes.items) |attribute| {
            self.allocator.free(attribute.name);
            self.allocator.free(attribute.value);
        }
        self.attributes.clearRetainingCapacity();
    }

    fn push(self: *Parser, name: []const u8) !void {
        if (self.depth >= self.options.max_depth) return ParseError.DepthLimitExceeded;
        try self.stack.append(name);
        self.depth += 1;
    }

    fn pop(self: *Parser) ?[]const u8 {
        if (self.stack.items.len == 0) return null;
        const name = self.stack.pop() orelse return null;
        self.depth -|= 1;
        return name;
    }

    pub fn parse(self: *Parser, html: []const u8, context: *anyopaque, visitor: Visitor) !void {
        var index: usize = 0;
        while (index < html.len) {
            self.nodes += 1;
            if (self.nodes > self.options.max_nodes) return ParseError.NodeLimitExceeded;
            if (html[index] != '<') {
                const start = index;
                while (index < html.len and html[index] != '<') index += 1;
                const raw = std.mem.trim(u8, html[start..index], " \t\r\n");
                if (raw.len == 0) continue;
                const text = if (self.options.decode_entities) try decodeEntities(self.allocator, raw) else try self.allocator.dupe(u8, raw);
                defer self.allocator.free(text);
                try visitor(context, .{
                    .kind = .text,
                    .name = "",
                    .text = text,
                    .attributes = &.{},
                    .depth = self.depth,
                    .offset = start,
                });
                continue;
            }
            if (index + 4 <= html.len and std.ascii.eqlIgnoreCase(html[index .. index + 4], "<!--")) {
                const end = std.mem.indexOfPos(u8, html, index + 4, "-->") orelse html.len;
                const content = html[index + 4 .. end];
                try visitor(context, .{ .kind = .comment, .name = "", .text = content, .attributes = &.{}, .depth = self.depth, .offset = index });
                index = if (end + 3 <= html.len) end + 3 else html.len;
                continue;
            }
            if (index + 2 <= html.len and html[index + 1] == '!') {
                const end = std.mem.indexOfScalarPos(u8, html, index + 2, '>') orelse html.len;
                const content = html[index + 2 .. end];
                const kind: EventKind = if (std.ascii.startsWithIgnoreCase(content, "[CDATA[")) .cdata else .doctype;
                try visitor(context, .{ .kind = kind, .name = "", .text = content, .attributes = &.{}, .depth = self.depth, .offset = index });
                index = if (end + 1 <= html.len) end + 1 else html.len;
                continue;
            }
            index += 1;
            var closing = false;
            if (index < html.len and html[index] == '/') {
                closing = true;
                index += 1;
            }
            const name_start = index;
            while (index < html.len and !std.ascii.isWhitespace(html[index]) and html[index] != '>' and html[index] != '/') index += 1;
            const raw_name = html[name_start..index];
            if (raw_name.len == 0) continue;
            const name = try std.ascii.allocLowerString(self.allocator, raw_name);
            defer self.allocator.free(name);
            self.clearAttributes();
            var self_closing = false;
            while (index < html.len and html[index] != '>') {
                while (index < html.len and std.ascii.isWhitespace(html[index])) index += 1;
                if (index >= html.len or html[index] == '>') break;
                if (html[index] == '/') {
                    self_closing = true;
                    index += 1;
                    continue;
                }
                const attribute_start = index;
                while (index < html.len and !std.ascii.isWhitespace(html[index]) and html[index] != '=' and html[index] != '>' and html[index] != '/') index += 1;
                const attribute_name = html[attribute_start..index];
                if (attribute_name.len == 0) {
                    index += 1;
                    continue;
                }
                var value: []const u8 = "";
                while (index < html.len and std.ascii.isWhitespace(html[index])) index += 1;
                if (index < html.len and html[index] == '=') {
                    index += 1;
                    while (index < html.len and std.ascii.isWhitespace(html[index])) index += 1;
                    if (index < html.len and (html[index] == '"' or html[index] == '\'')) {
                        const quote = html[index];
                        index += 1;
                        const value_start = index;
                        while (index < html.len and html[index] != quote) index += 1;
                        value = html[value_start..@min(index, html.len)];
                        if (index < html.len) index += 1;
                    } else {
                        const value_start = index;
                        while (index < html.len and !std.ascii.isWhitespace(html[index]) and html[index] != '>') index += 1;
                        value = html[value_start..index];
                    }
                }
                if (self.attributes.items.len >= self.options.max_attribute_count) continue;
                if (value.len > self.options.max_attribute_bytes) value = value[0..self.options.max_attribute_bytes];
                const decoded_value = if (self.options.decode_entities) try decodeEntities(self.allocator, value) else try self.allocator.dupe(u8, value);
                const stored_name = try std.ascii.allocLowerString(self.allocator, attribute_name);
                try self.attributes.append(.{ .name = stored_name, .value = decoded_value });
            }
            if (index < html.len and html[index] == '>') index += 1;
            if (closing) {
                var matched = false;
                var depth_check: usize = 0;
                while (depth_check < self.stack.items.len) : (depth_check += 1) {
                    const candidate = self.stack.items[self.stack.items.len - 1 - depth_check];
                    if (std.ascii.eqlIgnoreCase(candidate, name)) {
                        matched = true;
                        break;
                    }
                    if (!isOptionalClose(candidate)) break;
                }
                if (matched) {
                    var closing_index: usize = 0;
                    while (closing_index <= depth_check) : (closing_index += 1) {
                        if (self.pop()) |closed| {
                            try visitor(context, .{ .kind = .end_tag, .name = closed, .text = "", .attributes = &.{}, .depth = self.depth, .offset = index });
                            self.allocator.free(closed);
                        }
                    }
                } else {
                    try visitor(context, .{ .kind = .end_tag, .name = try self.allocator.dupe(u8, name), .text = "", .attributes = &.{}, .depth = self.depth, .offset = index });
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "table") and self.stack.items.len > 0) {
                const parent = self.stack.items[self.stack.items.len - 1];
                if (std.ascii.eqlIgnoreCase(parent, "table")) {
                    if (self.pop()) |closed| {
                        try visitor(context, .{ .kind = .end_tag, .name = closed, .text = "", .attributes = &.{}, .depth = self.depth, .offset = index });
                        self.allocator.free(closed);
                    }
                }
            }
            if (self.stack.items.len > 0 and isOptionalClose(self.stack.items[self.stack.items.len - 1]) and (std.ascii.eqlIgnoreCase(name, "p") or std.ascii.eqlIgnoreCase(name, "li") or std.ascii.eqlIgnoreCase(name, "tr") or std.ascii.eqlIgnoreCase(name, "td"))) {
                if (self.pop()) |closed| {
                    try visitor(context, .{ .kind = .end_tag, .name = closed, .text = "", .attributes = &.{}, .depth = self.depth, .offset = index });
                    self.allocator.free(closed);
                }
            }
            const stored_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(stored_name);
            try visitor(context, .{
                .kind = if (self_closing or isVoidElement(name)) .self_closing else .start_tag,
                .name = stored_name,
                .text = "",
                .attributes = self.attributes.items,
                .depth = self.depth,
                .offset = index,
            });
            if (self_closing or isVoidElement(name)) {
                self.allocator.free(stored_name);
            } else {
                try self.push(stored_name);
            }
            self.clearAttributes();
            if (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style")) {
                const terminator = if (std.ascii.eqlIgnoreCase(name, "script")) "</script>" else "</style>";
                const end = std.mem.indexOfPos(u8, html, index, terminator) orelse html.len;
                const content = html[index..end];
                if (self.options.emit_script_style_content) {
                    try visitor(context, .{
                        .kind = if (std.ascii.eqlIgnoreCase(name, "script")) .script_content else .style_content,
                        .name = name,
                        .text = content,
                        .attributes = &.{},
                        .depth = self.depth,
                        .offset = index,
                    });
                }
                if (self.pop()) |closed| {
                    try visitor(context, .{ .kind = .end_tag, .name = closed, .text = "", .attributes = &.{}, .depth = self.depth, .offset = end });
                    self.allocator.free(closed);
                }
                index = if (end + terminator.len <= html.len) end + terminator.len else html.len;
            }
        }
        while (self.stack.items.len > 0) {
            if (self.pop()) |closed| {
                try visitor(context, .{ .kind = .end_tag, .name = closed, .text = "", .attributes = &.{}, .depth = self.depth, .offset = html.len });
                self.allocator.free(closed);
            }
        }
        try visitor(context, .{ .kind = .eof, .name = "", .text = "", .attributes = &.{}, .depth = 0, .offset = html.len });
    }

    pub fn reset(self: *Parser) void {
        self.depth = 0;
        self.nodes = 0;
        self.stack.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
    }
};

pub fn attributeValue(attributes: []const Attribute, name: []const u8) ?[]const u8 {
    for (attributes) |attribute| {
        if (std.ascii.eqlIgnoreCase(attribute.name, name)) return attribute.value;
    }
    return null;
}
