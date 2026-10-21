const std = @import("std");
const json = std.json;
const time = @import("../util/time.zig");
const runtime = @import("browser_runtime.zig");

pub const ExecutorError = error{
    NavigationFailed,
    Timeout,
    EvaluationFailed,
    SelectorNotFound,
    ContentUnavailable,
    SessionClosed,
};

pub const WaitUntil = enum(u8) {
    dom_content_loaded,
    load,
    network_idle,
    network_almost_idle,
};

pub const RenderOptions = struct {
    timeout_ms: u64 = 30000,
    wait_until: WaitUntil = .network_almost_idle,
    wait_for_selector: []const u8 = "",
    scroll_passes: u32 = 0,
    settle_ms: u64 = 250,
    user_agent: []const u8 = "",
    blocked_url_patterns: []const []const u8 = &.{},
    script: []const u8 = "",
    capture_text: bool = true,
};

pub const RenderedPage = struct {
    requested_url: []const u8,
    final_url: []const u8,
    html: []const u8,
    title: []const u8,
    text: []const u8,
    elapsed_ms: f64,
    network_requests: u32,
    finished_requests: u32,
    console_messages: u32,
    scrolled_passes: u32,
    allocator: std.mem.Allocator,

    pub fn release(self: *RenderedPage) void {
        self.allocator.free(self.requested_url);
        self.allocator.free(self.final_url);
        self.allocator.free(self.html);
        self.allocator.free(self.title);
        self.allocator.free(self.text);
    }
};

pub const Page = struct {
    allocator: std.mem.Allocator,
    session: *runtime.Session,
    requests: u32 = 0,
    finished: u32 = 0,
    console_messages: u32 = 0,
    ready: bool = false,

    pub fn init(allocator: std.mem.Allocator, session: *runtime.Session) Page {
        return .{ .allocator = allocator, .session = session };
    }

    pub fn enable(self: *Page, options: RenderOptions) !void {
        var response = try self.session.command("Page.enable", "{}");
        if (response.failed()) return ExecutorError.SessionClosed;
        response = try self.session.command("Runtime.enable", "{}");
        if (response.failed()) return ExecutorError.SessionClosed;
        response = try self.session.command("Page.setLifecycleEventsEnabled", "{\"enabled\":true}");
        if (response.failed()) return ExecutorError.SessionClosed;
        if (options.user_agent.len > 0) {
            const params = try std.fmt.allocPrint(self.allocator, "{{\"userAgent\":\"{s}\"}}", .{options.user_agent});
            defer self.allocator.free(params);
            response = try self.session.command("Emulation.setUserAgentOverride", params);
            if (response.failed()) return ExecutorError.SessionClosed;
        }
        if (options.blocked_url_patterns.len > 0) {
            var list = std.ArrayList(u8).init(self.allocator);
            defer list.deinit();
            try list.appendSlice("{\"urls\":[");
            for (options.blocked_url_patterns, 0..) |pattern, index| {
                if (index > 0) try list.append(',');
                try list.writer().print("\"{s}\"", .{pattern});
            }
            try list.appendSlice("]}");
            response = try self.session.command("Network.setBlockedURLs", list.items);
            if (response.failed()) return ExecutorError.SessionClosed;
        }
        self.ready = true;
    }

    pub fn navigate(self: *Page, url: []const u8) !void {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"url\":\"{s}\"}}", .{url});
        defer self.allocator.free(params);
        const response = try self.session.command("Page.navigate", params);
        if (response.failed()) return ExecutorError.NavigationFailed;
    }

    pub fn waitForLoad(self: *Page, options: RenderOptions) !void {
        const lifecycle = switch (options.wait_until) {
            .dom_content_loaded => "DOMContentLoaded",
            .load => "load",
            .network_idle, .network_almost_idle => "networkIdle",
        };
        var deadline = time.Deadline.fromTimeout(options.timeout_ms);
        while (!deadline.isExpired()) {
            try self.session.drainEvents(50);
            for (self.session.events.items) |event| {
                if (std.mem.eql(u8, event.method, "Page.lifecycleEvent")) {
                    const name = if (event.params.object.get("name")) |field| switch (field) {
                        .string => field.string,
                        else => "",
                    } else "";
                    if (std.mem.eql(u8, name, lifecycle)) return;
                }
            }
            if (options.wait_until == .dom_content_loaded or options.wait_until == .load) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
        return ExecutorError.Timeout;
    }

    pub fn waitForSelector(self: *Page, selector: []const u8, timeout_ms: u64) !void {
        const expression = try std.fmt.allocPrint(
            self.allocator,
            "new Promise(function(resolve){{var started=Date.now();(function poll(){{var node=document.querySelector({s});if(node){{resolve(true);return;}}if(Date.now()-started>{d}){{resolve(false);return;}}setTimeout(poll,50);}})();}})",
            .{ try jsonString(self.allocator, selector), timeout_ms },
        );
        defer self.allocator.free(expression);
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"expression\":{s},\"awaitPromise\":true,\"returnByValue\":true}}",
            .{try jsonString(self.allocator, expression)},
        );
        defer self.allocator.free(params);
        const response = try self.session.command("Runtime.evaluate", params);
        if (response.failed()) return ExecutorError.EvaluationFailed;
        const found = response.result.?.object.get("result").?.object.get("value").?.bool;
        if (!found) return ExecutorError.SelectorNotFound;
    }

    pub fn evaluateValue(self: *Page, expression: []const u8) !json.Value {
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"expression\":{s},\"returnByValue\":true,\"awaitPromise\":true}}",
            .{try jsonString(self.allocator, expression)},
        );
        defer self.allocator.free(params);
        const response = try self.session.command("Runtime.evaluate", params);
        if (response.failed()) return ExecutorError.EvaluationFailed;
        return response.result.?.object.get("result").?.object.get("value").?;
    }

    pub fn evaluateString(self: *Page, expression: []const u8) ![]const u8 {
        const value = try self.evaluateValue(expression);
        return switch (value) {
            .string => try self.allocator.dupe(u8, value.string),
            .null => try self.allocator.dupe(u8, ""),
            else => try jsonParseString(self.allocator, value),
        };
    }

    pub fn scroll(self: *Page, passes: u32, settle_ms: u64) !u32 {
        var performed: u32 = 0;
        while (performed < passes) : (performed += 1) {
            _ = try self.evaluateString("(function(){window.scrollBy(0, window.innerHeight * 0.9); return window.scrollY;})()");
            std.Thread.sleep(settle_ms * std.time.ns_per_ms);
        }
        return performed;
    }

    pub fn outerHtml(self: *Page) ![]const u8 {
        const document = try self.session.command("DOM.getDocument", "{\"depth\":-1,\"pierce\":true}");
        if (document.failed()) return ExecutorError.ContentUnavailable;
        const node_id = document.result.?.object.get("root").?.object.get("nodeId").?.integer;
        const params = try std.fmt.allocPrint(self.allocator, "{{\"nodeId\":{d}}}", .{node_id});
        defer self.allocator.free(params);
        const response = try self.session.command("DOM.getOuterHTML", params);
        if (response.failed()) return ExecutorError.ContentUnavailable;
        const html = response.result.?.object.get("outerHTML").?.string;
        return try self.allocator.dupe(u8, html);
    }

    pub fn finalUrl(self: *Page) ![]const u8 {
        return self.evaluateString("window.location.href");
    }

    pub fn title(self: *Page) ![]const u8 {
        return self.evaluateString("document.title");
    }

    pub fn bodyText(self: *Page) ![]const u8 {
        return self.evaluateString("document.body ? document.body.innerText : \"\"");
    }

    pub fn click(self: *Page, selector: []const u8) !void {
        const expression = try std.fmt.allocPrint(
            self.allocator,
            "(function(){{var node=document.querySelector({s});if(!node){{return false;}}node.click();return true;}})()",
            .{try jsonString(self.allocator, selector)},
        );
        defer self.allocator.free(expression);
        const value = try self.evaluateValue(expression);
        if (value != .bool or !value.bool) return ExecutorError.SelectorNotFound;
    }

    pub fn dispatchKey(self: *Page, key: []const u8, code: []const u8) !void {
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d}}}",
            .{ key, code, @as(u32, if (key.len == 1) key[0] else 13) },
        );
        defer self.allocator.free(params);
        const response = try self.session.command("Input.dispatchKeyEvent", params);
        if (response.failed()) return ExecutorError.EvaluationFailed;
    }

    pub fn countEvents(self: *Page) void {
        for (self.session.events.items) |event| {
            if (std.mem.eql(u8, event.method, "Network.requestWillBeSent")) self.requests += 1;
            if (std.mem.eql(u8, event.method, "Network.loadingFinished")) self.finished += 1;
            if (std.mem.eql(u8, event.method, "Runtime.consoleAPICalled")) self.console_messages += 1;
        }
    }

    pub fn isReady(self: *const Page) bool {
        return self.ready;
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    browser: *runtime.Browser,
    options: RenderOptions,
    renders: u64 = 0,
    failures: u64 = 0,
    total_ms: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, browser: *runtime.Browser, options: RenderOptions) Renderer {
        return .{ .allocator = allocator, .browser = browser, .options = options };
    }

    pub fn render(self: *Renderer, url: []const u8) !RenderedPage {
        const started = time.StopWatch.start();
        var target = try self.browser.newTarget("about:blank");
        defer target.release(self.allocator);
        var session = try runtime.Session.connect(self.allocator, target.web_socket_debugger_url, target.id, self.options.timeout_ms);
        defer session.deinit();
        var page = Page.init(self.allocator, &session);
        try page.enable(self.options);
        try page.navigate(url);
        try page.waitForLoad(self.options);
        if (self.options.wait_for_selector.len > 0) {
            page.waitForSelector(self.options.wait_for_selector, self.options.timeout_ms) catch |err| {
                self.failures += 1;
                return err;
            };
        }
        const scrolled = try page.scroll(self.options.scroll_passes, self.options.settle_ms);
        if (self.options.script.len > 0) {
            _ = page.evaluateString(self.options.script) catch "";
        }
        const html = try page.outerHtml();
        const final_url = try page.finalUrl();
        const title = try page.title();
        const text = if (self.options.capture_text) try page.bodyText() else try self.allocator.dupe(u8, "");
        page.countEvents();
        std.Thread.sleep(self.options.settle_ms * std.time.ns_per_ms);
        const elapsed = started.elapsedMs();
        self.renders += 1;
        self.total_ms += elapsed;
        _ = self.browser.closeTarget(target.id) catch {};
        return .{
            .requested_url = try self.allocator.dupe(u8, url),
            .final_url = final_url,
            .html = html,
            .title = title,
            .text = text,
            .elapsed_ms = elapsed,
            .network_requests = page.requests,
            .finished_requests = page.finished,
            .console_messages = page.console_messages,
            .scrolled_passes = scrolled,
            .allocator = self.allocator,
        };
    }

    pub fn averageLatencyMs(self: *const Renderer) f64 {
        if (self.renders == 0) return 0.0;
        return self.total_ms / @as(f64, @floatFromInt(self.renders));
    }
};

fn jsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    try out.append('"');
    for (input) |byte| {
        switch (byte) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(byte),
        }
    }
    try out.append('"');
    return out.toOwnedSlice();
}

fn jsonParseString(allocator: std.mem.Allocator, value: json.Value) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    try json.stringify(value, .{}, out.writer());
    return out.toOwnedSlice();
}
