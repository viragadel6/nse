const std = @import("std");
const protocol = @import("workload");
const artifacts = @import("artifacts");
const cuda = @import("../models/cuda_runtime.zig");
const transformer = @import("../models/gpu_transformer.zig");
const signals = @import("../runtime/signals.zig");

fn batchLoss(allocator: std.mem.Allocator, graph: *transformer.Graph, queries: []const usize, documents: []const usize) !f32 {
    const runtime = graph.model.runtime;
    const batch = std.math.cast(i32, queries.len) orelse return error.BatchTooLarge;
    if (documents.len != queries.len or batch < 2) return error.InvalidContrastiveBatch;
    const vector_bytes = try std.math.mul(usize, queries.len, 4096 * 4);
    const q = try runtime.allocate(vector_bytes); defer runtime.free(q);
    const d = try runtime.allocate(vector_bytes); defer runtime.free(d);
    const gq = try runtime.allocate(vector_bytes); defer runtime.free(gq);
    const gd = try runtime.allocate(vector_bytes); defer runtime.free(gd);
    try runtime.zero(gq, vector_bytes); try runtime.zero(gd, vector_bytes);
    const matrix_bytes = try std.math.mul(usize, try std.math.mul(usize, queries.len, queries.len), 4);
    const probabilities = try runtime.allocate(matrix_bytes); defer runtime.free(probabilities);
    const similarities = try runtime.allocate(matrix_bytes); defer runtime.free(similarities);
    const norms = try runtime.allocate(queries.len * 8); defer runtime.free(norms);
    const losses = try runtime.allocate(queries.len * 4); defer runtime.free(losses);
    for (queries, documents, 0..) |qid, did, i| {
        try runtime.launch("copy_values", 4096, .{ graph.nodes.items[qid].data, q + i * 4096 * 4, @as(i32, 4096) });
        try runtime.launch("copy_values", 4096, .{ graph.nodes.items[did].data, d + i * 4096 * 4, @as(i32, 4096) });
    }
    const values = try allocator.alloc(f32, queries.len);
    defer allocator.free(values);
    var total: f32 = 0;
    for ([_]i32{ 256, 4096 }) |dims| {
        try runtime.launch("contrastive_norms", queries.len, .{ q, d, norms, batch, dims });
        try runtime.launch("contrastive_forward", queries.len, .{ q, d, graph.model.temperature(), norms, similarities, probabilities, losses, batch, dims, @as(f32, 0.5) });
        try runtime.launch("contrastive_backward", queries.len * 4096, .{ q, d, graph.model.temperature(), norms, similarities, probabilities, gq, gd, graph.model.temperatureGradient(), batch, dims, @as(f32, 0.5) });
        try runtime.download(std.mem.sliceAsBytes(values), losses);
        for (values) |value| { if (!std.math.isFinite(value)) return error.NonFiniteTrainingLoss; total += value; }
    }
    for (queries, documents, 0..) |qid, did, i| {
        try runtime.launch("copy_values", 4096, .{ gq + i * 4096 * 4, graph.nodes.items[qid].gradient, @as(i32, 4096) });
        try runtime.launch("copy_values", 4096, .{ gd + i * 4096 * 4, graph.nodes.items[did].gradient, @as(i32, 4096) });
    }
    return total;
}

fn loadPairs(allocator: std.mem.Allocator, root: []const u8, request: protocol.TrainingRequest) ![]protocol.Pair {
    if (request.dataset_path) |relative| {
        if (std.fs.path.isAbsolute(relative) or std.mem.indexOf(u8, relative, "..") != null) return error.InvalidDatasetPath;
        const path = try std.fs.path.join(allocator, &.{ root, "datasets", relative });
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var buffered = std.io.bufferedReader(file.reader());
        var pairs = std.ArrayList(protocol.Pair).init(allocator);
        var consumed: usize = 0;
        while (try buffered.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 8 * 1024 * 1024)) |line| {
            consumed = try std.math.add(usize, consumed, line.len);
            if (consumed > 256 * 1024 * 1024) return error.TrainingShardExceedsMemoryBudget;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            const parsed = try protocol.parse(protocol.Pair, allocator, trimmed);
            try protocol.validateItem(.{ .text = parsed.value.query, .kind = .query, .structure = parsed.value.query_structure });
            try protocol.validateItem(.{ .text = parsed.value.document, .structure = parsed.value.document_structure });
            try pairs.append(parsed.value);
        }
        if (pairs.items.len < 2) return error.InsufficientTrainingPairs;
        return pairs.toOwnedSlice();
    }
    return allocator.dupe(protocol.Pair, request.pairs);
}

fn initialize(allocator: std.mem.Allocator, request: protocol.TrainingRequest) !artifacts.Checkpoint {
    const count = try artifacts.parameterCount(request.hidden, request.layers, request.max_tokens);
    const p = try allocator.alloc(f32, count); errdefer allocator.free(p);
    const m = try allocator.alloc(f32, count); errdefer allocator.free(m);
    const v = try allocator.alloc(f32, count); errdefer allocator.free(v);
    var generator = std.Random.DefaultPrng.init(request.seed);
    const random = generator.random();
    const scale: f32 = @sqrt(6 / @as(f32, @floatFromInt(request.hidden)));
    for (p) |*value| value.* = (random.float(f32) * 2 - 1) * scale;
    p[count - 1] = @log(@as(f32, 0.07));
    @memset(m, 0); @memset(v, 0);
    return .{ .metadata = .{ .model_version = request.model_version, .hidden = request.hidden, .layers = request.layers, .max_tokens = request.max_tokens, .seed = request.seed, .parameter_count = count }, .parameters = p, .first_moment = m, .second_moment = v, .digest = @splat(0), .allocator = allocator };
}

pub fn run(allocator: std.mem.Allocator, runtime: *cuda.Runtime, root: []const u8, request: protocol.TrainingRequest) !protocol.TrainingResponse {
    try protocol.validateTraining(request);
    const started = try std.time.Timer.start();
    var timer = started;
    const directory = try std.fs.path.join(allocator, &.{ root, "jobs", request.job_id });
    defer allocator.free(directory);
    try std.fs.cwd().makePath(directory);
    const lock_path = try std.fs.path.join(allocator, &.{ directory, "writer.lock" });
    defer allocator.free(lock_path);
    const lock = try std.fs.cwd().createFile(lock_path, .{ .truncate = false });
    defer lock.close();
    if (!try lock.tryLock(.exclusive)) return error.TrainingJobAlreadyRunning;
    defer lock.unlock();
    const path = try std.fs.path.join(allocator, &.{ directory, "checkpoint.bin" });
    defer allocator.free(path);
    const request_path = try std.fs.path.join(allocator, &.{ directory, "request.json" });
    defer allocator.free(request_path);
    var canonical = request;
    canonical.@"resume" = true;
    const request_bytes = try std.json.stringifyAlloc(allocator, canonical, .{});
    defer allocator.free(request_bytes);
    if (std.fs.cwd().readFileAlloc(allocator, request_path, 64 * 1024 * 1024)) |previous| {
        defer allocator.free(previous);
        if (!std.mem.eql(u8, previous, request_bytes)) return error.TrainingResumeConfigurationMismatch;
        if (!request.@"resume") return error.TrainingJobAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => try artifacts.atomicWrite(allocator, request_path, request_bytes),
        else => return err,
    }
    var dataset_arena = std.heap.ArenaAllocator.init(allocator);
    defer dataset_arena.deinit();
    const pairs = try loadPairs(dataset_arena.allocator(), root, request);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (pairs) |pair| {
        var lengths: [16]u8 = undefined;
        std.mem.writeInt(u64, lengths[0..8], pair.query.len, .little);
        std.mem.writeInt(u64, lengths[8..16], pair.document.len, .little);
        hasher.update(&lengths);
        hasher.update(pair.query);
        hasher.update(pair.document);
        const structure = try std.json.stringifyAlloc(allocator, .{ .query = pair.query_structure, .document = pair.document_structure }, .{});
        defer allocator.free(structure);
        hasher.update(structure);
    }
    var data_digest: [32]u8 = undefined;
    hasher.final(&data_digest);
    const signature = std.fmt.bytesToHex(data_digest, .lower);
    const signature_path = try std.fs.path.join(allocator, &.{ directory, "dataset.sha256" });
    defer allocator.free(signature_path);
    if (std.fs.cwd().readFileAlloc(allocator, signature_path, 64)) |previous| {
        defer allocator.free(previous);
        if (!std.mem.eql(u8, previous, &signature)) return error.TrainingDatasetChanged;
    } else |err| switch (err) {
        error.FileNotFound => try artifacts.atomicWrite(allocator, signature_path, &signature),
        else => return err,
    }
    var random = std.Random.DefaultPrng.init(request.seed);
    random.random().shuffle(protocol.Pair, pairs);
    var initial = if (request.@"resume") artifacts.load(allocator, path, request.model_version) catch |err| switch (err) {
        error.FileNotFound => try initialize(allocator, request),
        else => return err,
    } else try initialize(allocator, request);
    defer initial.deinit();
    if (initial.metadata.hidden != request.hidden or initial.metadata.layers != request.layers or initial.metadata.max_tokens != request.max_tokens or initial.metadata.seed != request.seed or initial.metadata.step > request.steps) return error.TrainingResumeConfigurationMismatch;
    var model = try transformer.Model.init(runtime, initial.metadata, initial.parameters, initial.first_moment, initial.second_moment);
    defer model.deinit();
    var loss = initial.metadata.last_loss;
    var digest = initial.digest;
    const batch_size = @min(pairs.len, request.batch_size);
    const queries = try allocator.alloc(usize, batch_size); defer allocator.free(queries);
    const documents = try allocator.alloc(usize, batch_size); defer allocator.free(documents);
    while (model.metadata.step < request.steps) {
        if (signals.stopping() or timer.read() / std.time.ns_per_ms >= request.deadline_ms) {
            digest = try model.save(allocator, path);
            break;
        }
        try model.clearGradient();
        var graph = transformer.Graph.init(allocator, &model);
        defer graph.deinit();
        const offset = (try std.math.mul(u64, model.metadata.step, batch_size)) % pairs.len;
        for (0..batch_size) |i| {
            const pair = pairs[(@as(usize, @intCast(offset)) + i) % pairs.len];
            queries[i] = try graph.encode(.{ .text = pair.query, .kind = .query, .structure = pair.query_structure });
            documents[i] = try graph.encode(.{ .text = pair.document, .kind = .document, .structure = pair.document_structure });
        }
        loss = try batchLoss(allocator, &graph, queries, documents);
        try graph.backward();
        model.metadata.last_loss = loss;
        const next = model.metadata.step + 1;
        const warmup: f32 = if (request.warmup_steps == 0) 1 else @min(1, @as(f32, @floatFromInt(next)) / @as(f32, @floatFromInt(request.warmup_steps)));
        const progress: f32 = @as(f32, @floatFromInt(next)) / @as(f32, @floatFromInt(request.steps));
        const learning_rate = request.learning_rate * warmup * (0.1 + 0.9 * 0.5 * (1 + @cos(std.math.pi * progress)));
        const gradient_norm = try model.optimize(learning_rate, request.weight_decay, request.gradient_clip);
        if (model.metadata.step % request.checkpoint_interval == 0 or model.metadata.step == request.steps) {
            digest = try model.save(allocator, path);
            const progress_path = try std.fs.path.join(allocator, &.{ directory, "progress.json" });
            defer allocator.free(progress_path);
            const progress_bytes = try std.json.stringifyAlloc(allocator, .{ .step = model.metadata.step, .loss = loss, .gradient_norm = gradient_norm, .learning_rate = learning_rate, .elapsed_ms = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms }, .{});
            defer allocator.free(progress_bytes);
            try artifacts.atomicWrite(allocator, progress_path, progress_bytes);
        }
    }
    const completed = model.metadata.step == request.steps;
    var published = try allocator.dupe(u8, path);
    if (completed) {
        allocator.free(published);
        published = try artifacts.checkpointPath(allocator, root, request.model_version);
        try std.fs.cwd().makePath(std.fs.path.dirname(published).?);
        const exists = if (artifacts.load(allocator, published, request.model_version)) |value| blk: {
            var current = value;
            defer current.deinit();
            if (!std.mem.eql(u8, &current.digest, &digest)) return error.ModelVersionConflict;
            break :blk true;
        } else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (!exists) {
            const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024 * 1024);
            defer allocator.free(bytes);
            try artifacts.atomicWrite(allocator, published, bytes);
        }
    }
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
    return .{ .job_id = request.job_id, .model_version = request.model_version, .step = model.metadata.step, .loss = loss, .checkpoint = published, .sha256 = hex, .completed = completed, .elapsed_ms = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms, .gpu = runtime.name() };
}
