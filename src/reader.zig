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
const BoundedQueue = @import("queue.zig").BoundedQueue;
const ctrl = @import("control_channel.zig");
const SocketAddr = sctp.SocketAddr;
const alloc = std.heap.c_allocator;

/// A received WavPack-stream block for decoding.
const WpBlock = struct {
    data: []u8, // Heap-allocated. Freed after decoding.
};

/// A decoded PCM frame produced by the decode thread.
const PcmFrame = struct {
    samples: []i32, // Heap-allocated. Freed after copying to the caller.
};

/// Capacity of the decoded PCM queue. It is fixed at eight blocks.
const pcm_out_queue_depth = 8;
/// Prevent an unbounded caller-provided allocation.
const max_buffer_depth = 1 << 16;

/// Size of the stack-allocated SCTP receive buffer.
/// The current block-sizing policy caps payloads at 1452 bytes. This cap
/// applies to WavPack block sizing. It does not limit unrelated SCTP traffic.
const max_recv_buf = 2 * 1024;
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
    pub const Lifecycle = enum { uninitialized, initializing, initialized, running };

    /// Resource state used to make failed initialization and destruction safe.
    lifecycle: Lifecycle = .uninitialized,
    /// SCTP receiver transport.
    transport: sctp.SctpReceiver,
    /// Encoded blocks from the receive thread to the decode thread.
    /// `start()` sets its capacity. It acts as a jitter buffer.
    block_queue: BoundedQueue(WpBlock),
    /// Decoded PCM blocks from the decode thread to the caller.
    /// Its capacity is fixed by `pcm_out_queue_depth`.
    pcm_out_queue: BoundedQueue(PcmFrame),
    /// Background thread that receives encoded blocks.
    recv_thread: std.Thread,
    /// Background thread that decodes blocks.
    decode_thread: std.Thread,
    /// True after `start()` spawns the receive thread.
    recv_thread_started: bool = false,
    /// True after `start()` spawns the decode thread.
    decode_thread_started: bool = false,
    /// First fatal error reported by a background thread.
    bg_err: ?anyerror,
    bg_err_mutex: std.Io.Mutex = .init,
    /// Receiver configuration retained for takeover operations.
    sctp_cfg: sctp.SctpReceiver.Config,
    /// Io context backing the reader's mutexes and queues.
    io: std.Io = std.Io.failing,
    transport_initialized: bool = false,
    block_queue_initialized: bool = false,
    pcm_queue_initialized: bool = false,
    session_active: bool = false,
    config_received: bool = false,
    stream_config: ?StreamConfig = null,
    /// Blocks received before the control message is delivered.
    startup_blocks: std.ArrayListUnmanaged(WpBlock) = .empty,
    /// A frame retained after a caller supplied an undersized output buffer.
    pending_frame: ?PcmFrame = null,

    /// Configuration for a Reader.
    pub const Config = struct {
        /// SCTP receiver configuration.
        sctp: sctp.SctpReceiver.Config = .{},
    };

    /// Initialize the reader, bind it to `bind_addr`, and listen for senders.
    /// The supplied Io context must outlive the Reader.
    pub fn init(self: *Reader, cfg: Config, bind_addr: SocketAddr, io: std.Io) !void {
        if (self.lifecycle != .uninitialized) return error.AlreadyInitialized;
        self.lifecycle = .initializing;
        self.recv_thread_started = false;
        self.decode_thread_started = false;
        self.transport_initialized = false;
        self.block_queue_initialized = false;
        self.pcm_queue_initialized = false;
        self.session_active = false;
        self.config_received = false;
        self.stream_config = null;
        self.startup_blocks = .empty;
        self.pending_frame = null;
        self.bg_err = null;
        self.bg_err_mutex = .init;
        self.sctp_cfg = cfg.sctp;
        self.io = io;
        errdefer {
            self.cleanup();
            self.lifecycle = .uninitialized;
        }

        const num_sctp_streams: u16 = 2;
        self.transport = try sctp.SctpReceiver.init(bind_addr, num_sctp_streams, cfg.sctp, io);
        self.transport_initialized = true;
        // Allocate placeholder queues. start() replaces them at the final depth.
        self.block_queue = try BoundedQueue(WpBlock).init(alloc, io, 1);
        self.block_queue_initialized = true;
        self.pcm_out_queue = try BoundedQueue(PcmFrame).init(alloc, io, pcm_out_queue_depth);
        self.pcm_queue_initialized = true;
        self.lifecycle = .initialized;
    }

    /// Accept one incoming SCTP association.
    /// Block until a sender connects. This does not start either background
    /// thread. Call `recvConfig()` and then `start()`.
    pub fn accept(self: *Reader, cfg: Config) !void {
        if (self.lifecycle != .initialized or self.session_active) return error.InvalidState;
        try self.transport.accept(cfg.sctp);
        self.sctp_cfg = cfg.sctp;
        self.session_active = true;
        self.config_received = false;
        self.stream_config = null;
    }

    /// Read stream configuration from SCTP stream 0.
    /// Block until the control message arrives. Call after `accept()` and
    /// before `start()`.
    pub fn recvConfig(self: *Reader) !StreamConfig {
        if (self.lifecycle != .initialized or !self.session_active) return error.InvalidState;
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
                if (msg.sample_rate == 0 or
                    (msg.num_channels != 1 and msg.num_channels != 2) or
                    (msg.bits_per_sample != 16 and msg.bits_per_sample != 24))
                {
                    return error.ProtocolError;
                }
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
            if (self.startup_blocks.items.len >= max_startup_blocks) return error.ProtocolError;
            const copy = alloc.dupe(u8, buf[0..result.len]) catch return error.OutOfMemory;
            self.startup_blocks.append(alloc, .{ .data = copy }) catch {
                alloc.free(copy);
                return error.OutOfMemory;
            };
        }
    }

    /// Check for a new sender without blocking.
    /// When true, the next `nextSession()` call uses the pending connection.
    pub fn checkNewSender(self: *Reader) bool {
        if (self.lifecycle != .initialized and self.lifecycle != .running) return false;
        return self.transport.tryAcceptNew(self.sctp_cfg);
    }

    /// Return the peer address of the active association, or null when absent.
    /// The value changes after `accept()` and `nextSession()`.
    /// It is cleared when the connection closes.
    pub fn peerAddress(self: *const Reader) ?sctp.SocketAddr {
        if (self.lifecycle == .uninitialized or self.lifecycle == .initializing) return null;
        return self.transport.peerAddress();
    }

    /// End the current session and transition to the next sender.
    /// Promote a pending connection when one exists. Otherwise, block in
    /// `accept()` until a new sender connects. Return its stream configuration.
    pub fn nextSession(self: *Reader) !StreamConfig {
        if (self.lifecycle != .initialized and self.lifecycle != .running) return error.InvalidState;
        self.stopSession();
        self.bg_err = null;
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
        if (self.lifecycle != .initialized) return error.InvalidState;
        if (!self.session_active or !self.config_received) return error.InvalidState;
        if (self.recv_thread_started or self.decode_thread_started) return error.AlreadyStarted;
        if (buffer_depth < 1) return error.InvalidDepth;
        if (buffer_depth > max_buffer_depth) return error.InvalidDepth;
        const depth = @max(buffer_depth, self.startup_blocks.items.len);

        // Create replacement queues before releasing the old storage.
        var new_block_queue = try BoundedQueue(WpBlock).init(alloc, self.io, depth);
        var new_block_owned = true;
        errdefer if (new_block_owned) new_block_queue.deinit();
        var new_pcm_queue = try BoundedQueue(PcmFrame).init(alloc, self.io, pcm_out_queue_depth);
        var new_pcm_owned = true;
        errdefer if (new_pcm_owned) new_pcm_queue.deinit();

        self.block_queue.close();
        self.pcm_out_queue.close();
        self.drainQueues();
        // Re-create the block queue at the requested depth.
        self.block_queue.deinit();
        self.block_queue = new_block_queue;
        new_block_owned = false;
        self.block_queue_initialized = true;
        // Re-create the PCM output queue at its fixed depth.
        self.pcm_out_queue.deinit();
        self.pcm_out_queue = new_pcm_queue;
        new_pcm_owned = false;
        self.pcm_queue_initialized = true;

        for (self.startup_blocks.items) |block| {
            try self.block_queue.push(block);
        }
        self.startup_blocks.clearRetainingCapacity();

        // Start both background threads.
        self.recv_thread = try std.Thread.spawn(.{}, recvLoop, .{self});
        self.recv_thread_started = true;
        errdefer {
            self.stopSession();
            self.lifecycle = .initialized;
        }
        self.decode_thread = try std.Thread.spawn(.{}, decodeLoop, .{self});
        self.decode_thread_started = true;
        self.lifecycle = .running;
    }

    /// Copy the next decoded PCM block into `out_buf`.
    /// Return the number of interleaved i32 values written.
    /// Block until a decoded block is available or the session ends.
    pub fn readFrame(self: *Reader, out_buf: []i32) !u32 {
        if (self.lifecycle != .running) return error.NotInitialized;
        try self.checkBgErr();
        const frame = if (self.pending_frame) |pending| blk: {
            self.pending_frame = null;
            break :blk pending;
        } else self.pcm_out_queue.pop() catch |e| switch (e) {
            error.Closed => {
                try self.checkBgErr();
                return error.ConnectionClosed;
            },
            error.Canceled => return error.QueueCanceled,
        };
        if (frame.samples.len > out_buf.len) {
            self.pending_frame = frame;
            return error.BufferTooSmall;
        }
        defer alloc.free(frame.samples);
        @memcpy(out_buf[0..frame.samples.len], frame.samples);
        return @intCast(frame.samples.len);
    }

    /// Request shutdown of sockets and close queues to stop blocked reader operations.
    /// On Linux, socket shutdown wakes a thread blocked in `accept()` or
    /// `recv()`. The usrsctp backend cannot reliably wake a blocked `accept()`.
    /// Call `deinit()` after any background threads have exited.
    pub fn cancel(self: *Reader) void {
        if (self.lifecycle == .uninitialized) return;
        if (self.transport_initialized) self.transport.cancel();
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
    }

    /// Stop all reader threads and release queue and transport resources.
    pub fn deinit(self: *Reader) void {
        if (self.lifecycle == .uninitialized) return;
        self.cleanup();
        self.lifecycle = .uninitialized;
    }

    fn checkBgErr(self: *Reader) !void {
        if (self.lifecycle == .uninitialized) return error.NotInitialized;
        self.bg_err_mutex.lockUncancelable(self.io);
        defer self.bg_err_mutex.unlock(self.io);
        if (self.bg_err) |e| return e;
    }

    fn setBgErr(self: *Reader, e: anyerror) void {
        self.bg_err_mutex.lockUncancelable(self.io);
        defer self.bg_err_mutex.unlock(self.io);
        if (self.bg_err == null) self.bg_err = e;
    }

    fn failBackground(self: *Reader, e: anyerror) void {
        self.setBgErr(e);
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
    }

    fn freeStartupBlocks(self: *Reader) void {
        for (self.startup_blocks.items) |block| alloc.free(block.data);
        self.startup_blocks.clearRetainingCapacity();
    }

    fn drainQueues(self: *Reader) void {
        if (self.block_queue_initialized) {
            while (true) {
                const block = self.block_queue.pop() catch break;
                alloc.free(block.data);
            }
        }
        if (self.pcm_queue_initialized) {
            while (true) {
                const frame = self.pcm_out_queue.pop() catch break;
                alloc.free(frame.samples);
            }
        }
    }

    fn clearPendingFrame(self: *Reader) void {
        if (self.pending_frame) |frame| alloc.free(frame.samples);
        self.pending_frame = null;
    }

    fn stopSession(self: *Reader) void {
        if (self.recv_thread_started or self.decode_thread_started) {
            self.transport.shutdownConn();
        }
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
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
        self.freeStartupBlocks();
        self.session_active = false;
        self.config_received = false;
        self.stream_config = null;
        self.lifecycle = .initialized;
    }

    fn cleanup(self: *Reader) void {
        if (self.transport_initialized) self.transport.shutdown();
        if (self.block_queue_initialized) self.block_queue.close();
        if (self.pcm_queue_initialized) self.pcm_out_queue.close();
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
        self.freeStartupBlocks();
        self.startup_blocks.deinit(alloc);
        self.startup_blocks = .empty;
        if (self.block_queue_initialized) {
            self.block_queue.deinit();
            self.block_queue_initialized = false;
        }
        if (self.pcm_queue_initialized) {
            self.pcm_out_queue.deinit();
            self.pcm_queue_initialized = false;
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

            const copy = alloc.dupe(u8, data) catch |e| {
                self.failBackground(e);
                break;
            };
            self.block_queue.push(.{ .data = copy }) catch {
                alloc.free(copy);
                break;
            };
        }
    }

    /// Run the decode thread.
    /// Prime `block_queue`, decode blocks, and push PCM into `pcm_out_queue`.
    ///
    /// Reuse a decode buffer that grows to the largest block seen.
    /// Only the final PCM slice needs a per-block allocation.
    ///
    /// Exit when `block_queue` closes or `pcm_out_queue` closes.
    /// Always close `pcm_out_queue` so `readFrame()` can return.
    fn decodeLoop(self: *Reader) void {
        defer self.pcm_out_queue.close();
        // Prime the jitter buffer before decoding.
        self.block_queue.waitForDepth(self.block_queue.capacity) catch |e| {
            self.setBgErr(e);
            return;
        };

        // Reusable decode buffer. Grow it to the largest block seen.
        var decode_buf: []i32 = &.{};
        defer if (decode_buf.len > 0) alloc.free(decode_buf);
        var first_block = true;

        while (true) {
            const block = self.block_queue.pop() catch break;
            defer alloc.free(block.data);

            // Read the header to determine the required decode size.
            const header = wpstream.validateBlock(block.data) catch {
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
                const block_channels = wpstream.Decoder.getNumChannels(block.data) catch {
                    self.failBackground(error.ProtocolError);
                    return;
                };
                const block_rate = wpstream.Decoder.getSampleRate(block.data) catch {
                    self.failBackground(error.ProtocolError);
                    return;
                };
                const block_bits = wpstream.Decoder.getBitsPerSample(block.data) catch {
                    self.failBackground(error.ProtocolError);
                    return;
                };
                if (block_channels != cfg.num_channels or
                    block_rate != cfg.sample_rate or
                    block_bits != cfg.bits_per_sample)
                {
                    self.failBackground(error.ProtocolError);
                    return;
                }
                first_block = false;
            }

            // Grow the decode buffer when needed.
            if (needed > decode_buf.len) {
                if (decode_buf.len > 0) alloc.free(decode_buf);
                decode_buf = alloc.alloc(i32, needed) catch {
                    self.failBackground(error.OutOfMemory);
                    return;
                };
            }

            const n = wpstream.Decoder.decodeFrame(block.data, decode_buf[0..needed]) catch |e| {
                self.failBackground(e);
                return;
            };
            if (n == 0) continue;

            const copy = alloc.dupe(i32, decode_buf[0..n]) catch {
                self.failBackground(error.OutOfMemory);
                return;
            };
            self.pcm_out_queue.push(.{ .samples = copy }) catch {
                alloc.free(copy);
                break;
            };
        }
    }
};
