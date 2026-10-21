const std = @import("std");
const builtin = @import("builtin");

pub const Feature = enum(u8) {
    scalar,
    sse42,
    avx2,
    avx512f,
    avx512bw,
    avx512vnni,
    neon,
    sve,
};

pub const version_scalar: u32 = 1;
pub const version_sse42: u32 = 2;
pub const version_avx2: u32 = 3;
pub const version_avx512: u32 = 4;
pub const version_neon: u32 = 5;
pub const version_sve: u32 = 6;

pub const Capabilities = struct {
    feature: Feature,
    vector_width_bytes: u32,
    f32_lanes: u32,
    int8_lanes: u32,
    threads: u32,
    version: u32,

    pub fn describe(self: *const Capabilities, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "simd={s} width={d} cpus={d}", .{ @tagName(self.feature), self.vector_width_bytes, self.threads });
    }
};

fn hasFeature(comptime name: []const u8) bool {
    if (builtin.target.cpu.arch != .x86_64) return false;
    return std.Target.x86.featureSetHas(builtin.target.cpu.features, @field(std.Target.x86.Feature, name));
}

fn cpuCount() u32 {
    const set = std.posix.sched_getaffinity(0) catch return 1;
    const bits = @sizeOf(std.posix.cpu_set_t) / @sizeOf(usize);
    var count: u32 = 0;
    for (0..bits) |word| {
        count += @popCount(set[word]);
    }
    if (count == 0) return 1;
    return count;
}

pub fn detect() Capabilities {
    if (comptime builtin.target.cpu.arch == .x86_64) {
        if (comptime hasFeature("avx512vnni")) {
            return .{ .feature = .avx512vnni, .vector_width_bytes = 64, .f32_lanes = 16, .int8_lanes = 64, .threads = cpuCount(), .version = version_avx512 };
        }
        if (comptime hasFeature("avx512bw")) {
            return .{ .feature = .avx512bw, .vector_width_bytes = 64, .f32_lanes = 16, .int8_lanes = 64, .threads = cpuCount(), .version = version_avx512 };
        }
        if (comptime hasFeature("avx512f")) {
            return .{ .feature = .avx512f, .vector_width_bytes = 64, .f32_lanes = 16, .int8_lanes = 64, .threads = cpuCount(), .version = version_avx512 };
        }
        if (comptime hasFeature("avx2")) {
            return .{ .feature = .avx2, .vector_width_bytes = 32, .f32_lanes = 8, .int8_lanes = 32, .threads = cpuCount(), .version = version_avx2 };
        }
        if (comptime hasFeature("sse4_2")) {
            return .{ .feature = .sse42, .vector_width_bytes = 16, .f32_lanes = 4, .int8_lanes = 16, .threads = cpuCount(), .version = version_sse42 };
        }
        return .{ .feature = .scalar, .vector_width_bytes = 16, .f32_lanes = 4, .int8_lanes = 16, .threads = cpuCount(), .version = version_scalar };
    }
    if (comptime builtin.target.cpu.arch.isAARCH64()) {
        if (comptime std.Target.aarch64.featureSetHas(builtin.target.cpu.features, std.Target.aarch64.Feature.sve)) {
            return .{ .feature = .sve, .vector_width_bytes = 64, .f32_lanes = 16, .int8_lanes = 64, .threads = cpuCount(), .version = version_sve };
        }
        return .{ .feature = .neon, .vector_width_bytes = 16, .f32_lanes = 4, .int8_lanes = 16, .threads = cpuCount(), .version = version_neon };
    }
    return .{ .feature = .scalar, .vector_width_bytes = 8, .f32_lanes = 2, .int8_lanes = 8, .threads = cpuCount(), .version = version_scalar };
}

const ByteVector = if (hasFeature("avx512bw")) @Vector(64, u8) else if (hasFeature("avx2")) @Vector(32, u8) else @Vector(16, u8);
const FloatVector = if (hasFeature("avx512f")) @Vector(16, f32) else if (hasFeature("avx2")) @Vector(8, f32) else @Vector(4, f32);
const Int8Vector = if (hasFeature("avx512bw")) @Vector(64, i8) else if (hasFeature("avx2")) @Vector(32, i8) else @Vector(16, i8);
const Int32Vector = if (hasFeature("avx512bw")) @Vector(16, i32) else if (hasFeature("avx2")) @Vector(8, i32) else @Vector(4, i32);

pub const byte_lanes: usize = @sizeOf(ByteVector);
pub const f32_lanes: usize = @sizeOf(FloatVector) / 4;
pub const i8_lanes: usize = @sizeOf(Int8Vector);

pub fn hammingDistance(left: []const u8, right: []const u8) u32 {
    const length = @min(left.len, right.len);
    var total: u32 = 0;
    var index: usize = 0;
    while (index + byte_lanes <= length) : (index += byte_lanes) {
        const a: ByteVector = left[index..][0..byte_lanes].*;
        const b: ByteVector = right[index..][0..byte_lanes].*;
        const xor = a ^ b;
        comptime var lane: usize = 0;
        inline while (lane < byte_lanes) : (lane += 1) {
            total += @popCount(xor[lane]);
        }
    }
    while (index < length) : (index += 1) {
        total += @popCount(left[index] ^ right[index]);
    }
    return total;
}

pub fn hammingBatch(query: []const u8, matrix: []const u8, count: usize, out: []u32) void {
    const stride = query.len;
    for (0..count) |position| {
        out[position] = hammingDistance(query, matrix[position * stride ..][0..stride]);
    }
}

pub fn jaccardFromHamming(distance: u32, bits: u32) f64 {
    if (bits == 0) return 0.0;
    return @as(f64, @floatFromInt(bits - distance)) / @as(f64, @floatFromInt(bits));
}

pub fn dotF32(left: []const f32, right: []const f32) f64 {
    const length = @min(left.len, right.len);
    var accumulator: FloatVector = @splat(0.0);
    var index: usize = 0;
    while (index + f32_lanes <= length) : (index += f32_lanes) {
        const a: FloatVector = left[index..][0..f32_lanes].*;
        const b: FloatVector = right[index..][0..f32_lanes].*;
        accumulator += a * b;
    }
    var total: f64 = 0.0;
    inline for (0..f32_lanes) |lane| {
        total += accumulator[lane];
    }
    while (index < length) : (index += 1) {
        total += @as(f64, left[index]) * @as(f64, right[index]);
    }
    return total;
}

pub fn dotF32Batch(query: []const f32, matrix: []const f32, count: usize, out: []f32) void {
    const stride = query.len;
    for (0..count) |position| {
        out[position] = @floatCast(dotF32(query, matrix[position * stride ..][0..stride]));
    }
}

pub fn l2DistanceF32(left: []const f32, right: []const f32) f64 {
    const length = @min(left.len, right.len);
    var accumulator: FloatVector = @splat(0.0);
    var index: usize = 0;
    while (index + f32_lanes <= length) : (index += f32_lanes) {
        const a: FloatVector = left[index..][0..f32_lanes].*;
        const b: FloatVector = right[index..][0..f32_lanes].*;
        const difference = a - b;
        accumulator += difference * difference;
    }
    var total: f64 = 0.0;
    inline for (0..f32_lanes) |lane| {
        total += accumulator[lane];
    }
    while (index < length) : (index += 1) {
        const difference = @as(f64, left[index]) - @as(f64, right[index]);
        total += difference * difference;
    }
    return @sqrt(total);
}

pub fn int8Dot(left: []const i8, right: []const i8) i32 {
    const length = @min(left.len, right.len);
    var accumulator: Int32Vector = @splat(0);
    var index: usize = 0;
    const group_lanes = i8_lanes / 4;
    while (index + i8_lanes <= length) : (index += i8_lanes) {
        const a: Int8Vector = left[index..][0..i8_lanes].*;
        const b: Int8Vector = right[index..][0..i8_lanes].*;
        comptime var group: usize = 0;
        inline while (group < 4) : (group += 1) {
            var wide_a: Int32Vector = undefined;
            var wide_b: Int32Vector = undefined;
            comptime var lane: usize = 0;
            inline while (lane < group_lanes) : (lane += 1) {
                wide_a[lane] = a[group * group_lanes + lane];
                wide_b[lane] = b[group * group_lanes + lane];
            }
            accumulator += wide_a * wide_b;
        }
    }
    var total: i32 = 0;
    inline for (0..@typeInfo(Int32Vector).vector.len) |lane| {
        total += accumulator[lane];
    }
    while (index < length) : (index += 1) {
        total += @as(i32, left[index]) * @as(i32, right[index]);
    }
    return total;
}

pub fn quantizeInt8(input: []const f32, out: []i8, scale: f32) void {
    const length = @min(input.len, out.len);
    for (0..length) |index| {
        const value = input[index] * scale;
        const clamped = @min(127.0, @max(-127.0, value));
        out[index] = @intFromFloat(clamped);
    }
}

pub fn dequantizeInt8(input: []const i8, out: []f32, scale: f32) void {
    const length = @min(input.len, out.len);
    for (0..length) |index| {
        out[index] = @as(f32, @floatFromInt(input[index])) / scale;
    }
}

pub fn topK(scores: []const f32, indices: []u32, k: usize) usize {
    if (k == 0 or scores.len == 0) return 0;
    const limit = @min(k, scores.len);
    var heap = std.ArrayList(u32).init(std.heap.page_allocator);
    defer heap.deinit();
    for (0..scores.len) |position| {
        heap.append(@intCast(position)) catch break;
    }
    std.sort.block(u32, heap.items, scores, struct {
        fn gt(scores_ref: []const f32, a: u32, b: u32) bool {
            return scores_ref[a] > scores_ref[b];
        }
    }.gt);
    const count = @min(limit, heap.items.len);
    for (0..count) |position| {
        indices[position] = heap.items[position];
    }
    return count;
}

pub fn normalizeF32(values: []f32) void {
    var squared: FloatVector = @splat(0.0);
    var index: usize = 0;
    while (index + f32_lanes <= values.len) : (index += f32_lanes) {
        const a: FloatVector = values[index..][0..f32_lanes].*;
        squared += a * a;
    }
    var total: f64 = 0.0;
    inline for (0..f32_lanes) |lane| {
        total += squared[lane];
    }
    while (index < values.len) : (index += 1) {
        total += @as(f64, values[index]) * @as(f64, values[index]);
    }
    if (total <= 0.0) return;
    const inverse: f32 = @floatCast(1.0 / @sqrt(total));
    index = 0;
    while (index + f32_lanes <= values.len) : (index += f32_lanes) {
        const a: FloatVector = values[index..][0..f32_lanes].*;
        values[index..][0..f32_lanes].* = a * @as(FloatVector, @splat(inverse));
    }
    while (index < values.len) : (index += 1) {
        values[index] *= inverse;
    }
}

pub fn packSigns(values: []const f32, out: []u8) void {
    const bits = out.len * 8;
    const length = @min(values.len, bits);
    @memset(out, 0);
    for (0..length) |index| {
        if (values[index] > 0.0) out[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
}

pub fn unpackSigns(signs: []const u8, out: []f32) void {
    const bits = signs.len * 8;
    const length = @min(out.len, bits);
    for (0..length) |index| {
        const bit = (signs[index / 8] >> @intCast(index % 8)) & 1;
        out[index] = if (bit == 1) 1.0 else -1.0;
    }
    for (length..out.len) |index| {
        out[index] = 0.0;
    }
}

pub fn asymmetricDistance(query: []const f32, signs: []const u8, bits: usize) f64 {
    var total: f64 = 0.0;
    const length = @min(query.len, bits);
    for (0..length) |index| {
        const bit = (signs[index / 8] >> @intCast(index % 8)) & 1;
        const sign: f64 = if (bit == 1) 1.0 else -1.0;
        total += @as(f64, query[index]) * sign;
    }
    return total;
}
