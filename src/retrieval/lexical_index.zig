const std = @import("std");
const hashing = @import("../util/hashing.zig");
const text = @import("../ingestion/text_normalizer.zig");
const bm25 = @import("bm25.zig");

pub const IndexError = error{
    CorruptIndex,
    VersionMismatch,
    TermNotFound,
    InvalidBlock,
};

pub const block_size: usize = 128;
pub const version: u32 = 1;

pub const FieldMask = enum(u8) {
    body = 1 << 0,
    title = 1 << 1,
    heading = 1 << 2,
    anchor = 1 << 3,
    url = 1 << 4,
    metadata = 1 << 5,
};

pub const Posting = struct {
    document_id: u64,
    term_frequency: u16,
    field_mask: u8,
    positions: []u32,
};

pub const BlockStats = struct {
    maximum_score: f32,
    maximum_document_id: u64,
    length: usize,
};

pub const TermPostings = struct {
    term: []const u8,
    document_frequency: u32,
    collection_frequency: u64,
    postings: []Posting,
    blocks: []BlockStats,
    allocator: std.mem.Allocator,

    pub fn release(self: *TermPostings) void {
        for (self.postings) |posting| self.allocator.free(posting.positions);
        self.allocator.free(self.postings);
        self.allocator.free(self.blocks);
        self.allocator.free(self.term);
    }
};

pub const DocumentLengths = struct {
    lengths: []u32,
    total: u64,
    count: usize,
};

pub const LexicalIndex = struct {
    allocator: std.mem.Allocator,
    terms: std.StringHashMap(TermPostings),
    lengths: std.AutoHashMapUnmanaged(u64, u32),
    field_lengths: std.AutoHashMapUnmanaged(u64, u32),
    document_count: usize = 0,
    total_length: u64 = 0,
    k1: f64 = 1.2,
    b: f64 = 0.75,
    title_boost: f64 = 4.0,
    heading_boost: f64 = 2.0,
    anchor_boost: f64 = 2.5,
    url_boost: f64 = 1.5,
    additions: u64 = 0,
    queries: u64 = 0,
    postings_scored: u64 = 0,
    blocks_skipped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) LexicalIndex {
        return .{
            .allocator = allocator,
            .terms = std.StringHashMap(TermPostings).init(allocator),
            .lengths = .{},
            .field_lengths = .{},
        };
    }

    pub fn deinit(self: *LexicalIndex) void {
        var iterator = self.terms.iterator();
        while (iterator.next()) |entry| {
            var postings = entry.value_ptr;
            postings.release();
        }
        self.terms.deinit();
        self.lengths.deinit(self.allocator);
        self.field_lengths.deinit(self.allocator);
    }

    pub fn addDocument(self: *LexicalIndex, document_id: u64, sections: []const []const text.TermFrequency, field_ids: []const u8) !void {
        var document_length: u32 = 0;
        for (sections, 0..) |section_terms, section_index| {
            const field = if (section_index < field_ids.len) field_ids[section_index] else @as(u8, @intFromEnum(FieldMask.body));
            for (section_terms) |frequency| document_length += frequency.count;
            for (section_terms) |frequency| {
                const entry = try self.terms.getOrPut(frequency.term);
                if (!entry.found_existing) {
                    const owned = try self.allocator.dupe(u8, frequency.term);
                    entry.key_ptr.* = owned;
                    entry.value_ptr.* = .{
                        .term = owned,
                        .document_frequency = 0,
                        .collection_frequency = 0,
                        .postings = &.{},
                        .blocks = &.{},
                        .allocator = self.allocator,
                    };
                }
                const target = entry.value_ptr;
                var existing: ?usize = null;
                for (target.postings, 0..) |posting, index| {
                    if (posting.document_id == document_id) {
                        existing = index;
                        break;
                    }
                }
                if (existing) |index| {
                    const merged: u32 = @as(u32, target.postings[index].term_frequency) + frequency.count;
                    target.postings[index].term_frequency = @intCast(@min(merged, std.math.maxInt(u16)));
                    target.postings[index].field_mask |= field;
                } else {
                    var postings = try self.allocator.realloc(target.postings, target.postings.len + 1);
                    postings[postings.len - 1] = .{
                        .document_id = document_id,
                        .term_frequency = @intCast(@min(frequency.count, std.math.maxInt(u16))),
                        .field_mask = field,
                        .positions = &.{},
                    };
                    target.postings = postings;
                    target.document_frequency += 1;
                }
                target.collection_frequency += frequency.count;
            }
        }
        const previous = self.lengths.get(document_id) orelse 0;
        try self.lengths.put(self.allocator, document_id, previous + document_length);
        self.total_length += document_length;
        if (previous == 0) self.document_count += 1;
        self.additions += 1;
    }

    pub fn setLength(self: *LexicalIndex, document_id: u64, length: u32, field_length: u32) !void {
        const previous = self.lengths.get(document_id) orelse 0;
        try self.lengths.put(self.allocator, document_id, length);
        try self.field_lengths.put(self.allocator, document_id, field_length);
        self.total_length = self.total_length - previous + length;
        if (previous == 0) self.document_count += 1;
    }

    pub fn averageLength(self: *const LexicalIndex) f64 {
        if (self.document_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_length)) / @as(f64, @floatFromInt(self.document_count));
    }

    pub fn termCount(self: *const LexicalIndex) usize {
        return self.terms.count();
    }

    pub fn documentFrequency(self: *const LexicalIndex, term: []const u8) u32 {
        const entry = self.terms.get(term) orelse return 0;
        return entry.document_frequency;
    }

    pub fn postingsFor(self: *const LexicalIndex, term: []const u8) ?TermPostings {
        return self.terms.get(term);
    }

    pub fn idf(self: *const LexicalIndex, document_frequency: u32) f64 {
        const n = @as(f64, @floatFromInt(@max(1, self.document_count)));
        const df = @as(f64, @floatFromInt(@max(1, document_frequency)));
        return @log(1.0 + (n - df + 0.5) / (df + 0.5));
    }

    pub const ScoredDocument = struct {
        document_id: u64,
        score: f64,
        matched_terms: u32,
    };

    pub fn scoreTerm(self: *LexicalIndex, term: []const u8, limit: usize, minimum_score: f64) ![]ScoredDocument {
        const postings = self.terms.get(term) orelse return &.{};
        const average = self.averageLength();
        const inverse_df = self.idf(postings.document_frequency);
        var results = std.ArrayList(ScoredDocument).init(self.allocator);
        for (postings.postings) |posting| {
            const length = self.lengths.get(posting.document_id) orelse 0;
            const base = bm25.score(
                self.document_count,
                postings.document_frequency,
                @as(f64, @floatFromInt(posting.term_frequency)),
                length,
                average,
                self.k1,
                self.b,
            );
            var boost: f64 = 1.0;
            if (posting.field_mask & @intFromEnum(FieldMask.title) != 0) boost += self.title_boost;
            if (posting.field_mask & @intFromEnum(FieldMask.heading) != 0) boost += self.heading_boost;
            if (posting.field_mask & @intFromEnum(FieldMask.anchor) != 0) boost += self.anchor_boost;
            if (posting.field_mask & @intFromEnum(FieldMask.url) != 0) boost += self.url_boost;
            const score = inverse_df * base * boost;
            self.postings_scored += 1;
            if (score < minimum_score) continue;
            if (results.items.len < limit) {
                try results.append(.{ .document_id = posting.document_id, .score = score, .matched_terms = 1 });
            } else {
                var worst: usize = 0;
                var worst_score: f64 = std.math.inf(f64);
                for (results.items, 0..) |candidate, index| {
                    if (candidate.score < worst_score) {
                        worst_score = candidate.score;
                        worst = index;
                    }
                }
                if (score > worst_score) results.items[worst] = .{ .document_id = posting.document_id, .score = score, .matched_terms = 1 };
            }
        }
        std.sort.block(ScoredDocument, results.items, {}, struct {
            fn gt(_: void, a: ScoredDocument, b: ScoredDocument) bool {
                return a.score > b.score;
            }
        }.gt);
        return results.toOwnedSlice();
    }

    pub fn search(self: *LexicalIndex, allocator: std.mem.Allocator, query: []const u8, limit: usize, minimum_score: f64) ![]ScoredDocument {
        self.queries += 1;
        var scored = std.AutoHashMap(u64, ScoredDocument).init(allocator);
        defer scored.deinit();
        const tokens = try text.tokenize(allocator, query, 0, .{ .enable_stemming = true, .mark_stopwords = true, .language = "" });
        defer tokens.release();
        var unique = std.StringHashMap(void).init(allocator);
        defer unique.deinit();
        for (tokens.tokens) |token| {
            if (token.stopword) continue;
            if (unique.contains(token.stem)) continue;
            try unique.put(token.stem, {});
            const results = try self.scoreTerm(token.stem, limit, minimum_score);
            defer allocator.free(results);
            for (results) |candidate| {
                const entry = try scored.getOrPut(candidate.document_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = candidate;
                } else {
                    entry.value_ptr.score += candidate.score;
                    entry.value_ptr.matched_terms += 1;
                }
            }
        }
        var out = std.ArrayList(ScoredDocument).init(allocator);
        var iterator = scored.valueIterator();
        while (iterator.next()) |candidate| try out.append(candidate.*);
        std.sort.block(ScoredDocument, out.items, {}, struct {
            fn gt(_: void, a: ScoredDocument, b: ScoredDocument) bool {
                if (a.matched_terms != b.matched_terms) return a.matched_terms > b.matched_terms;
                return a.score > b.score;
            }
        }.gt);
        if (out.items.len > limit) out.shrinkRetainingCapacity(limit);
        return out.toOwnedSlice();
    }

    pub const TermKey = struct {
        hash: u64,
    };

    pub fn termKey(term: []const u8) u64 {
        return hashing.hash64(0x9E3779B97F4A7C15, term);
    }

    pub fn stats(self: *const LexicalIndex) LexicalStats {
        var postings_total: u64 = 0;
        var iterator = self.terms.valueIterator();
        while (iterator.next()) |postings| postings_total += @intCast(postings.postings.len);
        return .{
            .terms = self.terms.count(),
            .documents = self.document_count,
            .postings = postings_total,
            .average_length = self.averageLength(),
            .queries = self.queries,
            .postings_scored = self.postings_scored,
            .blocks_skipped = self.blocks_skipped,
        };
    }
};

pub const LexicalStats = struct {
    terms: usize,
    documents: usize,
    postings: u64,
    average_length: f64,
    queries: u64,
    postings_scored: u64,
    blocks_skipped: u64,
};
