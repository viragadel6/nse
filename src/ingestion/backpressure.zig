const std = @import("std");

pub const State = struct {
    capacity: usize,
    used: usize,
    high_water: f64,
    low_water: f64,
    blocked: bool = false,
};

pub fn init(capacity: usize, high_water: f64, low_water: f64) State {
    return State{ .capacity = capacity, .used = 0, .high_water = high_water, .low_water = low_water };
}

pub fn adjust(self: *State, used: usize) bool {
    self.used = used;
    if (self.blocked) {
        if (@as(f64, @intCast(used)) / @as(f64, @intCast(self.capacity)) <= self.low_water) {
            self.blocked = false;
            return true;
        }
        return false;
    }
    if (@as(f64, @intCast(used)) / @as(f64, @intCast(self.capacity)) >= self.high_water) {
        self.blocked = true;
        return false;
    }
    return true;
}

pub fn isBlocked(self: *const State) bool {
    return self.blocked;
}
