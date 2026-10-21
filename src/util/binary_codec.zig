const std = @import("std");

pub const Encoder = struct {
    bytes: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .bytes = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Encoder) void {
        self.bytes.deinit();
    }

    pub fn integer(self: *Encoder, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.bytes.appendSlice(&buffer);
    }

    pub fn float(self: *Encoder, value: f32) !void {
        try self.integer(u32, @bitCast(value));
    }

    pub fn string(self: *Encoder, value: []const u8) !void {
        const length = std.math.cast(u32, value.len) orelse return error.RecordTooLarge;
        try self.integer(u32, length);
        try self.bytes.appendSlice(value);
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn take(self: *Decoder, length: usize) ![]const u8 {
        if (length > self.bytes.len - self.offset) return error.TruncatedRecord;
        const result = self.bytes[self.offset..][0..length];
        self.offset += length;
        return result;
    }

    pub fn integer(self: *Decoder, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    pub fn float(self: *Decoder) !f32 {
        const value: f32 = @bitCast(try self.integer(u32));
        if (!std.math.isFinite(value)) return error.InvalidNumericValue;
        return value;
    }

    pub fn string(self: *Decoder) ![]const u8 {
        const result = try self.take(try self.integer(u32));
        if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
        return result;
    }

    pub fn finish(self: Decoder) !void {
        if (self.offset != self.bytes.len) return error.TrailingRecordData;
    }
};
