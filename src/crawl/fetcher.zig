const std = @import("std");
const http_client = @import("../network/http_client.zig");
const compression = @import("../util/compression.zig");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");
const urls = @import("url_normalization.zig");
const state = @import("crawl_state.zig");
const errors = @import("../runtime/errors.zig");

pub const FetchError = error{
    RobotsDisallowed,
    DeniedAccess,
    ChallengeResponse,
    ContentTooLarge,
    UnsupportedScheme,
    MalformedUrl,
    FetchFailed,
    RetryExhausted,
    PolitenessBlocked,
    Timeout,
};

pub const RobotsRule = struct {
    path_prefix: []const u8,
    allowed: bool,
};

pub const RobotsPolicy = struct {
    rules: []RobotsRule,
    crawl_delay_ms: u32,
    fetched_ms: i64,
    sitemap_urls: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RobotsPolicy) void {
        for (self.rules) |rule| self.allocator.free(rule.path_prefix);
        self.allocator.free(self.rules);
        for (self.sitemap_urls) |sitemap| self.allocator.free(sitemap);
        self.allocator.free(self.sitemap_urls);
    }

    pub fn allows(self: *const RobotsPolicy, path: []const u8) bool {
        var best: ?RobotsRule = null;
        for (self.rules) |rule| {
            if (!std.mem.startsWith(u8, path, rule.path_prefix)) continue;
            if (best == null or rule.path_prefix.len > best.?.path_prefix.len) best = rule;
        }
        return if (best) |rule| rule.allowed else true;
    }

    pub fn delayMs(self: *const RobotsPolicy) u32 {
        return self.crawl_delay_ms;
    }
};

pub const RobotsCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(RobotsPolicy) = .{},
    mutex: std.Thread.Mutex = .{},
    ttl_ms: i64 = 86400000,

    pub fn init(allocator: std.mem.Allocator) RobotsCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RobotsCache) void {
        self.mutex.lock();
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |policy| policy.deinit();
        self.entries.deinit(self.allocator);
        self.mutex.unlock();
    }

    pub fn parseBody(self: *RobotsCache, body: []const u8) !RobotsPolicy {
        var rules = std.ArrayList(RobotsRule).init(self.allocator);
        errdefer rules.deinit();
        var sitemaps = std.ArrayList([]const u8).init(self.allocator);
        errdefer sitemaps.deinit();
        var crawl_delay: u32 = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var applies = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..separator], " \t");
            const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
                applies = std.ascii.eqlIgnoreCase(value, "*") or std.ascii.indexOfIgnoreCase(value, "distributed-search-engine") != null;
                continue;
            }
            if (!applies) continue;
            if (std.ascii.eqlIgnoreCase(key, "disallow")) {
                try rules.append(.{ .path_prefix = try self.allocator.dupe(u8, value), .allowed = value.len == 0 });
            } else if (std.ascii.eqlIgnoreCase(key, "allow")) {
                try rules.append(.{ .path_prefix = try self.allocator.dupe(u8, value), .allowed = true });
            } else if (std.ascii.eqlIgnoreCase(key, "crawl-delay")) {
                crawl_delay = std.fmt.parseInt(u32, value, 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase(key, "sitemap")) {
                try sitemaps.append(try self.allocator.dupe(u8, value));
            }
        }
        return .{
            .rules = try rules.toOwnedSlice(),
            .crawl_delay_ms = crawl_delay,
            .fetched_ms = time.nowMs(),
            .sitemap_urls = try sitemaps.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    pub fn put(self: *RobotsCache, host: []const u8, policy: RobotsPolicy) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(host)) |existing| {
            var previous = existing.value;
            previous.deinit();
        }
        try self.entries.put(self.allocator, host, policy);
    }

    pub fn get(self: *RobotsCache, host: []const u8) ?*RobotsPolicy {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.getPtr(host);
    }

    pub fn isFresh(self: *RobotsCache, host: []const u8, now_ms: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const policy = self.entries.get(host) orelse return false;
        return now_ms - policy.fetched_ms < self.ttl_ms;
    }
};

pub const HostSchedule = struct {
    last_request_ms: i64 = 0,
    delay_ms: u32 = 1000,
    consecutive_failures: u32 = 0,
    in_flight: u32 = 0,
    penalty_ms: u32 = 0,

    pub fn readyAt(self: *const HostSchedule) i64 {
        return self.last_request_ms + @as(i64, self.delay_ms) + @as(i64, self.penalty_ms);
    }
};

pub const Politeness = struct {
    allocator: std.mem.Allocator,
    hosts: std.AutoHashMapUnmanaged(u64, HostSchedule) = .{},
    mutex: std.Thread.Mutex = .{},
    default_delay_ms: u32,

    pub fn init(allocator: std.mem.Allocator, default_delay_ms: u32) Politeness {
        return .{ .allocator = allocator, .default_delay_ms = default_delay_ms };
    }

    pub fn deinit(self: *Politeness) void {
        self.hosts.deinit(self.allocator);
    }

    pub fn waitMs(self: *Politeness, host_hash: u64, now_ms: i64) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.hosts.getOrPut(self.allocator, host_hash) catch return 0;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .delay_ms = self.default_delay_ms };
            return 0;
        }
        const ready = entry.value_ptr.readyAt();
        if (ready <= now_ms) return 0;
        return @intCast(ready - now_ms);
    }

    pub fn noteRequest(self: *Politeness, host_hash: u64, now_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.hosts.getOrPut(self.allocator, host_hash) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{ .delay_ms = self.default_delay_ms };
        entry.value_ptr.last_request_ms = now_ms;
    }

    pub fn setDelay(self: *Politeness, host_hash: u64, delay_ms: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.hosts.getOrPut(self.allocator, host_hash) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{ .delay_ms = self.default_delay_ms };
        entry.value_ptr.delay_ms = delay_ms;
    }

    pub fn noteFailure(self: *Politeness, host_hash: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.hosts.getOrPut(self.allocator, host_hash) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{ .delay_ms = self.default_delay_ms };
        entry.value_ptr.consecutive_failures += 1;
        entry.value_ptr.penalty_ms = @min(60000, entry.value_ptr.consecutive_failures * 1000);
    }

    pub fn noteSuccess(self: *Politeness, host_hash: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.hosts.getOrPut(self.allocator, host_hash) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{ .delay_ms = self.default_delay_ms };
        entry.value_ptr.consecutive_failures = 0;
        entry.value_ptr.penalty_ms = 0;
    }

    pub fn hostCount(self: *Politeness) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.hosts.count();
    }
};

pub const Options = struct {
    user_agent: []const u8 = "distributed-search-engine/1.0",
    max_response_bytes: u32 = 8388608,
    request_timeout_ms: u32 = 10000,
    max_redirects: u8 = 5,
    politeness_delay_ms: u32 = 1000,
    honor_robots: bool = true,
    challenge_as_failure: bool = true,
    max_retries: u32 = 2,
    retry_base_ms: u64 = 200,
    retry_max_ms: u64 = 5000,
    tls_enabled: bool = false,
};

pub const FetchResult = struct {
    url: []const u8,
    final_url: []const u8,
    status: u16 = 0,
    body: []u8,
    content_type: []const u8,
    etag: []const u8,
    last_modified: []const u8,
    redirect_target: []const u8,
    outcome: state.FetchOutcome = .pending,
    elapsed_ms: f64 = 0,
    bytes: usize = 0,
    retry_count: u32 = 0,
    denied: bool = false,
    challenge: bool = false,
    not_modified: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FetchResult) void {
        self.allocator.free(self.url);
        self.allocator.free(self.final_url);
        self.allocator.free(self.body);
        self.allocator.free(self.content_type);
        self.allocator.free(self.etag);
        self.allocator.free(self.last_modified);
        self.allocator.free(self.redirect_target);
    }
};

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    options: Options,
    client: http_client.Client,
    robots: RobotsCache,
    politeness: Politeness,
    requests: u64 = 0,
    successes: u64 = 0,
    failures: u64 = 0,
    denied: u64 = 0,
    challenges: u64 = 0,
    redirects: u64 = 0,
    not_modified: u64 = 0,
    bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Fetcher {
        var client = http_client.Client.init(allocator, .{
            .read_timeout_ms = options.request_timeout_ms,
            .write_timeout_ms = options.request_timeout_ms,
            .connect_timeout_ms = @min(options.request_timeout_ms, 3000),
            .max_response_bytes = options.max_response_bytes,
            .user_agent = options.user_agent,
            .follow_redirects = false,
        });
        client.options.follow_redirects = false;
        return .{
            .allocator = allocator,
            .options = options,
            .client = client,
            .robots = RobotsCache.init(allocator),
            .politeness = Politeness.init(allocator, options.politeness_delay_ms),
        };
    }

    pub fn deinit(self: *Fetcher) void {
        self.client.deinit();
        self.robots.deinit();
        self.politeness.deinit();
    }

    fn ensureRobots(self: *Fetcher, components: urls.Components) !void {
        if (!self.options.honor_robots) return;
        if (self.robots.isFresh(components.host, time.nowMs())) return;
        const robots_url = try std.fmt.allocPrint(self.allocator, "{s}://{s}/robots.txt", .{ components.scheme, components.host });
        defer self.allocator.free(robots_url);
        var response = self.client.get(robots_url) catch {
            try self.robots.put(try self.allocator.dupe(u8, components.host), .{
                .rules = &.{},
                .crawl_delay_ms = 0,
                .fetched_ms = time.nowMs(),
                .sitemap_urls = &.{},
                .allocator = self.allocator,
            });
            return;
        };
        defer response.deinit();
        var policy: RobotsPolicy = undefined;
        if (response.status == 200) {
            policy = try self.robots.parseBody(response.body);
        } else {
            policy = .{
                .rules = &.{},
                .crawl_delay_ms = 0,
                .fetched_ms = time.nowMs(),
                .sitemap_urls = &.{},
                .allocator = self.allocator,
            };
        }
        try self.robots.put(try self.allocator.dupe(u8, components.host), policy);
    }

    pub fn fetch(self: *Fetcher, raw_url: []const u8, conditional: struct { etag: []const u8 = "", modified_since: []const u8 = "" }) !FetchResult {
        const components = urls.parse(raw_url) catch return FetchError.MalformedUrl;
        if (!std.mem.eql(u8, components.scheme, "http") and !std.mem.eql(u8, components.scheme, "https")) {
            return FetchError.UnsupportedScheme;
        }
        if (std.mem.eql(u8, components.scheme, "https") and !self.options.tls_enabled) return FetchError.UnsupportedScheme;
        const host_hash = urls.hostHash(components.host);
        try self.ensureRobots(components);
        if (self.options.honor_robots) {
            if (self.robots.get(components.host)) |policy| {
                if (!policy.allows(components.path)) return FetchError.RobotsDisallowed;
                self.politeness.setDelay(host_hash, @max(self.options.politeness_delay_ms, policy.delayMs()));
            }
        }
        const wait = self.politeness.waitMs(host_hash, time.nowMs());
        if (wait > 0) std.Thread.sleep(wait * std.time.ns_per_ms);
        var attempt: u32 = 0;
        while (attempt <= self.options.max_retries) : (attempt += 1) {
            const started = time.StopWatch.start();
            self.politeness.noteRequest(host_hash, time.nowMs());
            self.requests += 1;
            var response = self.client.get(raw_url) catch {
                self.failures += 1;
                self.politeness.noteFailure(host_hash);
                const delay = @min(self.options.retry_max_ms, self.options.retry_base_ms << @intCast(@min(attempt, 10)));
                if (attempt == self.options.max_retries) break;
                std.Thread.sleep(delay * std.time.ns_per_ms);
                continue;
            };
            defer response.deinit();
            var result = FetchResult{
                .url = try self.allocator.dupe(u8, raw_url),
                .final_url = try self.allocator.dupe(u8, raw_url),
                .status = response.status,
                .body = try self.allocator.dupe(u8, response.body),
                .content_type = try self.allocator.dupe(u8, response.header("content-type") orelse ""),
                .etag = try self.allocator.dupe(u8, response.header("etag") orelse ""),
                .last_modified = try self.allocator.dupe(u8, response.header("last-modified") orelse ""),
                .redirect_target = try self.allocator.dupe(u8, response.header("location") orelse ""),
                .outcome = .success,
                .elapsed_ms = started.elapsedMs(),
                .bytes = response.body.len,
                .retry_count = attempt,
                .allocator = self.allocator,
            };
            self.bytes += response.body.len;
            if (response.status == 304) {
                result.outcome = .not_modified;
                result.not_modified = true;
                self.not_modified += 1;
            } else if (response.isRedirect()) {
                result.outcome = .redirect;
                self.redirects += 1;
            } else if (response.status == 401 or response.status == 403) {
                result.outcome = .denied;
                result.denied = true;
                self.denied += 1;
            } else if (response.status == 429 or response.status == 503) {
                result.outcome = .challenge;
                result.challenge = true;
                self.challenges += 1;
                self.politeness.noteFailure(host_hash);
                if (self.options.challenge_as_failure and attempt < self.options.max_retries) {
                    result.deinit();
                    std.Thread.sleep(@min(self.options.retry_max_ms, self.options.retry_base_ms << @intCast(@min(attempt + 2, 10))) * std.time.ns_per_ms);
                    continue;
                }
            } else if (response.status >= 400 and response.status < 500) {
                result.outcome = .client_error;
            } else if (response.status >= 500) {
                result.outcome = .server_error;
                self.failures += 1;
                self.politeness.noteFailure(host_hash);
                if (attempt < self.options.max_retries and errors.isRetriable(error.DependencyUnavailable)) {
                    result.deinit();
                    std.Thread.sleep(@min(self.options.retry_max_ms, self.options.retry_base_ms << @intCast(@min(attempt + 1, 10))) * std.time.ns_per_ms);
                    continue;
                }
            } else {
                self.successes += 1;
                self.politeness.noteSuccess(host_hash);
            }
            if (result.body.len > self.options.max_response_bytes) {
                result.deinit();
                return FetchError.ContentTooLarge;
            }
            _ = conditional;
            return result;
        }
        return FetchError.FetchFailed;
    }

    pub fn fetchConditional(self: *Fetcher, raw_url: []const u8, etag: []const u8, modified_since: []const u8, stored: *std.StringHashMapUnmanaged([]const u8)) !FetchResult {
        var conditional: struct { etag: []const u8 = "", modified_since: []const u8 = "" } = .{};
        if (stored.get(raw_url)) |cached_etag| conditional.etag = cached_etag;
        if (etag.len > 0) conditional.etag = etag;
        if (modified_since.len > 0) conditional.modified_since = modified_since;
        self.client.options.conditional_etag = conditional.etag;
        self.client.options.conditional_modified_since = conditional.modified_since;
        const result = try self.fetch(raw_url, conditional);
        self.client.options.conditional_etag = "";
        self.client.options.conditional_modified_since = "";
        return result;
    }

    pub fn contentFingerprint(body: []const u8) u64 {
        return hashing.hash64(0xC2B2AE3D27D4EB4F, body);
    }

    pub fn decompressIfNeeded(allocator: std.mem.Allocator, body: []const u8, encoding: []const u8) !?[]u8 {
        if (encoding.len == 0) return null;
        if (std.ascii.indexOfIgnoreCase(encoding, "gzip") != null) {
            return try compression.gzipDecompress(allocator, body, body.len * 8 + 65536);
        }
        if (std.ascii.indexOfIgnoreCase(encoding, "deflate") != null) {
            return try compression.zlibDecompress(allocator, body, body.len * 8 + 65536);
        }
        return null;
    }

    pub fn stats(self: *Fetcher) FetcherStats {
        return .{
            .requests = self.requests,
            .successes = self.successes,
            .failures = self.failures,
            .denied = self.denied,
            .challenges = self.challenges,
            .redirects = self.redirects,
            .not_modified = self.not_modified,
            .bytes = self.bytes,
            .hosts = self.politeness.hostCount(),
        };
    }
};

pub const FetcherStats = struct {
    requests: u64,
    successes: u64,
    failures: u64,
    denied: u64,
    challenges: u64,
    redirects: u64,
    not_modified: u64,
    bytes: u64,
    hosts: usize,
};
