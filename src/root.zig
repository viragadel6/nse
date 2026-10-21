const std = @import("std");
const configuration = @import("runtime/configuration.zig");
const Engine = @import("runtime/lifecycle.zig").Engine;
const routes = @import("api/routes.zig");
const documents = @import("storage/document.zig");
const codec = @import("api/request_codec.zig");
const inference = @import("models/inference_client.zig");
const protocol = @import("workload");
const artifacts = @import("artifacts");
const modal = @import("orchestration/modal_client.zig");
const cluster = @import("runtime/cluster_launcher.zig");
const worker = @import("runtime/deployment_worker.zig");

fn output(value: anytype) !void {
    try std.json.stringify(value, .{}, std.io.getStdOut().writer());
    try std.io.getStdOut().writer().writeByte('\n');
}

fn commandKnown(value: []const u8) bool {
    inline for (.{ "serve", "ingest", "search", "status", "refresh", "snapshot", "embed", "delete", "crawl", "embed-batch", "train", "train-status", "train-cancel", "checkpoint", "model-register", "cluster", "cluster-validate", "worker" }) |command| if (std.mem.eql(u8, value, command)) return true;
    return false;
}

pub fn run(default_command: []const u8) !void {
    var general = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const args = try std.process.argsAlloc(temporary);
    const explicit_command = args.len > 1 and commandKnown(args[1]);
    const command = if (explicit_command) args[1] else default_command;
    const start: usize = if (explicit_command) 2 else 1;
    var config_path: []const u8 = "settings";
    var positional = std.ArrayList([]const u8).init(temporary);
    {
        var cursor: usize = start;
        while (cursor < args.len) : (cursor += 1) {
            if (std.mem.eql(u8, args[cursor], "--config") and cursor + 1 < args.len) {
                config_path = args[cursor + 1];
                cursor += 1;
                continue;
            }
            try positional.append(args[cursor]);
        }
    }
    const first = if (positional.items.len > 0) positional.items[0] else null;
    const second = if (positional.items.len > 1) positional.items[1] else null;
    const third = if (positional.items.len > 2) positional.items[2] else null;
    if (std.mem.eql(u8, command, "cluster") or std.mem.eql(u8, command, "cluster-validate")) return cluster.run(temporary, first orelse "deploy", std.mem.eql(u8, command, "cluster"));
    if (std.mem.eql(u8, command, "worker")) {
        return worker.run(allocator, try (first orelse error.MissingWorkerArguments), try (second orelse error.MissingWorkerArguments));
    }

    const config = try configuration.load(temporary, config_path);
    if (std.mem.eql(u8, command, "train")) {
        if (positional.items.len < 1) return error.MissingTrainingRequest;
        const bytes = try std.fs.cwd().readFileAlloc(temporary, try (first orelse error.MissingTrainingRequest), 64 * 1024 * 1024);
        var request = try protocol.parse(protocol.TrainingRequest, temporary, bytes);
        const supplied = try protocol.parse(std.json.Value, temporary, bytes);
        try config.training.applyTrainingDefaults(&request.value, supplied.value);
        const submission = try modal.submit(temporary, config.model.workload_endpoint, request.value, config.runtime.connection_timeout_ms);
        const record = try std.json.stringifyAlloc(temporary, .{ .request = request.value, .submission = submission.value }, .{});
        const path = try std.fmt.allocPrint(temporary, "{s}/gpu_jobs/{s}.json", .{ config.runtime.data_dir, request.value.job_id });
        try artifacts.atomicWrite(temporary, path, record);
        return output(submission.value);
    }
    if (std.mem.eql(u8, command, "train-status") or std.mem.eql(u8, command, "train-cancel")) {
        if (positional.items.len < 1) return error.MissingTrainingCall;
        const result = if (std.mem.eql(u8, command, "train-status")) try modal.status(temporary, config.model.workload_endpoint, try (first orelse error.MissingTrainingCall), config.runtime.connection_timeout_ms) else try modal.cancel(temporary, config.model.workload_endpoint, try (first orelse error.MissingTrainingCall), config.runtime.connection_timeout_ms);
        return output(result.value);
    }
    if (std.mem.eql(u8, command, "checkpoint")) {
        if (positional.items.len < 2) return error.MissingCheckpointArguments;
        const version = try std.fmt.parseInt(u64, try (first orelse error.MissingCheckpointArguments), 10);
        return output(try modal.transfer(temporary, config.model.workload_endpoint, version, try (second orelse error.MissingCheckpointArguments), config.runtime.connection_timeout_ms));
    }
    if (std.mem.eql(u8, command, "model-register")) {
        if (positional.items.len < 1) return error.MissingModelVersion;
        const version = try std.fmt.parseInt(u64, try (first orelse error.MissingModelVersion), 10);
        const result = try modal.register(temporary, config.model.workload_endpoint, .{ .model_version = version, .expected_current_version = if (third) |value| try std.fmt.parseInt(u64, value, 10) else null }, config.runtime.connection_timeout_ms);
        return output(result.value);
    }
    if (std.mem.eql(u8, command, "embed-batch")) {
        if (positional.items.len < 1) return error.MissingEmbeddingInput;
        const bytes = try std.fs.cwd().readFileAlloc(temporary, try (first orelse error.MissingEmbeddingInput), config.api.max_request_bytes);
        const items = try protocol.parse([]const protocol.Item, temporary, bytes);
        const result = try inference.batch(temporary, config.model, items.value, config.runtime.connection_timeout_ms);
        return output(result.value);
    }
    if (std.mem.eql(u8, command, "embed")) {
        if (positional.items.len < 1) return error.MissingInputPath;
        const text = try std.fs.cwd().readFileAlloc(temporary, try (first orelse error.MissingInputPath), config.api.max_request_bytes);
        const embedding = try inference.embed(temporary, config.model, text, .document, config.runtime.connection_timeout_ms);
        try output(.{ .embedding = embedding, .model_version = config.model.model_version, .dimensions = config.model.primary_dim });
        return;
    }
    var engine = try Engine.open(allocator, config);
    defer engine.close();
    if (std.mem.eql(u8, command, "serve")) return routes.serve(allocator, &engine, config);
    if (std.mem.eql(u8, command, "status")) return output(engine.status());
    if (std.mem.eql(u8, command, "refresh")) return output(try engine.refresh(false));
    if (std.mem.eql(u8, command, "snapshot")) return output(try engine.refresh(true));
    if (std.mem.eql(u8, command, "delete")) {
        if (positional.items.len < 1) return error.MissingDocumentIdentifier;
        const id = try std.fmt.parseInt(u64, try (first orelse error.MissingDocumentIdentifier), 10);
        return output(.{ .deleted = try engine.delete(id), .index = engine.status() });
    }
    if (positional.items.len < 1) return error.MissingInputPath;
    if (std.mem.eql(u8, command, "crawl")) return output(try routes.crawl(temporary, &engine, try (first orelse error.MissingInputPath)));
    if (std.mem.eql(u8, command, "search")) {
        const bytes = try std.fs.cwd().readFileAlloc(temporary, try (first orelse error.MissingInputPath), config.api.max_request_bytes);
        const parsed = try codec.parse(codec.Search, temporary, bytes);
        defer parsed.deinit();
        return output(try engine.search(temporary, parsed.value));
    }
    if (std.mem.eql(u8, command, "ingest")) {
        const file = try std.fs.cwd().openFile(try (first orelse error.MissingInputPath), .{});
        defer file.close();
        var buffered = std.io.bufferedReader(file.reader());
        const reader = buffered.reader();
        while (true) {
            var record_arena = std.heap.ArenaAllocator.init(allocator);
            defer record_arena.deinit();
            const record_allocator = record_arena.allocator();
            const line = try reader.readUntilDelimiterOrEofAlloc(record_allocator, '\n', config.api.max_request_bytes) orelse break;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;
            const parsed = try codec.parse(documents.Input, record_allocator, trimmed);
            defer parsed.deinit();
            try output(try engine.ingest(record_allocator, parsed.value));
        }
        return;
    }
    return error.UnknownCommand;
}

export fn execute(command: [*:0]const u8) u8 {
    run(std.mem.span(command)) catch |err| {
        std.json.stringify(.{ .@"error" = .{ .code = @errorName(err) } }, .{}, std.io.getStdErr().writer()) catch return 1;
        std.io.getStdErr().writer().writeByte('\n') catch return 1;
        return 1;
    };
    return 0;
}
