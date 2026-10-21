const std = @import("std");
const hashing = @import("../util/hashing.zig");
const simd = @import("../scoring/simd_kernels.zig");
const checksums = @import("../util/checksums.zig");

pub const IndexError = error{
    InvalidDimensions,
    NoVectors,
    InvalidCentroidCount,
    CorruptIndex,
    VersionMismatch,
};

pub const magic = "NCEN";
pub const format_version: u32 = 1;

pub const Distance = enum(u8) {
    euclidean,
    cosine,
};

pub const Options = struct {
    centroid_count: u32 = 100000,
    dimension: u32 = 256,
    batch_size: u32 = 8192,
    iterations: u32 = 40,
    seed: u64 = 0x243F6A8885A308D3,
    capacity_per_centroid: u32 = 0,
    learning_rate: f64 = 0.1,
    probe_count: u32 = 32,
    distance: Distance = .cosine,
    min_points_per_centroid: u32 = 8,
};

pub const Sampler = struct {
    context: *anyopaque,
    next: *const fn (context: *anyopaque, buffer: []f32) anyerror!usize,
    reset: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn fill(self: *const Sampler, buffer: []f32) !usize {
        return self.next(self.context, buffer);
    }

    pub fn restart(self: *const Sampler) !void {
        if (self.reset) |reset| try reset(self.context);
    }
};

pub const TrainingStats = struct {
    iterations: u32,
    vectors_seen: u64,
    inertia: f64,
    reassigned: u64,
    elapsed_ms: u64,
    empty_centroids: u32,
};

pub const CentroidIndex = struct {
    allocator: std.mem.Allocator,
    options: Options,
    centroids: []f32,
    sums: []f64,
    counts: []u32,
    observed: []u32,
    assignments_total: u64 = 0,
    trained: bool = false,
    iterations_run: u32 = 0,
    inertia: f64 = 0.0,
    random: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, options: Options) !CentroidIndex {
        if (options.centroid_count == 0) return IndexError.InvalidCentroidCount;
        if (options.dimension == 0) return IndexError.InvalidDimensions;
        const total = @as(usize, options.centroid_count) * @as(usize, options.dimension);
        const centroids = try allocator.alloc(f32, total);
        errdefer allocator.free(centroids);
        const sums = try allocator.alloc(f64, total);
        errdefer allocator.free(sums);
        const counts = try allocator.alloc(u32, options.centroid_count);
        errdefer allocator.free(counts);
        const observed = try allocator.alloc(u32, options.centroid_count);
        errdefer allocator.free(observed);
        @memset(centroids, 0.0);
        @memset(sums, 0.0);
        @memset(counts, 0);
        @memset(observed, 0);
        return .{
            .allocator = allocator,
            .options = options,
            .centroids = centroids,
            .sums = sums,
            .counts = counts,
            .observed = observed,
            .random = std.Random.DefaultPrng.init(options.seed),
        };
    }

    pub fn deinit(self: *CentroidIndex) void {
        self.allocator.free(self.centroids);
        self.allocator.free(self.sums);
        self.allocator.free(self.counts);
        self.allocator.free(self.observed);
    }

    pub fn centroidSlice(self: *const CentroidIndex, index: u32) []const f32 {
        const dimension = self.options.dimension;
        return self.centroids[@as(usize, index) * dimension ..][0..dimension];
    }

    pub fn mutableCentroidSlice(self: *CentroidIndex, index: u32) []f32 {
        const dimension = self.options.dimension;
        return self.centroids[@as(usize, index) * dimension ..][0..dimension];
    }

    pub fn setCentroid(self: *CentroidIndex, index: u32, values: []const f32) !void {
        if (values.len != self.options.dimension) return IndexError.InvalidDimensions;
        @memcpy(self.mutableCentroidSlice(index), values);
    }

    pub fn normalizeCentroids(self: *CentroidIndex) void {
        const dimension = self.options.dimension;
        var index: u32 = 0;
        while (index < self.options.centroid_count) : (index += 1) {
            simd.normalizeF32(self.mutableCentroidSlice(index));
        }
        _ = dimension;
    }

    fn score(self: *const CentroidIndex, centroid: u32, vector: []const f32) f64 {
        const centroid_values = self.centroidSlice(centroid);
        return switch (self.options.distance) {
            .cosine => simd.dotF32(centroid_values, vector),
            .euclidean => -simd.l2DistanceF32(centroid_values, vector),
        };
    }

    pub fn assign(self: *CentroidIndex, vector: []const f32) !u32 {
        return self.assignRange(vector, 0, self.options.centroid_count);
    }

    pub fn assignRange(self: *CentroidIndex, vector: []const f32, from: u32, to: u32) !u32 {
        if (vector.len != self.options.dimension) return IndexError.InvalidDimensions;
        var best: u32 = from;
        var best_score: f64 = -std.math.inf(f64);
        var centroid = from;
        while (centroid < @min(to, self.options.centroid_count)) : (centroid += 1) {
            const value = self.score(centroid, vector);
            if (value > best_score) {
                best_score = value;
                best = centroid;
            }
        }
        self.assignments_total += 1;
        return best;
    }

    pub fn assignBatch(self: *CentroidIndex, vectors: []const f32, count: usize, out: []u32) !void {
        const dimension = self.options.dimension;
        for (0..count) |position| {
            out[position] = try self.assign(vectors[position * dimension ..][0..dimension]);
        }
    }

    pub fn assignWithCapacity(self: *CentroidIndex, vector: []const f32, probe_multiplier: u32) !u32 {
        if (self.options.capacity_per_centroid == 0) return self.assign(vector);
        const probes = @max(1, probe_multiplier);
        var best: u32 = 0;
        var best_score: f64 = -std.math.inf(f64);
        var found = false;
        var attempt: u32 = 0;
        while (attempt < probes) : (attempt += 1) {
            const candidate = try self.assign(vector);
            const saturated = self.observed[candidate] >= self.options.capacity_per_centroid;
            const value = self.score(candidate, vector) - if (saturated) 1.0 else 0.0;
            if (!found or value > best_score) {
                best_score = value;
                best = candidate;
                found = true;
            }
            if (!saturated) break;
        }
        return best;
    }

    pub fn accumulate(self: *CentroidIndex, centroid: u32, vector: []const f32) !void {
        if (centroid >= self.options.centroid_count) return IndexError.InvalidCentroidCount;
        const dimension = self.options.dimension;
        const base = @as(usize, centroid) * dimension;
        for (0..dimension) |index| {
            self.sums[base + index] += @as(f64, vector[index]);
        }
        self.counts[centroid] += 1;
    }

    pub fn applyUpdates(self: *CentroidIndex) u32 {
        const dimension = self.options.dimension;
        var updated: u32 = 0;
        for (0..self.options.centroid_count) |centroid| {
            const count = self.counts[centroid];
            if (count == 0) continue;
            const base = centroid * dimension;
            const inverse = @as(f32, @floatCast(1.0 / @as(f64, @floatFromInt(count))));
            for (0..dimension) |index| {
                const target: f32 = @floatCast(self.sums[base + index] * @as(f64, inverse));
                self.centroids[base + index] = target;
                self.sums[base + index] = 0.0;
            }
            self.counts[centroid] = 0;
            updated += 1;
        }
        return updated;
    }

    pub fn seedKmeansPlusPlus(self: *CentroidIndex, sampler: *const Sampler) !u32 {
        const dimension = self.options.dimension;
        const sample = try self.allocator.alloc(f32, dimension);
        defer self.allocator.free(sample);
        var candidates = try self.allocator.alloc(f32, @as(usize, 1024) * dimension);
        defer self.allocator.free(candidates);
        const read = try sampler.fill(sample);
        if (read < dimension) return IndexError.NoVectors;
        try self.setCentroid(0, sample);
        var chosen: u32 = 1;
        while (chosen < self.options.centroid_count) : (chosen += 1) {
            var fetched = @min(@as(usize, 1024), try sampler.fill(candidates));
            if (fetched < dimension) {
                try sampler.restart();
                fetched = @min(@as(usize, 1024), try sampler.fill(candidates));
                if (fetched < dimension) break;
            }
            const available = fetched / dimension;
            var best_index: usize = 0;
            var best_distance: f64 = -1.0;
            var total_distance: f64 = 0.0;
            var distances = try self.allocator.alloc(f64, available);
            defer self.allocator.free(distances);
            for (0..available) |position| {
                const vector = candidates[position * dimension ..][0..dimension];
                var nearest: f64 = std.math.inf(f64);
                var centroid: u32 = 0;
                while (centroid < chosen) : (centroid += 1) {
                    const value = switch (self.options.distance) {
                        .cosine => 1.0 - simd.dotF32(self.centroidSlice(centroid), vector),
                        .euclidean => simd.l2DistanceF32(self.centroidSlice(centroid), vector),
                    };
                    if (value < nearest) nearest = value;
                }
                distances[position] = nearest * nearest;
                total_distance += distances[position];
                if (distances[position] > best_distance) {
                    best_distance = distances[position];
                    best_index = position;
                }
            }
            const threshold = total_distance * @as(f64, @floatFromInt(self.random.random().int(u64))) / @as(f64, @floatFromInt(std.math.maxInt(u64)));
            var running: f64 = 0.0;
            var selected: usize = best_index;
            for (0..available) |position| {
                running += distances[position];
                if (running >= threshold) {
                    selected = position;
                    break;
                }
            }
            try self.setCentroid(chosen, candidates[selected * dimension ..][0..dimension]);
        }
        self.trained = chosen == self.options.centroid_count;
        return chosen;
    }

    pub fn train(self: *CentroidIndex, sampler: *const Sampler) !TrainingStats {
        const dimension = self.options.dimension;
        const batch_vectors = @max(1, self.options.batch_size);
        var batch = try self.allocator.alloc(f32, @as(usize, batch_vectors) * dimension);
        defer self.allocator.free(batch);
        var assignments = try self.allocator.alloc(u32, batch_vectors);
        defer self.allocator.free(assignments);
        const previous = try self.allocator.alloc(f32, self.centroids.len);
        defer self.allocator.free(previous);
        @memcpy(previous, self.centroids);
        var vectors_seen: u64 = 0;
        var reassigned: u64 = 0;
        const started = std.time.milliTimestamp();
        var iteration: u32 = 0;
        while (iteration < self.options.iterations) : (iteration += 1) {
            try sampler.restart();
            while (true) {
                const fetched = try sampler.fill(batch);
                if (fetched < dimension) break;
                const available = fetched / dimension;
                for (0..available) |position| {
                    const vector = batch[position * dimension ..][0..dimension];
                    const centroid = try self.assign(vector);
                    assignments[position] = centroid;
                    if (self.observed[centroid] < std.math.maxInt(u32)) self.observed[centroid] += 1;
                    try self.accumulate(centroid, vector);
                }
                vectors_seen += available;
            }
            _ = self.applyUpdates();
            if (self.options.distance == .cosine) self.normalizeCentroids();
            var empty_now: u32 = 0;
            for (self.observed) |value| {
                if (value == 0) empty_now += 1;
            }
            if (empty_now > 0 and iteration + 1 < self.options.iterations) {
                try sampler.restart();
                const fetched = try sampler.fill(batch);
                if (fetched >= dimension) {
                    const available = fetched / dimension;
                    var cursor: usize = 0;
                    for (0..self.options.centroid_count) |centroid| {
                        if (self.observed[centroid] != 0) continue;
                        const position = cursor % available;
                        cursor += 1;
                        try self.setCentroid(@intCast(centroid), batch[position * dimension ..][0..dimension]);
                    }
                }
            }
            var shift: f64 = 0.0;
            for (0..self.options.centroid_count) |centroid| {
                const base = centroid * dimension;
                for (0..dimension) |index| {
                    const delta = @as(f64, self.centroids[base + index]) - @as(f64, previous[base + index]);
                    shift += delta * delta;
                }
            }
            reassigned += 1;
            @memcpy(previous, self.centroids);
            self.inertia = @sqrt(shift);
            if (self.inertia < 1e-7) break;
        }
        self.iterations_run = iteration;
        self.trained = true;
        var empty: u32 = 0;
        for (self.observed) |count| {
            if (count < self.options.min_points_per_centroid) empty += 1;
        }
        return .{
            .iterations = iteration,
            .vectors_seen = vectors_seen,
            .inertia = self.inertia,
            .reassigned = reassigned,
            .elapsed_ms = @intCast(std.time.milliTimestamp() - started),
            .empty_centroids = empty,
        };
    }

    pub fn probesFor(self: *CentroidIndex, vector: []const f32, probe_count: u32) ![]u32 {
        const count = @min(probe_count, self.options.centroid_count);
        const out = try self.allocator.alloc(u32, count);
        var scores = try self.allocator.alloc(f64, count);
        defer self.allocator.free(scores);
        var filled: u32 = 0;
        @memset(scores, -std.math.inf(f64));
        var centroid: u32 = 0;
        while (centroid < self.options.centroid_count) : (centroid += 1) {
            const value = self.score(centroid, vector);
            if (filled < count) {
                var position = filled;
                out[position] = centroid;
                scores[position] = value;
                filled += 1;
                while (position > 0 and scores[position] > scores[position - 1]) {
                    const tmp_id = out[position];
                    const tmp_score = scores[position];
                    out[position] = out[position - 1];
                    scores[position] = scores[position - 1];
                    out[position - 1] = tmp_id;
                    scores[position - 1] = tmp_score;
                    position -= 1;
                }
            } else if (value > scores[count - 1]) {
                out[count - 1] = centroid;
                scores[count - 1] = value;
                var position = count - 1;
                while (position > 0 and scores[position] > scores[position - 1]) {
                    const tmp_id = out[position];
                    const tmp_score = scores[position];
                    out[position] = out[position - 1];
                    scores[position] = scores[position - 1];
                    out[position - 1] = tmp_id;
                    scores[position - 1] = tmp_score;
                    position -= 1;
                }
            }
        }
        return out;
    }

    pub fn encodedSize(self: *const CentroidIndex) usize {
        const vector_bytes = @as(usize, self.options.centroid_count) * @as(usize, self.options.dimension) * 4;
        return 32 + vector_bytes + @as(usize, self.options.centroid_count) * 4;
    }

    pub fn serialize(self: *const CentroidIndex, allocator: std.mem.Allocator) ![]u8 {
        const size = self.encodedSize();
        const buffer = try allocator.alloc(u8, size);
        @memcpy(buffer[0..4], magic);
        std.mem.writeInt(u32, buffer[4..8], format_version, .little);
        std.mem.writeInt(u32, buffer[8..12], self.options.centroid_count, .little);
        std.mem.writeInt(u32, buffer[12..16], self.options.dimension, .little);
        std.mem.writeInt(u32, buffer[16..20], @intFromEnum(self.options.distance), .little);
        std.mem.writeInt(u64, buffer[20..28], self.options.seed, .little);
        const vector_bytes = @as(usize, self.options.centroid_count) * @as(usize, self.options.dimension) * 4;
        var offset: usize = 28;
        for (self.centroids) |value| {
            std.mem.writeInt(u32, buffer[offset..][0..4], @bitCast(value), .little);
            offset += 4;
        }
        for (self.observed) |value| {
            std.mem.writeInt(u32, buffer[offset..][0..4], value, .little);
            offset += 4;
        }
        std.mem.writeInt(u32, buffer[offset..][0..4], checksums.crc32c(buffer[0..offset], 0), .little);
        _ = vector_bytes;
        return buffer;
    }

    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !CentroidIndex {
        if (bytes.len < 32) return IndexError.CorruptIndex;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return IndexError.CorruptIndex;
        const version = std.mem.readInt(u32, bytes[4..8], .little);
        if (version != format_version) return IndexError.VersionMismatch;
        const centroid_count = std.mem.readInt(u32, bytes[8..12], .little);
        const dimension = std.mem.readInt(u32, bytes[12..16], .little);
        const distance: Distance = @enumFromInt(std.mem.readInt(u32, bytes[16..20], .little));
        const seed = std.mem.readInt(u64, bytes[20..28], .little);
        var index = try CentroidIndex.init(allocator, .{
            .centroid_count = centroid_count,
            .dimension = dimension,
            .distance = distance,
            .seed = seed,
        });
        errdefer index.deinit();
        var offset: usize = 28;
        for (index.centroids) |*value| {
            value.* = @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
            offset += 4;
        }
        for (index.observed) |*value| {
            value.* = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            offset += 4;
        }
        index.trained = true;
        return index;
    }

    pub fn save(self: *const CentroidIndex, path: []const u8) !void {
        const encoded = try self.serialize(self.allocator);
        defer self.allocator.free(encoded);
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(encoded);
        try file.sync();
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !CentroidIndex {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        const bytes = try allocator.alloc(u8, stat.size);
        defer allocator.free(bytes);
        _ = try file.readAll(bytes);
        return deserialize(allocator, bytes);
    }

    pub fn stats(self: *const CentroidIndex) CentroidStats {
        var total: u64 = 0;
        var minimum: u32 = std.math.maxInt(u32);
        var maximum: u32 = 0;
        var empty: u32 = 0;
        for (self.observed) |count| {
            total += count;
            if (count < minimum) minimum = count;
            if (count > maximum) maximum = count;
            if (count == 0) empty += 1;
        }
        const mean = if (self.options.centroid_count > 0) @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.options.centroid_count)) else 0.0;
        var variance: f64 = 0.0;
        for (self.observed) |count| {
            const delta = @as(f64, @floatFromInt(count)) - mean;
            variance += delta * delta;
        }
        if (self.options.centroid_count > 0) variance /= @as(f64, @floatFromInt(self.options.centroid_count));
        return .{
            .centroids = self.options.centroid_count,
            .dimension = self.options.dimension,
            .observations = total,
            .min_observations = if (minimum == std.math.maxInt(u32)) 0 else minimum,
            .max_observations = maximum,
            .empty_centroids = empty,
            .balance_stddev = @sqrt(variance),
            .assignments = self.assignments_total,
            .trained = self.trained,
            .iterations = self.iterations_run,
        };
    }
};

pub const CentroidStats = struct {
    centroids: u32,
    dimension: u32,
    observations: u64,
    min_observations: u32,
    max_observations: u32,
    empty_centroids: u32,
    balance_stddev: f64,
    assignments: u64,
    trained: bool,
    iterations: u32,
};

pub fn stableCentroidKey(name: []const u8) u64 {
    return hashing.stableSeed(name);
}
