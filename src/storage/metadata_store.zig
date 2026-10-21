const std = @import("std");

pub const Metadata = struct {
    document_id: u64,
    domain: []const u8,
    language: []const u8,
    published_at: i64,
    quality: f32,
    source_quality: f32,
    freshness: f32,
};

pub const Store = struct {
    records: std.AutoHashMap(u64, Metadata),
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return Store{ .records = std.AutoHashMap(u64, Metadata).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.records.valueIterator()) |*entry| {
            self.allocator.free(entry.value_ptr().*.domain);
            self.allocator.free(entry.value_ptr().*.language);
        }
        self.records.deinit();
    }

    pub fn put(self: *Store, document_id: u64, domain: []const u8, language: []const u8, published_at: i64, quality: f32, source_quality: f32, freshness: f32) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.records.getOrPut(document_id);
    }

    pub fn get(self: *Store, document_id: u64) ?*Metadata {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.records.get(document_id);
    }
};
