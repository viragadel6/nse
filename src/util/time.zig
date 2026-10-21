const std = @import("std");

pub const ns_per_ms = std.time.ns_per_ms;
pub const ns_per_us = std.time.ns_per_us;
pub const ns_per_s = std.time.ns_per_s;
pub const ms_per_s = std.time.ms_per_s;
pub const ms_per_min = 60 * std.time.ms_per_s;
pub const ms_per_hour = 60 * ms_per_min;
pub const ms_per_day = 24 * ms_per_hour;

pub fn nowNs() i64 {
    return std.time.nanoTimestamp();
}

pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}

pub fn monotonicNs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) *% @as(u64, ns_per_s) +% @as(u64, @intCast(ts.nsec));
}

pub fn monotonicMs() u64 {
    return @divFloor(monotonicNs(), ns_per_ms);
}

pub fn wallToMonotonicOffsetMs() i64 {
    return nowMs() - @as(i64, @intCast(monotonicMs()));
}

pub const StopWatch = struct {
    started: u64,
    stopped: ?u64 = null,

    pub fn start() StopWatch {
        return .{ .started = monotonicNs() };
    }

    pub fn elapsedNs(self: StopWatch) u64 {
        const end = self.stopped orelse monotonicNs();
        return end -% self.started;
    }

    pub fn elapsedMs(self: StopWatch) f64 {
        return @as(f64, @floatFromInt(self.elapsedNs())) / @as(f64, @floatFromInt(ns_per_ms));
    }

    pub fn stop(self: *StopWatch) u64 {
        if (self.stopped == null) self.stopped = monotonicNs();
        return self.elapsedNs();
    }

    pub fn lap(self: *StopWatch) u64 {
        const previous = self.started;
        self.started = monotonicNs();
        self.stopped = null;
        return monotonicNs() -% previous;
    }
};

pub const Deadline = struct {
    deadline_ns: u64,
    started_ns: u64,

    pub fn fromTimeout(timeout_ms: u64) Deadline {
        const start = monotonicNs();
        return .{ .started_ns = start, .deadline_ns = start +% timeout_ms * ns_per_ms };
    }

    pub fn unlimited() Deadline {
        return .{ .started_ns = monotonicNs(), .deadline_ns = std.math.maxInt(u64) };
    }

    pub fn remainingNs(self: Deadline) i64 {
        const now = monotonicNs();
        if (now >= self.deadline_ns) return 0;
        return @as(i64, @intCast(self.deadline_ns - now));
    }

    pub fn remainingMs(self: Deadline) i64 {
        return @divFloor(self.remainingNs(), @as(i64, ns_per_ms));
    }

    pub fn expired(self: Deadline) bool {
        return monotonicNs() >= self.deadline_ns;
    }

    pub fn elapsedMs(self: Deadline) u64 {
        return @divFloor(monotonicNs() -% self.started_ns, ns_per_ms);
    }

    pub fn budgetRatio(self: Deadline) f64 {
        const total = self.deadline_ns -% self.started_ns;
        if (total == 0 or total >= std.math.maxInt(u64)) return 1.0;
        const used = monotonicNs() -% self.started_ns;
        return @min(1.0, @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total)));
    }

    pub fn shrink(self: Deadline, other: Deadline) Deadline {
        return .{ .started_ns = @min(self.started_ns, other.started_ns), .deadline_ns = @min(self.deadline_ns, other.deadline_ns) };
    }

    pub fn unixMs(self: Deadline) i64 {
        return self.started_ns_to_unix();
    }

    fn started_ns_to_unix(self: Deadline) i64 {
        const offset = wallToMonotonicOffsetMs();
        return @as(i64, @intCast(@divFloor(self.started_ns, ns_per_ms))) +% offset;
    }
};

pub fn isLeapYear(year: i32) bool {
    return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u32) u32 {
    return switch (month) {
        1 => 31,
        2 => if (isLeapYear(year)) 31 - 1 else 28,
        3 => 31,
        4 => 30,
        5 => 31,
        6 => 30,
        7 => 31,
        8 => 31,
        9 => 30,
        10 => 31,
        11 => 30,
        12 => 31,
        else => 0,
    };
}

pub const Civil = struct {
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    millis: u32,
};

pub fn civilFromMs(epoch_ms: i64) Civil {
    var days = @divFloor(epoch_ms, @as(i64, ms_per_day));
    var rem = @mod(epoch_ms, @as(i64, ms_per_day));
    if (rem < 0) {
        rem += @as(i64, ms_per_day);
        days -= 1;
    }
    var year: i32 = 1970;
    while (true) {
        const len: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < len) break;
        days -= len;
        year += 1;
    }
    var month: u32 = 1;
    while (month <= 12) {
        const len: i64 = @intCast(daysInMonth(year, month));
        if (days < len) break;
        days -= len;
        month += 1;
    }
    return .{
        .year = year,
        .month = month,
        .day = @intCast(days + 1),
        .hour = @intCast(@divFloor(rem, 3600000)),
        .minute = @intCast(@divFloor(@mod(rem, 3600000), 60000)),
        .second = @intCast(@divFloor(@mod(rem, 60000), 1000)),
        .millis = @intCast(@mod(rem, 1000)),
    };
}

pub fn formatUtc(epoch_ms: i64, buf: []u8) ![]u8 {
    const c = civilFromMs(epoch_ms);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second, c.millis,
    });
}

pub fn formatUtcAlloc(allocator: std.mem.Allocator, epoch_ms: i64) ![]u8 {
    var buf: [64]u8 = undefined;
    const s = try formatUtc(epoch_ms, &buf);
    return allocator.dupe(u8, s);
}

pub fn parseUtc(text: []const u8) !i64 {
    if (text.len < 19) return error.MalformedTimestamp;
    const year = try std.fmt.parseInt(i32, text[0..4], 10);
    if (text[4] != '-') return error.MalformedTimestamp;
    const month = try std.fmt.parseInt(u32, text[5..7], 10);
    if (text[7] != '-') return error.MalformedTimestamp;
    const day = try std.fmt.parseInt(u32, text[8..10], 10);
    if (text[10] != 'T' and text[10] != ' ') return error.MalformedTimestamp;
    const hour = try std.fmt.parseInt(u32, text[11..13], 10);
    if (text[13] != ':') return error.MalformedTimestamp;
    const minute = try std.fmt.parseInt(u32, text[14..16], 10);
    if (text[16] != ':') return error.MalformedTimestamp;
    const second = try std.fmt.parseInt(u32, text[17..19], 10);
    var millis: u32 = 0;
    if (text.len >= 21 and text[19] == '.') {
        var end: usize = 20;
        while (end < text.len and (text[end] >= '0' and text[end] <= '9')) end += 1;
        const digits = text[20..end];
        if (digits.len > 0) {
            var scale: u32 = 100;
            for (digits) |d| {
                millis += @as(u32, d - '0') * scale;
                scale /= 10;
                if (scale == 0) break;
            }
        }
    }
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.MalformedTimestamp;
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) days += if (isLeapYear(y)) 366 else 365;
    var m: u32 = 1;
    while (m < month) : (m += 1) days += @as(i64, daysInMonth(year, m));
    days += @as(i64, day) - 1;
    var epoch = days * @as(i64, ms_per_day);
    epoch += @as(i64, hour) * 3600000;
    epoch += @as(i64, minute) * 60000;
    epoch += @as(i64, second) * 1000;
    epoch += @as(i64, millis);
    if (text.len > 0 and (text[text.len - 1] == 'Z' or text[text.len - 1] == 'z')) return epoch;
    var sign_index: ?usize = null;
    for (text, 0..) |ch, i| {
        if (i >= 19 and (ch == '+' or ch == '-')) {
            sign_index = i;
            break;
        }
    }
    if (sign_index) |idx| {
        if (text.len >= idx + 5) {
            const oh = try std.fmt.parseInt(i32, text[idx + 1 .. idx + 3], 10);
            const om = try std.fmt.parseInt(i32, text[idx + 4 .. idx + 6], 10);
            const offset = (@as(i64, oh) * 60 + @as(i64, om)) * 60000;
            epoch -= if (text[idx] == '-') -offset else offset;
        }
    }
    return epoch;
}

pub fn parseHttpDate(text: []const u8) !i64 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    const _day = it.next() orelse return error.MalformedTimestamp;
    const mon = it.next() orelse return error.MalformedTimestamp;
    const year_text = it.next() orelse return error.MalformedTimestamp;
    const time_text = it.next() orelse return error.MalformedTimestamp;
    const day = std.fmt.parseInt(u32, _day, 10) catch return error.MalformedTimestamp;
    var month: u32 = 0;
    for (months, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m, mon)) month = @intCast(i + 1);
    }
    if (month == 0) return error.MalformedTimestamp;
    const year = std.fmt.parseInt(i32, year_text, 10) catch return error.MalformedTimestamp;
    var parts = std.mem.splitScalar(u8, time_text, ':');
    const hour = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    const minute = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    const second = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    if (day < 1 or day > daysInMonth(year, month)) return error.MalformedTimestamp;
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) days += if (isLeapYear(y)) 366 else 365;
    var m: u32 = 1;
    while (m < month) : (m += 1) days += @as(i64, daysInMonth(year, m));
    days += @as(i64, day) - 1;
    return days * @as(i64, ms_per_day) + @as(i64, hour) * 3600000 + @as(i64, minute) * 60000 + @as(i64, second) * 1000;
}

pub const RateMeter = struct {
    window_ms: u64,
    slots: []u64,
    slot_start_ms: u64,
    index: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, window_ms: u64, slot_count: usize) !RateMeter {
        if (slot_count == 0) return error.InvalidConfiguration;
        const slots = try allocator.alloc(u64, slot_count);
        @memset(slots, 0);
        return .{ .window_ms = window_ms, .slots = slots, .slot_start_ms = monotonicMs(), .index = 0, .allocator = allocator };
    }

    pub fn deinit(self: *RateMeter) void {
        self.allocator.free(self.slots);
    }

    pub fn record(self: *RateMeter, count: u64) void {
        self.advance();
        self.slots[self.index] += count;
    }

    fn advance(self: *RateMeter) void {
        const now = monotonicMs();
        const slot_width = @max(1, self.window_ms / @as(u64, self.slots.len));
        var steps = @divFloor(now - self.slot_start_ms, slot_width);
        if (steps == 0) return;
        if (steps >= self.slots.len) {
            @memset(self.slots, 0);
            self.slot_start_ms = now;
            self.index = 0;
            return;
        }
        while (steps > 0) : (steps -= 1) {
            self.index = (self.index + 1) % self.slots.len;
            self.slots[self.index] = 0;
        }
        self.slot_start_ms = now;
    }

    pub fn total(self: *RateMeter) u64 {
        self.advance();
        var sum: u64 = 0;
        for (self.slots) |s| sum += s;
        return sum;
    }

    pub fn perSecond(self: *RateMeter) f64 {
        const elapsed = @max(1, monotonicMs() - self.slot_start_ms + self.window_ms);
        return @as(f64, @floatFromInt(self.total())) / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
    }
};
