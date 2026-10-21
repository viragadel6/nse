const std = @import("std");
const tokenizer = @import("../models/tokenizer.zig");
const Document = @import("../storage/document.zig").Document;
const Store = @import("../storage/document_store.zig").Store;
const bm25 = @import("bm25.zig");
const Ranking = @import("../runtime/configuration.zig").RankingConfig;
const Deadline = @import("../runtime/cancellation.zig").Deadline;

pub const Posting = struct { id: u64, body: u32 = 0, title: u32 = 0, url: u32 = 0 };
pub const Candidate = struct { id: u64, score: f64 };

pub const Index = struct {
    allocator: std.mem.Allocator,
    terms: std.StringHashMap(std.ArrayList(Posting)),
    lengths: std.AutoHashMap(u64, u32),
    total_length: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator, .terms = std.StringHashMap(std.ArrayList(Posting)).init(allocator), .lengths = std.AutoHashMap(u64, u32).init(allocator) };
    }

    pub fn deinit(self: *Index) void {
        var iterator = self.terms.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.terms.deinit();
        self.lengths.deinit();
    }

    fn addField(self: *Index, arena: std.mem.Allocator, frequencies: *std.StringHashMap(Posting), id: u64, text: []const u8, comptime field: []const u8) !u32 {
        _ = self;
        var count: u32 = 0;
        var iterator = tokenizer.Iterator{ .text = text };
        while (iterator.next()) |token| {
            const term = try tokenizer.normalized(arena, token.text);
            const result = try frequencies.getOrPut(term);
            if (!result.found_existing) result.value_ptr.* = .{ .id = id };
            @field(result.value_ptr, field) = try std.math.add(u32, @field(result.value_ptr, field), 1);
            count = try std.math.add(u32, count, 1);
        }
        return count;
    }

    pub fn add(self: *Index, document: *const Document) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var frequencies = std.StringHashMap(Posting).init(arena.allocator());
        const body_length = try self.addField(arena.allocator(), &frequencies, document.id, document.text, "body");
        const title_length = try self.addField(arena.allocator(), &frequencies, document.id, document.title, "title");
        _ = try self.addField(arena.allocator(), &frequencies, document.id, document.url, "url");
        const length = try std.math.add(u32, body_length, title_length);
        try self.lengths.put(document.id, length);
        self.total_length = try std.math.add(u64, self.total_length, length);
        var iterator = frequencies.iterator();
        while (iterator.next()) |entry| {
            const existing = self.terms.getPtr(entry.key_ptr.*);
            if (existing) |postings| {
                try postings.append(entry.value_ptr.*);
            } else {
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(key);
                var postings = std.ArrayList(Posting).init(self.allocator);
                errdefer postings.deinit();
                try postings.append(entry.value_ptr.*);
                try self.terms.put(key, postings);
            }
        }
    }

    pub fn build(allocator: std.mem.Allocator, store: *const Store) !Index {
        var result = init(allocator);
        errdefer result.deinit();
        var iterator = store.entries.valueIterator();
        while (iterator.next()) |entry| try result.add(entry.*);
        return result;
    }

    fn better(_: void, left: Candidate, right: Candidate) bool {
        return left.score > right.score or (left.score == right.score and left.id < right.id);
    }

    pub fn search(self: *const Index, allocator: std.mem.Allocator, query: []const u8, ranking: Ranking, deadline: Deadline) ![]Candidate {
        var scores = std.AutoHashMap(u64, f64).init(allocator);
        defer scores.deinit();
        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var keys = seen.keyIterator();
            while (keys.next()) |key| allocator.free(key.*);
            seen.deinit();
        }
        var iterator = tokenizer.Iterator{ .text = query };
        const average = if (self.lengths.count() == 0) 0 else @as(f64, @floatFromInt(self.total_length)) / @as(f64, @floatFromInt(self.lengths.count()));
        while (iterator.next()) |token| {
            try deadline.check();
            const term = try tokenizer.normalized(allocator, token.text);
            defer allocator.free(term);
            if (seen.contains(term)) continue;
            const owned = try allocator.dupe(u8, term);
            seen.put(owned, {}) catch |err| {
                allocator.free(owned);
                return err;
            };
            if (self.terms.get(term)) |postings| {
                for (postings.items, 0..) |posting, position| {
                    if (position % 256 == 0) try deadline.check();
                    const tf = @as(f64, @floatFromInt(posting.body)) + ranking.title_field_weight * @as(f64, @floatFromInt(posting.title)) + ranking.url_field_weight * @as(f64, @floatFromInt(posting.url));
                    const value = bm25.score(self.lengths.count(), postings.items.len, tf, self.lengths.get(posting.id).?, average, ranking.bm25_k1, ranking.bm25_b);
                    const entry = try scores.getOrPut(posting.id);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += value;
                }
            }
        }
        var results = std.ArrayList(Candidate).init(allocator);
        errdefer results.deinit();
        var score_iterator = scores.iterator();
        while (score_iterator.next()) |entry| try results.append(.{ .id = entry.key_ptr.*, .score = entry.value_ptr.* });
        std.mem.sort(Candidate, results.items, {}, better);
        return results.toOwnedSlice();
    }
};
