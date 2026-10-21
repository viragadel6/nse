const std = @import("std");

pub const Compensator = struct {
    mode: enum { none, l2_ratio, mean_absolute } = .l2_ratio,

    pub fn compensate(self: *const Compensator, binary_score: f32, packed_norm: f32, query_norm: f32, mean_absolute: f32) f32 {
        switch (self.mode) {
            .l2_ratio => return binary_score * packed_norm * query_norm,
            .mean_absolute => return binary_score * mean_absolute * query_norm,
            .none => return binary_score,
        }
    }
};
