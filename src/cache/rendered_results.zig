const std = @import("std");

pub const Entry = struct {
    key_hash: u64,
    model_version: u64,
    index_generation: u64,
    body: []u8,
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
        for (self.entries.items) |*entry| allocator.free(entry.body);
        self.entries.deinit();
        self.index.deinit();
    }

    pub fn lookup(self: *Cache, key_hash: u64, model_version: u64, index_generation: u64, now: i64) ?[]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const position = self.index.get(key_hash) orelse return null;
        const entry = self.entries.items[position];
        if (entry.model_version != model_version or entry.index_generation != index_generation) return null;
        if (now - @as(i64, @intCast(entry.created_at)) > @as(i64, @intCast(entry.ttl_ms))) return null;
        return entry.body;
    }

    pub fn insert(self: *Cache, key_hash: u64, model_version: u64, index_generation: u64, body: []u8, now: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.entries.items.len >= @intCast(self.max_entries)) {
            const evicted = self.entries.items.pop();
            _ = self.index.remove(evicted.key_hash);
            allocator.free(evicted.body);
        }
        const position = @as(usize, @intCast(self.entries.items.len));
        _ = try self.entries.append(Entry{ .key_hash = key_hash, .model_version = model_version, .index_generation = index_generation, .body = body, .created_at = @as(u64, @intCast(now)), .ttl_ms = self.ttl_ms });
        _ = try self.index.put(key_hash, position);
    }

    pub fn invalidate(self: *Cache, model_version: u64, index_generation: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].model_version != model_version or self.entries.items[i].index_generation != index_generation) {
                allocator.free(self.entries.items[i].body);
                _ = self.index.remove(self.entries.items[i].key_hash);
                _ = self.entries.items.remove(i);
                continue;
            }
            i += 1;
        }
    }
};
