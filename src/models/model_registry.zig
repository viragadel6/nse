const std = @import("std");
const checkpoint = @import("checkpoint.zig");

pub const ModelRecord = struct {
    model_version: u64,
    dimensions: u16,
    retained_dimensions: u16,
    path: []const u8,
    checksum: [32]u8,
    registered_at: i64,
    active: bool = false,
};

pub const Registry = struct {
    records: std.ArrayList(ModelRecord),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{ .records = std.ArrayList(ModelRecord).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.records.items) |*record| self.allocator.free(record.path);
        self.records.deinit();
    }

    pub fn register(self: *Registry, version: u64, dimensions: u16, retained_dimensions: u16, path: []const u8, checksum: [32]u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < self.records.items.len) {
            if (self.records.items[i].model_version == version) return error.DuplicateModelVersion;
            i += 1;
        }
        _ = try self.records.append(ModelRecord{ .model_version = version, .dimensions = dimensions, .retained_dimensions = retained_dimensions, .path = try self.allocator.dupe(u8, path), .checksum = checksum, .registered_at = std.time.milliTimestamp(std.time.Clock.wall()) catch 0, .active = false });
    }

    pub fn activate(self: *Registry, version: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < self.records.items.len) {
            self.records.items[i].active = self.records.items[i].model_version == version;
            i += 1;
        }
    }

    pub fn active(self: *Registry) ?*ModelRecord {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.records.items) |*record| if (record.active) return record;
        return null;
    }

    pub fn get(self: *Registry, version: u64) ?*ModelRecord {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.records.items) |*record| if (record.model_version == version) return record;
        return null;
    }
};
