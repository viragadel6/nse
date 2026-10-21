const std = @import("std");

pub const ArenaPool = struct {
    arenas: std.ArrayList(std.heap.ArenaAllocator),
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) ArenaPool {
        return ArenaPool{ .arenas = std.ArrayList(std.heap.ArenaAllocator).init(backing), .backing = backing };
    }

    pub fn acquire(self: *ArenaPool) std.heap.ArenaAllocator {
        if (self.arenas.items.len > 0) {
            return self.arenas.items.pop();
        }
        return std.heap.ArenaAllocator.init(self.backing);
    }

    pub fn release(self: *ArenaPool, arena: std.heap.ArenaAllocator) void {
        _ = self.arenas.append(arena);
    }

    pub fn deinit(self: *ArenaPool) void {
        for (self.arenas.items) |*a| a.deinit();
        self.arenas.deinit();
    }
};

pub const PoolAllocator = struct {
    allocator: std.mem.Allocator,
    object_size: usize,
    blocks: [][]u8,
    free: []usize,
    free_count: usize,
    block_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, object_size: usize, block_capacity: usize) !PoolAllocator {
        const blocks = try allocator.alloc([]u8, block_capacity);
        const free = try allocator.alloc(usize, block_capacity);
        var i: usize = 0;
        while (i < block_capacity) {
            free[i] = i;
            i += 1;
        }
        return PoolAllocator{
            .allocator = allocator,
            .object_size = object_size,
            .blocks = blocks,
            .free = free,
            .free_count = block_capacity,
            .block_capacity = block_capacity,
        };
    }

    pub fn deinit(self: *PoolAllocator) void {
        for (self.blocks) |block| if (block != null) self.allocator.free(block);
        self.allocator.free(self.blocks);
        self.allocator.free(self.free);
    }

    pub fn alloc(self: *PoolAllocator) ![]u8 {
        if (self.free_count == 0) return error.OutOfMemory;
        self.free_count -= 1;
        const index = self.free[self.free_count];
        if (self.blocks[index] == null) {
            self.blocks[index] = try self.allocator.alloc(u8, self.object_size * self.block_capacity);
        }
        const offset = index * self.object_size;
        return self.blocks[index][offset..][0..self.object_size];
    }

    pub fn free(self: *PoolAllocator, slice: []u8) void {
        _ = slice;
    }
};
