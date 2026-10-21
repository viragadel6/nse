const std = @import("std");
const checksums = @import("checksums.zig");

pub const CompressionError = error{
    CorruptStream,
    OutputTooSmall,
    InputTooLarge,
    UnsupportedFormat,
    ChecksumMismatch,
    TruncatedInput,
    InvalidHeader,
    InvalidBlockType,
    HuffmanError,
    DistanceOutOfRange,
    LengthOutOfRange,
};

pub const block_magic = "NZB1";
pub const max_window: usize = 1 << 30;

pub fn compressBound(source_len: usize) usize {
    return source_len + @divFloor(source_len, 16) + 64 + block_magic.len;
}

const hash_bits = 16;
const hash_size = 1 << hash_bits;
const min_match: usize = 4;
const max_match: usize = 1024;
const max_offset: usize = 65535;
const match_depth: usize = 32;

pub fn compress(source: []const u8, destination: []u8) CompressionError!usize {
    if (source.len == 0) {
        if (destination.len < block_magic.len + 8) return CompressionError.OutputTooSmall;
        @memcpy(destination[0..4], block_magic);
        std.mem.writeInt(u32, destination[4..8], 0, .little);
        return block_magic.len + 4;
    }
    if (destination.len < compressBound(source.len)) return CompressionError.OutputTooSmall;
    @memcpy(destination[0..4], block_magic);
    std.mem.writeInt(u32, destination[4..8], @intCast(source.len), .little);
    var out: usize = 8;
    var recent: [hash_size]u32 = undefined;
    var older: [hash_size]u32 = undefined;
    @memset(&recent, 0xFFFFFFFF);
    @memset(&older, 0xFFFFFFFF);
    var pos: usize = 0;
    var literal_start: usize = 0;
    while (pos + min_match <= source.len) {
        const h = hash4(source[pos..]);
        var best_len: usize = 0;
        var best_off: usize = 0;
        var candidate = recent[h];
        var attempts: usize = 0;
        while (attempts < 2) : (attempts += 1) {
            if (candidate == 0xFFFFFFFF) {
                candidate = older[h];
                continue;
            }
            const cand: usize = candidate;
            candidate = older[h];
            if (cand + min_match > pos) continue;
            const distance = pos - cand;
            if (distance == 0 or distance > max_offset) continue;
            var len: usize = 0;
            while (len < max_match and pos + len < source.len and source[cand + len] == source[pos + len]) : (len += 1) {}
            if (len >= min_match and len > best_len) {
                best_len = len;
                best_off = distance;
            }
        }
        older[h] = recent[h];
        recent[h] = @intCast(pos);
        if (best_len >= min_match) {
            try flushLiterals(source[literal_start..pos], destination, &out);
            const encoded_len = @min(best_len, 65535 + 10);
            if (encoded_len <= 10) {
                destination[out] = 0x80 | @as(u8, @intCast((encoded_len - min_match) << 4));
                out += 1;
            } else {
                destination[out] = 0x80 | 0x70;
                out += 1;
                var extra = encoded_len - 10;
                while (extra >= 0x80) {
                    destination[out] = @as(u8, @truncate(extra)) | 0x80;
                    out += 1;
                    extra >>= 7;
                }
                destination[out] = @as(u8, @truncate(extra));
                out += 1;
            }
            std.mem.writeInt(u16, destination[out..][0..2], @intCast(best_off), .little);
            out += 2;
            pos += encoded_len;
            literal_start = pos;
        } else {
            pos += 1;
        }
    }
    try flushLiterals(source[literal_start..], destination, &out);
    return out;
}

fn hash4(bytes: []const u8) u16 {
    const v = std.mem.readInt(u32, bytes[0..4], .little) & 0xFFFFFFFF;
    return @truncate((v *% 2654435761) >> (32 - hash_bits));
}

fn flushLiterals(literals: []const u8, destination: []u8, out: *usize) CompressionError!void {
    var offset: usize = 0;
    while (offset < literals.len) {
        const run = @min(128, literals.len - offset);
        destination[out.*] = @truncate(run - 1);
        out.* += 1;
        @memcpy(destination[out.* .. out.* + run], literals[offset .. offset + run]);
        out.* += run;
        offset += run;
    }
}

pub fn compressedSize(source_len: u32, stream: []const u8) !usize {
    _ = source_len;
    return stream.len;
}

pub fn decompress(source: []const u8, destination: []u8) CompressionError!usize {
    if (source.len < 8) return CompressionError.TruncatedInput;
    if (!std.mem.eql(u8, source[0..4], block_magic)) return CompressionError.InvalidHeader;
    const expected = std.mem.readInt(u32, source[4..8], .little);
    if (expected > destination.len) return CompressionError.OutputTooSmall;
    var in: usize = 8;
    var out: usize = 0;
    while (in < source.len) {
        const control = source[in];
        in += 1;
        if (control & 0x80 == 0) {
            const run = @as(usize, control & 0x7F) + 1;
            if (in + run > source.len) return CompressionError.TruncatedInput;
            if (out + run > destination.len) return CompressionError.OutputTooSmall;
            @memcpy(destination[out .. out + run], source[in .. in + run]);
            in += run;
            out += run;
        } else {
            const lcode = @as(usize, (control >> 4) & 0x07);
            var len: usize = 0;
            if (lcode == 7) {
                len = 10;
                var shift: u6 = 0;
                while (true) {
                    if (in >= source.len) return CompressionError.TruncatedInput;
                    const b = source[in];
                    in += 1;
                    len += @as(usize, b & 0x7F) << shift;
                    if (b & 0x80 == 0) break;
                    shift += 7;
                    if (shift >= 63) return CompressionError.CorruptStream;
                }
            } else {
                len = lcode + min_match;
            }
            if (in + 2 > source.len) return CompressionError.TruncatedInput;
            const offset = std.mem.readInt(u16, source[in..][0..2], .little);
            in += 2;
            if (offset == 0 or offset > out) return CompressionError.DistanceOutOfRange;
            if (out + len > destination.len) return CompressionError.OutputTooSmall;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                destination[out] = destination[out - offset];
                out += 1;
            }
        }
    }
    if (out != expected) return CompressionError.CorruptStream;
    return out;
}

pub fn compressAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const dst = try allocator.alloc(u8, compressBound(source.len));
    const n = compress(source, dst) catch |err| {
        allocator.free(dst);
        return err;
    };
    return allocator.realloc(dst, n);
}

pub fn decompressAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len < 8) return CompressionError.TruncatedInput;
    if (!std.mem.eql(u8, source[0..4], block_magic)) return CompressionError.InvalidHeader;
    const expected = std.mem.readInt(u32, source[4..8], .little);
    const dst = try allocator.alloc(u8, expected);
    const n = decompress(source, dst) catch |err| {
        allocator.free(dst);
        return err;
    };
    if (n != expected) {
        allocator.free(dst);
        return CompressionError.CorruptStream;
    }
    return dst;
}

const length_base = [_]u16{
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};
const length_extra = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [_]u16{
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
const distance_extra = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const code_length_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

const Huffman = struct {
    counts: [16]u16,
    symbols: [288]u16,
    max_bits: u8,

    fn init(lengths: []const u8) CompressionError!Huffman {
        var h = Huffman{ .counts = @splat(0), .symbols = @splat(0), .max_bits = 0 };
        for (lengths) |len| {
            if (len > 15) return CompressionError.HuffmanError;
            h.counts[len] += 1;
        }
        h.counts[0] = 0;
        var offsets: [16]u16 = @splat(0);
        for (1..16) |bits| offsets[bits] = offsets[bits - 1] + h.counts[bits - 1];
        for (lengths, 0..) |len, symbol| {
            if (len != 0) {
                h.symbols[offsets[len]] = @intCast(symbol);
                offsets[len] += 1;
                h.max_bits = @max(h.max_bits, len);
            }
        }
        return h;
    }

    fn decode(self: *const Huffman, reader: *BitReader) CompressionError!u16 {
        var code: u16 = 0;
        var first: u16 = 0;
        var index: u16 = 0;
        var bits: u5 = 1;
        while (bits <= 15) : (bits += 1) {
            code |= @as(u16, @intCast(try reader.readBit()));
            const count = self.counts[bits];
            if (code -% first < count) return self.symbols[index + (code - first)];
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        return CompressionError.HuffmanError;
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    bit_buffer: u32 = 0,
    bit_count: u5 = 0,

    fn readBit(self: *BitReader) CompressionError!u32 {
        if (self.bit_count == 0) {
            if (self.pos >= self.data.len) return CompressionError.TruncatedInput;
            self.bit_buffer = @as(u32, self.data[self.pos]);
            self.pos += 1;
            self.bit_count = 8;
        }
        const bit = self.bit_buffer & 1;
        self.bit_buffer >>= 1;
        self.bit_count -= 1;
        return bit;
    }

    fn readBits(self: *BitReader, count: u5) CompressionError!u32 {
        var value: u32 = 0;
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            value |= (try self.readBit()) << @as(u5, i);
        }
        return value;
    }

    fn alignToByte(self: *BitReader) void {
        self.bit_buffer >>= self.bit_count;
        self.bit_count = 0;
    }
};

pub const Inflater = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8) = .{},
    limit: usize,

    pub fn init(allocator: std.mem.Allocator, limit: usize) Inflater {
        return .{ .allocator = allocator, .limit = limit };
    }

    pub fn deinit(self: *Inflater) void {
        self.output.deinit(self.allocator);
    }

    pub fn inflate(self: *Inflater, source: []const u8) CompressionError![]u8 {
        var reader = BitReader{ .data = source };
        while (true) {
            const final = try reader.readBit();
            const btype = try reader.readBits(2);
            switch (btype) {
                0 => try self.storedBlock(&reader),
                1 => try self.huffmanBlock(&reader, null, null),
                2 => try self.dynamicBlock(&reader),
                else => return CompressionError.InvalidBlockType,
            }
            if (final == 1) break;
        }
        self.output.shrinkAndFree(self.allocator, self.output.items.len);
        return self.output.items;
    }

    fn push(self: *Inflater, value: u8) CompressionError!void {
        if (self.output.items.len >= self.limit) return CompressionError.InputTooLarge;
        self.output.append(self.allocator, value) catch return CompressionError.InputTooLarge;
    }

    fn copyBack(self: *Inflater, distance: usize, length: usize) CompressionError!void {
        if (distance == 0 or distance > self.output.items.len) return CompressionError.DistanceOutOfRange;
        for (0..length) |_| {
            const value = self.output.items[self.output.items.len - distance];
            try self.push(value);
        }
    }

    fn storedBlock(self: *Inflater, reader: *BitReader) CompressionError!void {
        reader.alignToByte();
        if (reader.pos + 4 > reader.data.len) return CompressionError.TruncatedInput;
        const len = std.mem.readInt(u16, reader.data[reader.pos..][0..2], .little);
        const nlen = std.mem.readInt(u16, reader.data[reader.pos + 2 ..][0..2], .little);
        reader.pos += 4;
        if (len != ~nlen) return CompressionError.CorruptStream;
        if (reader.pos + len > reader.data.len) return CompressionError.TruncatedInput;
        for (0..len) |i| try self.push(reader.data[reader.pos + i]);
        reader.pos += len;
    }

    fn fixedTables(self: *Inflater, literal: *Huffman, distance: *Huffman) CompressionError!void {
        var literal_lengths: [288]u8 = undefined;
        for (0..144) |i| literal_lengths[i] = 8;
        for (144..256) |i| literal_lengths[i] = 9;
        for (256..280) |i| literal_lengths[i] = 7;
        for (280..288) |i| literal_lengths[i] = 8;
        literal.* = try Huffman.init(&literal_lengths);
        var distance_lengths: [30]u8 = @splat(5);
        distance.* = try Huffman.init(&distance_lengths);
        _ = self;
    }

    fn dynamicBlock(self: *Inflater, reader: *BitReader) CompressionError!void {
        const hlit = (try reader.readBits(5)) + 257;
        const hdist = (try reader.readBits(5)) + 1;
        const hclen = (try reader.readBits(4)) + 4;
        if (hlit > 286 or hdist > 30) return CompressionError.HuffmanError;
        var cl_lengths: [19]u8 = @splat(0);
        for (0..hclen) |i| cl_lengths[code_length_order[i]] = @intCast(try reader.readBits(3));
        const cl_table = try Huffman.init(&cl_lengths);
        var lengths_buffer: [320]u8 = @splat(0);
        var index: usize = 0;
        while (index < hlit + hdist) {
            const symbol = try cl_table.decode(reader);
            if (symbol < 16) {
                lengths_buffer[index] = @intCast(symbol);
                index += 1;
            } else if (symbol == 16) {
                if (index == 0) return CompressionError.CorruptStream;
                const previous = lengths_buffer[index - 1];
                const repeat = (try reader.readBits(2)) + 3;
                for (0..repeat) |_| {
                    lengths_buffer[index] = previous;
                    index += 1;
                }
            } else if (symbol == 17) {
                const repeat = (try reader.readBits(3)) + 3;
                for (0..repeat) |_| {
                    lengths_buffer[index] = 0;
                    index += 1;
                }
            } else if (symbol == 18) {
                const repeat = (try reader.readBits(7)) + 11;
                for (0..repeat) |_| {
                    lengths_buffer[index] = 0;
                    index += 1;
                }
            } else {
                return CompressionError.HuffmanError;
            }
            if (index > hlit + hdist) return CompressionError.CorruptStream;
        }
        const literal = try Huffman.init(lengths_buffer[0..hlit]);
        const distance = try Huffman.init(lengths_buffer[hlit .. hlit + hdist]);
        return self.huffmanBlock(reader, literal, distance);
    }

    fn huffmanBlock(self: *Inflater, reader: *BitReader, maybe_literal: ?Huffman, maybe_distance: ?Huffman) CompressionError!void {
        var literal: Huffman = undefined;
        var distance: Huffman = undefined;
        if (maybe_literal) |l| {
            literal = l;
            distance = maybe_distance.?;
        } else {
            self.fixedTables(&literal, &distance) catch return CompressionError.HuffmanError;
        }
        while (true) {
            const symbol = try literal.decode(reader);
            if (symbol < 256) {
                try self.push(@intCast(symbol));
            } else if (symbol == 256) {
                return;
            } else {
                const length_index: usize = symbol - 257;
                if (length_index >= length_base.len) return CompressionError.LengthOutOfRange;
                const length = @as(usize, length_base[length_index]) + @as(usize, try reader.readBits(@intCast(length_extra[length_index])));
                const distance_symbol = try distance.decode(reader);
                if (distance_symbol >= distance_base.len) return CompressionError.DistanceOutOfRange;
                const dist = @as(usize, distance_base[distance_symbol]) + @as(usize, try reader.readBits(@intCast(distance_extra[distance_symbol])));
                try self.copyBack(dist, length);
            }
        }
    }
};

pub fn inflate(allocator: std.mem.Allocator, source: []const u8, limit: usize) ![]u8 {
    var inflater = Inflater.init(allocator, limit);
    errdefer inflater.deinit();
    return inflater.inflate(source);
}

pub fn gzipDecompress(allocator: std.mem.Allocator, source: []const u8, limit: usize) ![]u8 {
    if (source.len < 18) return CompressionError.TruncatedInput;
    if (source[0] != 0x1F or source[1] != 0x8B) return CompressionError.InvalidHeader;
    if (source[2] != 8) return CompressionError.UnsupportedFormat;
    const flags = source[3];
    var pos: usize = 10;
    if (flags & 0x04 != 0) {
        if (pos + 2 > source.len) return CompressionError.TruncatedInput;
        const xlen = std.mem.readInt(u16, source[pos..][0..2], .little);
        pos += 2 + xlen;
    }
    if (flags & 0x08 != 0) {
        while (pos < source.len and source[pos] != 0) pos += 1;
        pos += 1;
    }
    if (flags & 0x10 != 0) {
        while (pos < source.len and source[pos] != 0) pos += 1;
        pos += 1;
    }
    if (flags & 0x02 != 0) pos += 2;
    if (pos + 8 > source.len) return CompressionError.TruncatedInput;
    const payload = source[pos .. source.len - 8];
    const expected_crc = std.mem.readInt(u32, source[source.len - 8 ..][0..4], .little);
    const expected_size = std.mem.readInt(u32, source[source.len - 4 ..][0..4], .little);
    const output = try inflate(allocator, payload, limit);
    errdefer allocator.free(output);
    if (output.len != expected_size) return CompressionError.ChecksumMismatch;
    if (checksums.crc32(output, 0) != expected_crc) return CompressionError.ChecksumMismatch;
    return output;
}

pub fn zlibDecompress(allocator: std.mem.Allocator, source: []const u8, limit: usize) ![]u8 {
    if (source.len < 6) return CompressionError.TruncatedInput;
    const cmf = source[0];
    const flg = source[1];
    if (cmf & 0x0F != 8) return CompressionError.UnsupportedFormat;
    if (((@as(u16, cmf) << 8) | @as(u16, flg)) % 31 != 0) return CompressionError.InvalidHeader;
    if (flg & 0x20 != 0) return CompressionError.UnsupportedFormat;
    return inflate(allocator, source[2..], limit);
}

pub fn identityRatio(source: []const u8) f32 {
    if (source.len == 0) return 1.0;
    const bound = compressBound(source.len);
    const scratch = std.heap.page_allocator.alloc(u8, bound) catch return 1.0;
    defer std.heap.page_allocator.free(scratch);
    const n = compress(source, scratch) catch return 1.0;
    return @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(source.len));
}
