const std = @import("std");

/// Low-level WavPack-stream bindings and encoder types.
pub const wpstream = @import("wpstream.zig");
/// Platform-selected SCTP transport types and address helpers.
pub const sctp = @import("sctp.zig");
/// Threaded PCM encoder and SCTP sender.
pub const Writer = @import("writer.zig").Writer;
/// Threaded SCTP receiver and PCM decoder.
pub const Reader = @import("reader.zig").Reader;
/// Stream properties received from a writer.
pub const StreamConfig = @import("reader.zig").StreamConfig;
/// Wire and buffer sizing rules.
pub const protocol = @import("protocol.zig");

const SocketAddr = sctp.SocketAddr;

/// C-compatible WavPack-stream configuration.
///
/// Boolean fields use u8: 0 = false, non-zero = true.
/// The transport supports one or two channels and 16 or 24 bits per sample.
pub const WpConfig = extern struct {
    /// Sample rate in samples per second. The default is 44100.
    sample_rate: u32 = 44100,
    /// Number of interleaved channels. Supported values are 1 and 2.
    num_channels: u16 = 2,
    /// Bits per sample. Supported values are 16 and 24.
    bits_per_sample: u8 = 16,
    /// Reserved padding for the C ABI.
    _pad0: u8 = 0,
    /// Microsoft-style channel mask. Zero derives a mask from the channel count.
    channel_mask: i32 = 0,
    /// Quality selector: 0 default, 1 fast, 2 high, 3 very high.
    quality: u8 = 0,
    /// Nonzero enables no-delay cross-channel decorrelation.
    cross_decorr: u8 = 0,
    /// Joint stereo selector: 0 auto, 1 force on, 2 force off.
    joint_stereo: u8 = 0,
    /// Reserved padding for the C ABI.
    _pad1: u8 = 0,

    /// Convert this C configuration to the typed WavPack configuration.
    /// Return error.UnsupportedConfig for an unsupported channel count or bit depth.
    fn toZig(self: WpConfig) !wpstream.Config {
        const cfg: wpstream.Config = .{
            .sample_rate = self.sample_rate,
            .num_channels = self.num_channels,
            .bits_per_sample = self.bits_per_sample,
            .channel_mask = self.channel_mask,
            .quality = switch (self.quality) {
                1 => .fast,
                2 => .high,
                3 => .very_high,
                else => .default,
            },
            .joint_stereo = switch (self.joint_stereo) {
                1 => .force_on,
                2 => .force_off,
                else => .auto,
            },
            .cross_decorr = self.cross_decorr != 0,
        };
        try cfg.validate();
        return cfg;
    }
};

/// Return the default WavPack-stream configuration.
export fn swps_wp_config_default() WpConfig {
    return .{};
}

/// C-compatible SCTP sender configuration.
pub const SctpConfig = extern struct {
    /// Nonzero disables Nagle-style batching. The default is 1.
    nodelay: u8 = 1,
    /// Reserved padding for the C ABI.
    _pad0: u8 = 0,
    /// Remote RFC 6951 UDP port. Zero disables Linux encapsulation.
    udp_encaps_port: u16 = 0,
    /// Linux SO_SNDBUF size in bytes. Zero selects the system default.
    sndbuf_size: u32 = 0,

    /// Convert this C configuration to the typed SCTP sender configuration.
    fn toZig(self: SctpConfig) sctp.SctpSender.Config {
        return .{
            .nodelay = self.nodelay != 0,
            .sndbuf_size = self.sndbuf_size,
            .udp_encaps_port = self.udp_encaps_port,
        };
    }
};

/// Return the default SCTP sender configuration.
export fn swps_sctp_config_default() SctpConfig {
    return .{};
}

/// Return the process-wide Io context used by C ABI objects.
///
/// This is the only place where the library creates an Io. The C ABI cannot
/// accept a Zig Io value, so the exported wrappers supply this context to the
/// Zig API. Zig callers must pass their own Io to Writer, Reader, and the
/// transport constructors.
///
/// This uses `std.Io.Threaded.global_single_threaded`. That instance does not
/// support concurrency or cancellation, which is safe here for two reasons:
/// the mutex, condition, event, and semaphore primitives are futex-based and
/// independent of the owning instance, and the C ABI never requests
/// cancellation. Blocking waits therefore work correctly across threads.
/// The instance needs no explicit setup or teardown.
fn cApiIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Return the allocator used by C ABI handles and objects.
///
/// This is the only allocator the library creates. Zig callers pass their own
/// allocator to Writer.init() and Reader.init().
fn cApiAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

/// Allocate a writer handle.
/// Return null when allocation fails.
export fn swps_writer_create() ?*Writer {
    const w = cApiAllocator().create(Writer) catch return null;
    w.initUninitialized();
    return w;
}

/// Initialize a writer and connect it to the destination address.
///
/// The address uses a 16-byte buffer, a host-order port, and a family selector.
/// Family 4 selects IPv4 and reads the first 4 bytes. Family 6 selects IPv6
/// and reads all 16 bytes. Keep w at a stable address while it is initialized.
/// Return 0 on success and -1 on failure.
export fn swps_writer_init(
    w: ?*Writer,
    wp_cfg: ?*const WpConfig,
    sctp_cfg: ?*const SctpConfig,
    ip: ?[*]const u8,
    port: u16,
    family: u8,
) c_int {
    const writer = w orelse return -1;
    const wp_config = wp_cfg orelse return -1;
    const sctp_config = sctp_cfg orelse return -1;
    const ip_ptr = ip orelse return -1;
    const dest: SocketAddr = switch (family) {
        4 => SocketAddr.parseIp4(ip_ptr[0..4].*, port),
        6 => SocketAddr.parseIp6(ip_ptr[0..16].*, port, 0),
        else => return -1,
    };

    writer.init(.{
        .wp = wp_config.toZig() catch return -1,
        .sctp = sctp_config.toZig(),
    }, dest, cApiIo()) catch return -1;
    return 0;
}

/// Queue interleaved signed PCM values widened to i32.
///
/// num_i32 is a value count, not a frame count. It must be divisible by the
/// configured channel count and at most 16384. The input is copied before this
/// function returns. Return 0 on success and -1 on failure.
export fn swps_writer_write(w: ?*Writer, samples: ?[*]const i32, num_i32: u32) c_int {
    const writer = w orelse return -1;
    const values: []const i32 = if (num_i32 == 0)
        &.{}
    else
        (samples orelse return -1)[0..num_i32];
    writer.write(values) catch return -1;
    return 0;
}

/// Queue interleaved signed PCM values widened to i32 without blocking.
///
/// num_i32 is a value count, not a frame count. It must be divisible by the
/// configured channel count and at most 16384. The input is copied before this
/// function returns. Return 0 on success and -1 on failure, including a full
/// PCM ring.
export fn swps_writer_try_write(w: ?*Writer, samples: ?[*]const i32, num_i32: u32) c_int {
    const writer = w orelse return -1;
    const values: []const i32 = if (num_i32 == 0)
        &.{}
    else
        (samples orelse return -1)[0..num_i32];
    writer.tryWrite(values) catch return -1;
    return 0;
}

/// Flush all queued PCM and wait for its encoded blocks to be sent.
/// Return 0 on success and -1 on failure.
export fn swps_writer_flush(w: ?*Writer) c_int {
    const writer = w orelse return -1;
    writer.flush() catch return -1;
    return 0;
}

/// Check whether a background thread has reported a fatal error.
/// Returns 0 if the writer is healthy, -1 if an error has occurred.
/// Non-blocking. Safe from another thread while the writer is initialized and
/// is not being destroyed.
export fn swps_writer_check(w: ?*Writer) c_int {
    const writer = w orelse return -1;
    writer.checkBgErr() catch return -1;
    return 0;
}

/// Stop a writer without freeing its allocation.
/// The handle can be initialized again after this call.
export fn swps_writer_deinit(w: ?*Writer) void {
    if (w) |writer| writer.deinit();
}

/// Stop a writer and free its allocation.
export fn swps_writer_destroy(w: ?*Writer) void {
    const writer = w orelse return;
    writer.deinit();
    cApiAllocator().destroy(writer);
}

/// Interrupt a writer initialization blocked in the Linux connect syscall.
/// Safe to call from another thread. No-op when no connect is in progress.
/// The usrsctp backend does not expose a cancellable file descriptor.
export fn swps_writer_cancel_connect(w: ?*Writer) void {
    if (w) |writer| writer.cancelConnect();
}

/// Acquire one reference to the process-wide SCTP stack.
/// The usrsctp backend uses local_port, with zero selecting port 9899.
/// Linux returns success without changing process state.
/// Return 0 on success and -1 on failure.
export fn swps_stack_acquire(local_port: u16) c_int {
    sctp.acquireStack(local_port, cApiIo()) catch return -1;
    return 0;
}

/// Release one reference to the process-wide SCTP stack.
export fn swps_stack_release() void {
    sctp.releaseStack(cApiIo());
}

/// C-compatible SCTP receiver configuration.
/// Boolean fields use u8: 0 = false, non-zero = true.
pub const SctpRecvConfig = extern struct {
    /// Nonzero disables Nagle-style batching. The default is 1.
    nodelay: u8 = 1,
    /// Reserved padding for the C ABI.
    _pad0: u8 = 0,
    /// Remote peer UDP encapsulation port. Zero leaves the peer port unset.
    udp_encaps_port: u16 = 0,
    /// Linux SO_RCVBUF size in bytes. Zero selects the system default.
    rcvbuf_size: u32 = 0,

    /// Convert the C configuration to the typed SCTP receiver configuration.
    fn toZig(self: SctpRecvConfig) sctp.SctpReceiver.Config {
        return .{
            .nodelay = self.nodelay != 0,
            .rcvbuf_size = self.rcvbuf_size,
            .udp_encaps_port = self.udp_encaps_port,
        };
    }
};

/// C-compatible stream properties returned by the reader.
/// The values come from the writer's control message.
/// Both configuration functions fill this structure.
pub const SwpsStreamConfig = extern struct {
    /// Sample rate in samples per second.
    sample_rate: u32,
    /// Number of interleaved channels.
    num_channels: u16,
    /// Bits per sample.
    bits_per_sample: u8,
    /// Reserved padding for the C ABI.
    _pad: u8,
};

/// Return the default SCTP receiver configuration.
export fn swps_sctp_recv_config_default() SctpRecvConfig {
    return .{};
}

/// Allocate a reader handle.
/// Return null when allocation fails.
export fn swps_reader_create() ?*Reader {
    const r = cApiAllocator().create(Reader) catch return null;
    r.initUninitialized();
    return r;
}

/// Initialize a reader, bind it to the address, and start listening.
///
/// `ip` points to a 16-byte address buffer. Family 4 reads the first 4 bytes.
/// Family 6 reads all 16 bytes. `port` is in host byte order. Zero requests
/// an ephemeral port. Return 0 on success and -1 on failure.
export fn swps_reader_init(
    r: ?*Reader,
    sctp_cfg: ?*const SctpRecvConfig,
    ip: ?[*]const u8,
    port: u16,
    family: u8,
) c_int {
    const reader = r orelse return -1;
    const sctp_config = sctp_cfg orelse return -1;
    const ip_ptr = ip orelse return -1;
    const bind_addr: SocketAddr = switch (family) {
        4 => SocketAddr.parseIp4(ip_ptr[0..4].*, port),
        6 => SocketAddr.parseIp6(ip_ptr[0..16].*, port, 0),
        else => return -1,
    };

    reader.init(cApiAllocator(), .{
        .sctp = sctp_config.toZig(),
    }, bind_addr, cApiIo()) catch return -1;
    return 0;
}

/// Accept one incoming writer association.
/// Block until a sender connects. This does not start the receive thread.
/// Call swps_reader_recv_config() next. Return 0 on success and -1 on failure.
export fn swps_reader_accept(r: ?*Reader, sctp_cfg: ?*const SctpRecvConfig) c_int {
    const reader = r orelse return -1;
    const sctp_config = sctp_cfg orelse return -1;
    reader.accept(.{
        .sctp = sctp_config.toZig(),
    }) catch return -1;
    return 0;
}

/// Read stream properties from the control channel.
/// Block until the sender's control message arrives. Call this after accept
/// and before start. Return 0 on success and -1 on transport or protocol error.
export fn swps_reader_recv_config(r: ?*Reader, out: ?*SwpsStreamConfig) c_int {
    const reader = r orelse return -1;
    const output = out orelse return -1;
    const cfg = reader.recvConfig() catch return -1;
    output.sample_rate = cfg.sample_rate;
    output.num_channels = cfg.num_channels;
    output.bits_per_sample = cfg.bits_per_sample;
    output._pad = 0;
    return 0;
}

/// Start the reader background threads.
/// `buffer_blocks` is the receive queue capacity in WavPack-stream blocks.
/// It must be between 1 and 65536. The queue is pre-filled before the first
/// read_frame call returns. Return 0 on success and -1 on failure.
export fn swps_reader_start(r: ?*Reader, buffer_blocks: u32) c_int {
    const reader = r orelse return -1;
    reader.start(@intCast(buffer_blocks)) catch return -1;
    return 0;
}

/// Receive one decoded block of interleaved signed PCM values.
/// Block until a block arrives or the session ends. `out_buf_cap` is measured
/// in int32_t values. Store the number written in `out_len`.
/// Return 0 on success and -1 on failure. When the buffer is too small, the
/// frame is retained and `out_len` receives the required value count.
export fn swps_reader_read_frame(
    r: ?*Reader,
    out_buf: ?[*]i32,
    out_buf_cap: u32,
    out_len: ?*u32,
) c_int {
    const reader = r orelse return -1;
    const output_len = out_len orelse return -1;
    const output: []i32 = if (out_buf_cap == 0)
        &.{}
    else
        (out_buf orelse return -1)[0..out_buf_cap];
    const n = reader.readFrame(output) catch |err| switch (err) {
        error.BufferTooSmall => {
            if (reader.pendingFrameLen()) |required| output_len.* = required;
            return -1;
        },
        else => return -1,
    };
    output_len.* = n;
    return 0;
}

/// Poll for a new incoming sender without blocking.
/// Return 1 when a sender is pending for swps_reader_next_session().
/// Return 0 when no sender is pending.
export fn swps_reader_poll_new_sender(r: ?*Reader) c_int {
    const reader = r orelse return 0;
    return if (reader.checkNewSender()) 1 else 0;
}

/// End the current session and transition to the next sender.
/// Promote a pending sender when poll_new_sender() returned 1. Otherwise,
/// block until a sender connects. Read the new stream properties into `out`.
/// The reader is stopped after this call. Call start() before reading again.
/// Return 0 on success and -1 on failure.
export fn swps_reader_next_session(r: ?*Reader, out: ?*SwpsStreamConfig) c_int {
    const reader = r orelse return -1;
    const output = out orelse return -1;
    const cfg = reader.nextSession() catch return -1;
    output.sample_rate = cfg.sample_rate;
    output.num_channels = cfg.num_channels;
    output.bits_per_sample = cfg.bits_per_sample;
    output._pad = 0;
    return 0;
}

/// Request shutdown of reader I/O. Join workers with swps_reader_destroy().
export fn swps_reader_cancel(r: ?*Reader) void {
    if (r) |reader| reader.cancel();
}

/// Stop the reader, close its sockets, and free its allocation.
export fn swps_reader_destroy(r: ?*Reader) void {
    const reader = r orelse return;
    reader.deinit();
    cApiAllocator().destroy(reader);
}

test {
    _ = wpstream;
    _ = @import("queue.zig");
    _ = sctp;
    _ = @import("tests.zig");
}

test "WpConfig.toZig" {
    const testing = std.testing;

    // Verify default values.
    const def = try (WpConfig{}).toZig();
    try testing.expectEqual(def.sample_rate, 44100);
    try testing.expectEqual(def.num_channels, 2);
    try testing.expectEqual(def.bits_per_sample, 16);
    try testing.expectEqual(def.quality, .default);
    try testing.expectEqual(def.joint_stereo, .auto);

    // Verify quality mapping.
    try testing.expectEqual((try (WpConfig{ .quality = 1 }).toZig()).quality, .fast);
    try testing.expectEqual((try (WpConfig{ .quality = 2 }).toZig()).quality, .high);
    try testing.expectEqual((try (WpConfig{ .quality = 3 }).toZig()).quality, .very_high);
    try testing.expectEqual((try (WpConfig{ .quality = 255 }).toZig()).quality, .default);

    // Verify joint-stereo mapping.
    try testing.expectEqual((try (WpConfig{ .joint_stereo = 0 }).toZig()).joint_stereo, .auto);
    try testing.expectEqual((try (WpConfig{ .joint_stereo = 1 }).toZig()).joint_stereo, .force_on);
    try testing.expectEqual((try (WpConfig{ .joint_stereo = 2 }).toZig()).joint_stereo, .force_off);
    try testing.expectEqual((try (WpConfig{ .joint_stereo = 99 }).toZig()).joint_stereo, .auto);

    // Verify cross-channel decorrelation mapping.
    try testing.expect((try (WpConfig{ .cross_decorr = 1 }).toZig()).cross_decorr);
    try testing.expect(!(try (WpConfig{ .cross_decorr = 0 }).toZig()).cross_decorr);

    // Reject unsupported format values.
    try testing.expectError(error.UnsupportedConfig, (WpConfig{ .num_channels = 3 }).toZig());
    try testing.expectError(error.UnsupportedConfig, (WpConfig{ .num_channels = 0 }).toZig());
    try testing.expectError(error.UnsupportedConfig, (WpConfig{ .bits_per_sample = 32 }).toZig());
    try testing.expectError(error.UnsupportedConfig, (WpConfig{ .bits_per_sample = 8 }).toZig());
    try testing.expectError(error.UnsupportedConfig, (WpConfig{ .sample_rate = 0 }).toZig());
    try testing.expectError(error.UnsupportedConfig, (WpConfig{ .sample_rate = 0xFFFFFFFF }).toZig());
}

test "SctpConfig.toZig" {
    const testing = std.testing;
    const def = (SctpConfig{}).toZig();
    try testing.expect(def.nodelay);
    try testing.expectEqual(def.sndbuf_size, 0);
    try testing.expectEqual(def.udp_encaps_port, 0);

    const custom = (SctpConfig{ .nodelay = 0, .sndbuf_size = 65536, .udp_encaps_port = 9899 }).toZig();
    try testing.expect(!custom.nodelay);
    try testing.expectEqual(custom.sndbuf_size, 65536);
    try testing.expectEqual(custom.udp_encaps_port, 9899);
}

test "SctpRecvConfig.toZig" {
    const testing = std.testing;
    const def = (SctpRecvConfig{}).toZig();
    try testing.expect(def.nodelay);
    try testing.expectEqual(def.rcvbuf_size, 0);
    try testing.expectEqual(def.udp_encaps_port, 0);

    const custom = (SctpRecvConfig{ .nodelay = 0, .rcvbuf_size = 131072, .udp_encaps_port = 9899 }).toZig();
    try testing.expect(!custom.nodelay);
    try testing.expectEqual(custom.rcvbuf_size, 131072);
    try testing.expectEqual(custom.udp_encaps_port, 9899);
}

test "Writer sizing is fixed at compile time" {
    try std.testing.expectEqual(protocol.max_pcm_chunk_samples, Writer.max_chunk_samples);
    try std.testing.expectEqual(protocol.pcm_ring_slots, Writer.pcm_slots);
    try std.testing.expectEqual(@as(usize, 16384), Writer.max_chunk_samples);
}

test "C ABI functions return codes" {
    const testing = std.testing;

    // Default functions must return initialized structures.
    const wp_def = swps_wp_config_default();
    try testing.expectEqual(wp_def.sample_rate, 44100);
    try testing.expectEqual(wp_def.num_channels, 2);
    try testing.expectEqual(wp_def.bits_per_sample, 16);

    const sctp_def = swps_sctp_config_default();
    try testing.expectEqual(sctp_def.nodelay, 1);
    try testing.expectEqual(sctp_def.udp_encaps_port, 0);
    try testing.expectEqual(sctp_def.sndbuf_size, 0);

    const recv_def = swps_sctp_recv_config_default();
    try testing.expectEqual(recv_def.nodelay, 1);
    try testing.expectEqual(recv_def.udp_encaps_port, 0);
    try testing.expectEqual(recv_def.rcvbuf_size, 0);

    const empty_w = swps_writer_create() orelse return;
    swps_writer_deinit(empty_w);
    swps_writer_destroy(empty_w);
    const empty_r = swps_reader_create() orelse return;
    swps_reader_cancel(empty_r);
    swps_reader_destroy(empty_r);

    // An invalid family must return -1 instead of crashing.
    const w = swps_writer_create() orelse return;
    defer swps_writer_destroy(w);
    var ip_buf = [_]u8{ 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(swps_writer_check(w), -1);
    swps_writer_cancel_connect(w);
    try testing.expectEqual(swps_writer_write(w, null, 0), -1);
    try testing.expectEqual(swps_writer_try_write(w, null, 0), -1);
    try testing.expectEqual(swps_writer_init(w, &wp_def, &sctp_def, &ip_buf, 5000, 99), -1);

    // The reader must reject an invalid family in the same way.
    const r = swps_reader_create() orelse return;
    defer swps_reader_destroy(r);
    try testing.expectEqual(swps_reader_init(r, &recv_def, &ip_buf, 5000, 99), -1);
    try testing.expectEqual(swps_reader_poll_new_sender(r), 0);
    swps_reader_cancel(r);

    // Null pointers must fail without dereferencing them.
    try testing.expectEqual(swps_writer_init(null, &wp_def, &sctp_def, &ip_buf, 5000, 4), -1);
    try testing.expectEqual(swps_reader_init(null, &recv_def, &ip_buf, 5000, 4), -1);
    try testing.expectEqual(swps_writer_write(null, null, 0), -1);
    try testing.expectEqual(swps_reader_read_frame(null, null, 0, null), -1);

    // Exercise the stack reference API. It is a no-op on Linux.
    try testing.expectEqual(swps_stack_acquire(0), 0);
    swps_stack_release();
}
