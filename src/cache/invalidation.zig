const std = @import("std");

pub const Generation = struct {
    model_version: u64 = 1,
    index_generation: u64 = 1,
    config_version: u64 = 1,
    lock: std.Thread.Mutex,

    pub fn bumpModel(self: *Generation, version: u64) void {
        self.lock.lock();
        self.model_version = version;
        self.lock.unlock();
    }

    pub fn bumpIndex(self: *Generation, generation: u64) void {
        self.lock.lock();
        self.index_generation = generation;
        self.lock.unlock();
    }

    pub fn snapshot(self: *Generation) struct { model_version: u64, index_generation: u64, config_version: u64 } {
        self.lock.lock();
        const result = .{ .model_version = self.model_version, .index_generation = self.index_generation, .config_version = self.config_version };
        self.lock.unlock();
        return result;
    }
};
