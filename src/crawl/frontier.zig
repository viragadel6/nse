const std = @import("std");
const hashing = @import("../util/hashing.zig");
const time = @import("../util/time.zig");
const state = @import("crawl_state.zig");
const partitions = @import("frontier_partition.zig");
const txlog = @import("../storage/transaction_log.zig");

pub const FrontierError = error{
    CapacityExceeded,
    PartitionUnavailable,
    InvalidRecord,
    LeaseUnavailable,
    NotFound,
    CheckpointFailed,
};

pub const slot_chunk: u64 = 256;

pub const Options = struct {
    dir: []const u8 = "data/frontier",
    partition_count: u32 = 64,
    slots_per_partition: u64 = 1 << 16,
    capacity_urls: u64 = 1400000000000,
    lease_duration_ms: u64 = 300000,
    scan_window: u32 = 512,
    wal_dir: []const u8 = "data/frontier/wal",
    default_interval_ms: u64 = 86400000,
    min_interval_ms: u64 = 3600000,
    max_interval_ms: u64 = 2592000000,
};

pub const DiscoveryOutcome = enum(u8) {
    inserted,
    duplicate,
    rejected,
    updated,
};

pub const Frontier = struct {
    allocator: std.mem.Allocator,
    options: Options,
    partitions: []partitions.Partition,
    wal: txlog.Log,
    mutex: std.Thread.Mutex = .{},
    cursors: []u64,
    discovered: u64 = 0,
    duplicates: u64 = 0,
    leased: u64 = 0,
    completed: u64 = 0,
    rejected: u64 = 0,
    redirected: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Frontier {
        std.fs.cwd().makePath(options.dir) catch {};
        const list = try allocator.alloc(partitions.Partition, options.partition_count);
        errdefer allocator.free(list);
        for (list, 0..) |*slot, index| {
            slot.* = try partitions.Partition.init(allocator, options.dir, @intCast(index), .{ .slot_count = options.slots_per_partition });
        }
        const cursors = try allocator.alloc(u64, options.partition_count);
        @memset(cursors, 0);
        const wal = try txlog.Log.init(allocator, .{ .dir = options.wal_dir, .sync_on_write = true });
        var frontier = Frontier{
            .allocator = allocator,
            .options = options,
            .partitions = list,
            .wal = wal,
            .cursors = cursors,
        };
        _ = try frontier.recover();
        return frontier;
    }

    pub fn deinit(self: *Frontier) void {
        for (self.partitions) |*partition| partition.deinit();
        self.allocator.free(self.partitions);
        self.allocator.free(self.cursors);
        self.wal.deinit();
    }

    fn partitionIndex(self: *const Frontier, canonical_hash: u64) u32 {
        return partitions.partitionFor(canonical_hash, self.options.partition_count);
    }

    pub fn trackedCount(self: *Frontier) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var total: u64 = 0;
        for (self.partitions) |*partition| total += partition.live_count;
        return total;
    }

    pub fn capacityUtilization(self: *Frontier) f64 {
        if (self.options.capacity_urls == 0) return 1.0;
        return @as(f64, @floatFromInt(self.trackedCount())) / @as(f64, @floatFromInt(self.options.capacity_urls));
    }

    pub fn discover(self: *Frontier, record: state.UrlRecord) !DiscoveryOutcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.trackedCountLocked() >= self.options.capacity_urls) return FrontierError.CapacityExceeded;
        const index = self.partitionIndex(record.canonical_hash);
        const partition = &self.partitions[index];
        if (try partition.lookup(record.canonical_hash)) |existing| {
            var mutable = existing;
            defer mutable.release(self.allocator);
            self.duplicates += 1;
            if (record.priority > mutable.priority) {
                mutable.priority = record.priority;
                try partition.upsert(&mutable);
                return .updated;
            }
            return .duplicate;
        }
        var inserted = record;
        if (inserted.state == .discovered) {
            inserted.state = .scheduled;
            inserted.next_fetch_ms = time.nowMs();
        }
        if (inserted.discovered_ms == 0) inserted.discovered_ms = time.nowMs();
        try partition.upsert(&inserted);
        self.discovered += 1;
        try self.recordTransition(inserted.canonical_hash, state.FetchState.discovered, inserted.state, 0);
        return .inserted;
    }

    fn trackedCountLocked(self: *Frontier) u64 {
        var total: u64 = 0;
        for (self.partitions) |*partition| total += partition.live_count;
        return total;
    }

    pub fn lookup(self: *Frontier, allocator: std.mem.Allocator, canonical_hash: u64) !?state.UrlRecord {
        const index = self.partitionIndex(canonical_hash);
        return self.partitions[index].lookup(allocator, canonical_hash);
    }

    pub fn contains(self: *Frontier, canonical_hash: u64) !bool {
        const index = self.partitionIndex(canonical_hash);
        return self.partitions[index].contains(canonical_hash);
    }

    pub fn lease(self: *Frontier, worker_id: u32, count: usize, now_ms: i64) ![]state.UrlRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        var candidates = std.ArrayList(state.UrlRecord).init(self.allocator);
        const expiry = now_ms + @as(i64, @intCast(self.options.lease_duration_ms));
        const partition_count = self.partitions.len;
        var inspected: usize = 0;
        var buffer: [slot_chunk * partitions.slot_bytes]u8 = undefined;
        while (candidates.items.len < count and inspected < partition_count * 4) : (inspected += 1) {
            const index = @mod(@as(u64, @intCast(inspected)), @as(u64, @intCast(partition_count)));
            const partition = &self.partitions[index];
            if (partition.live_count == 0) continue;
            const cursor = self.cursors[index];
            const window = self.scanWindowFor(partition);
            var scanned: u64 = 0;
            while (scanned < window and candidates.items.len < count) {
                const slot_index = (cursor + scanned) % partition.options.slot_count;
                const slots = try partition.readSlotRange(&buffer, slot_index, slot_chunk);
                if (slots == 0) break;
                for (0..slots) |offset| {
                    if (candidates.items.len >= count) break;
                    const slot = partitions.Slot.decode(buffer[offset * partitions.slot_bytes ..][0..partitions.slot_bytes]) catch continue;
                    if (slot.hash == 0) continue;
                    if (slot.state != @intFromEnum(state.FetchState.scheduled)) continue;
                    const record = (try partition.lookup(slot.hash)) orelse continue;
                    if (record.next_fetch_ms > now_ms) {
                        record.release(self.allocator);
                        continue;
                    }
                    var leased_record = record;
                    leased_record.state = .leased;
                    leased_record.lease_owner = worker_id;
                    leased_record.lease_expiry_ms = expiry;
                    try partition.upsert(&leased_record);
                    try self.recordTransition(leased_record.canonical_hash, state.FetchState.scheduled, state.FetchState.leased, worker_id);
                    try candidates.append(leased_record);
                    self.leased += 1;
                }
                scanned += slots;
            }
            self.cursors[index] = (cursor + scanned) % partition.options.slot_count;
        }
        return candidates.toOwnedSlice();
    }

    fn scanWindowFor(self: *const Frontier, partition: *const partitions.Partition) u64 {
        if (partition.live_count * 8 < partition.options.slot_count) return partition.options.slot_count;
        return @min(self.options.scan_window, partition.options.slot_count);
    }

    fn readSlot(_: *Frontier, partition: *partitions.Partition, slot_index: u64) !partitions.Slot {
        var buffer: [partitions.slot_bytes]u8 = undefined;
        _ = try partition.slot_file.preadAll(&buffer, 64 + slot_index * partitions.slot_bytes);
        return partitions.Slot.decode(&buffer);
    }

    pub fn complete(self: *Frontier, canonical_hash: u64, outcome: state.FetchOutcome, status: u16, fingerprint: u64, changed: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.partitionIndex(canonical_hash);
        const partition = &self.partitions[index];
        var record = (try partition.lookup(canonical_hash)) orelse return FrontierError.NotFound;
        defer record.release(self.allocator);
        const from = record.state;
        record.outcome = outcome;
        record.last_status = status;
        record.previous_fetch_ms = time.nowMs();
        record.fetch_count += 1;
        if (changed) {
            record.change_count += 1;
            record.content_fingerprint = fingerprint;
        }
        record.state = .fetched;
        record.lease_owner = 0;
        record.lease_expiry_ms = 0;
        record.next_fetch_ms = time.nowMs() + @as(i64, @intCast(self.options.default_interval_ms));
        try partition.upsert(&record);
        try self.recordTransition(canonical_hash, from, state.FetchState.fetched, record.lease_owner);
        self.completed += 1;
    }

    pub fn reject(self: *Frontier, canonical_hash: u64, reason: state.RejectReason) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.partitionIndex(canonical_hash);
        const partition = &self.partitions[index];
        var record = (try partition.lookup(canonical_hash)) orelse return FrontierError.NotFound;
        defer record.release(self.allocator);
        const from = record.state;
        record.state = .rejected;
        record.reject_reason = reason;
        record.next_fetch_ms = time.nowMs() + @as(i64, @intCast(self.options.max_interval_ms));
        try partition.upsert(&record);
        try self.recordTransition(canonical_hash, from, state.FetchState.rejected, record.lease_owner);
        self.rejected += 1;
    }

    pub fn redirect(self: *Frontier, original_hash: u64, target: []const u8, target_hash: u64, status: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.partitionIndex(original_hash);
        const partition = &self.partitions[index];
        var record = (try partition.lookup(original_hash)) orelse return FrontierError.NotFound;
        defer record.release(self.allocator);
        const from = record.state;
        record.state = .redirected;
        record.last_status = status;
        record.redirect_target = try self.allocator.dupe(u8, target);
        record.next_fetch_ms = time.nowMs() + @as(i64, @intCast(self.options.max_interval_ms));
        try partition.upsert(&record);
        var target_record = state.UrlRecord{
            .canonical_hash = target_hash,
            .url_hash = hashing.hash64(0xA5A5A5A5, target),
            .domain_hash = record.domain_hash,
            .canonical_url = try self.allocator.dupe(u8, target),
            .original_url = try self.allocator.dupe(u8, target),
            .state = .scheduled,
            .discovered_ms = time.nowMs(),
            .next_fetch_ms = time.nowMs(),
            .priority = record.priority,
            .flags = record.flags,
        };
        defer target_record.release(self.allocator);
        const target_index = self.partitionIndex(target_hash);
        try self.partitions[target_index].upsert(&target_record);
        try self.recordTransition(original_hash, from, state.FetchState.redirected, record.lease_owner);
        self.redirected += 1;
    }

    pub fn reschedule(self: *Frontier, canonical_hash: u64, interval_ms: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.partitionIndex(canonical_hash);
        const partition = &self.partitions[index];
        var record = (try partition.lookup(canonical_hash)) orelse return FrontierError.NotFound;
        defer record.release(self.allocator);
        const from = record.state;
        const clamped = @min(self.options.max_interval_ms, @max(self.options.min_interval_ms, interval_ms));
        record.state = .scheduled;
        record.next_fetch_ms = time.nowMs() + @as(i64, @intCast(clamped));
        record.lease_owner = 0;
        record.lease_expiry_ms = 0;
        try partition.upsert(&record);
        try self.recordTransition(canonical_hash, from, state.FetchState.scheduled, 0);
    }

    pub fn requeueExpiredLeases(self: *Frontier, now_ms: i64) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var requeued: u64 = 0;
        for (self.partitions) |*partition| {
            var index: u64 = 0;
            var buffer: [partitions.slot_bytes]u8 = undefined;
            while (index < partition.options.slot_count) : (index += 1) {
                const read = try partition.slot_file.preadAll(&buffer, 64 + index * partitions.slot_bytes);
                if (read < partitions.slot_bytes) break;
                const slot = try partitions.Slot.decode(&buffer);
                if (slot.hash == 0) continue;
                if (slot.state != @intFromEnum(state.FetchState.leased)) continue;
                const record = (try partition.lookup(slot.hash)) orelse continue;
                var mutable = record;
                if (mutable.lease_expiry_ms <= now_ms) {
                    mutable.state = .scheduled;
                    mutable.next_fetch_ms = now_ms;
                    mutable.lease_owner = 0;
                    mutable.lease_expiry_ms = 0;
                    try partition.upsert(&mutable);
                    try self.recordTransition(mutable.canonical_hash, state.FetchState.leased, state.FetchState.scheduled, 0);
                    requeued += 1;
                }
                mutable.release(self.allocator);
            }
        }
        return requeued;
    }

    fn recordTransition(self: *Frontier, canonical_hash: u64, from: state.FetchState, to: state.FetchState, worker: u32) !void {
        var buffer: [state.Transition.encoded_size]u8 = undefined;
        const transition = state.Transition{
            .canonical_hash = canonical_hash,
            .from = from,
            .to = to,
            .worker = worker,
            .timestamp_ms = time.nowMs(),
            .detail = @splat(0),
        };
        const payload = transition.encode(&buffer) catch return;
        _ = self.wal.append(.frontier_transition, payload) catch {};
    }

    pub fn recover(self: *Frontier) !usize {
        var context = RecoveryContext{ .frontier = self, .applied = 0 };
        return self.wal.replay(&context, applyTransition);
    }

    const RecoveryContext = struct {
        frontier: *Frontier,
        applied: usize,
    };

    fn applyTransition(context: *anyopaque, record: txlog.Record) !void {
        const recovery: *RecoveryContext = @ptrCast(@alignCast(context));
        if (record.kind != .frontier_transition) return;
        const transition = state.Transition.decode(record.payload) catch return;
        const frontier = recovery.frontier;
        const index = frontier.partitionIndex(transition.canonical_hash);
        const partition = &frontier.partitions[index];
        var stored = (try partition.lookup(transition.canonical_hash)) orelse return;
        if (@intFromEnum(stored.state) == @intFromEnum(transition.from)) {
            stored.state = transition.to;
            if (transition.to == .leased) stored.lease_expiry_ms = record.timestamp_ms + 300000;
            try partition.upsert(&stored);
            recovery.applied += 1;
        }
        stored.release(frontier.allocator);
    }

    pub fn stats(self: *Frontier) FrontierStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        var depth: u64 = 0;
        const due: u64 = 0;
        var max_load: f64 = 0;
        var min_load: f64 = 1.0;
        var total_bytes: u64 = 0;
        for (self.partitions) |*partition| {
            const partition_stats = partition.stats();
            depth += partition_stats.live;
            total_bytes += partition_stats.bytes_written;
            if (partition_stats.load_factor > max_load) max_load = partition_stats.load_factor;
            if (partition_stats.load_factor < min_load) min_load = partition_stats.load_factor;
        }
        return .{
            .tracked_urls = depth,
            .due_urls = due,
            .discovered = self.discovered,
            .duplicates = self.duplicates,
            .leased = self.leased,
            .completed = self.completed,
            .rejected = self.rejected,
            .redirected = self.redirected,
            .partitions = self.partitions.len,
            .skew = max_load - min_load,
            .max_load_factor = max_load,
            .capacity_urls = self.options.capacity_urls,
            .bytes_written = total_bytes,
        };
    }

    pub fn dedupRate(self: *Frontier) f64 {
        const total = self.discovered + self.duplicates;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.duplicates)) / @as(f64, @floatFromInt(total));
    }

    pub fn countDue(self: *Frontier, allocator: std.mem.Allocator, now_ms: i64) !u64 {
        var context = DueContext{ .now_ms = now_ms, .count = 0 };
        for (self.partitions) |*partition| {
            _ = try partition.scan(allocator, countDueVisitor, &context);
        }
        return context.count;
    }
};

const DueContext = struct {
    now_ms: i64,
    count: u64,
};

fn countDueVisitor(context: *anyopaque, record: state.UrlRecord) !void {
    const due: *DueContext = @ptrCast(@alignCast(context));
    if (state.dueForFetch(&record, due.now_ms)) due.count += 1;
}

pub const FrontierStats = struct {
    tracked_urls: u64,
    due_urls: u64,
    discovered: u64,
    duplicates: u64,
    leased: u64,
    completed: u64,
    rejected: u64,
    redirected: u64,
    partitions: usize,
    skew: f64,
    max_load_factor: f64,
    capacity_urls: u64,
    bytes_written: u64,
};
