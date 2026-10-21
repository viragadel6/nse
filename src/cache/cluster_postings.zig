const std = @import("std");

pub const Entry = struct {
    centroid_id: u32,
    index_generation: u64,
    postings: []u64,
    created_at: i64,
    ttl_ms: u64,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry),
    index: std.HashMap(u32, usize),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    max_entries: u32,
    ttl_ms: u64,

    pub fn init(allocator: std.mem.Allocator, max_entries: u32, ttl_ms: u64) !Cache {
        return Cache{
            .entries = std.ArrayList(Entry).init(allocator),
            .index = std.HashMap(u32, usize).init(allocator),
            .lock = .{},
            .allocator = allocator,
            .max_entries = max_entries,
            .ttl_ms = ttl_ms,
        };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |*entry| allocator.free(entry.postings);
        self.entries.deinit();
        self.index.deinit();
    }

    pub fn lookup(self: *Cache, centroid_id: u32, index_generation: u64, now: i64) ?[]const u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const position = self.index.get(centroid_id) orelse return null;
        const entry = self.entries.items[position];
        if (entry.index_generation != index_generation) return null;
        if (now - @as(i64, @intCast(entry.created_at)) > @as(i64, @intCast(entry.ttl_ms))) return null;
        return entry.postings;
    }

    pub fn insert(self: *Cache, centroid_id: u32, index_generation: u64, postings: []u64, now: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.entries.items.len >= @intCast(self.max_entries)) {
            const evicted = self.entries.items.pop();
            _ = self.index.remove(evicted.centroid_id);
            allocator.free(evicted.postings);
        }
        const position = @as(usize, @intCast(self.entries.items.len));
        _ = try self.entries.append(Entry{ .centroid_id = centroid_id, .index_generation = index_generation, .postings = postings, .created_at = @as(u64, @intCast(now)), .ttl_ms = self.ttl_ms });
        _ = try self.index.put(centroid_id, position);
    }

    pub fn invalidateGeneration(self: *Cache, index_generation: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].index_generation != index_generation) {
                allocator.free(self.entries.items[i].postings);
                _ = self.index.remove(self.entries.items[i].centroid_id);
                _ = self.entries.items.remove(i);
                continue;
            }
            i += 1;
        }
    }
};
