const std = @import("std");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");
const text = @import("text_normalizer.zig");

pub const FieldId = enum(u8) {
    title = 0,
    heading = 1,
    body = 2,
    anchor = 3,
    url = 4,
    metadata = 5,
    table = 6,
    list = 7,
};

pub const field_weights = [8]f32{ 6.0, 3.0, 1.0, 2.5, 2.0, 1.5, 1.2, 1.0 };

pub const Section = struct {
    field: FieldId,
    text: []const u8,
    weight: f32,
    prominence: f32,
    depth: u32,
    heading_path: []u64,
    token_count: u32,
    position: u32,

    pub fn release(self: *Section, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.heading_path);
    }
};

pub const Anchor = struct {
    target: []const u8,
    anchor_text: []const u8,
    nofollow: bool,
    prominence: f32,

    pub fn release(self: *Anchor, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.anchor_text);
    }
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,

    pub fn release(self: *KeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const QualitySignals = struct {
    word_count: u32,
    unique_terms: u32,
    sentence_count: u32,
    heading_count: u32,
    link_count: u32,
    boilerplate_ratio: f32,
    link_density: f32,
    stopword_ratio: f32,
    average_sentence_length: f32,
    term_diversity: f32,
    spam_score: f32,
    quality: f32,
};

pub const BuiltDocument = struct {
    document_id: u64,
    canonical_hash: u64,
    domain_hash: u64,
    content_hash: u64,
    url: []const u8,
    canonical_url: []const u8,
    title: []const u8,
    language: []const u8,
    author: []const u8,
    site_name: []const u8,
    description: []const u8,
    flattened: []const u8,
    sections: []Section,
    anchors: []Anchor,
    metadata: []KeyValue,
    terms: []text.TermFrequency,
    quality: QualitySignals,
    published_at: i64,
    modified_at: i64,
    build_ms: f64,
    allocator: std.mem.Allocator,

    pub fn release(self: *BuiltDocument) void {
        self.allocator.free(self.url);
        self.allocator.free(self.canonical_url);
        self.allocator.free(self.title);
        self.allocator.free(self.language);
        self.allocator.free(self.author);
        self.allocator.free(self.site_name);
        self.allocator.free(self.description);
        self.allocator.free(self.flattened);
        for (self.sections) |*section| section.release(self.allocator);
        self.allocator.free(self.sections);
        for (self.anchors) |*anchor| anchor.release(self.allocator);
        self.allocator.free(self.anchors);
        for (self.metadata) |*entry| entry.release(self.allocator);
        self.allocator.free(self.metadata);
        text.releaseTermFrequencies(self.allocator, self.terms);
    }

    pub fn fieldText(self: *const BuiltDocument, field: FieldId) ?[]const u8 {
        for (self.sections) |section| {
            if (section.field == field) return section.text;
        }
        return null;
    }
};

pub const Input = struct {
    url: []const u8,
    canonical_url: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    language: []const u8 = "",
    author: []const u8 = "",
    site_name: []const u8 = "",
    body: []const u8 = "",
    headings: []const []const u8 = &.{},
    paragraphs: []const []const u8 = &.{},
    tables: []const []const u8 = &.{},
    links: []const AnchorInput = &.{},
    metadata: []const KeyValue = &.{},
    boilerplate_ratio: f32 = 0.0,
    published_at: i64 = 0,
    modified_at: i64 = 0,
    content_hash: u64 = 0,
    domain_hash: u64 = 0,
};

pub const AnchorInput = struct {
    target: []const u8,
    anchor_text: []const u8,
    nofollow: bool = false,
    prominence: f32 = 0.0,
};

pub const Options = struct {
    enable_stemming: bool = true,
    mark_stopwords: bool = true,
    detect_language: bool = true,
    default_language: []const u8 = "en",
    max_sections: usize = 4096,
    max_terms: usize = 65536,
    min_quality: f32 = 0.05,
    spam_link_density: f32 = 0.75,
    spam_boilerplate: f32 = 0.9,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    built: u64 = 0,
    rejected: u64 = 0,
    total_ms: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Builder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn build(self: *Builder, document_id: u64, input: Input) !BuiltDocument {
        const started = time.StopWatch.start();
        var sections = std.ArrayList(Section).init(self.allocator);
        errdefer {
            for (sections.items) |*section| section.release(self.allocator);
            sections.deinit();
        }
        const language = if (self.options.detect_language and input.language.len == 0)
            try self.allocator.dupe(u8, text.detectLanguage(input.body))
        else if (input.language.len > 0)
            try self.allocator.dupe(u8, input.language)
        else
            try self.allocator.dupe(u8, self.options.default_language);
        errdefer self.allocator.free(language);
        const normalize_options = text.Options{ .enable_stemming = self.options.enable_stemming, .mark_stopwords = self.options.mark_stopwords, .language = language };

        if (input.title.len > 0) {
            try sections.append(try self.makeSection(.title, input.title, 0, 0, &.{}, normalize_options));
        }
        var heading_hashes = std.ArrayList(u64).init(self.allocator);
        defer heading_hashes.deinit();
        for (input.headings) |heading| {
            if (sections.items.len >= self.options.max_sections) break;
            const hash = hashing.hash64(0x9E3779B97F4A7C15, heading);
            try heading_hashes.append(hash);
            const path = try self.allocator.dupe(u64, heading_hashes.items);
            try sections.append(try self.makeSection(.heading, heading, 0, 0, path, normalize_options));
        }
        var position: u32 = 0;
        for (input.paragraphs) |paragraph| {
            if (sections.items.len >= self.options.max_sections) break;
            position += 1;
            const path = try self.allocator.dupe(u64, heading_hashes.items);
            try sections.append(try self.makeSection(.body, paragraph, 0, position, path, normalize_options));
        }
        for (input.tables) |table| {
            if (sections.items.len >= self.options.max_sections) break;
            const path = try self.allocator.dupe(u64, heading_hashes.items);
            try sections.append(try self.makeSection(.table, table, 0, position, path, normalize_options));
        }
        for (input.links) |link| {
            if (sections.items.len >= self.options.max_sections) break;
            if (link.anchor_text.len == 0) continue;
            const path = try self.allocator.dupe(u64, heading_hashes.items);
            try sections.append(try self.makeSection(.anchor, link.anchor_text, link.prominence, 0, path, normalize_options));
        }

        var anchors = std.ArrayList(Anchor).init(self.allocator);
        errdefer anchors.deinit();
        for (input.links) |link| {
            try anchors.append(.{
                .target = try self.allocator.dupe(u8, link.target),
                .anchor_text = try self.allocator.dupe(u8, link.anchor_text),
                .nofollow = link.nofollow,
                .prominence = link.prominence,
            });
        }
        var metadata = std.ArrayList(KeyValue).init(self.allocator);
        errdefer metadata.deinit();
        for (input.metadata) |entry| {
            try metadata.append(.{
                .key = try self.allocator.dupe(u8, entry.key),
                .value = try self.allocator.dupe(u8, entry.value),
            });
        }

        var flattened = std.ArrayList(u8).init(self.allocator);
        errdefer flattened.deinit();
        for (sections.items) |section| {
            if (flattened.items.len > 0) try flattened.append('\n');
            try flattened.appendSlice(section.text);
        }

        var all_tokens = std.ArrayList(text.Token).init(self.allocator);
        defer {
            for (all_tokens.items) |*token| token.release(self.allocator);
            all_tokens.deinit();
        }
        var global_position: u32 = 0;
        for (sections.items, 0..) |section, section_index| {
            const list = try text.tokenize(self.allocator, section.text, @intFromEnum(section.field), normalize_options);
            defer list.release();
            for (list.tokens) |token| {
                try all_tokens.append(.{
                    .text = try self.allocator.dupe(u8, token.text),
                    .stem = try self.allocator.dupe(u8, token.stem),
                    .start = token.start,
                    .end = token.end,
                    .kind = token.kind,
                    .field = token.field,
                    .position = global_position,
                    .sentence = @intCast(section_index),
                    .stopword = token.stopword,
                });
                global_position += 1;
            }
        }
        const terms = try text.termFrequencies(self.allocator, all_tokens.items);
        const trimmed = if (terms.len > self.options.max_terms) terms[0..self.options.max_terms] else terms;

        var stopwords: u32 = 0;
        var word_count: u32 = 0;
        for (all_tokens.items) |token| {
            if (token.kind != .word) continue;
            word_count += 1;
            if (token.stopword) stopwords += 1;
        }
        const sentence_list = try text.sentences(self.allocator, input.body);
        defer text.releaseStrings(self.allocator, sentence_list);
        var unique: usize = 0;
        for (trimmed) |term| {
            if (term.count == 1) unique += 1;
        }
        const anchor_bytes: usize = blk: {
            var total: usize = 0;
            for (input.links) |link| total += link.anchor_text.len;
            break :blk total;
        };
        const body_bytes: usize = input.body.len;
        const link_density: f32 = if (body_bytes > 0) @as(f32, @floatFromInt(anchor_bytes)) / @as(f32, @floatFromInt(body_bytes)) else 0.0;
        const stopword_ratio: f32 = if (word_count > 0) @as(f32, @floatFromInt(stopwords)) / @as(f32, @floatFromInt(word_count)) else 0.0;
        const average_sentence_length: f32 = if (sentence_list.len > 0) @as(f32, @floatFromInt(word_count)) / @as(f32, @floatFromInt(sentence_list.len)) else 0.0;
        const term_diversity: f32 = if (trimmed.len > 0) @as(f32, @floatFromInt(unique)) / @as(f32, @floatFromInt(trimmed.len)) else 0.0;
        var spam_score: f32 = 0.0;
        if (link_density > self.options.spam_link_density) spam_score += 0.4;
        if (input.boilerplate_ratio > self.options.spam_boilerplate) spam_score += 0.3;
        if (word_count > 0 and word_count < 40) spam_score += 0.2;
        if (term_diversity < 0.2 and word_count > 200) spam_score += 0.2;
        if (stopword_ratio > 0.75 and word_count > 100) spam_score += 0.1;
        spam_score = @min(1.0, spam_score);
        const length_score = @min(1.0, @log(1.0 + @as(f32, @floatFromInt(word_count))) / 6.0);
        const quality: f32 = @max(0.0, @min(1.0, 0.45 * length_score + 0.25 * (1.0 - @min(1.0, spam_score)) + 0.15 * (1.0 - @min(1.0, link_density)) + 0.15 * term_diversity));

        const content_hash = if (input.content_hash != 0) input.content_hash else hashing.hash64(0xC2B2AE3D27D4EB4F, flattened.items);
        const canonical_url = if (input.canonical_url.len > 0) input.canonical_url else input.url;
        const elapsed = started.elapsedMs();
        self.built += 1;
        self.total_ms += elapsed;
        return .{
            .document_id = document_id,
            .canonical_hash = hashing.hash64(0x9E3779B97F4A7C15, canonical_url),
            .domain_hash = input.domain_hash,
            .content_hash = content_hash,
            .url = try self.allocator.dupe(u8, input.url),
            .canonical_url = try self.allocator.dupe(u8, canonical_url),
            .title = try self.allocator.dupe(u8, input.title),
            .language = language,
            .author = try self.allocator.dupe(u8, input.author),
            .site_name = try self.allocator.dupe(u8, input.site_name),
            .description = try self.allocator.dupe(u8, input.description),
            .flattened = try flattened.toOwnedSlice(),
            .sections = try sections.toOwnedSlice(),
            .anchors = try anchors.toOwnedSlice(),
            .metadata = try metadata.toOwnedSlice(),
            .terms = trimmed,
            .quality = .{
                .word_count = word_count,
                .unique_terms = @intCast(trimmed.len),
                .sentence_count = @intCast(sentence_list.len),
                .heading_count = @intCast(input.headings.len),
                .link_count = @intCast(input.links.len),
                .boilerplate_ratio = input.boilerplate_ratio,
                .link_density = link_density,
                .stopword_ratio = stopword_ratio,
                .average_sentence_length = average_sentence_length,
                .term_diversity = term_diversity,
                .spam_score = spam_score,
                .quality = quality,
            },
            .published_at = input.published_at,
            .modified_at = input.modified_at,
            .build_ms = elapsed,
            .allocator = self.allocator,
        };
    }

    fn makeSection(self: *Builder, field: FieldId, raw: []const u8, prominence: f32, position: u32, path: []u64, options: text.Options) !Section {
        const normalized = try text.canonicalText(self.allocator, raw, .{ .enable_stemming = options.enable_stemming, .mark_stopwords = options.mark_stopwords, .language = options.language });
        defer self.allocator.free(normalized);
        const list = try text.tokenize(self.allocator, normalized, @intFromEnum(field), options);
        defer list.release();
        var weight = field_weights[@intFromEnum(field)];
        if (prominence > 0.0) weight += @min(3.0, prominence * 0.25);
        return .{
            .field = field,
            .text = try self.allocator.dupe(u8, normalized),
            .weight = weight,
            .prominence = prominence,
            .depth = 0,
            .heading_path = path,
            .token_count = @intCast(list.tokens.len),
            .position = position,
        };
    }

    pub fn averageBuildMs(self: *const Builder) f64 {
        if (self.built == 0) return 0.0;
        return self.total_ms / @as(f64, @floatFromInt(self.built));
    }
};
