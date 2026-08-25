/// Cross-process loopback test helper.
///
/// The helper plays the endpoint that the parent test does not play.
/// usrsctp sender and receiver endpoints use separate processes.
/// Linux also uses this helper for cross-process tests.
///
/// Usage:
///   peer sender   <sctp_port> <num_bytes> [udp_local_port] [udp_encaps_port]
///   peer receiver <sctp_port> <num_bytes> [udp_local_port] [udp_encaps_port]
///   peer writer   <sctp_port> <num_frames> <channels> [udp_local_port] [udp_encaps_port]
///   peer reader   <sctp_port> <num_frames> <channels> [udp_local_port] [udp_encaps_port]
///
/// Status output uses "OK <count>" on success and "ERROR <message>" on
/// failure. Diagnostic lines can also appear on stdout.
/// Exit code 0 means success. Exit code 1 means failure.
///
/// Sender and receiver modes exchange a fixed pattern (byte = pos % 256)
/// on SCTP stream 0 with the raw SctpSender and SctpReceiver APIs.
/// Writer and reader modes use the high-level wrappers to encode and decode
/// WavPack-stream audio frames.
const std = @import("std");
const sctp = @import("sctp.zig");
const SocketAddr = sctp.SocketAddr;
const root = @import("root.zig");
const Writer = root.Writer;
const Reader = root.Reader;

const alloc = std.heap.c_allocator;

/// Run one peer mode from the command line.
pub fn main(init: std.process.Init) !void {
    const io_inst = init.io;
    io_global = io_inst;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        print("usage: peer <mode> <sctp_port> <count> [channels] [udp_local] [udp_remote]\n", .{});
        std.process.exit(1);
    }

    const mode = args[1];
    const sctp_port = std.fmt.parseInt(u16, args[2], 10) catch fail("bad sctp_port");
    const count_arg = std.fmt.parseInt(usize, args[3], 10) catch fail("bad count");
    const channels_arg: u16 = if (args.len > 4) (std.fmt.parseInt(u16, args[4], 10) catch fail("bad channels")) else 2;
    const udp_local: u16 = if (args.len > 5) (std.fmt.parseInt(u16, args[5], 10) catch fail("bad udp_local")) else 9899;
    const udp_remote: u16 = if (args.len > 6) (std.fmt.parseInt(u16, args[6], 10) catch fail("bad udp_remote")) else 9899;

    if ((std.mem.eql(u8, mode, "writer") or std.mem.eql(u8, mode, "reader")) and
        (channels_arg != 1 and channels_arg != 2))
    {
        fail("channels must be 1 or 2");
    }

    if (std.mem.eql(u8, mode, "sender")) {
        try runSender(io_inst, sctp_port, count_arg, udp_local, udp_remote);
    } else if (std.mem.eql(u8, mode, "receiver")) {
        try runReceiver(io_inst, sctp_port, count_arg, udp_local, udp_remote);
    } else if (std.mem.eql(u8, mode, "writer")) {
        try runWriter(io_inst, sctp_port, count_arg, channels_arg, udp_local, udp_remote);
    } else if (std.mem.eql(u8, mode, "reader")) {
        try runReader(io_inst, sctp_port, count_arg, channels_arg, udp_local, udp_remote);
    } else {
        fail("unknown mode");
    }
}

fn print(comptime fmt: []const u8, args: anytype) void {
    // The test runner reads status lines from stdout.
    var buf: [256]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io_global, written) catch |e|
        std.log.err("peer stdout write failed: {}", .{e});
}

// SAFETY: main() assigns io_global before print() or fail() reads it.
var io_global: std.Io = undefined;

fn fail(msg: []const u8) noreturn {
    print("ERROR {s}\n", .{msg});
    std.process.exit(1);
}

const Pattern = struct {
    /// Return the test byte at a stream position.
    pub fn byteAt(pos: usize) u8 {
        return @intCast(pos % 256);
    }
};

/// Send a fixed byte pattern with the low-level SCTP sender.
fn runSender(io_inst: std.Io, sctp_port: u16, num_bytes: usize, udp_local: u16, udp_remote: u16) !void {
    print("peer sender: acquireStack udp_local={d}\n", .{udp_local});
    try sctp.acquireStack(udp_local, io_inst);
    defer sctp.releaseStack();

    print("peer sender: SctpSender.init sctp_port={d} udp_remote={d}\n", .{ sctp_port, udp_remote });
    var sender = sctp.SctpSender.init(
        SocketAddr.loopbackIp4(sctp_port),
        2,
        .{
            .nodelay = true,
            .udp_encaps_port = udp_remote,
        },
        null,
        io_inst,
    ) catch |e| {
        print("ERROR SctpSender.init: {t}\n", .{e});
        std.process.exit(1);
    };
    defer sender.close();

    print("peer sender: SctpSender.init returned, sending {d} bytes\n", .{num_bytes});
    // Send num_bytes of a fixed pattern on stream 0.
    var buf: [4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < num_bytes) {
        const chunk = @min(buf.len, num_bytes - sent);
        for (0..chunk) |i| buf[i] = Pattern.byteAt(sent + i);
        sender.send(0, buf[0..chunk]) catch |e| {
            print("ERROR send: {t}\n", .{e});
            std.process.exit(1);
        };
        sent += chunk;
    }
    print("OK SENT {d}\n", .{sent});
}

/// Receive and verify a fixed byte pattern with the low-level SCTP receiver.
fn runReceiver(io_inst: std.Io, sctp_port: u16, num_bytes: usize, udp_local: u16, udp_remote: u16) !void {
    print("peer receiver: acquireStack udp_local={d}\n", .{udp_local});
    try sctp.acquireStack(udp_local, io_inst);
    defer sctp.releaseStack();

    print("peer receiver: SctpReceiver.init sctp_port={d} udp_remote={d}\n", .{ sctp_port, udp_remote });
    var receiver = sctp.SctpReceiver.init(
        SocketAddr.loopbackIp4(sctp_port),
        2,
        .{
            .nodelay = true,
            .udp_encaps_port = udp_remote,
        },
        io_inst,
    ) catch |e| {
        print("ERROR SctpReceiver.init: {t}\n", .{e});
        std.process.exit(1);
    };
    defer receiver.close();

    print("peer receiver: accept waiting\n", .{});
    receiver.accept(.{ .udp_encaps_port = udp_remote }) catch |e| {
        print("ERROR accept: {t}\n", .{e});
        std.process.exit(1);
    };
    print("peer receiver: accept returned\n", .{});

    var buf: [4096]u8 = undefined;
    var got: usize = 0;
    while (got < num_bytes) {
        const r = receiver.recv(&buf) catch |e| {
            print("ERROR recv: {t}\n", .{e});
            std.process.exit(1);
        };
        // Verify the received pattern.
        for (0..r.len) |i| {
            const expected = Pattern.byteAt(got + i);
            if (buf[i] != expected) {
                print("ERROR pattern mismatch at {d}: got {d}, expected {d}\n", .{ got + i, buf[i], expected });
                std.process.exit(1);
            }
        }
        got += r.len;
    }
    print("OK RECV {d}\n", .{got});
}

/// Generate and send a sine wave with the high-level Writer.
fn runWriter(io_inst: std.Io, sctp_port: u16, num_frames: usize, channels: u16, udp_local: u16, udp_remote: u16) !void {
    try sctp.acquireStack(udp_local, io_inst);
    defer sctp.releaseStack();

    const channel_mask: i32 = switch (channels) {
        1 => 0x4, // Front center.
        2 => 0x3, // Front left and front right.
        else => unreachable,
    };

    const w = try alloc.create(Writer);
    defer alloc.destroy(w);
    w.lifecycle = .uninitialized;

    w.init(.{
        .wp = .{
            .sample_rate = 44100,
            .num_channels = channels,
            .bits_per_sample = 16,
            .channel_mask = channel_mask,
        },
        .sctp = .{
            .nodelay = true,
            .udp_encaps_port = udp_remote,
        },
    }, SocketAddr.loopbackIp4(sctp_port), io_inst) catch |e| {
        print("ERROR Writer.init failed: {t}\n", .{e});
        std.process.exit(1);
    };
    defer w.deinit();

    // Generate num_frames of a sine wave and send it to the writer.
    const samples_per_call = 1024;
    var samples: [samples_per_call * 8]i32 = undefined;
    var sent: usize = 0;
    while (sent < num_frames) {
        const n = @min(samples_per_call, num_frames - sent);
        for (0..n) |i| {
            const t: f64 = @as(f64, @floatFromInt(sent + i)) / 44100.0;
            const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
            for (0..channels) |c| {
                samples[i * channels + c] = val;
            }
        }
        w.write(samples[0 .. n * channels]) catch fail("Writer.write failed");
        sent += n;
    }
    w.flush() catch fail("Writer.flush failed");
    print("OK WROTE {d}\n", .{sent});
}

/// Receive and count sine-wave frames with the high-level Reader.
fn runReader(io_inst: std.Io, sctp_port: u16, num_frames: usize, channels: u16, udp_local: u16, udp_remote: u16) !void {
    try sctp.acquireStack(udp_local, io_inst);
    defer sctp.releaseStack();

    const r = try alloc.create(Reader);
    defer alloc.destroy(r);
    // SAFETY: r.init() overwrites every Reader field before any field is read.
    r.* = undefined;
    r.lifecycle = .uninitialized;

    r.init(.{
        .sctp = .{
            .nodelay = true,
            .udp_encaps_port = udp_remote,
        },
    }, SocketAddr.loopbackIp4(sctp_port), io_inst) catch fail("Reader.init failed");
    defer r.deinit();

    r.accept(.{ .sctp = .{ .udp_encaps_port = udp_remote } }) catch fail("accept failed");
    const cfg = r.recvConfig() catch fail("recvConfig failed");
    if (cfg.num_channels != channels) fail("channel count mismatch");

    r.start(1) catch fail("start failed");

    var output: [8192 * 8]i32 = undefined;
    var got: usize = 0;
    while (got < num_frames) {
        const want = @min(output.len / channels, num_frames - got);
        const n = r.readFrame(output[0 .. want * channels]) catch fail("readFrame failed");
        if (n == 0) fail("readFrame returned 0");
        got += n / channels;
    }
    print("OK READ {d}\n", .{got});
}
