const std = @import("std");

pub const CrawlStats = struct {
    fetched: usize = 0,
    failed: usize = 0,
    redirected: usize = 0,
    duplicated: usize = 0,
    bytes: u64 = 0,
    links_discovered: usize = 0,
};

pub const CrawlState = struct {
    stats: CrawlStats,
    lock: std.Thread.Mutex,

    pub fn init() CrawlState {
        return CrawlState{ .lock = .{} };
    }

    pub fn recordFetch(self: *CrawlState, bytes: usize) void {
        self.lock.lock();
        self.stats.fetched += 1;
        self.stats.bytes += @as(u64, @intCast(bytes));
        self.lock.unlock();
    }

    pub fn recordFailure(self: *CrawlState) void {
        self.lock.lock();
        self.stats.failed += 1;
        self.lock.unlock();
    }

    pub fn recordRedirect(self: *CrawlState) void {
        self.lock.lock();
        self.stats.redirected += 1;
        self.lock.unlock();
    }

    pub fn recordDuplicate(self: *CrawlState) void {
        self.lock.lock();
        self.stats.duplicated += 1;
        self.lock.unlock();
    }

    pub fn snapshot(self: *CrawlState) CrawlStats {
        self.lock.lock();
        const snapshot = self.stats;
        self.lock.unlock();
        return snapshot;
    }
};
