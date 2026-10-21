const std = @import("std");

pub const Anomaly = enum { template_shift, length_distribution, missing_fields, abnormal_redirects, honeypot, duplicate_spike };

pub const Detector = struct {
    lock: std.Thread.Mutex,
    anomalies: std.ArrayList(struct { kind: Anomaly, domain: []const u8, timestamp_ms: i64, severity: f32 }),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Detector {
        return Detector{ .lock = .{}, .anomalies = std.ArrayList(struct { kind: Anomaly, domain: []const u8, timestamp_ms: i64, severity: f32 }).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Detector) void {
        for (self.anomalies.items) |*anomaly| self.allocator.free(anomaly.domain);
        self.anomalies.deinit();
    }

    pub fn record(self: *Detector, kind: Anomaly, domain: []const u8, severity: f32, timestamp_ms: i64) void {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try self.anomalies.append({ .kind = kind, .domain = try self.allocator.dupe(u8, domain), .timestamp_ms = timestamp_ms, .severity = severity });
    }

    pub fn count(self: *Detector) usize {
        self.lock.lock();
        const count = self.anomalies.items.len;
        self.lock.unlock();
        return count;
    }
};
