const std = @import("std");

var stopped = std.atomic.Value(bool).init(false);

fn handler(_: c_int) callconv(.c) void {
    stopped.store(true, .release);
}

pub fn install() void {
    stopped.store(false, .release);
    const action = std.posix.Sigaction{ .handler = .{ .handler = handler }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    const ignored = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignored, null);
}

pub fn stopping() bool {
    return stopped.load(.acquire);
}
