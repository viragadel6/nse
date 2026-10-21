const std = @import("std");

pub const Entry = struct {
    query_hash: u64,
    model_version: u64,
    embedding: []f32,
    created_at: i64,
    ttl_ms: u64,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry),
    index: std.HashMap(u64, usize),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    max_entries: u32,
    ttl_ms: u64,

    pub fn init(allocator: std.mem.Allocator, max_entries: u32, ttl_ms: u64) !Cache {
        return Cache{
            .entries = std.ArrayList(Entry).init(allocator),
            .index = std.HashMap(u64, usize).init(allocator),
            .lock = .{},
            .allocator = allocator,
            .max_entries = max_entries,
            .ttl_ms = ttl_ms,
        };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |*entry| allocator.free(entry.embedding);
        self.entries.deinit();
        self.index.deinit();
    }

    pub fn lookup(self: *Cache, query_hash: u64, model_version: u64, now: i64) ?[]const f32 {
        self.lock.lock();
        defer self.lock.unlock();
        const position = self.index.get(query_hash) orelse return null;
        const entry = self.entries.items[position];
        if (entry.model_version != model_version) return null;
        if (now - @as(i64, @intCast(entry.created_at)) > @as(i64, @intCast(entry.ttl_ms))) return null;
        return entry.embedding;
    }

    pub fn insert(self: *Cache, query_hash: u64, model_version: u64, embedding: []f32, now: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.index.contains(query_hash)) {
            const position = self.index.get(query_hash).?;
            allocator.free(self.entries.items[position].embedding);
            self.entries.items[position] = Entry{ .query_hash = query_hash, .model_version = model_version, .embedding = embedding, .created_at = @as(u64, @intCast(now)), .ttl_ms = self.ttl_ms };
            return;
        }
        if (self.entries.items.len >= @intCast(self.max_entries)) {
            const evicted = self.entries.items.pop();
            _ = self.index.remove(evicted.query_hash);
            allocator.free(evicted.embedding);
        }
        const position = @as(usize, @intCast(self.entries.items.len));
        _ = try self.entries.append(Entry{ .query_hash = query_hash, .model_version = model_version, .embedding = embedding, .created_at = @as(u64, @intCast(now)), .ttl_ms = self.ttl_ms });
        _ = try self.index.put(query_hash, position);
    }

    pub fn invalidate(self: *Cache, model_version: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].model_version != model_version) {
                allocator.free(self.entries.items[i].embedding);
                _ = self.index.remove(self.entries.items[i].query_hash);
                _ = self.entries.items.remove(i);
                continue;
            }
            i += 1;
        }
    }
};
