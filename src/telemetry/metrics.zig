const std = @import("std");
const Counter = std.atomic.Value(u64);

pub const Metrics = struct {
    requests: Counter = Counter.init(0),
    errors: Counter = Counter.init(0),
    searches: Counter = Counter.init(0),
    ingested: Counter = Counter.init(0),
    deleted: Counter = Counter.init(0),
    recovered: Counter = Counter.init(0),
    fetched: Counter = Counter.init(0),
    fetch_errors: Counter = Counter.init(0),
    active: Counter = Counter.init(0),
    latency_sum_ns: Counter = Counter.init(0),
    latency_count: Counter = Counter.init(0),
    buckets: [12]Counter = [_]Counter{Counter.init(0)} ** 12,

    pub fn increment(counter: *Counter) void {
        _ = counter.fetchAdd(1, .monotonic);
    }

    pub fn observe(self: *Metrics, nanoseconds: u64) void {
        _ = self.latency_sum_ns.fetchAdd(nanoseconds, .monotonic);
        increment(&self.latency_count);
        var boundary: u64 = std.time.ns_per_ms;
        for (&self.buckets) |*bucket| {
            if (nanoseconds <= boundary) increment(bucket);
            boundary *= 2;
        }
    }

    pub fn render(self: *const Metrics, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();
        inline for (.{ "requests", "errors", "searches", "ingested", "deleted", "recovered", "fetched", "fetch_errors", "active" }) |name| {
            try output.writer().print("search_{s} {d}\n", .{ name, @field(self, name).load(.monotonic) });
        }
        var boundary: u64 = 1;
        for (&self.buckets) |*bucket| {
            try output.writer().print("search_latency_ms_bucket{{le=\"{d}\"}} {d}\n", .{ boundary, bucket.load(.monotonic) });
            boundary *= 2;
        }
        const count = self.latency_count.load(.monotonic);
        try output.writer().print("search_latency_ms_bucket{{le=\"+Inf\"}} {d}\nsearch_latency_ms_count {d}\nsearch_latency_ms_sum {d}\n", .{ count, count, @as(f64, @floatFromInt(self.latency_sum_ns.load(.monotonic))) / std.time.ns_per_ms });
        return output.toOwnedSlice();
    }
}
;