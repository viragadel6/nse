const std = @import("std");

pub const WorkloadClass = enum { interactive, research, background };

pub const Coordinator = struct {
    interactive_capacity: u32 = 4096,
    research_capacity: u32 = 1024,
    interactive_queued: usize = 0,
    research_queued: usize = 0,
    lock: std.Thread.Mutex,

    pub fn init() Coordinator {
        return Coordinator{ .lock = .{} };
    }

    pub fn admit(self: *Coordinator, class: WorkloadClass) bool {
        self.lock.lock();
        defer self.lock.unlock();
        switch (class) {
            .interactive => {
                if (self.interactive_queued >= @intCast(self.interactive_capacity)) return false;
                self.interactive_queued += 1;
                return true;
            }
            .research => {
                if (self.research_queued >= @intCast(self.research_capacity)) return false;
                self.research_queued += 1;
                return true;
            }
            .background => return true,
        }
    }

    pub fn release(self: *Coordinator, class: WorkloadClass) void {
        self.lock.lock();
        defer self.lock.unlock();
        switch (class) {
            .interactive => if (self.interactive_queued > 0) self.interactive_queued -= 1,
            .research => if (self.research_queued > 0) self.research_queued -= 1,
            .background => {},
        }
    }
};
