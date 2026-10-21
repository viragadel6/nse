const std = @import("std");

pub const Posting = struct {
    document_id: u64,
    term_frequency: u32,
    positions: []u32,
};

pub const PostingList = struct {
    term: []const u8,
    document_frequency: u32,
    postings: []Posting,
};

pub const Index = struct {
    lists: std.StringHashMap(PostingList),
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Index {
        return Index{ .lists = std.StringHashMap(PostingList).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        for (self.lists.iterator()) |*entry| {
            self.allocator.free(entry.value_ptr().*.term);
            self.allocator.free(entry.value_ptr().*.postings);
        }
        self.lists.deinit();
    }

    pub fn add(self: *Index, term: []const u8, document_id: u64, term_frequency: u32, positions: []u32) !void {
        self.lock.lock();
        defer self.lock.unlock();
        var list = self.lists.getOrPut(try self.allocator.dupe(u8, term), .{ .term = "", .document_frequency = 0, .postings = &[_]Posting{} }) catch |err| return err;
        list.value_ptr().*.document_frequency += 1;
        var postings = try self.allocator.alloc(Posting, list.value_ptr().*.postings.len + 1);
        var i: usize = 0;
        while (i < list.value_ptr().*.postings.len) {
            postings[i] = list.value_ptr().*.postings[i];
            i += 1;
        }
        postings[list.value_ptr().*.postings.len] = Posting{ .document_id = document_id, .term_frequency = term_frequency, .positions = positions };
        self.allocator.free(list.value_ptr().*.postings);
        list.value_ptr().*.postings = postings;
        if (list.value_ptr().*.term.len == 0) list.value_ptr().*.term = term;
    }

    pub fn lookup(self: *Index, term: []const u8) ?*PostingList {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.lists.get(term);
    }
};
