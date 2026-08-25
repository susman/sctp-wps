/// Threaded WavPack-stream encoder and SCTP sender.
///
/// `write()` copies PCM into a bounded queue. The encode thread consumes that
/// queue and produces WavPack blocks. The network thread sends each block on
/// SCTP stream 1. A single-slot handoff keeps each encoded block in place
/// until the network thread finishes sending it.
///
/// Slow network output creates backpressure. It can block `write()` when the
/// PCM queue is full. `flush()` waits for the encoder and network thread.
/// `deinit()` closes the queues, joins both threads, and releases resources.
///
/// Keep the Writer at a stable address after initialization. WavPack stores an
/// internal pointer to the Encoder and the callback context refers to Writer.
const std = @import("std");
const wpstream = @import("wpstream.zig");
const sctp = @import("sctp.zig");
const BoundedQueue = @import("queue.zig").BoundedQueue;
const BlockHandoff = @import("queue.zig").BlockHandoff;
const ctrl = @import("control_channel.zig");
const SocketAddr = sctp.SocketAddr;
const alloc = std.heap.c_allocator;
const max_pcm_buffer_depth = 1 << 16;

/// PCM values queued for the encoder, or a flush sentinel.
/// `write()` allocates and owns the sample copy. The encode thread frees it
/// after encoding.
///
/// A flush sentinel has `is_flush` set and an empty sample slice. It tells the
/// encode thread to flush the encoder and post `flush_sem`.
const PcmFrames = struct {
    samples: []i32, // Heap-allocated copy of the caller's samples.
    is_flush: bool, // True for a flush sentinel with no samples.
};

/// A threaded WavPack-stream writer with SCTP transport.
pub const Writer = struct {
    pub const Lifecycle = enum { uninitialized, initializing, initialized };

    /// Resource state used to make failed initialization and destruction safe.
    lifecycle: Lifecycle = .uninitialized,
    /// WavPack-stream encoder context.
    encoder: wpstream.Encoder,
    /// SCTP sender transport.
    transport: sctp.SctpSender,
    /// PCM values queued for the encoder thread.
    pcm_queue: BoundedQueue(PcmFrames),
    /// Synchronizes `flush()` with the encoder thread.
    /// The encoder posts it after processing a flush sentinel.
    flush_sem: std.Io.Semaphore = .{},
    /// Handoff from the encoder callback to the network thread.
    block_handoff: BlockHandoff,
    /// Background thread that encodes queued PCM.
    encode_thread: std.Thread,
    /// Background thread that sends encoded blocks.
    network_thread: std.Thread,
    /// First fatal error reported by a background thread.
    /// `write()` and `flush()` check this before queueing work.
    bg_err: ?anyerror,
    bg_err_mutex: std.Io.Mutex = .init,
    /// True after the encoder thread is spawned.
    encode_started: bool = false,
    network_started: bool = false,
    transport_initialized: bool = false,
    encoder_initialized: bool = false,
    pcm_queue_initialized: bool = false,
    handoff_initialized: bool = false,
    /// Atomic state used to interrupt a Linux connect call.
    connect_state: sctp.ConnectState = .{},
    /// Configured interleaved channel count.
    configured_channels: u16 = 0,
    /// Shared Io context for queues and synchronization.
    io: std.Io,

    /// Configuration for a Writer.
    pub const Config = struct {
        /// WavPack-stream encoder configuration.
        wp: wpstream.Config = .{},
        /// SCTP sender configuration.
        sctp: sctp.SctpSender.Config = .{},
        /// PCM queue capacity. Must be between 1 and 65536. The default is 8.
        pcm_buffer_depth: usize = 8,
    };

    /// Initialize the writer in place.
    /// Connect to `dest`, configure WavPack-stream, send stream metadata, and
    /// start the encoder and network threads.
    ///
    /// WavPack-stream block size calculation:
    /// The writer queries the SCTP maximum segment size after connecting.
    /// It rounds the value down to four-byte alignment and subtracts two.
    /// This matches WavPack-stream block alignment and limits fragmentation.
    ///
    /// The `io` context must outlive the Writer.
    pub fn init(self: *Writer, cfg: Config, dest: SocketAddr, io: std.Io) !void {
        if (self.lifecycle != .uninitialized) return error.AlreadyInitialized;
        if (cfg.pcm_buffer_depth == 0 or cfg.pcm_buffer_depth > max_pcm_buffer_depth) {
            return error.InvalidDepth;
        }
        try cfg.wp.validate();

        self.lifecycle = .initializing;
        self.encode_started = false;
        self.network_started = false;
        self.transport_initialized = false;
        self.encoder_initialized = false;
        self.pcm_queue_initialized = false;
        self.handoff_initialized = false;
        self.connect_state = .{};
        self.configured_channels = cfg.wp.num_channels;
        self.io = io;
        self.bg_err = null;
        self.bg_err_mutex = .init;
        errdefer {
            self.cleanup();
            self.lifecycle = .uninitialized;
        }

        // Stream 0 carries metadata. Stream 1 carries encoded audio blocks.
        const num_sctp_streams: u16 = 2;

        self.transport = try sctp.SctpSender.init(dest, num_sctp_streams, cfg.sctp, &self.connect_state, io);
        self.transport_initialized = true;

        self.encoder = .{
            .wpc = null,
            .block_output = &blockOutputCallback,
            .user_ctx = @ptrCast(self),
        };
        var wp = cfg.wp;
        // Size blocks from the connected transport limit.
        const mss = self.transport.maxSegSize();
        wp.block_bytes = @intCast((mss & ~@as(u32, 3)) -| 2);
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

        self.pcm_queue = try BoundedQueue(PcmFrames).init(alloc, io, cfg.pcm_buffer_depth);
        self.pcm_queue_initialized = true;
        self.flush_sem = .{};
        self.block_handoff = BlockHandoff.init(io);
        self.handoff_initialized = true;

        self.encode_thread = try std.Thread.spawn(.{}, encodeLoop, .{self});
        self.encode_started = true;
        self.network_thread = try std.Thread.spawn(.{}, networkLoop, .{self});
        self.network_started = true;
        self.lifecycle = .initialized;
    }

    /// Queue interleaved PCM values widened to i32.
    /// The slice length must be a multiple of the configured channel count.
    /// The input is copied before this function returns.
    /// Return a background error when one has been recorded.
    pub fn write(self: *Writer, samples: []i32) !void {
        if (self.lifecycle != .initialized) return error.NotInitialized;
        try self.checkBgErr();
        if (samples.len % @as(usize, self.configured_channels) != 0) {
            return error.InvalidSampleCount;
        }
        const copy = try alloc.dupe(i32, samples);
        errdefer alloc.free(copy);
        // Map queue shutdown errors to the writer-level error.
        self.pcm_queue.push(.{ .samples = copy, .is_flush = false }) catch |e| switch (e) {
            error.Closed, error.Canceled => return error.QueueClosed,
        };
    }

    /// Flush all buffered samples.
    /// Block until the encoder has emitted and the network thread has sent them.
    pub fn flush(self: *Writer) !void {
        if (self.lifecycle != .initialized) return error.NotInitialized;
        try self.checkBgErr();
        self.pcm_queue.push(.{ .samples = &.{}, .is_flush = true }) catch |e| switch (e) {
            error.Closed, error.Canceled => return error.QueueClosed,
        };
        // Use an uncancelable wait so the flush sentinel is always observed.
        self.flush_sem.waitUncancelable(self.io);
        try self.checkBgErr();
    }

    /// Cancel a connect operation when the backend supports it.
    pub fn cancelConnect(self: *Writer) void {
        if (self.lifecycle != .initializing) return;
        sctp.cancelConnect(&self.connect_state);
    }

    /// Shut down the pipeline and release its resources.
    pub fn deinit(self: *Writer) void {
        if (self.lifecycle == .uninitialized) return;
        self.cleanup();
        self.lifecycle = .uninitialized;
    }

    /// Check for a fatal background error without waiting for pipeline work.
    pub fn checkBgErr(self: *Writer) !void {
        if (self.lifecycle == .uninitialized) return error.NotInitialized;
        self.bg_err_mutex.lockUncancelable(self.io);
        defer self.bg_err_mutex.unlock(self.io);
        if (self.bg_err) |e| return e;
    }

    /// Record the first fatal background error.
    /// Later errors are ignored.
    fn setBgErr(self: *Writer, e: anyerror) void {
        self.bg_err_mutex.lockUncancelable(self.io);
        defer self.bg_err_mutex.unlock(self.io);
        if (self.bg_err == null) {
            self.bg_err = e;
            // Wake a flush waiting for a sentinel that cannot be processed.
            self.flush_sem.post(self.io);
        }
    }

    /// Stop workers and release resources in dependency order.
    /// This is also used by the initialization error path.
    fn cleanup(self: *Writer) void {
        if (self.transport_initialized) self.transport.shutdown();
        if (self.pcm_queue_initialized) self.pcm_queue.close();
        if (self.handoff_initialized) self.block_handoff.signalDone();

        if (self.encode_started) {
            self.encode_thread.join();
            self.encode_started = false;
        }
        if (self.network_started) {
            self.network_thread.join();
            self.network_started = false;
        }

        if (self.pcm_queue_initialized) {
            while (true) {
                const frames = self.pcm_queue.pop() catch break;
                alloc.free(frames.samples);
            }
            self.pcm_queue.deinit();
            self.pcm_queue_initialized = false;
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
    }

    /// Run the encoder thread.
    /// Drain `pcm_queue` until it is closed. Encode each PCM item and hand
    /// completed blocks to the network thread. Flush sentinels post `flush_sem`.
    /// Signal the handoff when the queue is drained.
    fn encodeLoop(self: *Writer) void {
        while (true) {
            const frames = self.pcm_queue.pop() catch |e| switch (e) {
                error.Closed, error.Canceled => break,
            };
            if (frames.is_flush) {
                if (!self.block_handoff.isDone()) {
                    self.encoder.flush() catch |e| {
                        self.setBgErr(e);
                        self.pcm_queue.close();
                    };
                }
                self.flush_sem.post(self.io);
                self.checkBgErr() catch break;
                continue;
            }
            defer alloc.free(frames.samples);
            if (!self.block_handoff.isDone()) {
                self.encoder.packSamples(frames.samples) catch |e| {
                    self.setBgErr(e);
                    self.pcm_queue.close();
                    break;
                };
            }
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
            self.transport.send(1, data) catch |e| {
                self.setBgErr(e);
                self.block_handoff.ack(false);
                self.block_handoff.signalDone();
                self.pcm_queue.close();
                return;
            };
            self.block_handoff.ack(true);
        }
    }
};
