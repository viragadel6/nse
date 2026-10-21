const std = @import("std");

pub const MetadataIndex = struct {
    domains: std.StringHashMap([]u64),
    languages: std.StringHashMap([]u64),
    timestamps: []struct { document_id: u64, published_at: i64 },
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !MetadataIndex {
        return MetadataIndex{
            .domains = std.StringHashMap([]u64).init(allocator),
            .languages = std.StringHashMap([]u64).init(allocator),
            .timestamps = &[_]struct { document_id: u64, published_at: i64 }{},
            .lock = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MetadataIndex) void {
        for (self.domains.iterator()) |*entry| self.allocator.free(entry.value_ptr().*);
        self.domains.deinit();
        for (self.languages.iterator()) |*entry| self.allocator.free(entry.value_ptr().*);
        self.languages.deinit();
    }

    pub fn add(self: *MetadataIndex, document_id: u64, domain: []const u8, language: []const u8, published_at: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
    }

    pub fn queryDomain(self: *MetadataIndex, domain: []const u8) ?[]const u64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.domains.get(domain);
    }
};
