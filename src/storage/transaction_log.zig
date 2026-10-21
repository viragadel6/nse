const std = @import("std");

pub const Transaction = struct {
    id: u64,
    operation: []const u8,
    document_id: u64,
    sequence: u64,
    committed: bool = false,
};

pub const Log = struct {
    transactions: std.ArrayList(Transaction),
    lock: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Log {
        return Log{ .transactions = std.ArrayList(Transaction).init(allocator), .lock = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Log) void {
        for (self.transactions.items) |*transaction| self.allocator.free(transaction.operation);
        self.transactions.deinit();
    }

    pub fn begin(self: *Log, operation: []const u8, document_id: u64, sequence: u64) !u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const id = self.next_id;
        self.next_id += 1;
        _ = try self.transactions.append(Transaction{ .id = id, .operation = try self.allocator.dupe(u8, operation), .document_id = document_id, .sequence = sequence });
        return id;
    }

    pub fn commit(self: *Log, id: u64) bool {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.transactions.items) |*transaction| if (transaction.id == id) { transaction.committed = true; return true; }
        return false;
    }
};
