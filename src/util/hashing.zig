const std = @import("std");

const p0: u64 = 0xa0761d6478bd642f;
const p1: u64 = 0xe7037ed1a0b428db;
const p2: u64 = 0x8ebc6af09c88c6e3;
const p3: u64 = 0x589965cc75374cc3;
const p4: u64 = 0x1d8e4e27c47d124f;
const p5: u64 = 0xeb44accab455d165;

fn wymum(x: u64, y: u64) [2]u64 {
    const r: u128 = @as(u128, x) * @as(u128, y);
    return .{ @truncate(r & 0xFFFFFFFFFFFFFFFF), @truncate(r >> 64) };
}

fn wymix(x: u64, y: u64) u64 {
    const r = wymum(x, y);
    return r[0] ^ r[1];
}

pub fn mix64(value: u64) u64 {
    var z = value;
    z ^= z >> 30;
    z = z *% 0xbf58476d1ce4e5b9;
    z ^= z >> 27;
    z = z *% 0x94d049bb133111eb;
    z ^= z >> 31;
    return z;
}

fn readU64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

fn readU32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn readPartial(b: []const u8) u64 {
    if (b.len >= 8) return readU64(b);
    if (b.len >= 4) {
        const lo = readU32(b[0..4]);
        const hi = readU32(b[b.len - 4 ..]);
        return (@as(u64, hi) << 32) | @as(u64, lo);
    }
    var v: u64 = 0;
    for (b, 0..) |c, i| v |= @as(u64, c) << @intCast(i * 8);
    return v;
}

pub fn hash64(seed: u64, input: []const u8) u64 {
    var h = Hasher.init(seed);
    h.update(input);
    return h.final();
}

pub fn hash128(seed: u64, input: []const u8) [2]u64 {
    const a = hash64(seed, input);
    const b = hash64(seed ^ p5, input);
    return .{ a, b };
}

pub fn hashString(seed: u64, input: []const u8) u64 {
    return hash64(seed, input);
}

pub fn fingerprint64(parts: []const []const u8) u64 {
    var h = Hasher.init(0x9E3779B97F4A7C15);
    for (parts) |part| {
        h.update(part);
        h.updateByte(0x1F);
    }
    return h.final();
}

pub fn stableSeed(name: []const u8) u64 {
    return hash64(0x243F6A8885A308D3, name) | 1;
}

pub const Hasher = struct {
    state: u64,
    seed: u64,
    length: usize,
    tail: [32]u8 = @splat(0),
    tail_len: usize = 0,

    pub fn init(seed: u64) Hasher {
        return .{ .state = seed ^ p0, .seed = seed ^ p0, .length = 0, .tail_len = 0 };
    }

    pub fn reset(self: *Hasher, seed: u64) void {
        self.state = seed ^ p0;
        self.seed = seed ^ p0;
        self.length = 0;
        self.tail_len = 0;
        self.tail = @splat(0);
    }

    pub fn updateByte(self: *Hasher, value: u8) void {
        self.tail[self.tail_len] = value;
        self.tail_len += 1;
        self.length += 1;
        if (self.tail_len == 32) self.drain();
    }

    pub fn update(self: *Hasher, input: []const u8) void {
        var rest = input;
        self.length += rest.len;
        if (self.tail_len > 0) {
            const need = 32 - self.tail_len;
            const take = @min(need, rest.len);
            @memcpy(self.tail[self.tail_len .. self.tail_len + take], rest[0..take]);
            self.tail_len += take;
            rest = rest[take..];
            if (self.tail_len < 32) return;
            self.drain();
        }
        while (rest.len >= 32) {
            self.state = mixBlock(self.state, rest[0..32]);
            rest = rest[32..];
        }
        if (rest.len > 0) {
            @memcpy(self.tail[0..rest.len], rest);
            self.tail_len = rest.len;
        }
    }

    fn drain(self: *Hasher) void {
        self.state = mixBlock(self.state, &self.tail);
        self.tail = @splat(0);
        self.tail_len = 0;
    }

    pub fn final(self: *Hasher) u64 {
        var acc = self.state;
        if (self.tail_len > 0) {
            var block: [32]u8 = @splat(0);
            @memcpy(block[0..self.tail_len], self.tail[0..self.tail_len]);
            acc = mixBlock(acc, &block);
        }
        const tail_value: u64 = if (self.tail_len > 0) readPartial(self.tail[0..@min(self.tail_len, 32)]) else p5;
        acc = wymix(acc ^ @as(u64, @intCast(self.length)), wymix(self.seed ^ p4, tail_value));
        if (acc == 0) acc = p2 ^ @as(u64, @intCast(self.length));
        return acc;
    }
};

fn mixBlock(state: u64, block: *const [32]u8) u64 {
    const a = readU64(block[0..8]) ^ p1;
    const b = readU64(block[8..16]) ^ p2;
    const c = readU64(block[16..24]) ^ p3;
    const d = readU64(block[24..32]) ^ p4;
    const left = wymix(a, state ^ b);
    const right = wymix(c ^ state, d);
    return wymix(left ^ right, state ^ (@as(u64, block[0]) << 56 | @as(u64, block[31])));
}

pub fn shardFor(hash_value: u64, shard_count: u32) u32 {
    if (shard_count == 0) return 0;
    if (shard_count & (shard_count - 1) == 0) {
        return @truncate(hash_value & (@as(u64, shard_count) - 1));
    }
    return @truncate(@as(u64, @intCast(@as(u128, hash_value) * @as(u128, @intCast(shard_count)) >> 64)));
}

pub fn bucketFor(hash_value: u64, bucket_count: u64) u64 {
    if (bucket_count == 0) return 0;
    return @mod(mix64(hash_value), bucket_count);
}

pub fn jumpConsistent(key: u64, buckets: u32) u32 {
    if (buckets == 0) return 0;
    var k: i64 = @bitCast(key);
    var b: i64 = -1;
    var j: i64 = 0;
    while (j < @as(i64, @intCast(buckets))) {
        b = j;
        k = k *% 2862933555777941757 +% 1;
        const kk = @as(f64, @floatFromInt((@as(u64, @bitCast(k)) >> 33) + 1)) / 2147483648.0;
        j = @intFromFloat(@as(f64, @floatFromInt(j + 1)) / kk);
    }
    return @intCast(b);
}

pub fn hammingWeight(bytes: []const u8) u32 {
    var count: u32 = 0;
    for (bytes) |b| count += @popCount(b);
    return count;
}

pub fn hammingDistance(a: []const u8, b: []const u8) u32 {
    const n = @min(a.len, b.len);
    var count: u32 = 0;
    for (0..n) |i| count += @popCount(a[i] ^ b[i]);
    return count;
}

pub fn jaccardEstimate(left: u64, right: u64) f32 {
    var intersection: u32 = 0;
    var union_count: u32 = 0;
    for (0..64) |i| {
        const a = (left >> @intCast(i)) & 1;
        const b = (right >> @intCast(i)) & 1;
        if (a == 1 and b == 1) intersection += 1;
        if (a == 1 or b == 1) union_count += 1;
    }
    if (union_count == 0) return 1.0;
    return @as(f32, @floatFromInt(intersection)) / @as(f32, @floatFromInt(union_count));
}
