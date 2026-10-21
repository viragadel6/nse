const std = @import("std");
const event_codec = @import("event_codec.zig");
const partition_router = @import("partition_router.zig");
const backpressure = @import("backpressure.zig");
const content_filter = @import("content_filter.zig");
const spam_classifier = @import("spam_classifier.zig");
const quality_features = @import("quality_features.zig");
const write_ahead_log = @import("write_ahead_log.zig");

pub const StreamEvent = struct {
    partition: u32,
    sequence: u64,
    event: event_codec.Event,
};

pub const Engine = struct {
    router: partition_router.Router,
    backpressure: backpressure.State,
    filter: content_filter.Filter,
    spam: spam_classifier.Classifier,
    wal: *write_ahead_log.Log,
    allocator: std.mem.Allocator,
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, partition_count: u32, wal: *write_ahead_log.Log) Engine {
        return Engine{
            .router = partition_router.Router.init(partition_count),
            .backpressure = backpressure.init(10000, 0.8, 0.5),
            .filter = .{},
            .spam = .{},
            .wal = wal,
            .allocator = allocator,
            .lock = .{},
        };
    }

    pub fn submit(self: *Engine, document_id: u64, url: []const u8, text: []const u8, payload: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const quality = quality_features.compute(text, 0, 0).quality;
        if (self.filter.filter(text, quality) == .reject) return;
        const prediction = self.spam.classify(text);
        if (prediction.is_spam) return;
        const partition = self.router.route(url);
        const event = event_codec.Event{ .kind = .document, .sequence = 0, .document_id = document_id, .url = url, .timestamp = std.time.milliTimestamp(std.time.Clock.wall()) catch 0, .payload = payload };
        const encoded = try event_codec.encode(self.allocator, &event);
        defer self.allocator.free(encoded);
        try self.wal.appendAt(.document, encoded, event.sequence + 1);
    }

    pub fn deinit(self: *Engine) void {
    }
};
