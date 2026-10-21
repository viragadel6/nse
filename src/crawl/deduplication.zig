const std = @import("std");
const hashing = @import("../util/hashing.zig");
const bloom = @import("../util/bloom_filter.zig");

pub const signature_width: usize = 128;
pub const band_count: usize = 32;
pub const band_rows: usize = signature_width / band_count;

pub const MinHashSignature = struct {
    values: [signature_width]u32,

    pub fn init(tokens: [][]const u8) MinHashSignature {
        var values: [signature_width]u32 = @splat(std.math.maxInt(u32));
        for (tokens) |token| {
            if (token.len == 0) continue;
            for (0..signature_width) |index| {
                const candidate: u32 = @truncate(hashing.hash64(@as(u64, index) *% 0x9E3779B97F4A7C15 ^ 0x5DEECE66D, token));
                if (candidate < values[index]) values[index] = candidate;
            }
        }
        return .{ .values = values };
    }

    pub fn jaccardEstimate(self: *const MinHashSignature, other: *const MinHashSignature) f64 {
        var matching: usize = 0;
        for (self.values, other.values) |left, right| {
            if (left == right) matching += 1;
        }
        return @as(f64, @floatFromInt(matching)) / @as(f64, @floatFromInt(signature_width));
    }

    pub fn bandHash(self: *const MinHashSignature, band: usize) u64 {
        const start = band * band_rows;
        var digest: u64 = 0x243F6A8885A308D3;
        for (self.values[start .. start + band_rows]) |value| {
            digest = hashing.mix64(digest ^ @as(u64, value));
        }
        return digest;
    }

    pub fn encode(self: *const MinHashSignature, buffer: []u8) !void {
        if (buffer.len < signature_width * 4) return error.BufferTooSmall;
        for (self.values, 0..) |value, index| {
            std.mem.writeInt(u32, buffer[index * 4 ..][0..4], value, .little);
        }
    }

    pub fn decode(buffer: []const u8) !MinHashSignature {
        if (buffer.len < signature_width * 4) return error.BufferTooSmall;
        var values: [signature_width]u32 = undefined;
        for (0..signature_width) |index| {
            values[index] = std.mem.readInt(u32, buffer[index * 4 ..][0..4], .little);
        }
        return .{ .values = values };
    }
};

pub fn tokenize(allocator: std.mem.Allocator, text: []const u8, ngram: usize) ![][]const u8 {
    var words = std.ArrayList([]const u8).init(allocator);
    errdefer words.deinit();
    var iterator = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c.,;:!?\"'`()[]{}<>/\\|-_=+*&^%$#@~");
    while (iterator.next()) |word| {
        if (word.len == 0) continue;
        const lower = try std.ascii.allocLowerString(allocator, word);
        try words.append(lower);
    }
    var grams = std.ArrayList([]const u8).init(allocator);
    errdefer grams.deinit();
    if (words.items.len == 0) {
        for (words.items) |word| allocator.free(word);
        words.deinit();
        return grams.toOwnedSlice();
    }
    if (words.items.len < ngram) {
        var joined = std.ArrayList(u8).init(allocator);
        for (words.items) |word| {
            if (joined.items.len > 0) try joined.append(' ');
            try joined.appendSlice(word);
        }
        try grams.append(try joined.toOwnedSlice());
    } else {
        var index: usize = 0;
        while (index + ngram <= words.items.len) : (index += 1) {
            var joined = std.ArrayList(u8).init(allocator);
            var offset: usize = 0;
            while (offset < ngram) : (offset += 1) {
                if (offset > 0) try joined.append(' ');
                try joined.appendSlice(words.items[index + offset]);
            }
            try grams.append(try joined.toOwnedSlice());
        }
    }
    for (words.items) |word| allocator.free(word);
    words.deinit();
    return grams.toOwnedSlice();
}

pub fn releaseTokens(allocator: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |token| allocator.free(token);
    allocator.free(tokens);
}

pub fn simhash(tokens: [][]const u8) u64 {
    var accumulator: [64]i32 = @splat(0);
    for (tokens) |token| {
        if (token.len == 0) continue;
        const digest = hashing.hash64(0x0123456789ABCDEF, token);
        for (0..64) |bit| {
            if ((digest >> @intCast(bit)) & 1 == 1) {
                accumulator[bit] += 1;
            } else {
                accumulator[bit] -= 1;
            }
        }
    }
    var out: u64 = 0;
    for (accumulator, 0..) |value, bit| {
        if (value > 0) out |= @as(u64, 1) << @intCast(bit);
    }
    return out;
}

pub fn hammingDistance(left: u64, right: u64) u8 {
    return @popCount(left ^ right);
}

pub const LshIndex = struct {
    allocator: std.mem.Allocator,
    bands: [band_count]std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u64)),
    signatures: std.AutoHashMapUnmanaged(u64, MinHashSignature),
    exact: std.AutoHashMapUnmanaged(u64, u64),
    inserted: u64 = 0,
    candidate_checks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !LshIndex {
        var bands: [band_count]std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u64)) = undefined;
        for (&bands) |*band| band.* = .{};
        return .{ .allocator = allocator, .bands = bands, .signatures = .{}, .exact = .{} };
    }

    pub fn deinit(self: *LshIndex) void {
        for (&self.bands) |*band| {
            var iterator = band.valueIterator();
            while (iterator.next()) |list| list.deinit(self.allocator);
            band.deinit(self.allocator);
        }
        self.signatures.deinit(self.allocator);
        self.exact.deinit(self.allocator);
    }

    pub fn insert(self: *LshIndex, document_id: u64, content_hash: u64, signature: MinHashSignature) !void {
        try self.signatures.put(self.allocator, document_id, signature);
        try self.exact.put(self.allocator, content_hash, document_id);
        for (0..band_count) |band| {
            const key = signature.bandHash(band);
            const entry = try self.bands[band].getOrPut(self.allocator, key);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            try entry.value_ptr.append(self.allocator, document_id);
        }
        self.inserted += 1;
    }

    pub fn candidates(self: *LshIndex, signature: *const MinHashSignature) ![]u64 {
        var seen = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen.deinit();
        var out = std.ArrayList(u64).init(self.allocator);
        for (0..band_count) |band| {
            const key = signature.bandHash(band);
            const bucket = self.bands[band].get(key) orelse continue;
            for (bucket.items) |document_id| {
                if (seen.contains(document_id)) continue;
                try seen.put(document_id, {});
                try out.append(document_id);
            }
        }
        self.candidate_checks += 1;
        return out.toOwnedSlice();
    }

    pub fn nearDuplicates(self: *LshIndex, signature: *const MinHashSignature, threshold: f64) ![]u64 {
        const candidate_list = try self.candidates(signature);
        defer self.allocator.free(candidate_list);
        var out = std.ArrayList(u64).init(self.allocator);
        for (candidate_list) |document_id| {
            const stored = self.signatures.get(document_id) orelse continue;
            if (stored.jaccardEstimate(signature) >= threshold) try out.append(document_id);
        }
        return out.toOwnedSlice();
    }

    pub fn exactDuplicate(self: *LshIndex, content_hash: u64) ?u64 {
        return self.exact.get(content_hash);
    }

    pub fn documentCount(self: *const LshIndex) usize {
        return self.signatures.count();
    }
};

pub const ShingleSet = struct {
    hashes: []u64,

    pub fn init(allocator: std.mem.Allocator, tokens: [][]const u8) !ShingleSet {
        const hashes = try allocator.alloc(u64, tokens.len);
        for (tokens, 0..) |token, index| {
            hashes[index] = hashing.hash64(0x27D4EB2F165667C5, token);
        }
        std.sort.block(u64, hashes, {}, struct {
            fn lt(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lt);
        return .{ .hashes = hashes };
    }

    pub fn release(self: *ShingleSet, allocator: std.mem.Allocator) void {
        allocator.free(self.hashes);
    }

    pub fn containment(self: *const ShingleSet, other: *const ShingleSet) f64 {
        if (self.hashes.len == 0 or other.hashes.len == 0) return 0.0;
        var intersection: usize = 0;
        var left: usize = 0;
        var right: usize = 0;
        while (left < self.hashes.len and right < other.hashes.len) {
            if (self.hashes[left] == other.hashes[right]) {
                intersection += 1;
                left += 1;
                right += 1;
            } else if (self.hashes[left] < other.hashes[right]) {
                left += 1;
            } else {
                right += 1;
            }
        }
        return @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(@min(self.hashes.len, other.hashes.len)));
    }
};

pub const TemplateDetector = struct {
    allocator: std.mem.Allocator,
    host: u64,
    document_frequency: std.AutoHashMapUnmanaged(u64, u32),
    documents: u32 = 0,
    threshold: f64 = 0.8,
    template_hashes: []u64 = &.{},

    pub fn init(allocator: std.mem.Allocator, host: u64, threshold: f64) TemplateDetector {
        return .{ .allocator = allocator, .host = host, .document_frequency = .{}, .threshold = threshold };
    }

    pub fn deinit(self: *TemplateDetector) void {
        self.document_frequency.deinit(self.allocator);
        if (self.template_hashes.len > 0) self.allocator.free(self.template_hashes);
    }

    pub fn observe(self: *TemplateDetector, tokens: [][]const u8) !void {
        var seen = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen.deinit();
        for (tokens) |token| {
            const hash = hashing.hash64(0x27D4EB2F165667C5, token);
            if (seen.contains(hash)) continue;
            try seen.put(hash, {});
            const entry = try self.document_frequency.getOrPut(self.allocator, hash);
            if (!entry.found_existing) {
                entry.value_ptr.* = 1;
            } else {
                entry.value_ptr.* += 1;
            }
        }
        self.documents += 1;
    }

    pub fn finalize(self: *TemplateDetector) !void {
        var template = std.ArrayList(u64).init(self.allocator);
        var iterator = self.document_frequency.iterator();
        const minimum: f64 = self.threshold * @as(f64, @floatFromInt(self.documents));
        while (iterator.next()) |entry| {
            if (@as(f64, @floatFromInt(entry.value_ptr.*)) >= minimum) try template.append(entry.key_ptr.*);
        }
        std.sort.block(u64, template.items, {}, struct {
            fn lt(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lt);
        if (self.template_hashes.len > 0) self.allocator.free(self.template_hashes);
        self.template_hashes = try template.toOwnedSlice();
    }

    pub fn templateRatio(self: *const TemplateDetector, tokens: [][]const u8) f64 {
        if (self.template_hashes.len == 0 or tokens.len == 0) return 0.0;
        var matched: usize = 0;
        for (tokens) |token| {
            const hash = hashing.hash64(0x27D4EB2F165667C5, token);
            if (std.sort.binarySearch(u64, self.template_hashes, hash, struct {
                fn order(a: u64, b: u64) std.math.Order {
                    return std.math.order(a, b);
                }
            }.order) != null) matched += 1;
        }
        return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(tokens.len));
    }

    pub fn isTemplateShingle(self: *const TemplateDetector, token: []const u8) bool {
        const hash = hashing.hash64(0x27D4EB2F165667C5, token);
        return std.sort.binarySearch(u64, self.template_hashes, hash, struct {
            fn order(a: u64, b: u64) std.math.Order {
                return std.math.order(a, b);
            }
        }.order) != null;
    }

    pub fn templateSize(self: *const TemplateDetector) usize {
        return self.template_hashes.len;
    }
};

pub const DuplicateClass = enum(u8) {
    unique,
    exact,
    near_duplicate,
    boilerplate_variant,
    syndicated,
    mirror,
};

pub const Verdict = struct {
    class: DuplicateClass,
    canonical_id: u64,
    similarity: f64,
    template_ratio: f64,
};

pub const Deduplicator = struct {
    allocator: std.mem.Allocator,
    index: LshIndex,
    templates: std.AutoHashMapUnmanaged(u64, *TemplateDetector),
    content_filter: bloom.BloomFilter,
    ngram: usize = 5,
    near_threshold: f64 = 0.9,
    simplex_threshold: u8 = 3,
    exact: u64 = 0,
    near: u64 = 0,
    boilerplate: u64 = 0,
    unique: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, expected_documents: u64) !Deduplicator {
        return .{
            .allocator = allocator,
            .index = try LshIndex.init(allocator),
            .templates = .{},
            .content_filter = try bloom.BloomFilter.init(allocator, @max(1024, expected_documents * 8), 0.01),
        };
    }

    pub fn deinit(self: *Deduplicator) void {
        self.index.deinit();
        var iterator = self.templates.valueIterator();
        while (iterator.next()) |detector| {
            detector.*.deinit();
            self.allocator.destroy(detector.*);
        }
        self.templates.deinit(self.allocator);
        self.content_filter.deinit();
    }

    pub fn templateFor(self: *Deduplicator, host: u64) !*TemplateDetector {
        if (self.templates.get(host)) |detector| return detector;
        const detector = try self.allocator.create(TemplateDetector);
        detector.* = TemplateDetector.init(self.allocator, host, 0.8);
        try self.templates.put(self.allocator, host, detector);
        return detector;
    }

    pub fn classify(self: *Deduplicator, document_id: u64, host: u64, text: []const u8) !Verdict {
        const content_hash = hashing.hash64(0xC2B2AE3D27D4EB4F, text);
        if (self.index.exactDuplicate(content_hash)) |existing| {
            self.exact += 1;
            return .{ .class = .exact, .canonical_id = existing, .similarity = 1.0, .template_ratio = 0.0 };
        }
        const tokens = try tokenize(self.allocator, text, self.ngram);
        defer releaseTokens(self.allocator, tokens);
        const template = try self.templateFor(host);
        const template_ratio = template.templateRatio(tokens);
        try template.observe(tokens);
        const signature = MinHashSignature.init(tokens);
        const duplicates = try self.index.nearDuplicates(&signature, self.near_threshold);
        defer self.allocator.free(duplicates);
        const simplex = simhash(tokens);
        var best: u64 = document_id;
        var best_similarity: f64 = 0.0;
        for (duplicates) |candidate| {
            const stored = self.index.signatures.get(candidate) orelse continue;
            const estimate = stored.jaccardEstimate(&signature);
            if (estimate > best_similarity) {
                best_similarity = estimate;
                best = candidate;
            }
        }
        _ = simplex;
        if (best_similarity >= self.near_threshold) {
            self.near += 1;
            return .{ .class = .near_duplicate, .canonical_id = best, .similarity = best_similarity, .template_ratio = template_ratio };
        }
        if (template_ratio > 0.85) {
            self.boilerplate += 1;
            try self.index.insert(document_id, content_hash, signature);
            return .{ .class = .boilerplate_variant, .canonical_id = document_id, .similarity = best_similarity, .template_ratio = template_ratio };
        }
        self.unique += 1;
        try self.index.insert(document_id, content_hash, signature);
        return .{ .class = .unique, .canonical_id = document_id, .similarity = best_similarity, .template_ratio = template_ratio };
    }

    pub fn finalizeTemplates(self: *Deduplicator) !void {
        var iterator = self.templates.valueIterator();
        while (iterator.next()) |detector| try detector.*.finalize();
    }

    pub fn stats(self: *const Deduplicator) DedupStats {
        return .{
            .documents = self.index.documentCount(),
            .exact = self.exact,
            .near = self.near,
            .boilerplate = self.boilerplate,
            .unique = self.unique,
            .templates = self.templates.count(),
        };
    }
};

pub const DedupStats = struct {
    documents: usize,
    exact: u64,
    near: u64,
    boilerplate: u64,
    unique: u64,
    templates: usize,
};
