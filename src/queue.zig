/// Bounded blocking ring queue for inter-thread communication.
///
/// The queue supports one or more producers and one consumer. `push()` blocks
/// when the queue is full. `pop()` blocks when it is empty.
/// `waitForDepth()` blocks until the requested number of items is queued.
///
/// `close()` wakes all waiters. After close, `push()` returns `error.Closed`.
/// `pop()` drains existing items, then returns `error.Closed`.
/// Blocking queue operations can also return `error.Canceled` when the Io
/// context is canceled. The Writer and Reader use this queue for pipeline data.
const std = @import("std");

/// Single-slot rendezvous for zero-copy block handoff between two threads.
///
/// The producer deposits a block pointer and length, signals the consumer, and
/// waits for an acknowledgement. The block data is not copied. The producer
/// remains inside the C callback, so the encoder buffer stays valid.
///
/// The consumer waits for a block, sends it over SCTP, and calls `ack()`.
///
/// One condition variable handles readiness and acknowledgement. Both threads
/// recheck `has_block`, `consumer_active`, and `done` after every wakeup.
pub const BlockHandoff = struct {
    /// Protects handoff state.
    mutex: std.Io.Mutex = .init,
    /// Wakes producers and consumers.
    cond: std.Io.Condition = .init,
    /// Io context for synchronization.
    io: std.Io,

    /// Pointer to the current encoder-owned block.
    block_ptr: [*]const u8,
    /// Length of the current block.
    block_len: usize = 0,
    /// Result reported by the consumer.
    send_ok: bool = false,
    /// True while a block awaits acknowledgement.
    has_block: bool = false,
    /// True after consume() returns a block and before ack() is called.
    consumer_active: bool = false,
    /// True after shutdown begins.
    done: bool = false,

    /// Initialize an empty handoff.
    pub fn init(io: std.Io) BlockHandoff {
        // SAFETY: consume() reads block_ptr only after produce() sets has_block.
        return .{ .io = io, .block_ptr = undefined };
    }

    /// Publish a block and wait for the consumer acknowledgement.
    /// Return true when the consumer reports success. Return false after an
    /// error or shutdown. This method uses uncancelable waits because the C
    /// callback cannot propagate a Zig error. Keep `data` valid until return.
    pub fn produce(self: *BlockHandoff, data: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.done) return false;

        self.block_ptr = data.ptr;
        self.block_len = data.len;
        self.consumer_active = false;
        self.has_block = true;
        self.cond.signal(self.io);

        while (self.has_block) {
            // A shutdown may abandon a block that no consumer has taken, but
            // it must not release the producer while a consumer owns it.
            if (self.done and !self.consumer_active) {
                self.has_block = false;
                break;
            }
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        if (self.done) return false;
        return self.send_ok;
    }

    /// Wait for and return the current block.
    /// Return null after `signalDone()` when no block remains.
    /// The returned slice remains valid until `ack()` is called.
    pub fn consume(self: *BlockHandoff) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.has_block and !self.done) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        if (self.done) return null;

        self.consumer_active = true;
        return self.block_ptr[0..self.block_len];
    }

    /// Report whether the current block was sent successfully.
    /// Wake the producer blocked in `produce()`.
    /// Call once for each slice returned by `consume()`.
    pub fn ack(self: *BlockHandoff, ok: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.send_ok = ok;
        self.consumer_active = false;
        self.has_block = false;
        self.cond.signal(self.io);
    }

    /// Signal that no more blocks will be produced.
    /// Wake any producer or consumer waiting on the handoff.
    pub fn signalDone(self: *BlockHandoff) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.done = true;
        self.cond.broadcast(self.io);
    }

    /// Return true after `signalDone()` has been called.
    pub fn isDone(self: *BlockHandoff) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.done;
    }
};
/// Create a bounded blocking ring queue for values of type `T`.
pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Errors returned by `push()`.
        pub const PushError = error{ Closed, Canceled };
        /// Errors returned by `pop()`.
        pub const PopError = error{ Closed, Canceled };

        /// Ring storage.
        buf: []T = &.{},
        /// Maximum number of queued values. Zero means not initialized.
        capacity: usize = 0,
        head: usize = 0, // Next pop slot.
        tail: usize = 0, // Next push slot.
        count: usize = 0, // Number of queued items.
        /// True after close() begins shutdown.
        closed: bool = false,
        /// Io context used by the queue.
        io: std.Io = std.Io.failing,
        /// Allocator for ring storage.
        allocator: std.mem.Allocator = std.heap.c_allocator,
        /// Protects ring state.
        mutex: std.Io.Mutex = .init,
        not_empty: std.Io.Condition = .init, // Wakes pop and waitForDepth.
        not_full: std.Io.Condition = .init, // Wakes push.

        /// Construct an empty queue with capacity at least 1.
        /// The Io context and allocator must outlive the queue.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            const buf = try allocator.alloc(T, capacity);
            return .{
                .buf = buf,
                .capacity = capacity,
                .io = io,
                .allocator = allocator,
            };
        }

        /// Free the ring buffer.
        pub fn deinit(self: *Self) void {
            if (self.capacity == 0) return;
            self.allocator.free(self.buf);
            self.buf = &.{};
            self.capacity = 0;
            self.head = 0;
            self.tail = 0;
            self.count = 0;
            self.closed = true;
        }

        /// Reset the queue without freeing its ring buffer.
        /// Call this only after all users and waiters have stopped.
        pub fn reset(self: *Self) void {
            if (self.capacity == 0) return;
            self.head = 0;
            self.tail = 0;
            self.count = 0;
            self.closed = false;
        }

        /// Push an item into the queue.
        /// Block while the queue is full.
        pub fn push(self: *Self, item: T) PushError!void {
            if (self.capacity == 0) return error.Closed;
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            while (self.count == self.capacity) {
                if (self.closed) return error.Closed;
                try self.not_full.wait(self.io, &self.mutex);
            }
            if (self.closed) return error.Closed;

            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.not_empty.signal(self.io);
        }

        /// Pop the oldest item from the queue.
        /// Block while the queue is empty.
        pub fn pop(self: *Self) PopError!T {
            if (self.capacity == 0) return error.Closed;
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            while (self.count == 0) {
                if (self.closed) return error.Closed;
                try self.not_empty.wait(self.io, &self.mutex);
            }

            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            self.not_full.signal(self.io);
            return item;
        }

        /// Block until at least `depth` items are queued or the queue closes.
        /// A normal return after close does not prove that the depth was met.
        pub fn waitForDepth(self: *Self, depth: usize) error{Canceled}!void {
            if (self.capacity == 0) return;
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.count < depth and !self.closed) {
                try self.not_empty.wait(self.io, &self.mutex);
            }
        }

        /// Close the queue and wake all waiters.
        /// `pop()` continues to drain queued items before returning
        /// `error.Closed`.
        pub fn close(self: *Self) void {
            // Use an uncancelable lock for the shutdown path.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.not_empty.broadcast(self.io);
            self.not_full.broadcast(self.io);
        }
    };
}

// Queue tests.
test "push/pop FIFO ordering" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    try q.push(10);
    try q.push(20);
    try q.push(30);
    try std.testing.expectEqual(10, try q.pop());
    try std.testing.expectEqual(20, try q.pop());
    try std.testing.expectEqual(30, try q.pop());
}

test "fill to capacity then drain" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    for (0..4) |i| try q.push(@intCast(i));
    for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), try q.pop());
    q.close();
    try std.testing.expectError(error.Closed, q.pop());
}

test "ring buffer wrapping" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    // Fill and drain to move the ring indexes to the buffer end.
    for (0..4) |i| try q.push(@intCast(i));
    for (0..4) |_| _ = try q.pop();
    // Verify wraparound at the start of the internal array.
    for (100..103) |i| try q.push(@intCast(i));
    for (100..103) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), try q.pop());
}

test "close makes push return error.Closed" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    q.close();
    try std.testing.expectError(error.Closed, q.push(1));
}

test "zero capacity is rejected" {
    try std.testing.expectError(
        error.InvalidCapacity,
        BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 0),
    );
}

test "close lets pop drain then return error.Closed" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    try q.push(7);
    try q.push(8);
    q.close();
    try std.testing.expectEqual(7, try q.pop());
    try std.testing.expectEqual(8, try q.pop());
    try std.testing.expectError(error.Closed, q.pop());
}

test "close unblocks blocked pop" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    var result: ?u32 = undefined;
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *BoundedQueue(u32), out: *?u32) void {
            // The empty queue blocks this pop. close() wakes it.
            out.* = queue.pop() catch null;
        }
    }.run, .{ &q, &result });
    q.close();
    t.join();
    try std.testing.expectEqual(result, null);
}

test "close unblocks blocked push" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 1);
    defer q.deinit();
    try q.push(1); // Fill the queue.
    var result: bool = undefined;
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *BoundedQueue(u32), out: *bool) void {
            // The full queue blocks this push. close() wakes it.
            queue.push(99) catch {
                out.* = false;
                return;
            };
            out.* = true;
        }
    }.run, .{ &q, &result });
    q.close();
    t.join();
    try std.testing.expect(!result);
}

test "waitForDepth blocks until threshold met" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 8);
    defer q.deinit();
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *BoundedQueue(u32)) void {
            queue.waitForDepth(3) catch {};
        }
    }.run, .{&q});
    for (0..3) |i| try q.push(@intCast(i));
    t.join(); // The join would hang if the wait did not unblock.
}

test "waitForDepth returns immediately if already at depth" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 8);
    defer q.deinit();
    for (0..5) |i| try q.push(@intCast(i));
    try q.waitForDepth(3); // The requested depth is already present.
}

test "waitForDepth unblocks on close" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 8);
    defer q.deinit();
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *BoundedQueue(u32)) void {
            queue.waitForDepth(10) catch {};
        }
    }.run, .{&q});
    q.close();
    t.join(); // The join would hang if close did not wake the waiter.
}

test "multiple producers" {
    // Two producers push distinct ranges. The main thread drains the queue
    // after both producers finish. Capacity exceeds the total item count.
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 256);
    defer q.deinit();

    const Producer = struct {
        fn run(queue: *BoundedQueue(u32), start: u32, count: u32) void {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                queue.push(start + i) catch return;
            }
        }
    };

    const p1 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 0, 50 });
    const p2 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 1000, 50 });
    p1.join();
    p2.join();
    q.close();

    // Drain all items and verify both producer ranges.
    var seen_p1: u32 = 0;
    var seen_p2: u32 = 0;
    while (q.pop() catch null) |v| {
        if (v < 1000) seen_p1 += 1 else seen_p2 += 1;
    }
    try std.testing.expectEqual(seen_p1, 50);
    try std.testing.expectEqual(seen_p2, 50);
}

test "close during waitForDepth" {
    // The waiter requests five items, but only two are queued.
    // close() must wake it.
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 16);
    defer q.deinit();
    // Seed the queue below the requested depth.
    try q.push(1);
    try q.push(2);

    var woken: bool = false;
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *BoundedQueue(u32), out: *bool) void {
            queue.waitForDepth(5) catch {};
            out.* = true;
        }
    }.run, .{ &q, &woken });
    q.close();
    t.join();
    try std.testing.expect(woken);
}

test "reset clears state without freeing buffer" {
    var q = try BoundedQueue(u32).init(std.testing.allocator, std.testing.io, 4);
    defer q.deinit();
    try q.push(1);
    try q.push(2);
    q.close();
    // close() still permits draining queued items.
    try std.testing.expectEqual(1, try q.pop());
    try std.testing.expectEqual(2, try q.pop());
    try std.testing.expectError(error.Closed, q.pop());
    // Reset reopens the queue with the same capacity.
    q.reset();
    try q.push(10);
    try std.testing.expectEqual(10, try q.pop());
}

// BlockHandoff tests.
const TestData = struct {
    fn runConsumer(h: *BlockHandoff, sent_ok: *bool, done: *bool) void {
        while (true) {
            const data = h.consume() orelse {
                done.* = true;
                return;
            };
            // Simulate a successful send.
            sent_ok.* = true;
            h.ack(true);
            _ = data;
        }
    }
};

test "BlockHandoff basic produce/consume" {
    var h = BlockHandoff.init(std.testing.io);
    const payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };

    var sent_ok: bool = false;
    var consumer_done: bool = false;
    const consumer = try std.Thread.spawn(.{}, TestData.runConsumer, .{ &h, &sent_ok, &consumer_done });
    const ok = h.produce(&payload);
    try std.testing.expect(ok);
    try std.testing.expect(sent_ok);

    h.signalDone();
    consumer.join();
    try std.testing.expect(consumer_done);
}

test "BlockHandoff produce with ack(false) propagates error" {
    var h = BlockHandoff.init(std.testing.io);
    var payload: [3]u8 = .{ 'a', 'b', 'c' };

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(handoff: *BlockHandoff) void {
            const data = handoff.consume().?;
            _ = data;
            handoff.ack(false);
        }
    }.run, .{&h});
    const ok = h.produce(&payload);
    try std.testing.expect(!ok);

    h.signalDone();
    consumer.join();
}

test "BlockHandoff keeps an active consumer alive during shutdown" {
    var h = BlockHandoff.init(std.testing.io);
    var payload = [_]u8{'x'};
    var consumed: std.Io.Semaphore = .{};
    var release: std.Io.Semaphore = .{};
    var producer_returned: bool = false;

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(handoff: *BlockHandoff, consumed_signal: *std.Io.Semaphore, release_signal: *std.Io.Semaphore) void {
            _ = handoff.consume().?;
            consumed_signal.post(std.testing.io);
            release_signal.waitUncancelable(std.testing.io);
            handoff.ack(true);
        }
    }.run, .{ &h, &consumed, &release });
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(handoff: *BlockHandoff, data: []const u8, returned: *bool) void {
            _ = handoff.produce(data);
            @atomicStore(bool, returned, true, .seq_cst);
        }
    }.run, .{ &h, &payload, &producer_returned });

    consumed.waitUncancelable(std.testing.io);
    h.signalDone();
    try std.testing.expect(!@atomicLoad(bool, &producer_returned, .seq_cst));

    release.post(std.testing.io);
    producer.join();
    consumer.join();
    try std.testing.expect(@atomicLoad(bool, &producer_returned, .seq_cst));
}

test "BlockHandoff signalDone unblocks producer" {
    var h = BlockHandoff.init(std.testing.io);
    var payload: [3]u8 = .{ 'x', 'y', 'z' };

    // No consumer is present, so produce blocks without an acknowledgement.
    // signalDone must unblock it.
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(handoff: *BlockHandoff, data: []const u8) void {
            _ = handoff.produce(data); // Blocks until signalDone.
        }
    }.run, .{ &h, &payload });
    h.signalDone();
    producer.join();
}

test "BlockHandoff signalDone unblocks consumer" {
    var h = BlockHandoff.init(std.testing.io);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(handoff: *BlockHandoff) void {
            const data = handoff.consume();
            _ = data;
        }
    }.run, .{&h});
    h.signalDone();
    consumer.join();
}

test "BlockHandoff isDone returns true after signalDone" {
    var h = BlockHandoff.init(std.testing.io);
    try std.testing.expect(!h.isDone());
    h.signalDone();
    try std.testing.expect(h.isDone());
}

test "BlockHandoff multiple produce/consume cycles" {
    var h = BlockHandoff.init(std.testing.io);
    var errors: usize = 0;

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(handoff: *BlockHandoff, errs: *usize) void {
            var i: usize = 0;
            while (true) {
                const data = handoff.consume() orelse return;
                if (data.len == 0 or data[0] != 'a' + @as(u8, @truncate(i))) {
                    @atomicStore(usize, errs, errs.* + 1, .seq_cst);
                }
                handoff.ack(true);
                i += 1;
            }
        }
    }.run, .{ &h, &errors });
    for (0..5) |i| {
        const byte: u8 = 'a' + @as(u8, @truncate(i));
        var buf = [_]u8{byte};
        const ok = h.produce(&buf);
        try std.testing.expect(ok);
    }

    h.signalDone();
    consumer.join();
    try std.testing.expectEqual(errors, 0);
}

test "BlockHandoff produce returns false after signalDone" {
    var h = BlockHandoff.init(std.testing.io);
    h.signalDone();
    var buf = [_]u8{'x'};
    const ok = h.produce(&buf);
    try std.testing.expect(!ok);
}
