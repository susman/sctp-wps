/// Threaded SCTP receiver and WavPack-stream decoder.
/// The receive thread queues encoded blocks. The decode thread converts them to
/// PCM. The caller reads decoded blocks with `readFrame()`.
///
/// Lifecycle:
///   init() -> accept() -> recvConfig() -> start() -> readFrame() loop -> deinit()
///
/// Thread model:
///   Receive thread copies WavPack blocks into `block_queue`.
///   Decode thread primes that queue, decodes blocks, and fills `pcm_out_queue`.
///   Caller thread pops decoded PCM blocks from `pcm_out_queue`.
///
/// Backpressure propagates from a slow caller to the SCTP sender. A full PCM
/// queue blocks decoding. A full block queue blocks receiving.
///
/// Session takeover: a live sender can be replaced without restarting the
/// Reader. The caller polls `checkNewSender()`. When it returns true, call
/// `nextSession()`. That method stops both threads, drains both queues,
/// promotes the pending connection or waits for a new one, and reads the new
/// stream configuration. Call `start()` to resume receiving.
///
/// Keep the Reader at a stable address while it owns background threads.
const std = @import("std");
const wpstream = @import("wpstream.zig");
const sctp = @import("sctp.zig");
const protocol = @import("protocol.zig");
const BoundedQueue = @import("queue.zig").BoundedQueue;
const BgErr = @import("queue.zig").BgErr;
const ctrl = @import("control_channel.zig");
const SocketAddr = sctp.SocketAddr;

/// A received WavPack-stream block for decoding.
/// The payload is copied into fixed storage owned by the queue.
const WpBlock = struct {
    data: [max_recv_buf]u8,
    len: usize,

    fn slice(self: *const WpBlock) []const u8 {
        return self.data[0..self.len];
    }
};

/// Copy one validated block into fixed storage.
fn newWpBlock(data: []const u8) WpBlock {
    // SAFETY: the copy initializes every byte read through `len`.
    var block: WpBlock = undefined;
    @memcpy(block.data[0..data.len], data);
    block.len = data.len;
    return block;
}

/// One decoded frame slot reference. The samples live in `Reader.pcm_pool`.
const PcmRef = struct {
    slot: u8,
    len: usize,
};

/// Capacity of the decoded PCM pool and its queue. Fixed at eight blocks.
const pcm_pool_slots = 8;
/// Prevent an unbounded caller-provided block queue.
///
/// Memory cost scales with this value. Each queued WavPack block occupies
/// about 2 KiB, so a depth of 65536 allocates roughly 128 MiB for the
/// block queue alone. Choose the depth from the expected network jitter.
const max_buffer_depth = 1 << 16;

/// Size of the stack-allocated SCTP receive buffer.
/// The writer caps each WavPack block below this bound.
const max_recv_buf: usize = protocol.max_wire_block_bytes;
/// Bound audio blocks received before the control message arrives.
const max_startup_blocks = 8;

/// Stream configuration received from the writer on the control channel.
pub const StreamConfig = struct {
    /// Sample rate in samples per second.
    sample_rate: u32,
    /// Number of interleaved channels.
    num_channels: u16,
    /// Bits per sample.
    bits_per_sample: u8,
};

/// A threaded WavPack-stream reader with SCTP transport.
pub const Reader = struct {
    pub const Lifecycle = enum(u8) { uninitialized, initializing, initialized, running };

    /// Resource state used to make failed initialization and destruction safe.
    lifecycle: std.atomic.Value(Lifecycle) = .init(.uninitialized),
    /// SCTP receiver transport.
    transport: sctp.SctpReceiver,
    /// Encoded blocks from the receive thread to the decode thread.
    /// `start()` sets its capacity. It acts as a jitter buffer.
    block_queue: BoundedQueue(WpBlock),
    /// Decoded frame references from the decode thread to the caller.
    pcm_out_queue: BoundedQueue(PcmRef),
    /// Free decoded frame slots. Initialized with 0..pcm_pool_slots - 1.
    free_slots: BoundedQueue(u8),
    /// Fixed decoded sample storage. Each slot is one WavPack block frame.
    pcm_pool: [pcm_pool_slots][protocol.max_decoded_samples]i32,
    /// Background thread that receives encoded blocks.
    recv_thread: std.Thread,
    /// Background thread that decodes blocks.
    decode_thread: std.Thread,
    /// True after `start()` spawns the receive thread.
    recv_thread_started: bool = false,
    /// True after `start()` spawns the decode thread.
    decode_thread_started: bool = false,
    /// First fatal error reported by a background thread.
    bg_err: BgErr = .{},
    /// Receiver configuration retained for takeover operations.
    sctp_cfg: sctp.SctpReceiver.Config,
    /// Io context backing the reader's mutexes and queues.
    io: std.Io = std.Io.failing,
    /// Allocator for queues. Set by init().
    allocator: std.mem.Allocator,
    transport_initialized: bool = false,
    block_queue_initialized: bool = false,
    pcm_queue_initialized: bool = false,
    free_queue_initialized: bool = false,
    session_active: bool = false,
    config_received: bool = false,
    stream_config: ?StreamConfig = null,
    /// Blocks received before the control message is delivered.
    startup_blocks: [max_startup_blocks]WpBlock,
    startup_count: usize = 0,
    /// A frame retained after a caller supplied an undersized output buffer.
    pending_frame: ?PcmRef = null,

    /// Initialize every field for a handle that is not yet ready for use.
    /// The C ABI and tests use this before the first init() call.
    pub fn initUninitialized(self: *Reader) void {
        self.* = .{
            .transport = .{},
            // SAFETY: init() assigns the caller allocator before the queues run.
            .block_queue = .{ .allocator = undefined },
            // SAFETY: init() assigns the caller allocator before the queues run.
            .pcm_out_queue = .{ .allocator = undefined },
            // SAFETY: init() assigns the caller allocator before the queues run.
            .free_slots = .{ .allocator = undefined },
            // SAFETY: the decode thread writes each slot before readFrame reads it.
            .pcm_pool = undefined,
            // SAFETY: the started flags gate every join and these handles are
            // assigned before the corresponding flag becomes true.
            .recv_thread = undefined,
            // SAFETY: the started flags gate every join and these handles are
            // assigned before the corresponding flag becomes true.
            .decode_thread = undefined,
            .sctp_cfg = .{},
            // SAFETY: init() assigns the caller allocator before any allocation.
            .allocator = undefined,
            // SAFETY: recvConfig() fills a slot before start() reads it.
            .startup_blocks = undefined,
        };
    }

    fn lifecycleLoad(self: *const Reader) Lifecycle {
        return self.lifecycle.load(.acquire);
    }

    fn lifecycleStore(self: *Reader, value: Lifecycle) void {
        self.lifecycle.store(value, .release);
    }

    /// Configuration for a Reader.
    pub const Config = struct {
        /// SCTP receiver configuration.
        sctp: sctp.SctpReceiver.Config = .{},
    };

    /// Initialize the reader, bind it to `bind_addr`, and listen for senders.
    /// The supplied allocator and Io context must outlive the Reader.
    /// Call initUninitialized() first when the storage is uninitialized.
    pub fn init(
        self: *Reader,
        allocator: std.mem.Allocator,
        cfg: Config,
        bind_addr: SocketAddr,
        io: std.Io,
    ) !void {
        if (self.lifecycleLoad() != .uninitialized) return error.AlreadyInitialized;
        self.lifecycleStore(.initializing);
        self.recv_thread_started = false;
        self.decode_thread_started = false;
        self.transport_initialized = false;
        self.block_queue_initialized = false;
        self.pcm_queue_initialized = false;
        self.free_queue_initialized = false;
        self.session_active = false;
        self.config_received = false;
        self.stream_config = null;
        self.startup_count = 0;
        self.pending_frame = null;
        self.bg_err = .{};
        self.sctp_cfg = cfg.sctp;
        self.io = io;
        self.allocator = allocator;
        errdefer {
            self.cleanup();
            self.lifecycleStore(.uninitialized);
        }

        const num_sctp_streams: u16 = 2;
        self.transport = try sctp.SctpReceiver.init(bind_addr, num_sctp_streams, cfg.sctp, io);
        self.transport_initialized = true;
        // Allocate placeholder queues. start() replaces the block queue at the
        // final depth and resets the fixed-size PCM queues.
        self.block_queue = try BoundedQueue(WpBlock).init(self.allocator, io, 1);
        self.block_queue_initialized = true;
        self.pcm_out_queue = try BoundedQueue(PcmRef).init(self.allocator, io, pcm_pool_slots);
        self.pcm_queue_initialized = true;
        self.free_slots = try BoundedQueue(u8).init(self.allocator, io, pcm_pool_slots);
        self.free_queue_initialized = true;
        for (0..pcm_pool_slots) |i|
            try self.free_slots.push(@intCast(i));
        self.lifecycleStore(.initialized);
    }

    /// Accept one incoming SCTP association.
    /// Block until a sender connects. This does not start either background
    /// thread. Call `recvConfig()` and then `start()`.
    pub fn accept(self: *Reader, cfg: Config) !void {
        if (self.lifecycleLoad() != .initialized or self.session_active) return error.InvalidState;
        try self.transport.accept(cfg.sctp);
        self.sctp_cfg = cfg.sctp;
        self.session_active = true;
        self.config_received = false;
        self.stream_config = null;
        self.startup_count = 0;
    }

    /// Read stream configuration from SCTP stream 0.
    /// Block until the control message arrives. Call after `accept()` and
    /// before `start()`.
    pub fn recvConfig(self: *Reader) !StreamConfig {
        if (self.lifecycleLoad() != .initialized or !self.session_active) return error.InvalidState;
        if (self.config_received) return self.stream_config.?;

        var buf: [max_recv_buf]u8 = undefined;
        while (true) {
            const result = try self.transport.recv(&buf);
            if (result.len > buf.len) return error.ProtocolError;

            if (result.stream_id == 0) {
                const msg = ctrl.CtrlMsg.decode(buf[0..result.len]) catch return error.ProtocolError;
                if (msg.magic != ctrl.ctrl_magic or msg.version != ctrl.ctrl_version) {
                    return error.ProtocolError;
                }
                if (!std.mem.eql(u8, &msg._pad0, &[_]u8{ 0, 0, 0 }) or msg._pad1 != 0) {
                    return error.ProtocolError;
                }
                wpstream.validateFormat(msg.sample_rate, msg.num_channels, msg.bits_per_sample) catch
                    return error.ProtocolError;
                const cfg = StreamConfig{
                    .sample_rate = msg.sample_rate,
                    .num_channels = msg.num_channels,
                    .bits_per_sample = msg.bits_per_sample,
                };
                self.stream_config = cfg;
                self.config_received = true;
                return cfg;
            }

            if (result.stream_id != 1) return error.ProtocolError;
            _ = wpstream.validateBlock(buf[0..result.len]) catch return error.ProtocolError;
            if (self.startup_count >= max_startup_blocks) return error.ProtocolError;
            self.startup_blocks[self.startup_count] = newWpBlock(buf[0..result.len]);
            self.startup_count += 1;
        }
    }

    /// Check for a new sender without blocking.
    /// When true, the next `nextSession()` call uses the pending connection.
    pub fn checkNewSender(self: *Reader) bool {
        const state = self.lifecycleLoad();
        if (state != .initialized and state != .running) return false;
        if (!self.session_active) return false;
        return self.transport.tryAcceptNew(self.sctp_cfg);
    }

    /// Return the peer address of the active association, or null when absent.
    /// The value changes after `accept()` and `nextSession()`.
    /// It is cleared when the connection closes.
    pub fn peerAddress(self: *const Reader) ?sctp.SocketAddr {
        const state = self.lifecycleLoad();
        if (state == .uninitialized or state == .initializing) return null;
        return self.transport.peerAddress();
    }

    /// End the current session and transition to the next sender.
    /// Promote a pending connection when one exists. Otherwise, block in
    /// `accept()` until a new sender connects. Return its stream configuration.
    pub fn nextSession(self: *Reader) !StreamConfig {
        const state = self.lifecycleLoad();
        if (state != .initialized and state != .running) return error.InvalidState;
        self.stopSession();
        self.bg_err.clear(self.io);
        self.session_active = false;
        self.config_received = false;
        self.stream_config = null;
        // Promote a pending connection or wait for a new one.
        if (self.transport.hasPending()) {
            try self.transport.promotePending();
        } else {
            try self.transport.accept(self.sctp_cfg);
        }
        self.session_active = true;
        return try self.recvConfig();
    }

    /// Start the receive and decode threads.
    /// `buffer_depth` is the WavPack-stream block queue capacity.
    /// The decode thread pre-fills the queue to this depth before decoding.
    /// The value must be at least 1.
    pub fn start(self: *Reader, buffer_depth: usize) !void {
        if (self.lifecycleLoad() != .initialized) return error.InvalidState;
        if (!self.session_active or !self.config_received) return error.InvalidState;
        if (self.recv_thread_started or self.decode_thread_started) return error.AlreadyStarted;
        if (buffer_depth < 1) return error.InvalidDepth;
        if (buffer_depth > max_buffer_depth) return error.InvalidDepth;
        const depth = @max(buffer_depth, self.startup_count);

        // Create the replacement block queue before releasing the old storage.
        var new_block_queue = try BoundedQueue(WpBlock).init(self.allocator, self.io, depth);
        var new_block_owned = true;
        errdefer if (new_block_owned) new_block_queue.deinit();

        self.block_queue.close();
        self.pcm_out_queue.close();
        if (self.free_queue_initialized) self.free_slots.close();
        self.drainQueues();
        // Re-create the block queue at the requested depth.
        self.block_queue.deinit();
        self.block_queue = new_block_queue;
        new_block_owned = false;
        self.block_queue_initialized = true;
        // The PCM and free queues have fixed capacities. Reuse their storage.
        self.pcm_out_queue.reset();
        self.free_slots.reset();
        for (0..pcm_pool_slots) |i|
            try self.free_slots.push(@intCast(i));

        // Transfer startup blocks. The block queue capacity covers them.
        for (0..self.startup_count) |i|
            try self.block_queue.push(self.startup_blocks[i]);
        self.startup_count = 0;

        // Start both background threads.
        self.recv_thread = try std.Thread.spawn(.{}, recvLoop, .{self});
        self.recv_thread_started = true;
        errdefer {
            self.stopSession();
            self.lifecycleStore(.initialized);
        }
        self.decode_thread = try std.Thread.spawn(.{}, decodeLoop, .{self});
        self.decode_thread_started = true;
        self.lifecycleStore(.running);
    }

    /// Copy the next decoded PCM block into `out_buf`.
    /// Return the number of interleaved i32 values written.
    /// Block until a decoded block is available or the session ends.
    /// Call from one consumer thread only.
    pub fn readFrame(self: *Reader, out_buf: []i32) !u32 {
        if (self.lifecycleLoad() != .running) return error.InvalidState;
        try self.checkBgErr();
        const ref = if (self.pending_frame) |pending| blk: {
            self.pending_frame = null;
            break :blk pending;
        } else self.pcm_out_queue.pop() catch |e| switch (e) {
            error.Closed => {
                try self.checkBgErr();
                return error.ConnectionClosed;
            },
            error.Canceled => return error.QueueCanceled,
        };
        if (ref.len > out_buf.len) {
            self.pending_frame = ref;
            return error.BufferTooSmall;
        }
        defer self.releasePcmSlot(ref.slot);
        @memcpy(out_buf[0..ref.len], self.pcm_pool[ref.slot][0..ref.len]);
        return @intCast(ref.len);
    }

    /// Return one decoded slot to the free list.
    fn releasePcmSlot(self: *Reader, slot: u8) void {
        if (!self.free_queue_initialized) return;
        self.free_slots.push(slot) catch |err| switch (err) {
            // Teardown closes the queue. The pool is reset at the next start.
            error.Closed => {},
            error.Canceled => {},
        };
    }

    /// Return the value count required by a frame retained after a
    /// buffer-too-small error, or null when no frame is retained.
    pub fn pendingFrameLen(self: *const Reader) ?u32 {
        if (self.pending_frame) |ref| return @intCast(ref.len);
        return null;
    }

    /// Request shutdown of sockets and close queues to stop blocked reader operations.
    /// On Linux, socket shutdown wakes a thread blocked in `accept()` or
    /// `recv()`. The usrsctp backend cannot reliably wake a blocked `accept()`.
    /// Call `deinit()` after any background threads have exited.
    pub fn cancel(self: *Reader) void {
        const state = self.lifecycleLoad();
        if (state == .uninitialized or state == .initializing) return;
        if (self.transport_initialized) self.transport.cancel();
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
        if (self.free_queue_initialized) self.free_slots.close();
    }

    /// Stop all reader threads and release queue and transport resources.
    pub fn deinit(self: *Reader) void {
        if (self.lifecycleLoad() == .uninitialized) return;
        self.cleanup();
        self.lifecycleStore(.uninitialized);
    }

    fn checkBgErr(self: *Reader) !void {
        if (self.lifecycleLoad() == .uninitialized) return error.NotInitialized;
        try self.bg_err.check(self.io);
    }

    fn setBgErr(self: *Reader, e: anyerror) void {
        _ = self.bg_err.record(self.io, e);
    }

    fn failBackground(self: *Reader, e: anyerror) void {
        self.setBgErr(e);
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
        if (self.free_queue_initialized) self.free_slots.close();
    }

    fn resetStartupBlocks(self: *Reader) void {
        self.startup_count = 0;
    }

    fn drainQueues(self: *Reader) void {
        if (self.block_queue_initialized) {
            while (true) {
                _ = self.block_queue.pop() catch |err| switch (err) {
                    error.Closed => break,
                    error.Canceled => continue,
                };
            }
        }
        if (self.pcm_queue_initialized) {
            while (true) {
                _ = self.pcm_out_queue.pop() catch |err| switch (err) {
                    error.Closed => break,
                    error.Canceled => continue,
                };
            }
        }
        if (self.free_queue_initialized) {
            while (true) {
                _ = self.free_slots.pop() catch |err| switch (err) {
                    error.Closed => break,
                    error.Canceled => continue,
                };
            }
        }
    }

    fn clearPendingFrame(self: *Reader) void {
        self.pending_frame = null;
    }

    fn stopSession(self: *Reader) void {
        if (self.recv_thread_started or self.decode_thread_started) {
            self.transport.shutdownConn();
        }
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
        if (self.free_queue_initialized) self.free_slots.close();
        if (self.recv_thread_started) {
            self.recv_thread.join();
            self.recv_thread_started = false;
        }
        if (self.decode_thread_started) {
            self.decode_thread.join();
            self.decode_thread_started = false;
        }
        self.transport.closeConn();
        self.drainQueues();
        self.clearPendingFrame();
        self.resetStartupBlocks();
        self.session_active = false;
        self.config_received = false;
        self.stream_config = null;
        self.lifecycleStore(.initialized);
    }

    fn cleanup(self: *Reader) void {
        if (self.transport_initialized) self.transport.shutdown();
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
        if (self.free_queue_initialized) self.free_slots.close();
        if (self.recv_thread_started) {
            self.recv_thread.join();
            self.recv_thread_started = false;
        }
        if (self.decode_thread_started) {
            self.decode_thread.join();
            self.decode_thread_started = false;
        }
        self.drainQueues();
        self.clearPendingFrame();
        self.resetStartupBlocks();
        if (self.block_queue_initialized) {
            self.block_queue.deinit();
            self.block_queue_initialized = false;
        }
        if (self.pcm_queue_initialized) {
            self.pcm_out_queue.deinit();
            self.pcm_queue_initialized = false;
        }
        if (self.free_queue_initialized) {
            self.free_slots.deinit();
            self.free_queue_initialized = false;
        }
        if (self.transport_initialized) {
            self.transport.close();
            self.transport_initialized = false;
        }
        self.session_active = false;
        self.config_received = false;
        self.stream_config = null;
    }

    /// Run the receive thread.
    /// Copy each received WavPack block into `block_queue`.
    ///
    /// Exit when the transport or block queue closes. Always close
    /// `block_queue` so the decode thread can exit.
    fn recvLoop(self: *Reader) void {
        var recv_buf: [max_recv_buf]u8 = undefined;
        defer self.block_queue.close();

        while (true) {
            const result = self.transport.recv(&recv_buf) catch |e| {
                if (e != error.ConnectionClosed) self.failBackground(e);
                break;
            };

            if (result.len > recv_buf.len or result.stream_id != 1) {
                self.failBackground(error.ProtocolError);
                break;
            }
            const data = recv_buf[0..result.len];
            _ = wpstream.validateBlock(data) catch {
                self.failBackground(error.ProtocolError);
                break;
            };

            self.block_queue.push(newWpBlock(data)) catch break;
        }
    }

    /// Run the decode thread.
    /// Prime `block_queue`, decode blocks into the fixed PCM pool, and push
    /// slot references into `pcm_out_queue`.
    ///
    /// Exit when `block_queue` closes, `free_slots` closes, or
    /// `pcm_out_queue` closes. Always close `pcm_out_queue` so `readFrame()`
    /// can return.
    fn decodeLoop(self: *Reader) void {
        defer self.pcm_out_queue.close();
        // Prime the jitter buffer before decoding.
        self.block_queue.waitForDepth(self.block_queue.capacity) catch |e| {
            self.setBgErr(e);
            return;
        };

        var first_block = true;

        while (true) {
            const block = self.block_queue.pop() catch break;
            const data = block.slice();

            // Read the header to determine the required decode size.
            const header = wpstream.validateBlock(data) catch {
                self.failBackground(error.ProtocolError);
                return;
            };
            const is_mono = (header.flags & wpstream.BlockHeader.MONO_FLAG) != 0;
            const ch: usize = if (is_mono) 1 else 2;
            const needed: usize = @as(usize, header.block_samples) * ch;
            if (needed == 0) continue;

            if (first_block) {
                const cfg = self.stream_config orelse {
                    self.failBackground(error.ProtocolError);
                    return;
                };
                const info = wpstream.Decoder.getInfo(data) catch {
                    self.failBackground(error.ProtocolError);
                    return;
                };
                if (info.num_channels != cfg.num_channels or
                    info.sample_rate != cfg.sample_rate or
                    info.bits_per_sample != cfg.bits_per_sample or
                    info.frame_samples != header.block_samples)
                {
                    self.failBackground(error.ProtocolError);
                    return;
                }
                first_block = false;
            }

            const slot = self.free_slots.pop() catch break;
            const n = wpstream.Decoder.decodeFrame(
                data,
                self.pcm_pool[slot][0..needed],
            ) catch |e| {
                self.releasePcmSlot(slot);
                self.failBackground(e);
                return;
            };
            if (n == 0) {
                self.releasePcmSlot(slot);
                continue;
            }

            self.pcm_out_queue.push(.{ .slot = slot, .len = n }) catch {
                self.releasePcmSlot(slot);
                break;
            };
        }
    }
};

test "pendingFrameLen reports a retained frame size" {
    var reader: Reader = undefined;
    reader.initUninitialized();
    reader.pending_frame = .{ .slot = 0, .len = 4 };
    try std.testing.expectEqual(4, reader.pendingFrameLen().?);
}
