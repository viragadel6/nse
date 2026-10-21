const std = @import("std");

pub const Tensor = struct {
    dims: []usize,
    data: []f32,
    offset: usize = 0,

    pub fn rank(self: *const Tensor) usize {
        return self.dims.len;
    }

    pub fn size(self: *const Tensor) usize {
        var total: usize = 1;
        for (self.dims) |dim| total *= dim;
        return total;
    }

    pub fn index(self: *const Tensor, indices: []const usize) !usize {
        if (indices.len != self.dims.len) return error.RankMismatch;
        var position: usize = 0;
        var stride: usize = 1;
        var i: usize = self.dims.len;
        while (i > 0) {
            i -= 1;
            if (indices[i] >= self.dims[i]) return error.IndexOutOfBounds;
            position += indices[i] * stride;
            stride *= self.dims[i];
        }
        return self.offset + position;
    }

    pub fn get(self: *const Tensor, indices: []const usize) !f32 {
        return self.data[try self.index(indices)];
    }

    pub fn set(self: *Tensor, indices: []const usize, value: f32) !void {
        self.data[try self.index(indices)] = value;
    }
};

pub fn allocTensor(allocator: std.mem.Allocator, dims: []const usize) !Tensor {
    var total: usize = 1;
    for (dims) |dim| total *= dim;
    const data = try allocator.alloc(f32, total);
    var dims_copy = try allocator.dup(usize, dims);
    return Tensor{ .dims = dims_copy, .data = data };
}

pub fn freeTensor(allocator: std.mem.Allocator, tensor: Tensor) void {
    allocator.free(tensor.data);
    allocator.free(tensor.dims);
}
