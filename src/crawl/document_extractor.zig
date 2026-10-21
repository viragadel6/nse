const std = @import("std");
const parser = @import("html_parser.zig");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");

pub const ExtractError = error{
    EmptyDocument,
    NodeLimitExceeded,
    InvalidBaseUrl,
};

pub const ElementType = enum(u8) {
    root,
    document,
    head,
    body,
    title,
    metadata,
    script,
    style,
    heading,
    paragraph,
    list,
    list_item,
    table,
    table_row,
    table_cell,
    anchor,
    emphasis,
    strong,
    division,
    span,
    section,
    article,
    navigation,
    footer,
    header,
    aside,
    form,
    image,
    code,
    preformatted,
    blockquote,
    label,
    other,
};

fn classifyTag(name: []const u8) ElementType {
    if (name.len == 0) return .other;
    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') return .heading;
    const map = .{
        .{ "html", ElementType.document },
        .{ "head", ElementType.head },
        .{ "body", ElementType.body },
        .{ "title", ElementType.title },
        .{ "meta", ElementType.metadata },
        .{ "script", ElementType.script },
        .{ "style", ElementType.style },
        .{ "p", ElementType.paragraph },
        .{ "ul", ElementType.list },
        .{ "ol", ElementType.list },
        .{ "li", ElementType.list_item },
        .{ "table", ElementType.table },
        .{ "tr", ElementType.table_row },
        .{ "td", ElementType.table_cell },
        .{ "th", ElementType.table_cell },
        .{ "a", ElementType.anchor },
        .{ "em", ElementType.emphasis },
        .{ "i", ElementType.emphasis },
        .{ "strong", ElementType.strong },
        .{ "b", ElementType.strong },
        .{ "div", ElementType.division },
        .{ "span", ElementType.span },
        .{ "section", ElementType.section },
        .{ "article", ElementType.article },
        .{ "nav", ElementType.navigation },
        .{ "footer", ElementType.footer },
        .{ "header", ElementType.header },
        .{ "aside", ElementType.aside },
        .{ "form", ElementType.form },
        .{ "img", ElementType.image },
        .{ "code", ElementType.code },
        .{ "pre", ElementType.preformatted },
        .{ "blockquote", ElementType.blockquote },
        .{ "label", ElementType.label },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return .other;
}

pub const Span = struct {
    text: []const u8,
    start_offset: usize,
    end_offset: usize,
    element: ElementType,
    depth: u32,
    heading_path: []u64,
    heading_level: u8,
    css_prominence: f32,
    paragraph_index: u32,
    position_ratio: f32,
    link_context: []const u8,
    is_anchor_text: bool,
    token_count: u32,
    block_score: f32,

    pub fn release(self: Span, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.heading_path);
        if (self.link_context.len > 0) allocator.free(self.link_context);
    }
};

pub const Heading = struct {
    level: u8,
    text: []const u8,
    hash: u64,
    offset: usize,
};

pub const Link = struct {
    target: []const u8,
    anchor_text: []const u8,
    rel: []const u8,
    start_offset: usize,
    depth: u32,
    heading_level: u8,
    css_prominence: f32,
    nofollow: bool,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const ExtractedDocument = struct {
    canonical_url: []const u8,
    title: []const u8,
    description: []const u8,
    language: []const u8,
    author: []const u8,
    site_name: []const u8,
    generator: []const u8,
    published_ms: i64,
    modified_ms: i64,
    text: []const u8,
    spans: []Span,
    headings: []Heading,
    links: []Link,
    metadata: []KeyValue,
    structured_data: []const u8,
    token_count: u32,
    dom_nodes: u32,
    max_depth: u32,
    boilerplate_ratio: f32,
    link_density: f32,
    main_content_offset: usize,

    pub fn release(self: ExtractedDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.language);
        allocator.free(self.author);
        allocator.free(self.site_name);
        allocator.free(self.generator);
        allocator.free(self.text);
        allocator.free(self.structured_data);
        for (self.spans) |span| span.release(allocator);
        allocator.free(self.spans);
        for (self.headings) |heading| allocator.free(heading.text);
        allocator.free(self.headings);
        for (self.links) |link| {
            allocator.free(link.target);
            allocator.free(link.anchor_text);
            allocator.free(link.rel);
        }
        allocator.free(self.links);
        for (self.metadata) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(self.metadata);
    }
};

const OpenElement = struct {
    name: []const u8,
    element: ElementType,
    depth: u32,
    heading_level: u8,
    css_prominence: f32,
    link_target: []const u8,
    rel: []const u8,
    nofollow: bool,
    text: std.ArrayListUnmanaged(u8) = .{},
    link_bytes: usize = 0,
    start_offset: usize,
};

const Context = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(OpenElement),
    spans: std.ArrayList(Span),
    headings: std.ArrayList(Heading),
    links: std.ArrayList(Link),
    metadata: std.ArrayList(KeyValue),
    heading_path: std.ArrayList(u64),
    title: []const u8,
    description: []const u8,
    language: []const u8,
    author: []const u8,
    site_name: []const u8,
    generator: []const u8,
    canonical: []const u8,
    published_ms: i64,
    modified_ms: i64,
    structured: std.ArrayList(u8),
    paragraph_index: u32,
    dom_nodes: u32,
    max_depth: u32,
    total_text_bytes: usize,
    anchor_text_bytes: usize,
    max_nodes: u32,
    body_started: bool,
};

pub const Options = struct {
    max_nodes: u32 = 200000,
    max_depth: u32 = 512,
    max_text_bytes: usize = 4194304,
    collect_structured_data: bool = true,
    base_url: []const u8 = "",
};

pub const Extractor = struct {
    allocator: std.mem.Allocator,
    options: Options,
    parser: parser.Parser,

    pub fn init(allocator: std.mem.Allocator, options: Options) Extractor {
        return .{
            .allocator = allocator,
            .options = options,
            .parser = parser.Parser.init(allocator, .{ .max_depth = options.max_depth, .max_nodes = options.max_nodes }),
        };
    }

    pub fn deinit(self: *Extractor) void {
        self.parser.deinit();
    }

    pub fn extract(self: *Extractor, html: []const u8) !ExtractedDocument {
        var context = Context{
            .allocator = self.allocator,
            .stack = std.ArrayList(OpenElement).init(self.allocator),
            .spans = std.ArrayList(Span).init(self.allocator),
            .headings = std.ArrayList(Heading).init(self.allocator),
            .links = std.ArrayList(Link).init(self.allocator),
            .metadata = std.ArrayList(KeyValue).init(self.allocator),
            .heading_path = std.ArrayList(u64).init(self.allocator),
            .title = "",
            .description = "",
            .language = "",
            .author = "",
            .site_name = "",
            .generator = "",
            .canonical = "",
            .published_ms = 0,
            .modified_ms = 0,
            .structured = std.ArrayList(u8).init(self.allocator),
            .paragraph_index = 0,
            .dom_nodes = 0,
            .max_depth = 0,
            .total_text_bytes = 0,
            .anchor_text_bytes = 0,
            .max_nodes = self.options.max_nodes,
            .body_started = false,
        };
        defer {
            for (context.stack.items) |*element| {
                self.allocator.free(element.name);
                element.text.deinit(self.allocator);
                if (element.link_target.len > 0) self.allocator.free(element.link_target);
                if (element.rel.len > 0) self.allocator.free(element.rel);
            }
            context.stack.deinit();
            context.heading_path.deinit();
            context.structured.deinit();
        }
        self.parser.reset();
        try self.parser.parse(html, &context, visitor);
        try finalizeOpenElements(self.allocator, &context);
        if (context.spans.items.len == 0 and context.title.len == 0) return ExtractError.EmptyDocument;
        std.sort.block(Span, context.spans.items, {}, struct {
            fn lt(_: void, a: Span, b: Span) bool {
                return a.start_offset < b.start_offset;
            }
        }.lt);
        const text = try flattenText(self.allocator, context.spans.items, self.options.max_text_bytes);
        var main_offset: usize = 0;
        var best_score: f32 = -1.0;
        for (context.spans.items) |span| {
            if (span.block_score > best_score) {
                best_score = span.block_score;
                main_offset = span.start_offset;
            }
        }
        var boilerplate: usize = 0;
        var total: usize = 0;
        for (context.spans.items) |span| {
            total += span.text.len;
            if (span.element == .navigation or span.element == .footer or span.element == .aside) boilerplate += span.text.len;
        }
        return .{
            .canonical_url = try self.allocator.dupe(u8, if (context.canonical.len > 0) context.canonical else self.options.base_url),
            .title = try self.allocator.dupe(u8, context.title),
            .description = try self.allocator.dupe(u8, context.description),
            .language = try self.allocator.dupe(u8, context.language),
            .author = try self.allocator.dupe(u8, context.author),
            .site_name = try self.allocator.dupe(u8, context.site_name),
            .generator = try self.allocator.dupe(u8, context.generator),
            .published_ms = context.published_ms,
            .modified_ms = context.modified_ms,
            .text = text,
            .spans = try context.spans.toOwnedSlice(),
            .headings = try context.headings.toOwnedSlice(),
            .links = try context.links.toOwnedSlice(),
            .metadata = try context.metadata.toOwnedSlice(),
            .structured_data = try context.structured.toOwnedSlice(),
            .token_count = @intCast(@divFloor(context.total_text_bytes + 4, 5)),
            .dom_nodes = context.dom_nodes,
            .max_depth = context.max_depth,
            .boilerplate_ratio = if (total > 0) @as(f32, @floatFromInt(boilerplate)) / @as(f32, @floatFromInt(total)) else 0.0,
            .link_density = if (total > 0) @as(f32, @floatFromInt(context.anchor_text_bytes)) / @as(f32, @floatFromInt(total)) else 0.0,
            .main_content_offset = main_offset,
        };
    }
};

fn flattenText(allocator: std.mem.Allocator, spans: []Span, limit: usize) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (spans) |span| {
        if (out.items.len + span.text.len + 2 > limit) break;
        if (out.items.len > 0) try out.append('\n');
        try out.appendSlice(span.text);
    }
    return out.toOwnedSlice();
}

fn finalizeOpenElements(allocator: std.mem.Allocator, context: *Context) !void {
    while (context.stack.items.len > 0) {
        try closeElement(allocator, context);
    }
}

fn closeElement(allocator: std.mem.Allocator, context: *Context) !void {
    if (context.stack.items.len == 0) return;
    const element = context.stack.pop() orelse return;
    var mutable_element = element;
    defer {
        allocator.free(mutable_element.name);
        mutable_element.text.deinit(allocator);
        if (mutable_element.link_target.len > 0) allocator.free(mutable_element.link_target);
        if (mutable_element.rel.len > 0) allocator.free(mutable_element.rel);
    }
    const text = std.mem.trim(u8, mutable_element.text.items, " \t\r\n");
    if (text.len == 0) return;
    if (element.element == .title and context.title.len == 0) {
        context.title = try allocator.dupe(u8, text);
        return;
    }
    if (element.element == .script) return;
    if (element.element == .style) return;
    if (element.element == .anchor and element.link_target.len > 0) {
        try context.links.append(.{
            .target = try allocator.dupe(u8, element.link_target),
            .anchor_text = try allocator.dupe(u8, text),
            .rel = try allocator.dupe(u8, element.rel),
            .start_offset = element.start_offset,
            .depth = element.depth,
            .heading_level = element.heading_level,
            .css_prominence = element.css_prominence,
            .nofollow = element.nofollow,
        });
        return;
    }
    const is_block = switch (element.element) {
        .paragraph, .heading, .list_item, .table_cell, .blockquote, .preformatted, .division, .section, .article, .span, .navigation, .footer, .aside, .header => true,
        else => false,
    };
    if (!is_block) return;
    if (element.element == .heading) {
        const heading_hash = hashing.hash64(0x9E3779B97F4A7C15, text);
        try context.headings.append(.{
            .level = element.heading_level,
            .text = try allocator.dupe(u8, text),
            .hash = heading_hash,
            .offset = element.start_offset,
        });
        while (context.heading_path.items.len >= 8) _ = context.heading_path.orderedRemove(0);
        try context.heading_path.append(heading_hash);
    }
    context.paragraph_index += 1;
    const stored_text = try allocator.dupe(u8, text);
    errdefer allocator.free(stored_text);
    const heading_path = try context.allocator.dupe(u64, context.heading_path.items);
    errdefer allocator.free(heading_path);
    const link_context = if (element.link_target.len > 0) try allocator.dupe(u8, element.link_target) else "";
    const token_count: u32 = @intCast(@divFloor(text.len + 4, 5));
    const link_ratio = if (text.len > 0) @as(f32, @floatFromInt(element.link_bytes)) / @as(f32, @floatFromInt(text.len)) else 0.0;
    const negative_penalty: f32 = switch (element.element) {
        .navigation, .footer, .aside => 1.0,
        else => 0.0,
    };
    const length_score = @log(1.0 + @as(f32, @floatFromInt(text.len)));
    const block_score = length_score * (1.0 - link_ratio) - negative_penalty * 4.0 + element.css_prominence;
    try context.spans.append(.{
        .text = stored_text,
        .start_offset = element.start_offset,
        .end_offset = element.start_offset + text.len,
        .element = element.element,
        .depth = element.depth,
        .heading_path = heading_path,
        .heading_level = element.heading_level,
        .css_prominence = element.css_prominence,
        .paragraph_index = context.paragraph_index - 1,
        .position_ratio = 0.0,
        .link_context = link_context,
        .is_anchor_text = element.link_target.len > 0,
        .token_count = token_count,
        .block_score = block_score,
    });
    context.total_text_bytes += text.len;
    if (context.spans.items.len > 1) {
        const last = context.spans.items[context.spans.items.len - 1];
        const first = context.spans.items[0];
        const span_range = @max(1, last.end_offset - first.start_offset);
        for (context.spans.items) |*span| {
            span.position_ratio = @as(f32, @floatFromInt(span.start_offset - first.start_offset)) / @as(f32, @floatFromInt(span_range));
        }
    }
}

fn cssProminence(attributes: []const parser.Attribute, element: ElementType, heading_level: u8) f32 {
    var score: f32 = 0.0;
    if (heading_level > 0) score += @as(f32, @floatFromInt(7 - @min(heading_level, 6)));
    if (parser.attributeValue(attributes, "style")) |style| {
        if (std.ascii.indexOfIgnoreCase(style, "bold") != null) score += 1.0;
        if (std.ascii.indexOfIgnoreCase(style, "font-weight:700") != null) score += 1.0;
        if (std.ascii.indexOfIgnoreCase(style, "text-transform:uppercase") != null) score += 0.5;
        if (std.mem.indexOf(u8, style, "font-size")) |position| {
            const tail = style[position..];
            const colon = std.mem.indexOfScalar(u8, tail, ':') orelse 0;
            const digits_start = colon + 1;
            var end = digits_start;
            while (end < tail.len and !std.ascii.isDigit(tail[end]) and tail[end] != '.') end += 1;
            var digit_end = end;
            while (digit_end < tail.len and (std.ascii.isDigit(tail[digit_end]) or tail[digit_end] == '.')) digit_end += 1;
            if (digit_end > end) {
                const size = std.fmt.parseFloat(f32, tail[end..digit_end]) catch 0.0;
                if (size >= 24.0) score += 3.0;
                if (size >= 18.0 and size < 24.0) score += 1.5;
                if (size > 0.0 and size <= 10.0) score -= 1.0;
            }
        }
    }
    if (parser.attributeValue(attributes, "class")) |class_name| {
        if (std.ascii.indexOfIgnoreCase(class_name, "title") != null) score += 2.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "headline") != null) score += 2.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "lead") != null) score += 1.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "content") != null) score += 0.5;
        if (std.ascii.indexOfIgnoreCase(class_name, "sidebar") != null) score -= 2.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "footer") != null) score -= 2.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "nav") != null) score -= 2.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "ad") != null) score -= 3.0;
        if (std.ascii.indexOfIgnoreCase(class_name, "comment") != null) score -= 1.5;
    }
    if (element == .strong) score += 0.5;
    if (element == .emphasis) score += 0.2;
    return @max(-5.0, @min(10.0, score));
}

fn headingLevelOf(name: []const u8) u8 {
    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') return name[1] - '0';
    return 0;
}

fn visitor(raw_context: *anyopaque, event: parser.Event) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    switch (event.kind) {
        .start_tag, .self_closing => {
            context.dom_nodes += 1;
            if (event.depth > context.max_depth) context.max_depth = event.depth;
            if (context.dom_nodes > context.max_nodes) return ExtractError.NodeLimitExceeded;
            const element_type = classifyTag(event.name);
            const level = headingLevelOf(event.name);
            const prominence = cssProminence(event.attributes, element_type, level);
            if (element_type == .metadata) {
                try handleMeta(context, event);
            }
            if (std.ascii.eqlIgnoreCase(event.name, "html")) {
                if (parser.attributeValue(event.attributes, "lang")) |lang| {
                    if (context.language.len == 0) context.language = try context.allocator.dupe(u8, lang);
                }
            }
            if (std.ascii.eqlIgnoreCase(event.name, "body")) context.body_started = true;
            var link_target: []const u8 = "";
            if (element_type == .anchor) {
                if (parser.attributeValue(event.attributes, "href")) |href| link_target = try context.allocator.dupe(u8, href);
            }
            var rel: []const u8 = "";
            if (parser.attributeValue(event.attributes, "rel")) |rel_value| rel = try context.allocator.dupe(u8, rel_value);
            const nofollow = rel.len > 0 and std.ascii.indexOfIgnoreCase(rel, "nofollow") != null;
            try context.stack.append(.{
                .name = try context.allocator.dupe(u8, event.name),
                .element = element_type,
                .depth = event.depth,
                .heading_level = level,
                .css_prominence = prominence,
                .link_target = link_target,
                .rel = rel,
                .nofollow = nofollow,
                .start_offset = event.offset,
            });
            if (event.kind == .self_closing) {
                try closeElement(context.allocator, context);
            }
        },
        .end_tag => {
            try closeElement(context.allocator, context);
        },
        .text => {
            if (context.stack.items.len == 0) return;
            const top = &context.stack.items[context.stack.items.len - 1];
            if (top.element == .script or top.element == .style) return;
            if (context.total_text_bytes > 4194304) return;
            try top.text.appendSlice(context.allocator, event.text);
            try top.text.append(context.allocator, ' ');
            context.total_text_bytes += event.text.len;
            if (top.link_target.len > 0) {
                top.link_bytes += event.text.len;
                context.anchor_text_bytes += event.text.len;
            }
        },
        .script_content => {
            if (!context.body_started) return;
            if (std.mem.indexOf(u8, event.text, "application/ld+json") != null or std.mem.indexOf(u8, event.text, "\"@context\"") != null) {
                try context.structured.appendSlice(event.text);
            }
        },
        .style_content => {},
        else => {},
    }
}

fn handleMeta(context: *Context, event: parser.Event) !void {
    const name = parser.attributeValue(event.attributes, "name") orelse parser.attributeValue(event.attributes, "property") orelse "";
    const content = parser.attributeValue(event.attributes, "content") orelse "";
    if (content.len == 0) return;
    if (std.ascii.eqlIgnoreCase(name, "description") and context.description.len == 0) {
        context.description = try context.allocator.dupe(u8, content);
    } else if (std.ascii.eqlIgnoreCase(name, "author") and context.author.len == 0) {
        context.author = try context.allocator.dupe(u8, content);
    } else if (std.ascii.eqlIgnoreCase(name, "generator") and context.generator.len == 0) {
        context.generator = try context.allocator.dupe(u8, content);
    } else if (std.ascii.eqlIgnoreCase(name, "og:site_name") and context.site_name.len == 0) {
        context.site_name = try context.allocator.dupe(u8, content);
    } else if (std.ascii.eqlIgnoreCase(name, "article:published_time")) {
        context.published_ms = time.parseUtc(content) catch 0;
    } else if (std.ascii.eqlIgnoreCase(name, "article:modified_time")) {
        context.modified_ms = time.parseUtc(content) catch 0;
    } else if (name.len > 0) {
        try context.metadata.append(.{ .key = try context.allocator.dupe(u8, name), .value = try context.allocator.dupe(u8, content) });
    }
    if (parser.attributeValue(event.attributes, "http-equiv")) |equiv| {
        if (std.ascii.eqlIgnoreCase(equiv, "content-language") and context.language.len == 0) {
            context.language = try context.allocator.dupe(u8, content);
        }
    }
}

pub fn linkHashes(allocator: std.mem.Allocator, document: *const ExtractedDocument) ![]u64 {
    const out = try allocator.alloc(u64, document.links.len);
    for (document.links, 0..) |link, index| out[index] = hashing.hash64(0x9E3779B97F4A7C15, link.target);
    return out;
}
