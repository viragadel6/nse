const std = @import("std");
const root = @import("runtime");

pub fn main() u8 {
    root.run("serve") catch |err| {
        std.json.stringify(.{ .@"error" = .{ .code = @errorName(err) } }, .{}, std.io.getStdErr().writer()) catch return 1;
        std.io.getStdErr().writer().writeByte('\n') catch return 1;
        return 1;
    };
    return 0;
}
