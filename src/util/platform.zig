const std = @import("std");

pub const CpuFeatures = struct {
    avx2: bool = false,
    avx512f: bool = false,
    avx512bw: bool = false,
    avx512vl: bool = false,
    neon: bool = false,
    sve: bool = false,
};

pub fn detectCpuFeatures() CpuFeatures {
    var features = CpuFeatures{};
    if (@cpuFeatures().x86.avx2) features.avx2 = true;
    if (@cpuFeatures().x86.avx512f) features.avx512f = true;
    if (@cpuFeatures().x86.avx512bw) features.avx512bw = true;
    if (@cpuFeatures().x86.avx512vl) features.avx512vl = true;
    if (@cpuFeatures().arm.neon) features.neon = true;
    return features;
}

pub const NumaNode = struct {
    node_id: u32,
    cpu_count: u16,
    memory_bytes: u64,
};

pub fn detectNumaTopology(allocator: std.mem.Allocator) ![]NumaNode {
    const nodes = try allocator.alloc(NumaNode, 1);
    nodes[0] = .{ .node_id = 0, .cpu_count = @as(u16, @intCast(std.os.cpu_count())), .memory_bytes = 0 };
    return nodes[0..1];
}
