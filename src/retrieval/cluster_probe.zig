const std = @import("std");

pub const Probe = struct {
    nprobe: u32 = 16,
    max_nprobe: u32 = 256,
    min_recall: f32 = 0.9,
    adaptive: bool = true,

    pub fn select(self: *const Probe, confidence: f32, dispersion: f32, latency_budget_ms: u32) u32 {
        var nprobe = self.nprobe;
        if (confidence < 0.5) nprobe = @min(self.max_nprobe, nprobe * 2);
        if (dispersion > 0.5) nprobe = @min(self.max_nprobe, nprobe * 2);
        if (latency_budget_ms < 50) nprobe = @max(4, nprobe / 2);
        return nprobe;
    }
};
