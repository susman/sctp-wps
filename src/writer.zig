/// Threaded WavPack-stream encoder and SCTP sender.
///
/// `tryWrite()` copies PCM into a preallocated ring and returns without
/// blocking. It is safe to call from a real-time thread: no allocation, no
/// mutex, and no unbounded wait. A full ring returns `error.WouldBlock`.
/// `write()` uses the same ring but waits for space.
///
/// The encode thread consumes the ring and produces WavPack blocks. The
/// network thread sends each block on SCTP stream 1. A single-slot handoff
/// keeps each encoded block in place until the network thread finishes
/// sending it.
///
/// Slow network output creates backpressure: the ring fills and `tryWrite()`
/// reports `WouldBlock`. `flush()` waits for the encoder and network thread.
/// `flushTimeout()` bounds that wait. `deinit()` stops both threads and
/// releases resources.
///
/// Keep the Writer at a stable address after initialization. WavPack stores an
/// internal pointer to the Encoder and the callback context refers to Writer.
const std = @import("std");
const wpstream = @import("wpstream.zig");
const sctp = @import("sctp.zig");
const protocol = @import("protocol.zig");
const BlockHandoff = @import("queue.zig").BlockHandoff;
const BgErr = @import("queue.zig").BgErr;
const ctrl = @import("control_channel.zig");
const SocketAddr = sctp.SocketAddr;

/// Single-producer single-consumer ring of fixed-size PCM slots.
///
/// The producer writes `samples`, then publishes the slot with a release
/// store on `tail`. The consumer acquires `tail`, reads the slot, then
/// releases it with a release store on `head`. No allocation or lock happens.
fn PcmRing(comptime slot_count: u32, comptime max_samples: usize) type {
    return struct {
        const Self = @This();
        const slots: usize = slot_count;

        // The mask-based indexing requires a power-of-two slot count.
        comptime {
            std.debug.assert(slot_count & (slot_count - 1) == 0);
        }

        samples: [slots * max_samples]i32,
        lens: [slots]u32,
        head: std.atomic.Value(u32) = .init(0),
        tail: std.atomic.Value(u32) = .init(0),

        fn reset(self: *Self) void {
            self.head.store(0, .monotonic);
            self.tail.store(0, .monotonic);
        }

        fn push(self: *Self, values: []const i32) error{ Full, ChunkTooLarge }!void {
            if (values.len > max_samples) return error.ChunkTooLarge;

            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head >= slot_count) return error.Full;

            const slot: usize = @intCast(tail & (slot_count - 1));
            const offset = slot * max_samples;
            @memcpy(self.samples[offset..][0..values.len], values);
            self.lens[slot] = @intCast(values.len);
            self.tail.store(tail +% 1, .release);
        }

        fn peek(self: *Self) ?[]i32 {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;

            const slot: usize = @intCast(head & (slot_count - 1));
            const offset = slot * max_samples;
            const len: usize = self.lens[slot];
            return self.samples[offset..][0..len];
        }

        fn release(self: *Self) void {
            const head = self.head.load(.monotonic);
            self.head.store(head +% 1, .release);
        }
    };
}

const WriterPcmRing = PcmRing(protocol.pcm_ring_slots, protocol.max_pcm_chunk_samples);

/// A threaded WavPack-stream writer with SCTP transport.
pub const Writer = struct {
    pub const Lifecycle = enum(u8) { uninitialized, initializing, initialized };

    /// Resource state used to make failed initialization and destruction safe.
    lifecycle: std.atomic.Value(Lifecycle) = .init(.uninitialized),
    /// WavPack-stream encoder context.
    encoder: wpstream.Encoder,
    /// SCTP sender transport.
    transport: sctp.SctpSender,
    /// Preallocated PCM slots consumed by the encode thread.
    pcm_ring: WriterPcmRing,
    /// Wakes the encode thread when PCM or a flush request arrives.
    data_event: std.Io.Event = .unset,
    /// Wakes a blocked `write()` when a slot is released.
    space_event: std.Io.Event = .unset,
    /// Wakes a flush waiter when the encoder finishes a flush.
    flush_event: std.Io.Event = .unset,
    /// Serializes flush waiters and protects `flush_event.reset()`.
    flush_mutex: std.Io.Mutex = .init,
    /// Flush request generation. The encoder advances `flush_completed`.
    flush_generation: std.atomic.Value(u32) = .init(0),
    /// Flush generation already completed by the encoder.
    flush_completed: std.atomic.Value(u32) = .init(0),
    /// True after shutdown begins. Producers return `error.QueueClosed`.
    closed: std.atomic.Value(bool) = .init(false),
    /// Handoff from the encoder callback to the network thread.
    block_handoff: BlockHandoff,
    /// Background thread that encodes queued PCM.
    encode_thread: std.Thread,
    /// Background thread that sends encoded blocks.
    network_thread: std.Thread,
    /// First fatal error reported by a background thread.
    /// `checkBgErr()` returns it; `tryWrite()` only reports that it exists.
    bg_err: BgErr = .{},
    /// True after the encoder thread is spawned.
    encode_started: bool = false,
    network_started: bool = false,
    transport_initialized: bool = false,
    encoder_initialized: bool = false,
    handoff_initialized: bool = false,
    /// Atomic state used to interrupt a Linux connect call.
    connect_state: sctp.ConnectState = .{},
    /// Set by cancelConnect() and consumed by the next init() call.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Configured interleaved channel count.
    configured_channels: u16 = 0,
    /// Shared Io context for queues and synchronization.
    io: std.Io,

    /// Initialize every field for a handle that is not yet ready for use.
    /// The C ABI and tests use this before the first init() call.
    pub fn initUninitialized(self: *Writer) void {
        self.* = .{
            .encoder = .{
                .wpc = null,
                // SAFETY: init() assigns block_output before the encoder runs.
                .block_output = undefined,
                .user_ctx = null,
            },
            .transport = .{},
            // SAFETY: init() resets the ring indices. The sample and length
            // arrays are written before they are read.
            .pcm_ring = .{ .samples = undefined, .lens = undefined },
            .block_handoff = BlockHandoff.init(std.Io.failing),
            // SAFETY: the started flags gate every join and these handles are
            // assigned before the corresponding flag becomes true.
            .encode_thread = undefined,
            // SAFETY: the started flags gate every join and these handles are
            // assigned before the corresponding flag becomes true.
            .network_thread = undefined,
            .io = std.Io.failing,
        };
    }

    fn lifecycleLoad(self: *const Writer) Lifecycle {
        return self.lifecycle.load(.acquire);
    }

    fn lifecycleStore(self: *Writer, value: Lifecycle) void {
        self.lifecycle.store(value, .release);
    }

    /// Configuration for a Writer.
    pub const Config = struct {
        /// WavPack-stream encoder configuration.
        wp: wpstream.Config = .{},
        /// SCTP sender configuration.
        sctp: sctp.SctpSender.Config = .{},
    };

    /// Maximum interleaved i32 values accepted by one write.
    pub const max_chunk_samples: usize = protocol.max_pcm_chunk_samples;
    /// Number of PCM slots in the writer ring.
    pub const pcm_slots: u32 = protocol.pcm_ring_slots;

    /// Initialize the writer in place.
    /// Connect to `dest`, configure WavPack-stream, send stream metadata, and
    /// start the encoder and network threads.
    ///
    /// WavPack-stream block size calculation:
    /// The writer queries the transport block limit after connecting.
    /// The transport applies WavPack alignment and margin for the path.
    ///
    /// The `io` context must outlive the Writer.
    /// Call initUninitialized() first when the storage is uninitialized.
    pub fn init(
        self: *Writer,
        cfg: Config,
        dest: SocketAddr,
        io: std.Io,
    ) !void {
        if (self.lifecycleLoad() != .uninitialized) return error.AlreadyInitialized;
        if (self.cancel_requested.load(.acquire)) {
            self.cancel_requested.store(false, .release);
            return error.ConnectCanceled;
        }
        try cfg.wp.validate();

        self.encode_started = false;
        self.network_started = false;
        self.transport_initialized = false;
        self.encoder_initialized = false;
        self.handoff_initialized = false;
        self.connect_state.reset();
        self.configured_channels = cfg.wp.num_channels;
        self.io = io;
        self.bg_err = .{};
        self.flush_mutex = .init;
        self.flush_generation = std.atomic.Value(u32).init(0);
        self.flush_completed = std.atomic.Value(u32).init(0);
        self.closed = std.atomic.Value(bool).init(false);
        self.data_event = .unset;
        self.space_event = .unset;
        self.flush_event = .unset;
        self.lifecycleStore(.initializing);
        errdefer {
            self.cleanup();
            self.lifecycleStore(.uninitialized);
        }

        // Stream 0 carries metadata. Stream 1 carries encoded audio blocks.
        const num_sctp_streams: u16 = 2;

        if (self.cancel_requested.load(.acquire)) {
            self.cancel_requested.store(false, .release);
            return error.ConnectCanceled;
        }
        self.transport = try sctp.SctpSender.init(dest, num_sctp_streams, cfg.sctp, &self.connect_state, io);
        self.transport_initialized = true;

        self.encoder = .{
            .wpc = null,
            .block_output = &blockOutputCallback,
            .user_ctx = @ptrCast(self),
        };
        var wp = cfg.wp;
        // Size blocks from the connected transport limit. The transport
        // already applies WavPack alignment and margin.
        wp.block_bytes = @intCast(self.transport.maxBlockBytes());
        try self.encoder.init(wp);
        self.encoder_initialized = true;

        // Send stream metadata on the control channel.
        const ctrl_msg = ctrl.CtrlMsg{
            .magic = ctrl.ctrl_magic,
            .version = ctrl.ctrl_version,
            ._pad0 = .{ 0, 0, 0 },
            .sample_rate = cfg.wp.sample_rate,
            .num_channels = cfg.wp.num_channels,
            .bits_per_sample = cfg.wp.bits_per_sample,
            ._pad1 = 0,
        };
        const ctrl_bytes = ctrl_msg.encode();
        try self.transport.send(0, &ctrl_bytes);

        self.pcm_ring.reset();
        self.block_handoff = BlockHandoff.init(io);
        self.handoff_initialized = true;

        self.encode_thread = try std.Thread.spawn(.{}, encodeLoop, .{self});
        self.encode_started = true;
        self.network_thread = try std.Thread.spawn(.{}, networkLoop, .{self});
        self.network_started = true;
        self.lifecycleStore(.initialized);
    }

    /// Reject a PCM slice that is not a whole number of interleaved frames.
    fn validateChunkLen(self: *const Writer, samples: []const i32) !void {
        const channels: usize = self.configured_channels;
        if (channels != 0 and samples.len % channels != 0) {
            return error.InvalidSampleCount;
        }
    }

    /// Queue interleaved PCM values widened to i32 without blocking.
    ///
    /// Safe for a real-time thread: the input is copied into preallocated
    /// storage, and a full ring returns `error.WouldBlock`.
    /// The slice length must be a multiple of the configured channel count.
    /// Call from one producer thread only.
    pub fn tryWrite(self: *Writer, samples: []const i32) !void {
        if (self.lifecycleLoad() != .initialized) return error.NotInitialized;
        if (self.closed.load(.acquire)) return error.QueueClosed;
        if (self.bg_err.isSet()) return error.WriterFailed;
        if (samples.len == 0) return;
        try self.validateChunkLen(samples);

        self.pcm_ring.push(samples) catch |err| switch (err) {
            error.Full => return error.WouldBlock,
            error.ChunkTooLarge => return error.ChunkTooLarge,
        };
        self.data_event.set(self.io);
    }

    /// Queue interleaved PCM values widened to i32.
    /// The slice length must be a multiple of the configured channel count.
    /// The input is copied before this function returns.
    /// Call from one producer thread only.
    /// Block while the ring is full. Return a background error when one has
    /// been recorded. Use `tryWrite()` from a real-time thread.
    pub fn write(self: *Writer, samples: []const i32) !void {
        if (self.lifecycleLoad() != .initialized) return error.NotInitialized;
        if (self.closed.load(.acquire)) return error.QueueClosed;
        try self.checkBgErr();
        if (samples.len == 0) return;
        try self.validateChunkLen(samples);

        while (true) {
            self.pcm_ring.push(samples) catch |err| switch (err) {
                error.Full => {
                    self.space_event.waitUncancelable(self.io);
                    self.space_event.reset();
                    if (self.closed.load(.acquire)) return error.QueueClosed;
                    try self.checkBgErr();
                    continue;
                },
                error.ChunkTooLarge => return error.ChunkTooLarge,
            };
            self.data_event.set(self.io);
            return;
        }
    }

    /// Flush all buffered samples.
    /// Block until the encoder has emitted and the network thread has sent
    /// them, or a background error is reported.
    pub fn flush(self: *Writer) !void {
        try self.flushImpl(.none);
    }

    /// Flush all buffered samples with a bounded wait.
    /// `timeout_ms` must be positive. Return `error.FlushTimeout` when the
    /// encoder or network thread does not complete in time.
    pub fn flushTimeout(self: *Writer, timeout_ms: i64) !void {
        if (timeout_ms <= 0) return error.InvalidTimeout;
        const timeout = std.Io.Timeout{
            .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
                .clock = .awake,
            },
        };
        try self.flushImpl(timeout);
    }

    fn flushImpl(self: *Writer, timeout: std.Io.Timeout) !void {
        if (self.lifecycleLoad() != .initialized) return error.NotInitialized;
        self.flush_mutex.lockUncancelable(self.io);
        defer self.flush_mutex.unlock(self.io);

        try self.checkBgErr();
        if (self.closed.load(.acquire)) return error.QueueClosed;
        const generation = self.flush_generation.fetchAdd(1, .release) +% 1;
        const deadline = timeout.toDeadline(self.io);
        self.data_event.set(self.io);

        while (true) {
            self.flush_event.reset();
            if (self.closed.load(.acquire)) return error.QueueClosed;
            if (self.flush_completed.load(.acquire) == generation) break;
            if (self.bg_err.isSet()) try self.checkBgErr();
            switch (deadline) {
                .none => self.flush_event.waitUncancelable(self.io),
                else => self.flush_event.waitTimeout(self.io, deadline) catch |err| switch (err) {
                    error.Timeout => return error.FlushTimeout,
                    else => return err,
                },
            }
        }
        if (self.closed.load(.acquire)) return error.QueueClosed;
        try self.checkBgErr();
    }

    /// Cancel a connect operation when the backend supports it.
    /// Safe to call from another thread. The flag also covers the window
    /// before init() publishes the initializing state.
    pub fn cancelConnect(self: *Writer) void {
        self.cancel_requested.store(true, .release);
        sctp.cancelConnect(&self.connect_state);
    }

    /// Shut down the pipeline and release its resources.
    pub fn deinit(self: *Writer) void {
        if (self.lifecycleLoad() == .uninitialized) return;
        self.cleanup();
        self.lifecycleStore(.uninitialized);
    }

    /// Check for a fatal background error without waiting for pipeline work.
    pub fn checkBgErr(self: *Writer) !void {
        if (self.lifecycleLoad() == .uninitialized) return error.NotInitialized;
        try self.bg_err.check(self.io);
    }

    /// Record the first fatal background error.
    /// Later errors are ignored. Wake any producer or flush waiter.
    fn setBgErr(self: *Writer, err: anyerror) void {
        _ = self.bg_err.record(self.io, err);
        self.data_event.set(self.io);
        self.flush_event.set(self.io);
        self.space_event.set(self.io);
    }

    /// Stop workers and release resources in dependency order.
    /// This is also used by the initialization error path.
    fn cleanup(self: *Writer) void {
        if (self.transport_initialized) self.transport.shutdown();
        self.closed.store(true, .release);
        self.data_event.set(self.io);
        self.space_event.set(self.io);
        self.flush_event.set(self.io);
        if (self.handoff_initialized) self.block_handoff.signalDone();

        if (self.encode_started) {
            self.encode_thread.join();
            self.encode_started = false;
        }
        if (self.network_started) {
            self.network_thread.join();
            self.network_started = false;
        }

        if (self.encoder_initialized) {
            self.encoder.deinit();
            self.encoder_initialized = false;
        }
        if (self.transport_initialized) {
            self.transport.close();
            self.transport_initialized = false;
        }
        self.handoff_initialized = false;
        self.configured_channels = 0;
        self.cancel_requested.store(false, .release);
    }

    /// Run the encoder thread.
    /// Drain the PCM ring, hand completed blocks to the network thread, and
    /// service flush generations when the ring is empty.
    fn encodeLoop(self: *Writer) void {
        while (true) {
            if (self.pcm_ring.peek()) |samples| {
                if (!self.block_handoff.isDone()) {
                    self.encoder.packSamples(samples) catch |err| {
                        self.pcm_ring.release();
                        self.setBgErr(err);
                        break;
                    };
                }
                self.pcm_ring.release();
                self.space_event.set(self.io);
                continue;
            }

            const generation = self.flush_generation.load(.acquire);
            if (self.flush_completed.load(.acquire) != generation) {
                if (!self.block_handoff.isDone()) {
                    self.encoder.flush() catch |err| {
                        self.setBgErr(err);
                        break;
                    };
                }
                self.flush_completed.store(generation, .release);
                self.flush_event.set(self.io);
                continue;
            }

            if (self.bg_err.isSet()) break;

            if (self.closed.load(.acquire)) break;

            self.data_event.waitUncancelable(self.io);
            self.data_event.reset();
        }
        self.block_handoff.signalDone();
    }

    /// Handle one encoded block from WavPack-stream.
    /// Block until the network thread acknowledges the handoff.
    /// Return false after a send error or shutdown to stop the encoder.
    fn blockOutputCallback(ctx: ?*anyopaque, data: []const u8) bool {
        const self: *Writer = @ptrCast(@alignCast(ctx orelse return false));
        return self.block_handoff.produce(data);
    }

    /// Run the network thread.
    /// Consume encoded blocks, send them on SCTP stream 1, and acknowledge each
    /// handoff. Record send errors and signal the encoder to stop.
    fn networkLoop(self: *Writer) void {
        while (true) {
            const data = self.block_handoff.consume() orelse break;
            self.transport.send(1, data) catch |err| {
                self.setBgErr(err);
                self.block_handoff.ack(false);
                self.block_handoff.signalDone();
                return;
            };
            self.block_handoff.ack(true);
        }
    }
};

// Tests

const testing = std.testing;

test "cancelConnect before init blocks the next connect" {
    var writer: Writer = undefined;
    writer.initUninitialized();
    writer.cancelConnect();

    try testing.expectError(error.ConnectCanceled, writer.init(
        .{},
        sctp.SocketAddr.parseIp4(.{ 127, 0, 0, 1 }, 4010),
        std.Io.failing,
    ));
}

test "PcmRing FIFO and release" {
    var ring: PcmRing(2, 4) = undefined;
    ring.reset();

    try ring.push(&[_]i32{ 1, 2 });
    try ring.push(&[_]i32{3});

    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, ring.peek().?);
    ring.release();
    try testing.expectEqualSlices(i32, &[_]i32{3}, ring.peek().?);
    ring.release();
    try testing.expect(ring.peek() == null);
}

test "PcmRing full and chunk too large" {
    var ring: PcmRing(2, 4) = undefined;
    ring.reset();

    try ring.push(&[_]i32{1});
    try ring.push(&[_]i32{2});
    try testing.expectError(error.Full, ring.push(&[_]i32{3}));
    try testing.expectError(error.ChunkTooLarge, ring.push(&[_]i32{ 1, 2, 3, 4, 5 }));
}

test "PcmRing wraps slots" {
    var ring: PcmRing(2, 4) = undefined;
    ring.reset();

    for (0..8) |i| {
        const value: i32 = @intCast(i);
        try ring.push(&[_]i32{value});
        try testing.expectEqual(value, ring.peek().?[0]);
        ring.release();
    }
}

test "PcmRing concurrent producer and consumer" {
    var ring: PcmRing(4, 1) = undefined;
    ring.reset();

    const total = 1000;
    const Ctx = struct {
        fn produce(r: *PcmRing(4, 1)) void {
            var i: i32 = 0;
            while (i < total) : (i += 1) {
                while (true) {
                    r.push(&[_]i32{i}) catch continue;
                    break;
                }
            }
        }

        fn consume(r: *PcmRing(4, 1), out: *[total]i32) void {
            var i: usize = 0;
            while (i < total) {
                if (r.peek()) |samples| {
                    out[i] = samples[0];
                    r.release();
                    i += 1;
                }
            }
        }
    };

    var out: [total]i32 = undefined;
    const producer = try std.Thread.spawn(.{}, Ctx.produce, .{&ring});
    const consumer = try std.Thread.spawn(.{}, Ctx.consume, .{ &ring, &out });
    producer.join();
    consumer.join();

    for (out, 0..) |value, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), value);
    }
}
