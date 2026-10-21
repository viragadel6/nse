const std = @import("std");

pub const Consistency = enum { read_committed, snapshot, serializable };

pub const Guard = struct {
    mode: Consistency,
    generation: u64,
    commit_sequence: u64,

    pub fn visible(self: *const Guard, record_generation: u64, record_sequence: u64) bool {
        if (record_generation > self.generation) return false;
        if (record_generation == self.generation and record_sequence > self.commit_sequence) return false;
        return true;
    }
};
