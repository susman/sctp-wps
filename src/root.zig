const std = @import("std");
const builtin = @import("builtin");

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

const SocketAddr = sctp.SocketAddr;

const alloc = std.heap.c_allocator;

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
        // Validate the format fields before constructing the typed config.
        if (self.num_channels < 1 or self.num_channels > 2) {
            return error.UnsupportedConfig;
        }
        if (self.bits_per_sample != 16 and self.bits_per_sample != 24) {
            return error.UnsupportedConfig;
        }
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
/// The context is initialized by the standard library. It needs no explicit
/// setup or teardown. Its mutex, condition, and semaphore operations use
/// kernel-backed synchronization.
fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Allocate a writer handle.
/// Return null when allocation fails.
export fn swps_writer_create() ?*Writer {
    const w = alloc.create(Writer) catch return null;
    w.lifecycle = .uninitialized;
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
    }, dest, defaultIo()) catch return -1;
    return 0;
}

/// Queue interleaved signed PCM values widened to i32.
///
/// num_i32 is a value count, not a frame count. It must be divisible by the
/// configured channel count. The input is copied before this function returns.
/// Return 0 on success and -1 on failure.
export fn swps_writer_write(w: ?*Writer, samples: ?[*]i32, num_i32: u32) c_int {
    const writer = w orelse return -1;
    const values: []i32 = if (num_i32 == 0)
        &.{}
    else
        (samples orelse return -1)[0..num_i32];
    writer.write(values) catch return -1;
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
/// Non-blocking; safe to call from any thread at any time.
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
    alloc.destroy(writer);
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
    sctp.acquireStack(local_port, defaultIo()) catch return -1;
    return 0;
}

/// Release one reference to the process-wide SCTP stack.
export fn swps_stack_release() void {
    sctp.releaseStack();
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
    const r = alloc.create(Reader) catch return null;
    r.lifecycle = .uninitialized;
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

    reader.init(.{
        .sctp = sctp_config.toZig(),
    }, bind_addr, defaultIo()) catch return -1;
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
/// Return 0 on success and -1 on failure.
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
    const n = reader.readFrame(output) catch return -1;
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
    alloc.destroy(reader);
}

test {
    _ = wpstream;
    _ = @import("queue.zig");
    _ = sctp;
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

test "Writer rejects invalid queue depth before transport setup" {
    var writer: Writer = undefined;
    writer.lifecycle = .uninitialized;
    try std.testing.expectError(
        error.InvalidDepth,
        writer.init(.{ .pcm_buffer_depth = 0 }, SocketAddr.loopbackIp4(1), std.testing.io),
    );
}

test "Writer -> Reader lossless round-trip over loopback" {
    // Linux supports an in-process loopback test with kernel SCTP.
    // The usrsctp tests use a separate peer process.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const posix = std.posix;
    const linux = std.os.linux;
    try requireNetworkSctp();

    // Use the test Io context for all synchronization and network calls.
    const io = std.testing.io;

    // Bind the reader to an ephemeral loopback port.
    const reader = try alloc.create(Reader);
    defer alloc.destroy(reader);
    reader.lifecycle = .uninitialized;
    const bind_addr = SocketAddr.loopbackIp4(0);
    try reader.init(.{}, bind_addr, io);
    defer reader.deinit();

    // Read the port assigned by the operating system.
    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const rc = linux.getsockname(reader.transport.listen_fd, @ptrCast(&sa), &sa_len);
    if (@as(isize, @bitCast(rc)) < 0) return error.GetSockNameFailed;
    const bound = try SocketAddr.fromSockaddr(&sa, sa_len);
    const port = bound.getPort();

    // Connect the writer from a background thread.
    const writer = try alloc.create(Writer);
    var writer_initialized = false;
    defer {
        if (writer_initialized) writer.deinit();
        alloc.destroy(writer);
    }
    writer.lifecycle = .uninitialized;

    const dest_addr = SocketAddr.loopbackIp4(port);

    const ConnectThread = struct {
        fn run(w: *Writer, dest: SocketAddr, w_io: std.Io, result: *?anyerror) void {
            w.init(.{
                .wp = .{
                    .sample_rate = 44100,
                    .num_channels = 2,
                    .bits_per_sample = 16,
                },
            }, dest, w_io) catch |err| {
                result.* = err;
            };
        }
    };
    var connect_error: ?anyerror = null;
    const ct = try std.Thread.spawn(.{}, ConnectThread.run, .{ writer, dest_addr, io, &connect_error });

    var accept_error: ?anyerror = null;
    const AcceptThread = struct {
        fn run(r: *Reader, result: *?anyerror) void {
            r.accept(.{}) catch |err| {
                result.* = err;
            };
        }
    };
    const at = std.Thread.spawn(.{}, AcceptThread.run, .{ reader, &accept_error }) catch |err| {
        writer.cancelConnect();
        ct.join();
        return err;
    };
    ct.join();
    if (connect_error) |err| {
        reader.cancel();
        at.join();
        return err;
    }
    writer_initialized = true;
    at.join();
    if (accept_error) |err| return err;

    // Confirm that writer initialization succeeded.
    try writer.checkBgErr();

    const cfg = try reader.recvConfig();
    try std.testing.expectEqual(cfg.sample_rate, 44100);
    try std.testing.expectEqual(cfg.num_channels, 2);
    try std.testing.expectEqual(cfg.bits_per_sample, 16);

    try reader.start(1);

    // Generate and send a stereo sine wave.
    const num_frames = 1024;
    var input: [num_frames * 2]i32 = undefined;
    for (0..num_frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        input[i * 2] = val;
        input[i * 2 + 1] = val;
    }
    try writer.write(&input);
    try writer.flush();

    // Read decoded blocks until all samples arrive.
    var too_small: [0]i32 = .{};
    try std.testing.expectError(error.BufferTooSmall, reader.readFrame(&too_small));
    var output: [num_frames * 2]i32 = undefined;
    var total: u32 = 0;
    while (total < num_frames * 2) {
        const n = try reader.readFrame(output[total..]);
        total += n;
    }

    try std.testing.expectEqual(total, num_frames * 2);
    for (0..total) |i| {
        try std.testing.expectEqual(input[i], output[i]);
    }
}

test "SocketAddr IPv6 zone id handling" {
    const testing = std.testing;

    // A global IPv6 address uses interface .none for zone 0.
    const global_addr = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };
    const global = SocketAddr.parseIp6(global_addr, 443, 0);
    try testing.expectEqual(global.family(), std.posix.AF.INET6);
    try testing.expectEqual(global.getPort(), 443);
    // Zone 0 serializes as scope_id 0.
    var out_sa: std.posix.sockaddr.storage = undefined;
    var out_len: std.posix.socklen_t = 0;
    global.toSockaddr(&out_sa, &out_len);
    const out_in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&out_sa));
    try testing.expectEqual(out_in6.scope_id, 0);

    // Preserve a nonzero link-local zone as scope_id.
    // The kernel uses it to select the destination interface.
    const ll_addr = [16]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x42 };
    const ll = SocketAddr.parseIp6(ll_addr, 5683, 5);
    try testing.expectEqual(ll.getPort(), 5683);
    ll.toSockaddr(&out_sa, &out_len);
    const ll_in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&out_sa));
    try testing.expectEqual(ll_in6.scope_id, 5);

    // Convert the address back with fromSockaddr().
    const back = try SocketAddr.fromSockaddr(&out_sa, out_len);
    try testing.expectEqual(back.getPort(), 5683);
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

// ---------------------------------------------------------------------------
// Cross-process loopback tests use the sctp-wps-peer executable.
// usrsctp has one global UDP endpoint per process. A sender and receiver
// therefore use separate processes on macOS. Each process gets its own UDP
// port. Linux can use plain kernel SCTP, but it reuses the same peer tests.
// ---------------------------------------------------------------------------

const build_options = @import("build_options");

fn requireNetworkSctp() !void {
    if (builtin.os.tag == .macos) return;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const rc = std.os.linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, sctp.IPPROTO_SCTP);
    if (@as(isize, @bitCast(rc)) < 0) return error.SkipZigTest;
    _ = std.os.linux.close(@intCast(@as(isize, @bitCast(rc))));
}

const PeerResult = struct {
    term: ?std.process.Child.Term = null,
    spawned: bool = false,
    stdout: []u8 = "",
    stderr: []u8 = "",
};

/// Spawn a peer executable in a background thread.
/// Capture the peer's stdout and stderr in `out`.
/// Log stderr chunks while the peer is running.
fn spawnPeerThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    out: *PeerResult,
    inherit_stdio: bool,
    ready: *std.Io.Semaphore,
) !std.Thread {
    _ = inherit_stdio;
    const thread = try std.Thread.spawn(.{}, peerThreadMain, .{ allocator, io, argv, out, ready });
    ready.waitUncancelable(io);
    if (!out.spawned) {
        thread.join();
        return error.PeerSpawnFailed;
    }
    return thread;
}

fn peerThreadMain(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    out: *PeerResult,
    ready: *std.Io.Semaphore,
) void {
    // Pipe both output streams so stderr can be logged while the peer runs.
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        out.spawned = false;
        ready.post(io);
        return;
    };
    out.spawned = true;
    ready.post(io);

    // Drain stderr in this thread. Log each chunk for test diagnostics.
    var stderr_buf: std.ArrayListUnmanaged(u8) = .empty;
    var stdout_buf: std.ArrayListUnmanaged(u8) = .empty;

    var read_buf: [256]u8 = undefined;
    while (true) {
        // A zero-length read means that the child closed stderr.
        const stderr_file = child.stderr orelse break;
        const n = stderr_file.readStreaming(io, &.{read_buf[0..]}) catch break;
        if (n == 0) break;
        stderr_buf.appendSlice(allocator, read_buf[0..n]) catch break;
        std.log.debug("peer: {s}", .{read_buf[0..n]});
    }

    // Drain stdout after stderr reaches EOF.
    if (child.stdout) |stdout_file| {
        while (true) {
            const n = stdout_file.readStreaming(io, &.{read_buf[0..]}) catch break;
            if (n == 0) break;
            stdout_buf.appendSlice(allocator, read_buf[0..n]) catch break;
        }
    }

    const term = child.wait(io) catch null;
    out.* = .{
        .term = term,
        .spawned = true,
        .stdout = stdout_buf.toOwnedSlice(allocator) catch &.{},
        .stderr = stderr_buf.toOwnedSlice(allocator) catch &.{},
    };
}

/// Build the seven arguments required by the peer executable.
/// The returned slice points into `buf` and needs no allocation.
fn buildPeerArgv(
    buf: *[7][]const u8,
    peer_path: []const u8,
    mode: []const u8,
    port_str: []const u8,
    count_str: []const u8,
    channels_str: []const u8,
    udp_local_str: []const u8,
    udp_remote_str: []const u8,
) []const []const u8 {
    buf.* = .{ peer_path, mode, port_str, count_str, channels_str, udp_local_str, udp_remote_str };
    return buf[0..7];
}

/// Format a u16 in the supplied buffer and return the written slice.
fn u16ToSlice(buf: []u8, value: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch
        @panic("u16ToSlice: bufPrint failed");
}

test "SctpSender/SctpReceiver loopback with peer" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    // Use fixed SCTP and UDP ports for the two endpoints.
    const sctp_port: u16 = 5099;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    const num_bytes: usize = 4096;

    // The parent owns UDP port 9899 on macOS. This is a no-op on Linux.
    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack();

    var receiver = try sctp.SctpReceiver.init(
        SocketAddr.loopbackIp4(sctp_port),
        2,
        .{ .nodelay = true, .udp_encaps_port = udp_remote },
        io,
    );
    defer receiver.close();

    // Spawn the peer sender. It connects, sends a position modulo 256 pattern,
    // and exits.
    var port_buf: [8]u8 = undefined;
    var count_buf: [16]u8 = undefined;
    var udp_l_buf: [8]u8 = undefined;
    var udp_r_buf: [8]u8 = undefined;
    var argv_buf: [7][]const u8 = undefined;
    const argv = buildPeerArgv(
        &argv_buf,
        peer_path,
        "sender",
        u16ToSlice(&port_buf, sctp_port),
        u16ToSlice(&count_buf, @intCast(num_bytes)),
        "2",
        u16ToSlice(&udp_l_buf, udp_remote), // peer's local UDP port
        u16ToSlice(&udp_r_buf, udp_local), // parent's UDP port
    );

    var peer_result = PeerResult{};
    var peer_ready: std.Io.Semaphore = .{};
    const pt = try spawnPeerThread(alloc, io, argv, &peer_result, builtin.os.tag != .linux, &peer_ready);
    var peer_joined = false;
    defer {
        if (!peer_joined) {
            receiver.cancel();
            pt.join();
        }
        alloc.free(peer_result.stdout);
        alloc.free(peer_result.stderr);
    }

    // Accept the peer connection.
    try receiver.accept(.{ .nodelay = true, .udp_encaps_port = udp_remote });

    // Receive the expected byte count and verify the pattern.
    var buf: [4096]u8 = undefined;
    var got: usize = 0;
    while (got < num_bytes) {
        const r = try receiver.recv(&buf);
        for (0..r.len) |i| {
            const expected: u8 = @intCast((got + i) % 256);
            try std.testing.expectEqual(expected, buf[i]);
        }
        got += r.len;
    }

    // Wait for the peer and verify its exit status.
    pt.join();
    peer_joined = true;
    try std.testing.expect(peer_result.term != null);
    switch (peer_result.term.?) {
        .exited => |code| try std.testing.expectEqual(code, 0),
        else => return error.PeerAbnormalExit,
    }
    try std.testing.expect(std.mem.indexOf(u8, peer_result.stdout, "OK SENT") != null);
}

test "Writer -> Reader lossless round-trip with peer (cross-platform)" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    const sctp_port: u16 = 5098;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    const num_frames: usize = 1024;
    const channels: u16 = 2;

    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack();

    const reader = try alloc.create(Reader);
    defer alloc.destroy(reader);
    reader.lifecycle = .uninitialized;
    try reader.init(.{
        .sctp = .{
            .nodelay = true,
            .udp_encaps_port = udp_remote,
        },
    }, SocketAddr.loopbackIp4(sctp_port), io);
    defer reader.deinit();

    // Spawn the peer writer in a background thread.
    var port_buf: [8]u8 = undefined;
    var frame_buf: [16]u8 = undefined;
    var chan_buf: [4]u8 = undefined;
    var udp_l_buf: [8]u8 = undefined;
    var udp_r_buf: [8]u8 = undefined;
    var argv_buf: [7][]const u8 = undefined;
    const argv = buildPeerArgv(
        &argv_buf,
        peer_path,
        "writer",
        u16ToSlice(&port_buf, sctp_port),
        u16ToSlice(&frame_buf, @intCast(num_frames)),
        u16ToSlice(&chan_buf, channels),
        u16ToSlice(&udp_l_buf, udp_remote), // peer's local UDP port
        u16ToSlice(&udp_r_buf, udp_local), // parent's UDP port
    );

    var peer_result = PeerResult{};
    var peer_ready: std.Io.Semaphore = .{};
    const pt = try spawnPeerThread(alloc, io, argv, &peer_result, builtin.os.tag != .linux, &peer_ready);
    var peer_joined = false;
    defer {
        if (!peer_joined) {
            reader.cancel();
            pt.join();
        }
        alloc.free(peer_result.stdout);
        alloc.free(peer_result.stderr);
    }

    // Reader sequence: accept, read config, start, and read blocks.
    try reader.accept(.{ .sctp = .{ .udp_encaps_port = udp_remote } });
    const cfg = try reader.recvConfig();
    try std.testing.expectEqual(cfg.sample_rate, 44100);
    try std.testing.expectEqual(cfg.num_channels, channels);
    try std.testing.expectEqual(cfg.bits_per_sample, 16);

    try reader.start(1);

    // The peer generates a 440 Hz sine wave with peak amplitude 16000.
    // Verify the exact interleaved value count.
    var output: [num_frames * 2]i32 = undefined;
    var total: u32 = 0;
    while (total < num_frames * 2) {
        const n = try reader.readFrame(output[total..]);
        total += n;
    }
    try std.testing.expectEqual(total, num_frames * 2);

    // Reconstruct the waveform and verify a lossless round-trip.
    var expected: [num_frames * 2]i32 = undefined;
    for (0..num_frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        expected[i * 2] = val;
        expected[i * 2 + 1] = val;
    }
    for (0..total) |i| {
        try std.testing.expectEqual(expected[i], output[i]);
    }

    pt.join();
    peer_joined = true;
    try std.testing.expect(peer_result.term != null);
    switch (peer_result.term.?) {
        .exited => |code| try std.testing.expectEqual(code, 0),
        else => return error.PeerAbnormalExit,
    }
    try std.testing.expect(std.mem.indexOf(u8, peer_result.stdout, "OK WROTE") != null);
}

test "mono audio round-trip with peer" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    const sctp_port: u16 = 5097;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    const num_frames: usize = 512;
    const channels: u16 = 1;

    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack();

    const reader = try alloc.create(Reader);
    defer alloc.destroy(reader);
    reader.lifecycle = .uninitialized;
    try reader.init(.{
        .sctp = .{ .nodelay = true, .udp_encaps_port = udp_remote },
    }, SocketAddr.loopbackIp4(sctp_port), io);
    defer reader.deinit();

    var port_buf: [8]u8 = undefined;
    var frame_buf: [16]u8 = undefined;
    var chan_buf: [4]u8 = undefined;
    var udp_l_buf: [8]u8 = undefined;
    var udp_r_buf: [8]u8 = undefined;
    var argv_buf: [7][]const u8 = undefined;
    const argv = buildPeerArgv(
        &argv_buf,
        peer_path,
        "writer",
        u16ToSlice(&port_buf, sctp_port),
        u16ToSlice(&frame_buf, @intCast(num_frames)),
        u16ToSlice(&chan_buf, channels),
        u16ToSlice(&udp_l_buf, udp_remote),
        u16ToSlice(&udp_r_buf, udp_local),
    );

    var peer_result = PeerResult{};
    var peer_ready: std.Io.Semaphore = .{};
    const pt = try spawnPeerThread(alloc, io, argv, &peer_result, builtin.os.tag != .linux, &peer_ready);
    var peer_joined = false;
    defer {
        if (!peer_joined) {
            reader.cancel();
            pt.join();
        }
        alloc.free(peer_result.stdout);
        alloc.free(peer_result.stderr);
    }

    try reader.accept(.{ .sctp = .{ .udp_encaps_port = udp_remote } });
    const cfg = try reader.recvConfig();
    try std.testing.expectEqual(cfg.num_channels, channels);

    try reader.start(1);

    var output: [num_frames * 1]i32 = undefined;
    var total: u32 = 0;
    while (total < num_frames * 1) {
        const n = try reader.readFrame(output[total..]);
        total += n;
    }
    try std.testing.expectEqual(total, num_frames * 1);

    var expected: [num_frames]i32 = undefined;
    for (0..num_frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        expected[i] = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
    }
    for (0..total) |i| try std.testing.expectEqual(expected[i], output[i]);

    pt.join();
    peer_joined = true;
    try std.testing.expect(peer_result.term != null);
    switch (peer_result.term.?) {
        .exited => |code| try std.testing.expectEqual(code, 0),
        else => return error.PeerAbnormalExit,
    }
}

test "peer buffering pre-fill" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    const sctp_port: u16 = 5096;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    // Use multiple blocks and a depth greater than one so the test exercises
    // the pre-fill path rather than ordinary single-block decoding.
    const num_frames: usize = 4096;
    const channels: u16 = 2;
    // The first read waits until two blocks are queued.
    const buffer_depth: usize = 2;

    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack();

    const reader = try alloc.create(Reader);
    defer alloc.destroy(reader);
    reader.lifecycle = .uninitialized;
    try reader.init(.{
        .sctp = .{ .nodelay = true, .udp_encaps_port = udp_remote },
    }, SocketAddr.loopbackIp4(sctp_port), io);
    defer reader.deinit();

    var port_buf: [8]u8 = undefined;
    var frame_buf: [16]u8 = undefined;
    var chan_buf: [4]u8 = undefined;
    var udp_l_buf: [8]u8 = undefined;
    var udp_r_buf: [8]u8 = undefined;
    var argv_buf: [7][]const u8 = undefined;
    const argv = buildPeerArgv(
        &argv_buf,
        peer_path,
        "writer",
        u16ToSlice(&port_buf, sctp_port),
        u16ToSlice(&frame_buf, @intCast(num_frames)),
        u16ToSlice(&chan_buf, channels),
        u16ToSlice(&udp_l_buf, udp_remote),
        u16ToSlice(&udp_r_buf, udp_local),
    );

    var peer_result = PeerResult{};
    var peer_ready: std.Io.Semaphore = .{};
    const pt = try spawnPeerThread(alloc, io, argv, &peer_result, builtin.os.tag != .linux, &peer_ready);
    var peer_joined = false;
    defer {
        if (!peer_joined) {
            reader.cancel();
            pt.join();
        }
        alloc.free(peer_result.stdout);
        alloc.free(peer_result.stderr);
    }

    try reader.accept(.{ .sctp = .{ .udp_encaps_port = udp_remote } });
    _ = try reader.recvConfig();

    // The first readFrame() call waits for the configured queue depth.
    try reader.start(buffer_depth);

    var output: [num_frames * 2]i32 = undefined;
    var total: u32 = 0;
    while (total < num_frames * 2) {
        const n = try reader.readFrame(output[total..]);
        total += n;
    }
    try std.testing.expectEqual(total, num_frames * 2);

    pt.join();
    peer_joined = true;
    try std.testing.expect(peer_result.term != null);
    switch (peer_result.term.?) {
        .exited => |code| try std.testing.expectEqual(code, 0),
        else => return error.PeerAbnormalExit,
    }
}
