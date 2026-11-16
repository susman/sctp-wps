/// Integration tests for network SCTP paths.
///
/// The tests require network SCTP support and the sctp-wps-peer executable.
/// They skip when kernel SCTP is unavailable. The peer executable path comes
/// from build_options, which the test build injects. Library builds never
/// analyze this file.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const root = @import("root.zig");
const sctp = root.sctp;
const SocketAddr = sctp.SocketAddr;
const Writer = root.Writer;
const Reader = root.Reader;

/// Skip the test when the kernel cannot create an SCTP socket.
fn requireNetworkSctp() !void {
    if (builtin.os.tag == .macos) return;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const rc = std.os.linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, sctp.IPPROTO_SCTP);
    if (@as(isize, @bitCast(rc)) < 0) return error.SkipZigTest;
    _ = std.os.linux.close(@intCast(@as(isize, @bitCast(rc))));
}

/// Sine sample used by the peer writer and by reader-side verification.
fn sineValue(i: usize) i32 {
    const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
    return @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
}

/// Verify an interleaved sine buffer against the shared generator.
fn expectSine(samples: []const i32, num_frames: usize, channels: usize) !void {
    try std.testing.expectEqual(num_frames * channels, samples.len);
    for (0..num_frames) |i| {
        for (0..channels) |c| {
            try std.testing.expectEqual(sineValue(i), samples[i * channels + c]);
        }
    }
}

const PeerResult = struct {
    term: ?std.process.Child.Term = null,
    spawned: bool = false,
    stdout: []u8 = "",
    stderr: []u8 = "",
};

/// Spawn a peer executable in a background thread.
/// Capture the peer's stdout and stderr in `out`.
fn spawnPeerThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    out: *PeerResult,
    ready: *std.Io.Semaphore,
) !std.Thread {
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

    // Drain stdout and stderr concurrently. Reading one pipe to EOF before
    // the other can deadlock when the peer fills the second pipe.
    // SAFETY: init() fills the buffer and the reader before either is read.
    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    // SAFETY: init() fills the reader before any method is called.
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => {},
    }
    multi_reader.checkAnyError() catch |err|
        std.log.warn("peer output read failed: {t}", .{err});

    var empty_buf: [0]u8 = .{};
    const term = child.wait(io) catch null;
    const stdout_slice: []u8 = multi_reader.toOwnedSlice(0) catch &empty_buf;
    const stderr_slice: []u8 = multi_reader.toOwnedSlice(1) catch &empty_buf;
    out.* = .{
        .term = term,
        .spawned = true,
        .stdout = stdout_slice,
        .stderr = stderr_slice,
    };
}

/// Format a u16 in the supplied buffer and return the written slice.
fn u16ToSlice(buf: []u8, value: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch
        @panic("u16ToSlice: bufPrint failed");
}

/// One peer executable run owned by a test.
///
/// The harness builds the argument vector, spawns the peer, and joins it.
/// The storage for the argv strings lives in the struct, so the struct must
/// outlive the peer process.
const PeerTest = struct {
    io: std.Io,
    result: PeerResult = .{},
    ready: std.Io.Semaphore = .{},
    thread: ?std.Thread = null,
    joined: bool = false,
    argv_buf: [7][]const u8 = @splat(""),
    port_buf: [8]u8 = @splat(0),
    count_buf: [16]u8 = @splat(0),
    chan_buf: [4]u8 = @splat(0),
    udp_l_buf: [8]u8 = @splat(0),
    udp_r_buf: [8]u8 = @splat(0),

    /// Build argv and spawn the peer process in a background thread.
    /// `count` is the byte count for raw modes or the frame count for the
    /// writer and reader modes. `udp_l` is the peer's local UDP port and
    /// `udp_r` is the parent's UDP port.
    fn spawn(
        self: *PeerTest,
        peer_path: []const u8,
        mode: []const u8,
        sctp_port: u16,
        count: u16,
        channels: u16,
        udp_l: u16,
        udp_r: u16,
    ) !void {
        const argv: []const []const u8 = &.{
            peer_path,
            mode,
            u16ToSlice(&self.port_buf, sctp_port),
            u16ToSlice(&self.count_buf, count),
            u16ToSlice(&self.chan_buf, channels),
            u16ToSlice(&self.udp_l_buf, udp_l),
            u16ToSlice(&self.udp_r_buf, udp_r),
        };
        @memcpy(self.argv_buf[0..argv.len], argv);
        self.thread = try spawnPeerThread(std.testing.allocator, self.io, self.argv_buf[0..7], &self.result, &self.ready);
    }

    /// Join the peer thread. A repeat call is a no-op.
    fn join(self: *PeerTest) void {
        if (self.joined) return;
        if (self.thread) |t| t.join();
        self.joined = true;
    }

    /// Free the captured peer output.
    fn stop(self: *PeerTest) void {
        std.testing.allocator.free(self.result.stdout);
        std.testing.allocator.free(self.result.stderr);
    }

    /// Join the peer and require exit code 0.
    /// Require `marker` in the peer's stdout when given.
    fn expectExitOk(self: *PeerTest, marker: ?[]const u8) !void {
        self.join();
        try std.testing.expect(self.result.term != null);
        switch (self.result.term.?) {
            .exited => |code| try std.testing.expectEqual(code, 0),
            else => return error.PeerAbnormalExit,
        }
        if (marker) |m| {
            try std.testing.expect(std.mem.indexOf(u8, self.result.stdout, m) != null);
        }
    }
};

/// Create and initialize a Reader bound to a loopback SCTP port.
fn makePeerReader(udp_remote: u16, sctp_port: u16, io: std.Io) !*Reader {
    const reader = try std.testing.allocator.create(Reader);
    errdefer std.testing.allocator.destroy(reader);
    reader.initUninitialized();
    try reader.init(std.testing.allocator, .{
        .sctp = .{ .nodelay = true, .udp_encaps_port = udp_remote },
    }, SocketAddr.loopbackIp4(sctp_port), io);
    return reader;
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
    const reader = try std.testing.allocator.create(Reader);
    defer std.testing.allocator.destroy(reader);
    reader.initUninitialized();
    const bind_addr = SocketAddr.loopbackIp4(0);
    try reader.init(std.testing.allocator, .{}, bind_addr, io);
    defer reader.deinit();

    // Read the port assigned by the operating system.
    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const rc = linux.getsockname(reader.transport.listen_fd, @ptrCast(&sa), &sa_len);
    if (@as(isize, @bitCast(rc)) < 0) return error.GetSockNameFailed;
    const bound = try SocketAddr.fromSockaddr(&sa, sa_len);
    const port = bound.getPort();

    // Connect the writer from a background thread.
    const writer = try std.testing.allocator.create(Writer);
    var writer_initialized = false;
    defer {
        if (writer_initialized) writer.deinit();
        std.testing.allocator.destroy(writer);
    }
    writer.initUninitialized();

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
        input[i * 2] = sineValue(i);
        input[i * 2 + 1] = sineValue(i);
    }
    try writer.tryWrite(&input);
    try writer.flushTimeout(5000);

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
    try expectSine(output[0..total], num_frames, 2);
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

test "SctpSender/SctpReceiver loopback with peer" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    // Use fixed SCTP and UDP ports for the two endpoints.
    const sctp_port: u16 = 5099;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    const num_bytes: u16 = 4096;

    // The parent owns UDP port 9899 on macOS. This is a no-op on Linux.
    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack(io);

    var receiver = try sctp.SctpReceiver.init(
        SocketAddr.loopbackIp4(sctp_port),
        2,
        .{ .nodelay = true, .udp_encaps_port = udp_remote },
        io,
    );
    defer receiver.close();

    var peer: PeerTest = .{ .io = io };
    defer {
        if (!peer.joined) receiver.cancel();
        peer.join();
        peer.stop();
    }
    // The peer's local UDP port is the parent's remote port.
    try peer.spawn(peer_path, "sender", sctp_port, num_bytes, 2, udp_remote, udp_local);

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

    try peer.expectExitOk("OK SENT");
}

test "Writer -> Reader lossless round-trip with peer (cross-platform)" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    const sctp_port: u16 = 5098;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    const num_frames: u16 = 1024;
    const channels: u16 = 2;

    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack(io);

    const reader = try makePeerReader(udp_remote, sctp_port, io);
    defer std.testing.allocator.destroy(reader);
    defer reader.deinit();

    var peer: PeerTest = .{ .io = io };
    defer {
        if (!peer.joined) reader.cancel();
        peer.join();
        peer.stop();
    }
    try peer.spawn(peer_path, "writer", sctp_port, num_frames, channels, udp_remote, udp_local);

    // Reader sequence: accept, read config, start, and read blocks.
    try reader.accept(.{ .sctp = .{ .udp_encaps_port = udp_remote } });
    const cfg = try reader.recvConfig();
    try std.testing.expectEqual(cfg.sample_rate, 44100);
    try std.testing.expectEqual(cfg.num_channels, channels);
    try std.testing.expectEqual(cfg.bits_per_sample, 16);

    try reader.start(1);

    // Verify the exact interleaved value count and the lossless round-trip.
    var output: [num_frames * 2]i32 = undefined;
    var total: u32 = 0;
    while (total < num_frames * 2) {
        const n = try reader.readFrame(output[total..]);
        total += n;
    }
    try std.testing.expectEqual(total, num_frames * 2);
    try expectSine(output[0..total], num_frames, channels);

    try peer.expectExitOk("OK WROTE");
}

test "mono audio round-trip with peer" {
    try requireNetworkSctp();

    const io = std.testing.io;
    const peer_path = build_options.peer_path;

    const sctp_port: u16 = 5097;
    const udp_local: u16 = 9899;
    const udp_remote: u16 = 9900;
    const num_frames: u16 = 512;
    const channels: u16 = 1;

    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack(io);

    const reader = try makePeerReader(udp_remote, sctp_port, io);
    defer std.testing.allocator.destroy(reader);
    defer reader.deinit();

    var peer: PeerTest = .{ .io = io };
    defer {
        if (!peer.joined) reader.cancel();
        peer.join();
        peer.stop();
    }
    try peer.spawn(peer_path, "writer", sctp_port, num_frames, channels, udp_remote, udp_local);

    try reader.accept(.{ .sctp = .{ .udp_encaps_port = udp_remote } });
    const cfg = try reader.recvConfig();
    try std.testing.expectEqual(cfg.num_channels, channels);

    try reader.start(1);

    var output: [num_frames]i32 = undefined;
    var total: u32 = 0;
    while (total < num_frames) {
        const n = try reader.readFrame(output[total..]);
        total += n;
    }
    try std.testing.expectEqual(total, num_frames);
    try expectSine(output[0..total], num_frames, channels);

    try peer.expectExitOk(null);
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
    const num_frames: u16 = 4096;
    const channels: u16 = 2;
    // The first read waits until two blocks are queued.
    const buffer_depth: usize = 2;

    try sctp.acquireStack(udp_local, io);
    defer sctp.releaseStack(io);

    const reader = try makePeerReader(udp_remote, sctp_port, io);
    defer std.testing.allocator.destroy(reader);
    defer reader.deinit();

    var peer: PeerTest = .{ .io = io };
    defer {
        if (!peer.joined) reader.cancel();
        peer.join();
        peer.stop();
    }
    try peer.spawn(peer_path, "writer", sctp_port, num_frames, channels, udp_remote, udp_local);

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
    try expectSine(output[0..total], num_frames, channels);

    try peer.expectExitOk(null);
}
