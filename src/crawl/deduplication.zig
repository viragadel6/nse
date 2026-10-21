const std = @import("std");
const hashing = @import("../../util/hashing.zig");
const bloom = @import("../../util/bloom_filter.zig");

pub const Dedup = struct {
    seen: std.StringHashMap(void),
    bloom: bloom.Filter,
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, expected_items: usize) !Dedup {
        const filter = try bloom.Filter.init(allocator, expected_items, 0.01);
        return Dedup{ .seen = std.StringHashMap(void).init(allocator), .bloom = filter, .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Dedup) void {
        self.seen.deinit();
        self.bloom.deinit(self.allocator);
    }

    pub fn check(self: *Dedup, fingerprint: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const key = try? self.allocator.dupe(u8, fingerprint) orelse return self.bloom.contains(fingerprint);
        const present = self.seen.contains(key);
        self.allocator.free(key);
        return present;
    }

    pub fn insert(self: *Dedup, fingerprint: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const key = try? self.allocator.dupe(u8, fingerprint) orelse return false;
        if (self.seen.contains(key)) {
            self.allocator.free(key);
            return false;
        }
        _ = self.seen.put(key, {});
        self.bloom.insert(fingerprint);
        return true;
    }
};
