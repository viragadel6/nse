const std = @import("std");
const state = @import("frontier_state.zig");
const partition = @import("frontier_partition.zig");
const hashing = @import("../../util/hashing.zig");

pub const Frontier = struct {
    store: std.StringHashMap(state.FrontierRecord),
    partitions: partition.PartitionMap,
    partition_count: u32,
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, partition_count: u32) !Frontier {
        const partitions = try partition.PartitionMap.init(allocator, partition_count);
        return Frontier{ .store = std.StringHashMap(state.FrontierRecord).init(allocator), .partitions = partitions, .partition_count = partition_count, .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Frontier) void {
        for (self.store.iterator()) |*entry| {
            self.allocator.free(entry.value_ptr().*.canonical_url);
            self.allocator.free(entry.value_ptr().*.discovery_url);
            if (entry.value_ptr().*.redirect_target) |target| self.allocator.free(target);
            self.allocator.free(entry.value_ptr().*.provenance);
        }
        self.store.deinit();
        self.partitions.deinit(self.allocator);
    }

    fn keyFor(url: []const u8) []const u8 {
        return url;
    }

    pub fn lookup(self: *const Frontier, url: []const u8) ?*state.FrontierRecord {
        self.lock.lockShared();
        const entry = self.store.get(url);
        self.lock.unlockShared();
        return entry;
    }

    pub fn discover(self: *Frontier, url: []const u8, discovery_url: []const u8, domain_id: u64, now: i64) !bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.store.contains(url)) return false;
        const record = state.FrontierRecord{
            .url_hash = hashing.fnv1a_64(url),
            .canonical_url = try self.allocator.dupe(u8, url),
            .discovery_url = try self.allocator.dupe(u8, discovery_url),
            .domain_id = domain_id,
            .fetch_state = .discovered,
            .discovery_timestamp = now,
            .next_fetch_timestamp = now,
            .priority = 1,
            .provenance = "",
        };
        try self.store.put(url, record);
        const part = partition.partitionUrl(url, self.partition_count);
        self.partitions.record(part, 1);
        return true;
    }

    pub fn lease(self: *Frontier, url: []const u8) ?*state.FrontierRecord {
        self.lock.lock();
        defer self.lock.unlock();
        const entry = self.store.get(url) orelse return null;
        if (entry.value_ptr().*.fetch_state != .discovered and entry.value_ptr().*.fetch_state != .recrawl_pending) return null;
        entry.value_ptr().*.fetch_state = .leased;
        return entry.value_ptr();
    }

    pub fn complete(self: *Frontier, url: []const u8, http_status: u16, fingerprint: [32]u8, redirect_target: ?[]const u8, now: i64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const entry = self.store.get(url) orelse return;
        entry.value_ptr().*.fetch_state = .fetched;
        entry.value_ptr().*.http_status = http_status;
        entry.value_ptr().*.content_fingerprint = fingerprint;
        entry.value_ptr().*.previous_fetch_timestamp = now;
        if (redirect_target) |target| entry.value_ptr().*.redirect_target = try self.allocator.dupe(u8, target);
    }

    pub fn reschedule(self: *Frontier, url: []const u8, next_fetch: i64, priority: u32) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const entry = self.store.get(url) orelse return;
        entry.value_ptr().*.next_fetch_timestamp = next_fetch;
        entry.value_ptr().*.priority = priority;
        entry.value_ptr().*.fetch_state = .recrawl_pending;
    }

    pub fn due(self: *Frontier, now: i64, limit: usize) []state.FrontierRecord {
        self.lock.lockShared();
        var results = std.ArrayList(state.FrontierRecord).init(self.allocator);
        defer self.lock.unlockShared();
        for (self.store.iterator()) |entry| {
            if (entry.value_ptr().*.fetch_state == .discovered or entry.value_ptr().*.fetch_state == .recrawl_pending) {
                if (entry.value_ptr().*.next_fetch_timestamp <= now) {
                    _ = results.append(entry.value_ptr().*);
                }
            }
            if (results.items.len == limit) break;
        }
        return results.toOwnedSlice();
    }

    pub fn count(self: *Frontier) usize {
        self.lock.lockShared();
        const count = self.store.items.len;
        self.lock.unlockShared();
        return count;
    }
};
