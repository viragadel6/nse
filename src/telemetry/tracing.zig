const std = @import("std");

pub const Span = struct {
    trace_id: u64,
    span_id: u64,
    parent_id: ?u64,
    name: []const u8,
    start_ms: i64,
    end_ms: i64 = 0,
    finished: bool = false,
};

pub const Tracer = struct {
    spans: std.ArrayList(Span),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    sample_rate: f32 = 0.01,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) Tracer {
        return Tracer{ .spans = std.ArrayList(Span).init(allocator), .lock = .{}, .allocator = allocator, .sample_rate = sample_rate };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.spans.items) |*span| self.allocator.free(span.name);
        self.spans.deinit();
    }

    pub fn start(self: *Tracer, trace_id: u64, parent_id: ?u64, name: []const u8) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const span_id = self.next_id;
        self.next_id += 1;
        _ = try self.spans.append(Span{ .trace_id = trace_id, .span_id = span_id, .parent_id = parent_id, .name = try self.allocator.dupe(u8, name), .start_ms = std.time.milliTimestamp(std.time.Clock.wall()) catch 0 });
        return span_id;
    }

    pub fn finish(self: *Tracer, span_id: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.spans.items) |*span| if (span.span_id == span_id) { span.end_ms = std.time.milliTimestamp(std.time.Clock.wall()) catch 0; span.finished = true; break; }
    }
};
