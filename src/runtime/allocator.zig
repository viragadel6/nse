const std = @import("std");

pub const Accounting = struct {
    allocated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    freed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn live(self: *Accounting) u64 {
        const a = self.allocated.load(.monotonic);
        const f = self.freed.load(.monotonic);
        return if (a > f) a - f else 0;
    }

    pub fn reset(self: *Accounting) void {
        self.allocated.store(0, .monotonic);
        self.freed.store(0, .monotonic);
        self.peak.store(0, .monotonic);
        self.allocations.store(0, .monotonic);
        self.failures.store(0, .monotonic);
    }

    pub fn raisePeak(self: *Accounting, candidate: u64) void {
        var current = self.peak.load(.monotonic);
        while (candidate > current) {
            current = self.peak.cmpxchgWeak(current, candidate, .monotonic, .monotonic) orelse break;
        }
    }
};

pub const TrackingAllocator = struct {
    parent: std.mem.Allocator,
    accounting: *Accounting,
    limit: u64,
    mutex: std.Thread.Mutex = .{},
    sizes: std.AutoHashMapUnmanaged(usize, usize) = .{},

    pub fn init(parent: std.mem.Allocator, accounting: *Accounting, limit: u64) TrackingAllocator {
        return .{ .parent = parent, .accounting = accounting, .limit = limit };
    }

    pub fn deinit(self: *TrackingAllocator) void {
        self.mutex.lock();
        self.sizes.deinit(self.parent);
        self.mutex.unlock();
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        const live_bytes = self.accounting.live();
        if (self.limit != 0 and live_bytes + len > self.limit) {
            self.mutex.unlock();
            _ = self.accounting.failures.fetchAdd(1, .monotonic);
            return null;
        }
        self.mutex.unlock();
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse {
            _ = self.accounting.failures.fetchAdd(1, .monotonic);
            return null;
        };
        _ = self.accounting.allocated.fetchAdd(len, .monotonic);
        _ = self.accounting.allocations.fetchAdd(1, .monotonic);
        self.accounting.raisePeak(self.accounting.live());
        self.mutex.lock();
        self.sizes.put(self.parent, @intFromPtr(ptr), len) catch {};
        self.mutex.unlock();
        return ptr;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        const previous = self.sizes.get(@intFromPtr(memory.ptr)) orelse memory.len;
        const live_bytes = self.accounting.live();
        if (self.limit != 0 and new_len > previous and live_bytes + (new_len - previous) > self.limit) {
            self.mutex.unlock();
            _ = self.accounting.failures.fetchAdd(1, .monotonic);
            return false;
        }
        self.mutex.unlock();
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > previous) {
            _ = self.accounting.allocated.fetchAdd(new_len - previous, .monotonic);
        } else {
            _ = self.accounting.freed.fetchAdd(previous - new_len, .monotonic);
        }
        self.accounting.raisePeak(self.accounting.live());
        self.mutex.lock();
        self.sizes.put(self.parent, @intFromPtr(memory.ptr), new_len) catch {};
        self.mutex.unlock();
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        const previous = self.sizes.get(@intFromPtr(memory.ptr)) orelse memory.len;
        const live_bytes = self.accounting.live();
        if (self.limit != 0 and new_len > previous and live_bytes + (new_len - previous) > self.limit) {
            self.mutex.unlock();
            _ = self.accounting.failures.fetchAdd(1, .monotonic);
            return null;
        }
        self.mutex.unlock();
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > previous) {
            _ = self.accounting.allocated.fetchAdd(new_len - previous, .monotonic);
        } else {
            _ = self.accounting.freed.fetchAdd(previous - new_len, .monotonic);
        }
        self.accounting.raisePeak(self.accounting.live());
        self.mutex.lock();
        _ = self.sizes.remove(@intFromPtr(memory.ptr));
        self.sizes.put(self.parent, @intFromPtr(ptr), new_len) catch {};
        self.mutex.unlock();
        return ptr;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        const size = self.sizes.fetchRemove(@intFromPtr(memory.ptr)) orelse std.AutoHashMapUnmanaged(usize, usize).KV{ .key = 0, .value = memory.len };
        self.mutex.unlock();
        _ = self.accounting.freed.fetchAdd(size.value, .monotonic);
        self.parent.rawFree(memory, alignment, ret_addr);
    }

    pub fn live(self: *TrackingAllocator) u64 {
        return self.accounting.live();
    }

    pub fn outstanding(self: *TrackingAllocator) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sizes.count();
    }
};

pub const Region = struct {
    backing: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged([]u8) = .{},
    offset: usize = 0,
    block_size: usize,
    total_reserved: usize = 0,
    used: usize = 0,
    alignment: std.mem.Alignment,

    pub fn init(backing: std.mem.Allocator, block_size: usize, alignment: std.mem.Alignment) Region {
        return .{ .backing = backing, .block_size = @max(4096, block_size), .alignment = alignment };
    }

    pub fn deinit(self: *Region) void {
        for (self.blocks.items) |block| self.backing.free(block);
        self.blocks.deinit(self.allocator);
    }

    pub fn reset(self: *Region) void {
        self.offset = 0;
        self.used = 0;
    }

    pub fn allocator(self: *Region) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }

    fn reserve(self: *Region, len: usize, alignment: std.mem.Alignment) ?[]u8 {
        const mask = alignment.toByteUnits() - 1;
        const aligned_offset = (self.offset + mask) & ~mask;
        if (self.blocks.items.len > 0) {
            const block = self.blocks.items[self.blocks.items.len - 1];
            if (aligned_offset + len <= block.len) {
                self.offset = aligned_offset + len;
                self.used += len;
                return block[aligned_offset .. aligned_offset + len];
            }
        }
        const needed = @max(self.block_size, len + alignment.toByteUnits());
        const block = self.backing.alignedAlloc(u8, alignment.toByteUnits(), needed) catch return null;
        self.blocks.append(self.allocator, block) catch {
            self.backing.free(block);
            return null;
        };
        self.total_reserved += block.len;
        self.offset = len;
        self.used += len;
        return block[0..len];
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Region = @ptrCast(@alignCast(ctx));
        const slice = self.reserve(len, alignment) orelse return null;
        return slice.ptr;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Region = @ptrCast(@alignCast(ctx));
        if (self.blocks.items.len == 0) return false;
        const last = self.blocks.items[self.blocks.items.len - 1];
        if (memory.ptr >= last.ptr and @intFromPtr(memory.ptr) < @intFromPtr(last.ptr) + last.len) {
            const start = @intFromPtr(memory.ptr) - @intFromPtr(last.ptr);
            if (start + new_len <= last.len) {
                self.offset = start + new_len;
                self.used = self.used - memory.len + new_len;
                return true;
            }
        }
        _ = alignment;
        return false;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Region = @ptrCast(@alignCast(ctx));
        if (self.resizeFn(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
        const slice = self.reserve(new_len, alignment) orelse return null;
        @memcpy(slice[0..@min(memory.len, new_len)], memory[0..@min(memory.len, new_len)]);
        return slice.ptr;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }

    pub fn utilization(self: *const Region) f64 {
        if (self.total_reserved == 0) return 0.0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.total_reserved));
    }
};

pub const BlockPool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    free_list: std.ArrayListUnmanaged([]u8) = .{},
    block_size: usize,
    alignment: std.mem.Alignment,
    allocated_blocks: usize = 0,
    checkout_count: u64 = 0,
    release_count: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, block_size: usize, alignment: std.mem.Alignment, preallocate: usize) !BlockPool {
        var pool = BlockPool{ .allocator = allocator, .block_size = block_size, .alignment = alignment };
        for (0..preallocate) |_| {
            const block = try allocator.alignedAlloc(u8, alignment.toByteUnits(), block_size);
            try pool.free_list.append(allocator, block);
            pool.allocated_blocks += 1;
        }
        return pool;
    }

    pub fn deinit(self: *BlockPool) void {
        for (self.free_list.items) |block| self.allocator.free(block);
        self.free_list.deinit(self.allocator);
    }

    pub fn acquire(self: *BlockPool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.checkout_count += 1;
        if (self.free_list.pop()) |block| return block;
        self.misses += 1;
        self.allocated_blocks += 1;
        return self.allocator.alignedAlloc(u8, self.alignment.toByteUnits(), self.block_size) catch |err| {
            self.allocated_blocks -= 1;
            return err;
        };
    }

    pub fn release(self: *BlockPool, block: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.release_count += 1;
        self.free_list.append(self.allocator, block) catch {
            self.allocator.free(block);
            self.allocated_blocks -= 1;
        };
    }

    pub fn depth(self: *BlockPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_list.items.len;
    }
};

const scratch_size = 1 << 16;
threadlocal var scratch_backing: [scratch_size]u8 align(64) = undefined;
threadlocal var scratch_in_use: bool = false;

pub fn scratchAllocator() std.mem.Allocator {
    if (scratch_in_use) return std.heap.page_allocator;
    scratch_in_use = true;
    const state: *std.heap.FixedBufferAllocator = @ptrCast(&scratch_state);
    state.* = std.heap.FixedBufferAllocator.init(&scratch_backing);
    return state.allocator();
}

threadlocal var scratch_state: std.heap.FixedBufferAllocator = undefined;

pub fn releaseScratch(allocator: std.mem.Allocator) void {
    if (allocator.ptr == @as(*anyopaque, @ptrCast(&scratch_state))) {
        scratch_in_use = false;
    }
}

pub const MemoryBudget = struct {
    total_bytes: u64,
    reserved_bytes: u64,
    component: []const u8,
    accounting: *Accounting,

    pub fn remaining(self: *MemoryBudget) u64 {
        const used = self.accounting.live();
        if (used >= self.reserved_bytes) return 0;
        return self.reserved_bytes - used;
    }

    pub fn pressure(self: *MemoryBudget) f64 {
        if (self.reserved_bytes == 0) return 1.0;
        return @as(f64, @floatFromInt(self.accounting.live())) / @as(f64, @floatFromInt(self.reserved_bytes));
    }

    pub fn admits(self: *MemoryBudget, bytes: u64) bool {
        return self.remaining() >= bytes;
    }
};

pub fn alignedBuffer(allocator: std.mem.Allocator, comptime T: type, count: usize, alignment: usize) ![]T {
    const bytes = @sizeOf(T) * count;
    const raw = try allocator.alignedAlloc(u8, alignment, bytes);
    return std.mem.bytesAsSlice(T, raw);
}

pub fn cacheLineAligned(allocator: std.mem.Allocator, comptime T: type, count: usize, line: usize) ![]T {
    return alignedBuffer(allocator, T, count, line);
}
