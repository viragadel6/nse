const std = @import("std");
const text = @import("../ingestion/text_normalizer.zig");
const time = @import("../util/time.zig");

pub const feature_count: usize = 32;

pub const FeatureError = error{
    DimensionMismatch,
    EmptyDocument,
};

pub const QuerySignals = struct {
    terms: []const []const u8,
    bigrams: []const []const u8,
    term_count: usize,
    rarest_document_frequency: u32,
    is_question: bool,
    has_operator: bool,
    language: []const u8,
};

pub const DocumentSignals = struct {
    document_id: u64,
    lexical_score: f64,
    dense_score: f64,
    quality: f64,
    spam_score: f64,
    authority: f64,
    freshness_days: f64,
    length: u32,
    title_length: u32,
    link_count: u32,
    inbound_links: u32,
    click_prior: f64,
    matched_terms: u32,
    phrase_distance: ?i64,
    title_terms: []const []const u8,
    body_terms: []const []const u8,
    language: []const u8,
    is_homepage: bool,
    embedding_version: u32,
    model_version: u32,
};

pub const Vector = struct {
    values: [feature_count]f32,

    pub fn init() Vector {
        return .{ .values = @splat(0.0) };
    }

    pub fn set(self: *Vector, index: usize, value: f32) !void {
        if (index >= feature_count) return FeatureError.DimensionMismatch;
        self.values[index] = value;
    }

    pub fn get(self: *const Vector, index: usize) f32 {
        if (index >= feature_count) return 0.0;
        return self.values[index];
    }

    pub fn slice(self: *Vector) []f32 {
        return &self.values;
    }

    pub fn normalize(self: *Vector) void {
        var sum: f64 = 0.0;
        for (self.values) |value| sum += @as(f64, value) * @as(f64, value);
        if (sum <= 0.0) return;
        const scale: f32 = @floatCast(1.0 / @sqrt(sum));
        for (&self.values) |*value| value.* *= scale;
    }
};

pub fn build(query: QuerySignals, document: DocumentSignals) FeatureError!Vector {
    var vector = Vector.init();
    var matched: usize = 0;
    var title_matched: usize = 0;
    var positions: usize = 0;
    for (query.terms) |term| {
        var in_body = false;
        var in_title = false;
        for (document.body_terms) |candidate| {
            if (std.mem.eql(u8, candidate, term)) in_body = true;
        }
        for (document.title_terms) |candidate| {
            if (std.mem.eql(u8, candidate, term)) in_title = true;
        }
        if (in_body) {
            matched += 1;
            const position = indexOfTerm(document.body_terms, term);
            if (position) |found| positions += found;
        }
        if (in_title) title_matched += 1;
    }
    const term_total: usize = @max(1, query.term_count);
    const coverage = @as(f32, @floatFromInt(matched)) / @as(f32, @floatFromInt(term_total));
    const title_coverage = @as(f32, @floatFromInt(title_matched)) / @as(f32, @floatFromInt(term_total));
    const bigram_hits = countBigramHits(document.body_terms, query.bigrams);
    const average_position = @as(f32, @floatFromInt(positions)) / @as(f32, @floatFromInt(@max(1, matched)));

    try vector.set(0, @floatCast(document.lexical_score));
    try vector.set(1, @floatCast(document.dense_score));
    try vector.set(2, @floatCast(document.quality));
    try vector.set(3, @floatCast(document.spam_score));
    try vector.set(4, @floatCast(document.authority));
    try vector.set(5, @floatCast(@log(1.0 + @as(f64, @floatFromInt(document.inbound_links)))));
    try vector.set(6, @floatCast(1.0 / (1.0 + @log(1.0 + document.freshness_days))));
    try vector.set(7, @floatCast(@log(1.0 + @as(f64, @floatFromInt(document.length)))));
    try vector.set(8, coverage);
    try vector.set(9, title_coverage);
    try vector.set(10, @floatCast(@as(f64, @floatFromInt(bigram_hits)) / @as(f64, @floatFromInt(@max(1, query.bigrams.len)))));
    try vector.set(11, @floatCast(1.0 / (1.0 + @as(f64, average_position))));
    try vector.set(12, @floatCast(document.click_prior));
    try vector.set(13, @floatCast(@as(f64, @floatFromInt(document.matched_terms)) / @as(f64, @floatFromInt(term_total))));
    try vector.set(14, @floatCast(@as(f64, if (document.phrase_distance) |distance| 1.0 / (1.0 + @log(1.0 + @as(f64, @floatFromInt(@abs(distance))))) else 0.0)));
    try vector.set(15, @floatCast(@as(f64, if (document.is_homepage) 1.0 else 0.0)));
    try vector.set(16, @floatCast(@log(1.0 + @as(f64, @floatFromInt(document.title_length)))));
    try vector.set(17, @floatCast(@log(1.0 + @as(f64, @floatFromInt(document.link_count)))));
    try vector.set(18, @floatCast(1.0 / (1.0 + @log(1.0 + @as(f64, @floatFromInt(query.rarest_document_frequency))))));
    try vector.set(19, @floatCast(@as(f64, if (query.is_question) 1.0 else 0.0)));
    try vector.set(20, @floatCast(@as(f64, if (query.has_operator) 1.0 else 0.0)));
    try vector.set(21, @floatCast(@as(f64, if (std.mem.eql(u8, query.language, document.language)) 1.0 else 0.0)));
    try vector.set(22, @floatCast(@as(f64, @floatFromInt(document.embedding_version)) / 100.0));
    try vector.set(23, @floatCast(@as(f64, @floatFromInt(document.model_version)) / 100.0));
    try vector.set(24, @floatCast(@sqrt(@as(f64, coverage) * @as(f64, title_coverage))));
    try vector.set(25, @floatCast(@as(f64, document.dense_score) * @as(f64, coverage)));
    try vector.set(26, @floatCast(@as(f64, document.lexical_score) * @as(f64, document.quality)));
    try vector.set(27, @floatCast(@as(f64, document.authority) * @as(f64, document.dense_score)));
    try vector.set(28, @floatCast(@as(f64, if (document.length > 0 and document.length < 300) 1.0 else 0.0)));
    try vector.set(29, @floatCast(@as(f64, @floatFromInt(document.length)) / 10000.0));
    try vector.set(30, @floatCast(@as(f64, if (document.spam_score > 0.7) 1.0 else 0.0)));
    try vector.set(31, @floatCast(clamp01(@as(f64, document.quality) - @as(f64, document.spam_score))));
    return vector;
}

fn clamp01(value: f64) f64 {
    return @max(0.0, @min(1.0, value));
}

fn indexOfTerm(terms: []const []const u8, target: []const u8) ?usize {
    for (terms, 0..) |term, index| {
        if (std.mem.eql(u8, term, target)) return index;
    }
    return null;
}

fn countBigramHits(terms: []const []const u8, bigrams: []const []const u8) usize {
    var hits: usize = 0;
    if (terms.len < 2) return 0;
    for (bigrams) |bigram| {
        var cursor: usize = 0;
        while (cursor + 1 < terms.len) : (cursor += 1) {
            const candidate_len = terms[cursor].len + 1 + terms[cursor + 1].len;
            var buffer: [256]u8 = undefined;
            if (candidate_len >= buffer.len) continue;
            @memcpy(buffer[0..terms[cursor].len], terms[cursor]);
            buffer[terms[cursor].len] = ' ';
            @memcpy(buffer[terms[cursor].len + 1 ..][0..terms[cursor + 1].len], terms[cursor + 1]);
            if (std.mem.eql(u8, buffer[0..candidate_len], bigram)) {
                hits += 1;
                break;
            }
        }
    }
    return hits;
}

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    bigram_limit: usize = 8,

    pub fn signalize(self: *Analyzer, allocator: std.mem.Allocator, query: []const u8, rarest_document_frequency: u32) !QuerySignals {
        const tokens = try text.tokenize(allocator, query, 0, .{ .enable_stemming = true, .mark_stopwords = true, .language = "" });
        var terms = std.ArrayList([]const u8).init(allocator);
        for (tokens.tokens) |token| {
            if (token.stopword) continue;
            try terms.append(try allocator.dupe(u8, token.stem));
        }
        var bigrams = std.ArrayList([]const u8).init(allocator);
        if (terms.items.len >= 2) {
            var cursor: usize = 0;
            while (cursor + 1 < terms.items.len and bigrams.items.len < self.bigram_limit) : (cursor += 1) {
                try bigrams.append(try std.fmt.allocPrint(allocator, "{s} {s}", .{ terms.items[cursor], terms.items[cursor + 1] }));
            }
        }
        const term_count: usize = terms.items.len;
        const term_slice = try terms.toOwnedSlice();
        const bigram_slice = try bigrams.toOwnedSlice();
        const is_question = std.mem.indexOfScalar(u8, query, '?') != null or
            startsWithWord(query, "who") or startsWithWord(query, "what") or
            startsWithWord(query, "when") or startsWithWord(query, "where") or
            startsWithWord(query, "why") or startsWithWord(query, "how");
        const has_operator = std.mem.indexOfScalar(u8, query, '"') != null or
            std.mem.indexOfScalar(u8, query, '-') != null or
            containsWord(query, "site:") or containsWord(query, "AND") or containsWord(query, "OR");
        const language = try allocator.dupe(u8, text.detectLanguage(query));
        return .{
            .terms = term_slice,
            .bigrams = bigram_slice,
            .term_count = @intCast(term_count),
            .rarest_document_frequency = rarest_document_frequency,
            .is_question = is_question,
            .has_operator = has_operator,
            .language = language,
        };
    }

    pub fn releaseSignals(allocator: std.mem.Allocator, signals: *QuerySignals) void {
        for (signals.terms) |term| allocator.free(term);
        allocator.free(signals.terms);
        for (signals.bigrams) |bigram| allocator.free(bigram);
        allocator.free(signals.bigrams);
        allocator.free(signals.language);
    }
};

fn startsWithWord(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsWord(value: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, value, needle) != null;
}

pub const freshness_feature_index = 6;

pub fn freshnessDays(published_ms: i64, now_ms: i64) f64 {
    if (published_ms <= 0) return 3650.0;
    const age = now_ms - published_ms;
    if (age <= 0) return 0.0;
    return @as(f64, @floatFromInt(age)) / @as(f64, time.ms_per_day);
}
