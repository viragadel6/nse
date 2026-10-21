const std = @import("std");
const builtin = @import("builtin");

pub const Features = struct {
    sse42: bool = false,
    avx: bool = false,
    avx2: bool = false,
    fma: bool = false,
    bmi1: bool = false,
    bmi2: bool = false,
    popcnt: bool = false,
    avx512f: bool = false,
    avx512bw: bool = false,
    avx512vl: bool = false,
    avx512dq: bool = false,
    avx512vnni: bool = false,
    avx512vpopcntdq: bool = false,
    neon: bool = false,
    sve: bool = false,
    sve2: bool = false,
    crc32: bool = false,
    aes: bool = false,
    sha2: bool = false,

    pub fn detect() Features {
        var f = Features{};
        switch (builtin.target.cpu.arch) {
            .x86_64, .x86 => f.detectX86(),
            .aarch64, .aarch64_be, .arm, .armeb => f.detectArm(),
            else => {},
        }
        return f;
    }

    fn detectX86(self: *Features) void {
        const leaf0 = cpuid(0, 0);
        if (leaf0[0] < 1) return;
        const leaf1 = cpuid(1, 0);
        self.popcnt = leaf1[2] & (1 << 23) != 0;
        self.sse42 = leaf1[2] & (1 << 20) != 0;
        self.fma = leaf1[2] & (1 << 12) != 0;
        self.avx = leaf1[2] & (1 << 28) != 0;
        if (leaf0[0] >= 7) {
            const leaf7 = cpuid(7, 0);
            self.avx2 = leaf7[1] & (1 << 5) != 0;
            self.bmi1 = leaf7[1] & (1 << 3) != 0;
            self.bmi2 = leaf7[1] & (1 << 8) != 0;
            self.avx512f = leaf7[1] & (1 << 16) != 0;
            self.avx512dq = leaf7[1] & (1 << 17) != 0;
            self.avx512bw = leaf7[1] & (1 << 30) != 0;
            self.avx512vl = leaf7[1] & (1 << 31) != 0;
            self.avx512vnni = leaf7[2] & (1 << 11) != 0;
            self.avx512vpopcntdq = leaf7[2] & (1 << 14) != 0;
            self.sha2 = leaf7[1] & (1 << 29) != 0;
        }
        const leaf80000001 = cpuid(0x80000001, 0);
        _ = leaf80000001;
        if (leaf0[0] >= 1) {
            const leaf1c = cpuid(1, 1);
            _ = leaf1c;
        }
        if (leaf0[0] >= 7) {
            const leaf7c = cpuid(7, 1);
            _ = leaf7c;
        }
    }

    fn detectArm(self: *Features) void {
        const hwcap = hwcapValue();
        if (hwcap & hwcap_asimd != 0) self.neon = true;
        if (hwcap & hwcap_sve != 0) self.sve = true;
        if (hwcap & hwcap_crc32 != 0) self.crc32 = true;
        if (hwcap & hwcap_aes != 0) self.aes = true;
        if (hwcap & hwcap_sha2 != 0) self.sha2 = true;
        if (readCpuInfoFlag("sve")) self.sve = true;
        if (readCpuInfoFlag("sve2")) self.sve2 = true;
        if (readCpuInfoFlag("asimd")) self.neon = true;
        if (readCpuInfoFlag("crc32")) self.crc32 = true;
        if (!self.neon and comptime builtin.target.cpu.arch.isAARCH64()) self.neon = true;
    }

    pub fn bestSimdWidth(self: Features) usize {
        if (self.avx512bw and self.avx512vl and self.avx512vpopcntdq) return 64;
        if (self.avx512bw and self.avx512vl) return 64;
        if (self.avx512f) return 64;
        if (self.avx2) return 32;
        if (self.sve) return 64;
        if (self.neon) return 16;
        if (self.sse42) return 16;
        return 0;
    }

    pub fn tierName(self: Features) []const u8 {
        if (self.avx512bw and self.avx512vl) return "x86_avx512";
        if (self.avx2) return "x86_avx2";
        if (self.sve2) return "arm_sve2";
        if (self.sve) return "arm_sve";
        if (self.neon) return "arm_neon";
        if (self.sse42) return "x86_sse42";
        return "scalar";
    }

    pub fn supportsPopcountVector(self: Features) bool {
        return self.avx512vpopcntdq or self.avx2 or self.neon or self.sve or self.sse42;
    }
};

const hwcap_asimd: usize = 1 << 1;
const hwcap_aes: usize = 1 << 3;
const hwcap_crc32: usize = 1 << 7;
const hwcap_sha2: usize = 1 << 6;
const hwcap_sve: usize = 1 << 22;

fn hwcapValue() usize {
    if (comptime builtin.target.os.tag != .linux) return 0;
    const at_hwcap: usize = 16;
    return std.os.linux.getauxval(at_hwcap);
}

fn readCpuInfoFlag(flag: []const u8) bool {
    const file = std.fs.cwd().openFile("/proc/cpuinfo", .{}) catch return false;
    defer file.close();
    var reader = std.io.bufferedReader(file.reader());
    var stream = reader.reader();
    var line: std.ArrayListUnmanaged(u8) = .{};
    var arena = std.heap.stackFallback(8192, std.heap.page_allocator);
    defer line.deinit(arena.get());
    while (stream.streamUntilDelimiter(&line, '\n', 8192)) {
        if (std.mem.startsWith(u8, line.items, "Features")) {
            var it = std.mem.tokenizeAny(u8, line.items, " \t:");
            while (it.next()) |token| {
                if (std.mem.eql(u8, token, flag)) return true;
            }
        }
        line.clearRetainingCapacity();
    } else |_| {}
    return false;
}

fn cpuid(leaf: u32, sub: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    if (comptime builtin.target.cpu.arch == .x86_64 or builtin.target.cpu.arch == .x86) {
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [leaf] "{eax}" (leaf),
              [sub] "{ecx}" (sub),
        );
    } else {
        eax = 0;
        ebx = 0;
        ecx = 0;
        edx = 0;
    }
    return .{ eax, ebx, ecx, edx };
}

var feature_cache: ?Features = null;
var feature_lock: std.Thread.Mutex = .{};

pub fn features() Features {
    feature_lock.lock();
    defer feature_lock.unlock();
    if (feature_cache) |cached| return cached;
    const detected = Features.detect();
    feature_cache = detected;
    return detected;
}

pub fn cpuCount() usize {
    if (comptime builtin.target.os.tag == .linux) {
        const set = std.posix.sched_getaffinity(0) catch {
            return std.Thread.getCpuCount() catch 1;
        };
        const n = std.posix.CPU_COUNT(set);
        if (n > 0) return n;
    }
    return std.Thread.getCpuCount() catch 1;
}

pub fn totalMemoryBytes() u64 {
    if (comptime builtin.target.os.tag == .linux) {
        var info: std.os.linux.sysinfo = undefined;
        if (std.os.linux.sysinfo(&info) == 0) {
            return @as(u64, info.totalram) * @as(u64, info.mem_unit);
        }
    }
    return 0;
}

pub fn availableMemoryBytes() u64 {
    if (comptime builtin.target.os.tag == .linux) {
        var info: std.os.linux.sysinfo = undefined;
        if (std.os.linux.sysinfo(&info) == 0) {
            return @as(u64, info.freeram) * @as(u64, info.mem_unit);
        }
    }
    return 0;
}

pub fn cacheLineSize() usize {
    const path = "/sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size";
    const file = std.fs.cwd().openFile(path, .{}) catch return 64;
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.readAll(&buf) catch return 64;
    const value = std.fmt.parseInt(usize, std.mem.trimRight(u8, buf[0..n], " \n"), 10) catch return 64;
    return if (value == 0) 64 else value;
}

pub fn numaNodeCount() usize {
    const file = std.fs.cwd().openFile("/sys/devices/system/node/online", .{}) catch return 1;
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch return 1;
    const text = std.mem.trimRight(u8, buf[0..n], " \n");
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, ",");
    while (it.next()) |part| {
        count += 1;
        if (std.mem.indexOfScalar(u8, part, '-') != null) {
            var bounds = std.mem.splitScalar(u8, part, '-');
            const lo = std.fmt.parseInt(usize, bounds.next() orelse "0", 10) catch 0;
            const hi = std.fmt.parseInt(usize, bounds.next() orelse "0", 10) catch lo;
            count += hi - lo;
        }
    }
    return if (count == 0) 1 else count;
}

pub fn cpusForNode(node: usize) ![]usize {
    var list = std.ArrayList(usize).init(std.heap.page_allocator);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/sys/devices/system/node/node{d}/cpulist", .{node});
    const file = std.fs.cwd().openFile(path, .{}) catch {
        const all = try list.toOwnedSlice();
        return all;
    };
    defer file.close();
    var buf: [1024]u8 = undefined;
    const n = try file.readAll(&buf);
    const text = std.mem.trimRight(u8, buf[0..n], " \n");
    var groups = std.mem.tokenizeAny(u8, text, ",");
    while (groups.next()) |group| {
        var bounds = std.mem.splitScalar(u8, group, '-');
        const lo = std.fmt.parseInt(usize, bounds.next() orelse "0", 10) catch continue;
        const hi_text = bounds.next();
        const hi = if (hi_text) |h| std.fmt.parseInt(usize, h, 10) catch lo else lo;
        var cpu = lo;
        while (cpu <= hi) : (cpu += 1) try list.append(cpu);
    }
    return list.toOwnedSlice();
}

pub fn setThreadAffinity(cpus: []const usize) !void {
    if (comptime builtin.target.os.tag != .linux) return error.UnsupportedPlatform;
    if (cpus.len == 0) return error.InvalidConfiguration;
    var mask: [16]u64 = @splat(0);
    for (cpus) |cpu| {
        if (cpu >= 1024) return error.InvalidConfiguration;
        mask[cpu / 64] |= @as(u64, 1) << @intCast(cpu % 64);
    }
    const set: *const std.os.linux.cpu_set_t = @ptrCast(&mask);
    std.os.linux.sched_setaffinity(0, set) catch return error.AffinityFailed;
}

pub const Topology = struct {
    cpu_count: usize,
    numa_nodes: usize,
    cache_line: usize,
    total_memory_bytes: u64,
    features: Features,
    node_cpus: []usize,

    pub fn detect(allocator: std.mem.Allocator) !Topology {
        const nodes = numaNodeCount();
        const node_cpus = try allocator.alloc(usize, nodes);
        for (node_cpus, 0..) |*count, node| {
            const list = cpusForNode(node) catch &[_]usize{};
            count.* = list.len;
            allocator.free(list);
        }
        return .{
            .cpu_count = cpuCount(),
            .numa_nodes = nodes,
            .cache_line = cacheLineSize(),
            .total_memory_bytes = totalMemoryBytes(),
            .features = features(),
            .node_cpus = node_cpus,
        };
    }

    pub fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        allocator.free(self.node_cpus);
    }

    pub fn shardNode(self: Topology, shard: u64) usize {
        if (self.numa_nodes == 0) return 0;
        return @intCast(@mod(shard, @as(u64, @intCast(self.numa_nodes))));
    }

    pub fn cpusForShard(self: Topology, shard: u64, allocator: std.mem.Allocator) ![]usize {
        const node = self.shardNode(shard);
        if (node == 0 and self.numa_nodes <= 1) {
            const all = try allocator.alloc(usize, self.cpu_count);
            for (all, 0..) |*cpu, index| cpu.* = index;
            return all;
        }
        return cpusForNode(node);
    }
};

pub fn pageAlign(size: usize) usize {
    const page = std.heap.page_size_min;
    return (size + page - 1) & ~(page - 1);
}

pub fn adviseSequential(memory: []u8) void {
    if (comptime builtin.target.os.tag == .linux) {
        std.posix.madvise(@alignCast(memory.ptr), memory.len, std.os.linux.MADV.SEQUENTIAL) catch {};
    }
}

pub fn adviseRandom(memory: []u8) void {
    if (comptime builtin.target.os.tag == .linux) {
        std.posix.madvise(@alignCast(memory.ptr), memory.len, std.os.linux.MADV.RANDOM) catch {};
    }
}

pub fn prefetchRange(memory: []const u8) void {
    var offset: usize = 0;
    while (offset < memory.len) : (offset += 512) {
        @prefetch(memory.ptr + offset, .{ .cache = .data, .rw = .read, .locality = 1 });
    }
}
