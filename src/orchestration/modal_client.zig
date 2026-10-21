const std = @import("std");
const protocol = @import("workload");
const artifacts = @import("artifacts");
const http = @import("../network/http_client.zig");
pub const Submission = struct { protocol_version: u16, call_id: []const u8, state: enum { submitted } };
pub const Status = struct { protocol_version: u16, call_id: []const u8, state: enum { submitted, running, completed, interrupted, cancelled }, result: ?protocol.TrainingResponse = null };

pub fn endpoint(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (base.len == 0) return error.ModalDeploymentNotConfigured;
    const uri = try std.Uri.parse(base);
    if (uri.host == null or (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http"))) return error.InvalidModalEndpoint;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimRight(u8, base, "/"), path });
}

pub const ModalError = error{
    UnsupportedModalMethod,
};

fn checkedResponse(allocator: std.mem.Allocator, response: http.Response) !void {
    if (response.status == 200 or response.status == 202) return;
    const Failure = struct { @"error": struct { code: []const u8, message: ?[]const u8 = null, retryable: bool = false } };
    const parsed = protocol.parse(Failure, allocator, response.body) catch return error.InvalidModalErrorResponse;
    defer parsed.deinit();
    try std.io.getStdErr().writer().print("Modal {d}: {s}\n", .{ response.status, parsed.value.@"error".code });
    if (parsed.value.@"error".retryable) return error.ModalWorkerUnavailable;
    return error.ModalWorkloadFailed;
}

pub fn call(comptime T: type, allocator: std.mem.Allocator, base: []const u8, method: std.http.Method, path: []const u8, payload: anytype, timeout_ms: u32) !std.json.Parsed(T) {
    const url = try endpoint(allocator, base, path); defer allocator.free(url);
    const bytes = if (method == .POST) try std.json.stringifyAlloc(allocator, payload, .{}) else null;
    defer if (bytes) |value| allocator.free(value);
    var client = http.Client.init(allocator, .{
        .connect_timeout_ms = timeout_ms,
        .read_timeout_ms = timeout_ms,
        .write_timeout_ms = timeout_ms,
        .max_response_bytes = 64 * 1024 * 1024,
    });
    defer client.deinit();
    var response = switch (method) {
        .GET => try client.get(url),
        .POST => try client.post(url, &.{ .{ .name = "content-type", .value = "application/json" } }, bytes orelse ""),
        .DELETE => try client.delete(url, &.{}, ""),
        else => return ModalError.UnsupportedModalMethod,
    };
    defer response.deinit();
    try checkedResponse(allocator, response);
    return protocol.parse(T, allocator, response.body);
}

pub fn submit(allocator: std.mem.Allocator, base: []const u8, request: protocol.TrainingRequest, timeout_ms: u32) !std.json.Parsed(Submission) {
    try protocol.validateTraining(request);
    const result = try call(Submission, allocator, base, .POST, "/training", request, timeout_ms);
    errdefer result.deinit();
    if (result.value.protocol_version != protocol.version or result.value.call_id.len == 0) return error.InvalidModalResponse;
    return result;
}

pub fn status(allocator: std.mem.Allocator, base: []const u8, call_id: []const u8, timeout_ms: u32) !std.json.Parsed(Status) {
    if (!protocol.validIdentifier(call_id)) return error.InvalidCallIdentifier;
    const path = try std.fmt.allocPrint(allocator, "/training/{s}", .{call_id}); defer allocator.free(path);
    const result = try call(Status, allocator, base, .GET, path, .{}, timeout_ms);
    errdefer result.deinit();
    if (result.value.protocol_version != protocol.version or !std.mem.eql(u8, result.value.call_id, call_id)) return error.InvalidModalResponse;
    if (result.value.state == .completed and (result.value.result == null or !result.value.result.?.completed)) return error.InvalidTrainingResult;
    return result;
}

pub fn cancel(allocator: std.mem.Allocator, base: []const u8, call_id: []const u8, timeout_ms: u32) !std.json.Parsed(Status) {
    if (!protocol.validIdentifier(call_id)) return error.InvalidCallIdentifier;
    const path = try std.fmt.allocPrint(allocator, "/training/{s}", .{call_id}); defer allocator.free(path);
    return call(Status, allocator, base, .DELETE, path, .{}, timeout_ms);
}

pub fn transfer(allocator: std.mem.Allocator, base: []const u8, model_version: u64, destination: []const u8, timeout_ms: u32) !artifacts.Metadata {
    const path = try std.fmt.allocPrint(allocator, "/artifacts/{d}", .{model_version}); defer allocator.free(path);
    const url = try endpoint(allocator, base, path); defer allocator.free(url);
    var client = http.Client.init(allocator, .{
        .connect_timeout_ms = timeout_ms,
        .read_timeout_ms = timeout_ms,
        .write_timeout_ms = timeout_ms,
        .max_response_bytes = 2147483648,
    });
    defer client.deinit();
    var response = try client.get(url);
    defer response.deinit();
    try checkedResponse(allocator, response);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.download-{s}", .{ destination, try protocol.requestId(allocator) }); defer allocator.free(temporary);
    defer std.fs.cwd().deleteFile(temporary) catch {};
    try artifacts.atomicWrite(allocator, temporary, response.body);
    var checkpoint = try artifacts.load(allocator, temporary, model_version); defer checkpoint.deinit();
    try std.fs.cwd().rename(temporary, destination);
    var directory = try std.fs.cwd().openDir(std.fs.path.dirname(destination) orelse ".", .{ .iterate = true }); defer directory.close();
    return checkpoint.metadata;
}

pub fn register(allocator: std.mem.Allocator, base: []const u8, request: protocol.RegistryRequest, timeout_ms: u32) !std.json.Parsed(artifacts.Record) {
    return call(artifacts.Record, allocator, base, .POST, "/models/refresh", request, timeout_ms);
}
