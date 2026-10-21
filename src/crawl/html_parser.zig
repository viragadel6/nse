const std = @import("std");

pub const Link = struct { url: []const u8, start: usize };
pub const Paragraph = struct { start: usize, end: usize, depth: u32, element: []const u8 };
pub const Result = struct { title: []u8, text: []u8, language: []u8, canonical: ?[]const u8, links: []Link, paragraphs: []Paragraph };

const Attribute = struct { name: []const u8, value: []const u8 };
const Attributes = struct {
    text: []const u8,
    offset: usize = 0,

    fn next(self: *Attributes) ?Attribute {
        while (self.offset < self.text.len and (std.ascii.isWhitespace(self.text[self.offset]) or self.text[self.offset] == '/')) self.offset += 1;
        if (self.offset == self.text.len) return null;
        const start = self.offset;
        while (self.offset < self.text.len and !std.ascii.isWhitespace(self.text[self.offset]) and self.text[self.offset] != '=' and self.text[self.offset] != '/') self.offset += 1;
        const name = self.text[start..self.offset];
        while (self.offset < self.text.len and std.ascii.isWhitespace(self.text[self.offset])) self.offset += 1;
        if (self.offset == self.text.len or self.text[self.offset] != '=') return .{ .name = name, .value = "" };
        self.offset += 1;
        while (self.offset < self.text.len and std.ascii.isWhitespace(self.text[self.offset])) self.offset += 1;
        if (self.offset == self.text.len) return .{ .name = name, .value = "" };
        const quote = self.text[self.offset];
        if (quote == '\'' or quote == '"') {
            self.offset += 1;
            const value_start = self.offset;
            while (self.offset < self.text.len and self.text[self.offset] != quote) self.offset += 1;
            const value = self.text[value_start..self.offset];
            if (self.offset < self.text.len) self.offset += 1;
            return .{ .name = name, .value = value };
        }
        const value_start = self.offset;
        while (self.offset < self.text.len and !std.ascii.isWhitespace(self.text[self.offset])) self.offset += 1;
        return .{ .name = name, .value = self.text[value_start..self.offset] };
    }
};

fn entity(name: []const u8) ?u21 {
    if (name.len > 1 and name[0] == '#') {
        const hexadecimal = name.len > 2 and (name[1] == 'x' or name[1] == 'X');
        const code = std.fmt.parseInt(u21, name[if (hexadecimal) 2 else 1 ..], if (hexadecimal) 16 else 10) catch return null;
        if (code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) return 0xFFFD;
        return code;
    }
    const names = .{ "amp", "lt", "gt", "quot", "apos", "nbsp", "copy", "reg", "ndash", "mdash", "hellip", "lsquo", "rsquo", "ldquo", "rdquo", "euro" };
    const codes = [_]u21{ 38, 60, 62, 34, 39, 160, 169, 174, 8211, 8212, 8230, 8216, 8217, 8220, 8221, 8364 };
    inline for (names, 0..) |key, index| if (std.mem.eql(u8, name, key)) return codes[index];
    return null;
}

fn appendCode(output: *std.ArrayList(u8), code: u21, whitespace: bool) !void {
    if (whitespace and (code == 160 or (code < 128 and std.ascii.isWhitespace(@intCast(code))))) {
        if (output.items.len > 0 and output.items[output.items.len - 1] != ' ' and output.items[output.items.len - 1] != '\n') try output.append(' ');
    } else {
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(code, &bytes);
        try output.appendSlice(bytes[0..length]);
    }
}

fn appendText(output: *std.ArrayList(u8), text: []const u8, whitespace: bool) !void {
    var offset: usize = 0;
    while (offset < text.len) {
        if (text[offset] == '&') {
            if (std.mem.indexOfScalar(u8, text[offset..@min(text.len, offset + 34)], ';')) |end| {
                if (entity(text[offset + 1 .. offset + end])) |code| {
                    try appendCode(output, code, whitespace);
                    offset += end + 1;
                    continue;
                }
            }
        }
        const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch {
            try appendCode(output, 0xFFFD, whitespace);
            offset += 1;
            continue;
        };
        if (text.len - offset < length) {
            try appendCode(output, 0xFFFD, whitespace);
            break;
        }
        const code = std.unicode.utf8Decode(text[offset..][0..length]) catch {
            try appendCode(output, 0xFFFD, whitespace);
            offset += 1;
            continue;
        };
        try appendCode(output, code, whitespace);
        offset += length;
    }
}

fn decoded(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try appendText(&output, text, false);
    return output.toOwnedSlice();
}

fn block(tag: []const u8) bool {
    inline for (.{ "p", "div", "section", "article", "header", "footer", "main", "nav", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "td", "br", "blockquote", "pre" }) |name| if (std.ascii.eqlIgnoreCase(tag, name)) return true;
    return false;
}

fn boundary(output: *std.ArrayList(u8)) !void {
    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') _ = output.pop();
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append('\n');
}

pub fn parse(allocator: std.mem.Allocator, html: []const u8, maximum_depth: u32) !Result {
    if (maximum_depth == 0) return error.InvalidParserDepth;
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    var title = std.ArrayList(u8).init(allocator);
    errdefer title.deinit();
    var links = std.ArrayList(Link).init(allocator);
    errdefer links.deinit();
    var paragraphs = std.ArrayList(Paragraph).init(allocator);
    errdefer paragraphs.deinit();
    var language: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(language);
    var canonical: ?[]const u8 = null;
    var offset: usize = 0;
    var suppressed: ?[]const u8 = null;
    var in_title = false;
    var depth: u32 = 0;
    var paragraph_start: usize = 0;
    while (offset < html.len) {
        if (html[offset] != '<') {
            const end = std.mem.indexOfScalarPos(u8, html, offset, '<') orelse html.len;
            if (suppressed == null) {
                if (in_title) try appendText(&title, html[offset..end], true) else try appendText(&text, html[offset..end], true);
            }
            offset = end;
            continue;
        }
        if (std.mem.startsWith(u8, html[offset..], "<!--")) {
            offset = if (std.mem.indexOfPos(u8, html, offset + 4, "-->")) |end| end + 3 else html.len;
            continue;
        }
        var end = offset + 1;
        var quote: ?u8 = null;
        while (end < html.len) : (end += 1) {
            const byte = html[end];
            if (quote) |mark| {
                if (byte == mark) quote = null;
            } else if (byte == '\'' or byte == '"') {
                quote = byte;
            } else if (byte == '>') break;
        }
        if (end == html.len) {
            if (suppressed == null and !in_title) try appendText(&text, html[offset..], true);
            break;
        }
        const inside = std.mem.trim(u8, html[offset + 1 .. end], " \r\n\t");
        offset = end + 1;
        if (inside.len == 0 or inside[0] == '!' or inside[0] == '?') continue;
        const closing = inside[0] == '/';
        const content = if (closing) std.mem.trimLeft(u8, inside[1..], " \t\r\n") else inside;
        var tag_end: usize = 0;
        while (tag_end < content.len and !std.ascii.isWhitespace(content[tag_end]) and content[tag_end] != '/') tag_end += 1;
        const tag = content[0..tag_end];
        if (suppressed) |name| {
            if (closing and std.ascii.eqlIgnoreCase(tag, name)) suppressed = null;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "style") or std.ascii.eqlIgnoreCase(tag, "template")) {
            if (!closing) suppressed = tag;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tag, "title")) { in_title = !closing; continue; }
        if (closing) depth -|= 1 else if (!std.ascii.eqlIgnoreCase(tag, "br") and !std.ascii.eqlIgnoreCase(tag, "img") and !std.ascii.eqlIgnoreCase(tag, "meta") and !std.ascii.eqlIgnoreCase(tag, "link") and !std.mem.endsWith(u8, inside, "/")) {
            depth = try std.math.add(u32, depth, 1);
            if (depth > maximum_depth) return error.HtmlDepthExceeded;
        }
        if (block(tag)) {
            try boundary(&text);
            if (text.items.len > paragraph_start) try paragraphs.append(.{ .start = paragraph_start, .end = text.items.len, .depth = depth, .element = try allocator.dupe(u8, tag) });
            paragraph_start = text.items.len;
        }
        if (closing) continue;
        var attributes = Attributes{ .text = content[tag_end..] };
        var href: ?[]const u8 = null;
        var relation: ?[]const u8 = null;
        while (attributes.next()) |attribute| {
            if (std.ascii.eqlIgnoreCase(attribute.name, "href")) href = attribute.value;
            if (std.ascii.eqlIgnoreCase(attribute.name, "rel")) relation = attribute.value;
            if (std.ascii.eqlIgnoreCase(tag, "html") and std.ascii.eqlIgnoreCase(attribute.name, "lang")) {
                const replacement = try decoded(allocator, attribute.value);
                allocator.free(language);
                language = replacement;
            }
        }
        if (href) |url| {
            if (std.ascii.eqlIgnoreCase(tag, "a")) try links.append(.{ .url = try decoded(allocator, url), .start = text.items.len });
            if (std.ascii.eqlIgnoreCase(tag, "link") and relation != null and std.ascii.eqlIgnoreCase(relation.?, "canonical")) canonical = try decoded(allocator, url);
        }
    }
    try boundary(&text);
    if (text.items.len > paragraph_start) try paragraphs.append(.{ .start = paragraph_start, .end = text.items.len, .depth = depth, .element = try allocator.dupe(u8, "body") });
    return .{ .title = try title.toOwnedSlice(), .text = try text.toOwnedSlice(), .language = language, .canonical = canonical, .links = try links.toOwnedSlice(), .paragraphs = try paragraphs.toOwnedSlice() };
}
