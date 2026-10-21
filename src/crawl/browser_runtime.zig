const std = @import("std");

pub const RenderConfig = struct {
    deadline_ms: u32 = 15000,
    max_pages: u32 = 5,
    max_bytes: usize = 16 * 1024 * 1024,
    headless: bool = true,
    disable_images: bool = true,
    disable_css: bool = true,
    disable_javascript: bool = false,
};

pub const BrowserProcess = struct {
    pid: u64 = 0,
    allocated: bool = false,
};

pub const Runtime = struct {
    config: RenderConfig,
    active: std.Thread.Mutex,
    running: []BrowserProcess,

    pub fn init(config: RenderConfig) Runtime {
        return Runtime{ .config = config, .active = .{}, .running = &[_]BrowserProcess{} };
    }

    pub fn render(self: *Runtime, url: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = self.config;
        _ = allocator;
        _ = url;
        return error.UnsupportedOperation;
    }

    pub fn deinit(self: *Runtime) void {
    }
};
