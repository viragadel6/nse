const std = @import("std");
const time = @import("../util/time.zig");

pub const FilterError = error{
    InvalidFilter,
    TooManyClauses,
    UnsupportedOperator,
};

pub const Operator = enum(u8) {
    and_,
    or_,
    not_,
};

pub const NumericOp = enum(u8) {
    gt,
    gte,
    lt,
    lte,
    eq,
    neq,
    between,
};

pub const Clause = struct {
    field: []const u8,
    op: NumericOp,
    value_i64: i64 = 0,
    value_upper_i64: i64 = 0,
    value_f64: f64 = 0.0,
    value_upper_f64: f64 = 0.0,
    is_float: bool = false,
};

pub const TermSet = struct {
    field: []const u8,
    allow: []const u8,
    deny: []const u8,
    case_sensitive: bool = false,

    pub fn release(self: *TermSet, allocator: std.mem.Allocator) void {
        allocator.free(self.allow);
        allocator.free(self.deny);
        allocator.free(self.field);
    }
};

pub const Filter = struct {
    operator: Operator = .and_,
    clauses: []Clause,
    sets: []TermSet,
    children: []Filter,
    allocator: std.mem.Allocator,

    pub fn release(self: *Filter) void {
        for (self.sets) |*set| set.release(self.allocator);
        for (self.children) |*child| child.release();
        self.allocator.free(self.sets);
        self.allocator.free(self.clauses);
        self.allocator.free(self.children);
    }

    pub fn depth(self: *const Filter) usize {
        var deepest: usize = 0;
        for (self.children) |child| deepest = @max(deepest, child.depth());
        return deepest + 1;
    }

    pub fn clauseCount(self: *const Filter) usize {
        var total = self.clauses.len + self.sets.len;
        for (self.children) |child| total += child.clauseCount();
        return total;
    }
};

pub const DocumentAttributes = struct {
    document_id: u64,
    language: []const u8,
    domain: []const u8,
    url: []const u8,
    site: []const u8,
    kind: []const u8,
    quality: f64,
    spam_score: f64,
    authority: f64,
    published_ms: i64,
    fetched_ms: i64,
    indexed_ms: i64,
    length: u32,
    link_count: u32,
    inbound_links: u32,
    embedding_version: u32,
    flags: u32,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    max_clauses: usize = 256,
    evaluations: u64 = 0,
    rejected: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn evaluate(self: *Engine, filter: *const Filter, document: DocumentAttributes) !bool {
        self.evaluations += 1;
        const result = try self.evaluateNode(filter, document);
        if (!result) self.rejected += 1;
        return result;
    }

    fn evaluateNode(self: *Engine, filter: *const Filter, document: DocumentAttributes) !bool {
        switch (filter.operator) {
            .and_ => {
                for (filter.clauses) |clause| {
                    if (!self.evaluateClause(clause, document)) return false;
                }
                for (filter.sets) |set| {
                    if (!self.evaluateSet(set, document)) return false;
                }
                var child_result = true;
                for (filter.children) |child| {
                    if (!try self.evaluateNode(&child, document)) {
                        child_result = false;
                        break;
                    }
                }
                if (!child_result) return false;
                if (filter.clauses.len == 0 and filter.sets.len == 0 and filter.children.len == 0) return false;
                return true;
            },
            .or_ => {
                var any = false;
                for (filter.clauses) |clause| {
                    if (self.evaluateClause(clause, document)) any = true;
                }
                for (filter.sets) |set| {
                    if (self.evaluateSet(set, document)) any = true;
                }
                for (filter.children) |child| {
                    if (try self.evaluateNode(&child, document)) any = true;
                }
                return any;
            },
            .not_ => {
                for (filter.clauses) |clause| {
                    if (self.evaluateClause(clause, document)) return false;
                }
                for (filter.sets) |set| {
                    if (self.evaluateSet(set, document)) return false;
                }
                for (filter.children) |child| {
                    if (try self.evaluateNode(&child, document)) return false;
                }
                return true;
            },
        }
    }

    fn fieldValue(document: DocumentAttributes, field: []const u8) ?f64 {
        if (std.mem.eql(u8, field, "quality")) return document.quality;
        if (std.mem.eql(u8, field, "spam")) return document.spam_score;
        if (std.mem.eql(u8, field, "authority")) return document.authority;
        if (std.mem.eql(u8, field, "published")) return @floatFromInt(document.published_ms);
        if (std.mem.eql(u8, field, "fetched")) return @floatFromInt(document.fetched_ms);
        if (std.mem.eql(u8, field, "indexed")) return @floatFromInt(document.indexed_ms);
        if (std.mem.eql(u8, field, "length")) return @floatFromInt(document.length);
        if (std.mem.eql(u8, field, "links")) return @floatFromInt(document.link_count);
        if (std.mem.eql(u8, field, "inbound")) return @floatFromInt(document.inbound_links);
        if (std.mem.eql(u8, field, "age_days")) {
            const age = time.nowMs() - document.published_ms;
            return @floatFromInt(if (age > 0) @divFloor(age, 86400000) else 0);
        }
        if (std.mem.eql(u8, field, "embedding_version")) return @floatFromInt(document.embedding_version);
        if (std.mem.eql(u8, field, "flags")) return @floatFromInt(document.flags);
        return null;
    }

    fn evaluateClause(self: *Engine, clause: Clause, document: DocumentAttributes) bool {
        _ = self;
        const value = fieldValue(document, clause.field) orelse return false;
        const target: f64 = if (clause.is_float) clause.value_f64 else @floatFromInt(clause.value_i64);
        const upper: f64 = if (clause.is_float) clause.value_upper_f64 else @floatFromInt(clause.value_upper_i64);
        return switch (clause.op) {
            .gt => value > target,
            .gte => value >= target,
            .lt => value < target,
            .lte => value <= target,
            .eq => value == target,
            .neq => value != target,
            .between => value >= target and value <= upper,
        };
    }

    fn evaluateSet(self: *Engine, set: TermSet, document: DocumentAttributes) bool {
        _ = self;
        const value = if (std.mem.eql(u8, set.field, "language"))
            document.language
        else if (std.mem.eql(u8, set.field, "domain"))
            document.domain
        else if (std.mem.eql(u8, set.field, "site"))
            document.site
        else if (std.mem.eql(u8, set.field, "kind"))
            document.kind
        else if (std.mem.eql(u8, set.field, "url"))
            document.url
        else
            return false;
        if (set.allow.len > 0) {
            var matched = false;
            var offset: usize = 0;
            while (offset < set.allow.len) : (offset += @as(usize, @intCast(@as(i32, @intCast(set.allow[offset])))) + 1) {
                const start = offset + 1;
                const length = @as(usize, @intCast(set.allow[offset]));
                if (start + length > set.allow.len) break;
                const candidate = set.allow[start..][0..length];
                if (if (set.case_sensitive) std.mem.eql(u8, candidate, value) else std.ascii.eqlIgnoreCase(candidate, value)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        var offset: usize = 0;
        while (offset < set.deny.len) : (offset += @as(usize, @intCast(@as(i32, @intCast(set.deny[offset])))) + 1) {
            const start = offset + 1;
            const length = @as(usize, @intCast(set.deny[offset]));
            if (start + length > set.deny.len) break;
            const candidate = set.deny[start..][0..length];
            if (if (set.case_sensitive) std.mem.eql(u8, candidate, value) else std.ascii.eqlIgnoreCase(candidate, value)) return false;
        }
        return true;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    operator: Operator = .and_,
    clauses: std.ArrayList(Clause),
    sets: std.ArrayList(TermSet),
    children: std.ArrayList(Filter),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .clauses = std.ArrayList(Clause).init(allocator),
            .sets = std.ArrayList(TermSet).init(allocator),
            .children = std.ArrayList(Filter).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.clauses.deinit();
        self.sets.deinit();
        self.children.deinit();
    }

    pub fn addNumeric(self: *Builder, field: []const u8, op: NumericOp, value: f64, upper: f64) !void {
        try self.clauses.append(.{
            .field = try self.allocator.dupe(u8, field),
            .op = op,
            .value_f64 = value,
            .value_upper_f64 = upper,
            .is_float = true,
        });
    }

    pub fn addInteger(self: *Builder, field: []const u8, op: NumericOp, value: i64, upper: i64) !void {
        try self.clauses.append(.{ .field = try self.allocator.dupe(u8, field), .op = op, .value_i64 = value, .value_upper_i64 = upper });
    }

    pub fn addTermSet(self: *Builder, field: []const u8, allow: []const []const u8, deny: []const []const u8) !void {
        try self.sets.append(.{
            .field = try self.allocator.dupe(u8, field),
            .allow = try encodeTerms(self.allocator, allow),
            .deny = try encodeTerms(self.allocator, deny),
        });
    }

    pub fn addChild(self: *Builder, child: Filter) !void {
        try self.children.append(child);
    }

    pub fn build(self: *Builder, operator: Operator) !Filter {
        return .{
            .operator = operator,
            .clauses = try self.clauses.toOwnedSlice(),
            .sets = try self.sets.toOwnedSlice(),
            .children = try self.children.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
};

fn encodeTerms(allocator: std.mem.Allocator, terms: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (terms) |term| total += term.len + 1;
    var out = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (terms) |term| {
        out[offset] = @intCast(@min(term.len, 255));
        @memcpy(out[offset + 1 ..][0..term.len], term);
        offset += term.len + 1;
    }
    return out;
}
