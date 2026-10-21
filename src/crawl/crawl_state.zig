const std = @import("std");
const codec = @import("../util/binary_codec.zig");
const time = @import("../util/time.zig");

pub const StateError = error{
    InvalidTransition,
    LeaseExpired,
    RecordTooLarge,
    TruncatedRecord,
};

pub const FetchState = enum(u8) {
    discovered = 0,
    scheduled = 1,
    leased = 2,
    fetched = 3,
    failed = 4,
    redirected = 5,
    rejected = 6,
    expired = 7,
    quarantined = 8,
};

pub const RejectReason = enum(u8) {
    none = 0,
    robots_disallowed = 1,
    invalid_url = 2,
    content_too_large = 3,
    unsupported_scheme = 4,
    duplicate_content = 5,
    low_quality = 6,
    spam = 7,
    denied_access = 8,
    challenge_response = 9,
    malformed_document = 10,
};

pub const FetchOutcome = enum(u8) {
    pending = 0,
    success = 1,
    not_modified = 2,
    redirect = 3,
    client_error = 4,
    server_error = 5,
    network_error = 6,
    timeout = 7,
    denied = 8,
    challenge = 9,
    content_limit = 10,
    parse_failure = 11,
};

pub const UrlRecord = struct {
    canonical_hash: u64 = 0,
    url_hash: u64 = 0,
    domain_hash: u64 = 0,
    canonical_url: []const u8 = "",
    original_url: []const u8 = "",
    redirect_target: []const u8 = "",
    state: FetchState = .discovered,
    discoverer_domain_hash: u64 = 0,
    discovered_ms: i64 = 0,
    previous_fetch_ms: i64 = 0,
    next_fetch_ms: i64 = 0,
    last_status: u16 = 0,
    content_fingerprint: u64 = 0,
    retry_count: u8 = 0,
    priority: u16 = 0,
    fetch_count: u32 = 0,
    change_count: u32 = 0,
    lease_owner: u32 = 0,
    lease_expiry_ms: i64 = 0,
    reject_reason: RejectReason = .none,
    outcome: FetchOutcome = .pending,
    flags: u32 = 0,

    pub const flag_priority_content: u32 = 1 << 0;
    pub const flag_javascript_rendered: u32 = 1 << 1;
    pub const flag_sitemap_source: u32 = 1 << 2;
    pub const flag_manual_seed: u32 = 1 << 3;
    pub const flag_browser_render: u32 = 1 << 4;

    pub fn release(self: UrlRecord, allocator: std.mem.Allocator) void {
        if (self.canonical_url.len > 0) allocator.free(self.canonical_url);
        if (self.original_url.len > 0) allocator.free(self.original_url);
        if (self.redirect_target.len > 0) allocator.free(self.redirect_target);
    }

    pub fn encodedSize(self: UrlRecord) usize {
        return 8 * 3 + 4 + 8 * 4 + 2 + 1 + 1 + 2 + 4 + 4 + 4 + 8 + 1 + 1 + 4 + (4 + self.canonical_url.len) + (4 + self.original_url.len) + (4 + self.redirect_target.len);
    }

    pub fn encode(self: UrlRecord, allocator: std.mem.Allocator) ![]u8 {
        const size = self.encodedSize();
        if (size > (1 << 20)) return StateError.RecordTooLarge;
        const buffer = try allocator.alloc(u8, size);
        var writer = codec.Writer.init(buffer);
        try writer.writeU64(self.canonical_hash);
        try writer.writeU64(self.url_hash);
        try writer.writeU64(self.domain_hash);
        try writer.writeU32(@intFromEnum(self.state));
        try writer.writeU64(self.discoverer_domain_hash);
        try writer.writeI64(self.discovered_ms);
        try writer.writeI64(self.previous_fetch_ms);
        try writer.writeI64(self.next_fetch_ms);
        try writer.writeU16(self.last_status);
        try writer.writeByte(self.retry_count);
        try writer.writeByte(@intFromEnum(self.reject_reason));
        try writer.writeU16(self.priority);
        try writer.writeU32(self.fetch_count);
        try writer.writeU32(self.change_count);
        try writer.writeU32(self.lease_owner);
        try writer.writeI64(self.lease_expiry_ms);
        try writer.writeByte(@intFromEnum(self.outcome));
        try writer.writeU64(self.content_fingerprint);
        try writer.writeU32(self.flags);
        try writer.writeLengthPrefixed(self.canonical_url);
        try writer.writeLengthPrefixed(self.original_url);
        try writer.writeLengthPrefixed(self.redirect_target);
        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !UrlRecord {
        var reader = codec.Reader.init(payload);
        var record = UrlRecord{};
        record.canonical_hash = try reader.readU64();
        record.url_hash = try reader.readU64();
        record.domain_hash = try reader.readU64();
        record.state = @enumFromInt(try reader.readU32());
        record.discoverer_domain_hash = try reader.readU64();
        record.discovered_ms = try reader.readI64();
        record.previous_fetch_ms = try reader.readI64();
        record.next_fetch_ms = try reader.readI64();
        record.last_status = try reader.readU16();
        record.retry_count = try reader.readByte();
        record.reject_reason = @enumFromInt(try reader.readByte());
        record.priority = try reader.readU16();
        record.fetch_count = try reader.readU32();
        record.change_count = try reader.readU32();
        record.lease_owner = try reader.readU32();
        record.lease_expiry_ms = try reader.readI64();
        record.outcome = @enumFromInt(try reader.readByte());
        record.content_fingerprint = try reader.readU64();
        record.flags = try reader.readU32();
        record.canonical_url = try allocator.dupe(u8, try reader.readLengthPrefixed(1 << 16));
        errdefer allocator.free(record.canonical_url);
        record.original_url = try allocator.dupe(u8, try reader.readLengthPrefixed(1 << 16));
        errdefer allocator.free(record.original_url);
        record.redirect_target = try allocator.dupe(u8, try reader.readLengthPrefixed(1 << 16));
        return record;
    }
};

pub fn transitionAllowed(from: FetchState, to: FetchState) bool {
    return switch (from) {
        .discovered => to == .scheduled or to == .rejected or to == .quarantined or to == .expired,
        .scheduled => to == .leased or to == .rejected or to == .expired or to == .quarantined,
        .leased => to == .fetched or to == .failed or to == .redirected or to == .scheduled or to == .expired or to == .rejected,
        .fetched => to == .scheduled or to == .expired or to == .quarantined,
        .failed => to == .scheduled or to == .rejected or to == .expired,
        .redirected => to == .scheduled or to == .rejected or to == .fetched,
        .rejected => to == .scheduled or to == .expired,
        .expired => to == .scheduled or to == .discovered,
        .quarantined => to == .scheduled or to == .expired,
    };
}

pub fn applyTransition(record: *UrlRecord, to: FetchState) StateError!void {
    if (!transitionAllowed(record.state, to)) return StateError.InvalidTransition;
    record.state = to;
}

pub const Transition = struct {
    canonical_hash: u64,
    from: FetchState,
    to: FetchState,
    worker: u32,
    timestamp_ms: i64,
    detail: [16]u8,

    pub fn encode(self: Transition, buffer: []u8) ![]u8 {
        var writer = codec.Writer.init(buffer);
        try writer.writeU64(self.canonical_hash);
        try writer.writeU32(@intFromEnum(self.from));
        try writer.writeU32(@intFromEnum(self.to));
        try writer.writeU32(self.worker);
        try writer.writeI64(self.timestamp_ms);
        try writer.writeBytes(&self.detail);
        return writer.written();
    }

    pub fn decode(payload: []const u8) !Transition {
        var reader = codec.Reader.init(payload);
        var detail: [16]u8 = @splat(0);
        const canonical_hash = try reader.readU64();
        const from: FetchState = @enumFromInt(try reader.readU32());
        const to: FetchState = @enumFromInt(try reader.readU32());
        const worker = try reader.readU32();
        const timestamp = try reader.readI64();
        const detail_bytes = try reader.readBytes(16);
        @memcpy(&detail, detail_bytes);
        return .{ .canonical_hash = canonical_hash, .from = from, .to = to, .worker = worker, .timestamp_ms = timestamp, .detail = detail };
    }

    pub const encoded_size = 44;
};

pub fn leaseIsValid(record: *const UrlRecord, now_ms: i64) bool {
    return record.state == .leased and record.lease_expiry_ms > now_ms;
}

pub fn scheduleRetry(record: *UrlRecord, now_ms: i64, attempt: u32, base_delay_ms: u64, max_delay_ms: u64) void {
    const exponent = @min(@as(u32, 20), attempt);
    const delay = @min(max_delay_ms, base_delay_ms << @intCast(exponent));
    record.retry_count +|= 1;
    record.next_fetch_ms = now_ms + @as(i64, @intCast(delay));
    record.state = .scheduled;
}

pub fn priorityFor(record: *const UrlRecord, velocity_weight: f64, freshness_weight: f64, now_ms: i64) f64 {
    const age = @max(0, now_ms - record.discovered_ms);
    const freshness = 1.0 / (1.0 + @as(f64, @floatFromInt(@divFloor(age, 3600000))));
    const change_rate = if (record.fetch_count > 0) @as(f64, @floatFromInt(record.change_count)) / @as(f64, @floatFromInt(record.fetch_count)) else 0.0;
    const overdue = @max(0.0, @as(f64, @floatFromInt(now_ms - record.next_fetch_ms)));
    const base = @as(f64, @floatFromInt(record.priority)) / 65535.0;
    return base + velocity_weight * change_rate + freshness_weight * freshness + 0.000001 * overdue;
}

pub fn dueForFetch(record: *const UrlRecord, now_ms: i64) bool {
    if (record.state != .scheduled) return false;
    return record.next_fetch_ms <= now_ms;
}

pub fn nowMs() i64 {
    return time.nowMs();
}
