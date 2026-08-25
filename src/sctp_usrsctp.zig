/// Non-Linux SCTP backend using the usrsctp userspace stack.
///
/// usrsctp implements SCTP in userspace over a UDP socket.
/// `usrsctp_init(port)` opens that UDP socket. Port 9899 is the default RFC
/// 6951 SCTP-over-UDP port.
///
/// Key differences from the Linux backend:
///   - Sockets are opaque `*c.struct_socket` handles.
///   - The sender must bind to any:0 before connect().
///   - `tryAcceptNew()` temporarily enables non-blocking mode.
///   - connect cancellation is unavailable because usrsctp has no cancellable fd.
///
/// Flow:
///   Sender:   socket -> bind(any:0) -> SCTP_REMOTE_UDP_ENCAPS_PORT -> connect
///   Receiver: socket -> bind(port)  -> listen -> accept
///
/// Send and receive calls remain blocking thread operations.
/// The shared stack state uses `std.Io.Mutex` and the shared `SocketAddr` type.
const std = @import("std");
const posix = std.posix;
const SocketAddr = @import("sctp.zig").SocketAddr;
const ConnectState = @import("connect_state.zig").ConnectState;

const c = @import("usrsctp_c");

/// IANA protocol number for SCTP.
pub const IPPROTO_SCTP: u32 = c.IPPROTO_SCTP;

/// Cast any sockaddr-family pointer to [*c]c.struct_sockaddr as expected by usrsctp.
/// The Zig-side `posix.sockaddr` and the C `c.struct_sockaddr` share the same
/// memory layout (family + data trailing) so this cast is sound.
fn sa(ptr: anytype) [*c]c.struct_sockaddr {
    return @ptrCast(@constCast(ptr));
}

// Stack lifecycle. One usrsctp instance is shared by all senders and receivers.
// A reference count keeps the instance alive. All explicit ports must match
// because usrsctp binds one UDP port globally.
//
// The mutex needs an Io context for lock and unlock operations.
var g_stack_mutex: std.Io.Mutex = .init;
var g_stack_refcount: u32 = 0;
var g_stack_port: u16 = 0;
/// Io context captured by the first acquireStack() call.
/// Later releases reuse this context because releaseStack() has no Io argument.
var g_stack_io: std.Io = std.Io.failing;

/// Acquire a reference to the usrsctp stack.
/// The first call initializes it with `local_port`. Zero selects port 9899.
/// Pair each successful call with releaseStack().
/// `io` backs the stack mutex operations.
pub fn acquireStack(local_port: u16, io: std.Io) !void {
    try initStack(local_port, io);
}

/// Release one reference to the usrsctp stack.
/// Tear down the singleton when the last reference is released.
/// The first acquired Io context remains in use for locking.
pub fn releaseStack() void {
    deinitStack();
}

/// Initialize the singleton or increment its reference count.
/// The first call opens the UDP socket and starts usrsctp processing.
/// It also enables blackhole mode and CRC32 checks on loopback.
fn initStack(local_port: u16, io: std.Io) !void {
    g_stack_mutex.lockUncancelable(io);
    defer g_stack_mutex.unlock(io);
    if (g_stack_refcount == 0) {
        const port: u16 = if (local_port != 0) local_port else 9899;
        c.usrsctp_init(port, null, null);
        // Drop packets for unknown associations without sending ABORT.
        _ = c.usrsctp_sysctl_set_sctp_blackhole(2);
        // Verify the SCTP CRC32 path on loopback as on a real network.
        _ = c.usrsctp_sysctl_set_sctp_no_csum_on_loopback(0);
        g_stack_port = port;
        g_stack_io = io;
    } else if (local_port != 0 and local_port != g_stack_port) {
        return error.PortMismatch;
    }
    g_stack_refcount += 1;
}

/// Decrement the reference count and finish usrsctp at zero.
/// `usrsctp_finish()` can report active associations. Retry with a short
/// delay until shutdown completes or the retry limit is reached.
fn deinitStack() void {
    const io = g_stack_io;
    g_stack_mutex.lockUncancelable(io);
    defer g_stack_mutex.unlock(io);
    if (g_stack_refcount == 0) return;
    g_stack_refcount -= 1;
    if (g_stack_refcount == 0) {
        // Retry for about five seconds. Use the captured Io context for sleep.
        var tries: u32 = 0;
        while (tries < 50) : (tries += 1) {
            if (c.usrsctp_finish() == 0) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch |e|
                std.log.warn("usrsctp_finish sleep failed: {}", .{e});
        }
    }
}

// Public transport API.
/// Result of one usrsctp receive operation.
pub const RecvResult = struct {
    /// SCTP stream ID for the message.
    stream_id: u16,
    /// Number of bytes written into the receive buffer.
    len: usize,
};

/// usrsctp sender with an opaque socket handle.
/// Its public API matches the Linux SctpSender.
pub const SctpSender = struct {
    /// Connected usrsctp socket.
    sock: ?*c.struct_socket = null,
    /// Io context captured at initialization.
    /// The stack uses it when the sender closes.
    io: std.Io = std.Io.failing,

    /// usrsctp sender options.
    pub const Config = struct {
        /// Disable Nagle-style batching when true.
        nodelay: bool = true,
        /// Reserved for backend parity. The current backend ignores this field.
        sndbuf_size: u32 = 0,
        /// Remote RFC 6951 UDP port. Zero selects the default port 9899.
        udp_encaps_port: u16 = 0,
    };

    /// Create, configure, and connect a usrsctp sender.
    /// `num_streams` is the requested inbound and outbound stream count.
    /// `cancel_state` is unused because usrsctp has no cancellable file descriptor.
    /// The Io context must outlive the returned sender.
    pub fn init(dest: SocketAddr, num_streams: u16, cfg: Config, cancel_state: ?*ConnectState, io: std.Io) !SctpSender {
        _ = cancel_state;
        try initStack(0, io);
        errdefer deinitStack();

        const sock = c.usrsctp_socket(
            @intCast(dest.family()),
            posix.SOCK.STREAM,
            c.IPPROTO_SCTP,
            null,
            null,
            0,
            null,
        ) orelse {
            std.log.err("usrsctp_socket failed", .{});
            return error.SocketFailed;
        };
        errdefer c.usrsctp_close(sock);

        var initmsg = std.mem.zeroes(c.sctp_initmsg);
        initmsg.sinit_num_ostreams = num_streams;
        initmsg.sinit_max_instreams = num_streams;
        if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_INITMSG, &initmsg, @sizeOf(c.sctp_initmsg)) != 0) {
            std.log.err("SCTP_INITMSG failed errno={d}", .{std.c._errno().*});
            return error.SetSockOptFailed;
        }

        if (cfg.nodelay) {
            const one: u32 = 1;
            if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_NODELAY, &one, @sizeOf(u32)) != 0) {
                std.log.err("SCTP_NODELAY failed errno={d}", .{std.c._errno().*});
                return error.SetSockOptFailed;
            }
        }

        // usrsctp requires an explicit any:0 bind before connect().
        // Use the destination family for the wildcard address.
        const bind_addr: SocketAddr = switch (dest.family()) {
            posix.AF.INET => SocketAddr.anyIp4(0),
            posix.AF.INET6 => SocketAddr.parseIp6(.{0} ** 16, 0, 0),
            else => return error.UnsupportedAddressFamily,
        };
        // SAFETY: toSockaddr() fills bind_sa before bind reads it.
        var bind_sa: posix.sockaddr.storage = undefined;
        var bind_sa_len: posix.socklen_t = 0;
        bind_addr.toSockaddr(&bind_sa, &bind_sa_len);
        if (c.usrsctp_bind(sock, sa(&bind_sa), bind_sa_len) != 0) {
            std.log.err("usrsctp_bind failed errno={d}", .{std.c._errno().*});
            return error.BindFailed;
        }

        // Configure the remote UDP port and SCTP-level destination address.
        // RFC 6951 requires both fields for association-scoped encapsulation.
        const udp_port: u16 = if (cfg.udp_encaps_port > 0) cfg.udp_encaps_port else 9899;
        var encaps = std.mem.zeroes(c.sctp_udpencaps);
        // Use a wildcard address for the future association. The destination
        // address is supplied separately to connect().
        // Zero the unused bytes so no undefined data reaches the C structure.
        var enc_sa: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
        var enc_sa_len: posix.socklen_t = 0;
        const wildcard = switch (dest.ip) {
            .ip4 => SocketAddr.anyIp4(0),
            .ip6 => SocketAddr.parseIp6(.{0} ** 16, 0, 0),
        };
        wildcard.toSockaddr(&enc_sa, &enc_sa_len);
        const ss_size = @min(@sizeOf(posix.sockaddr.storage), @sizeOf(@TypeOf(encaps.sue_address)));
        @memcpy(
            @as([*]u8, @ptrCast(&encaps.sue_address))[0..ss_size],
            @as([*]const u8, @ptrCast(&enc_sa))[0..ss_size],
        );
        encaps.sue_port = std.mem.nativeToBig(u16, udp_port);
        if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_REMOTE_UDP_ENCAPS_PORT, &encaps, @sizeOf(c.sctp_udpencaps)) != 0) {
            std.log.err("SCTP_REMOTE_UDP_ENCAPS_PORT failed errno={d}", .{std.c._errno().*});
            return error.SetSockOptFailed;
        }

        // SAFETY: toSockaddr() fills dest_sa before connect reads it.
        var dest_sa: posix.sockaddr.storage = undefined;
        var dest_sa_len: posix.socklen_t = 0;
        dest.toSockaddr(&dest_sa, &dest_sa_len);
        if (c.usrsctp_connect(sock, sa(&dest_sa), dest_sa_len) != 0) {
            std.log.err("usrsctp_connect failed errno={d}", .{std.c._errno().*});
            return error.ConnectFailed;
        }

        return .{ .sock = sock, .io = io };
    }

    /// Send data on one SCTP stream.
    /// The buffer must remain valid until this call returns.
    pub fn send(self: *const SctpSender, stream_id: u16, data: []const u8) !void {
        const sock = self.sock orelse return error.NotConnected;
        var sndinfo = std.mem.zeroes(c.sctp_sndinfo);
        sndinfo.snd_sid = stream_id;
        const rc = c.usrsctp_sendv(
            sock,
            data.ptr,
            data.len,
            null,
            0,
            &sndinfo,
            @sizeOf(c.sctp_sndinfo),
            c.SCTP_SENDV_SNDINFO,
            0,
        );
        if (rc < 0) return error.SendFailed;
        if (@as(usize, @intCast(rc)) != data.len) return error.PartialSend;
    }

    /// Query the SCTP fragmentation point with SCTP_STATUS.
    /// usrsctp provides this value after connect.
    ///
    /// Cap the result to a 1452-byte payload for an Ethernet-like path.
    /// This avoids large loopback blocks. Return 1200 when the query is empty.
    pub fn maxSegSize(self: *const SctpSender) u32 {
        const sock = self.sock orelse return 1200;
        var status = std.mem.zeroes(c.sctp_status);
        var len: c.socklen_t = @sizeOf(c.sctp_status);
        _ = c.usrsctp_getsockopt(sock, c.IPPROTO_SCTP, c.SCTP_STATUS, &status, &len);
        const frag = status.sstat_fragmentation_point;
        if (frag == 0) return 1200;
        // Cap the fragmentation point to an Ethernet-like payload.
        const cap: u32 = 1500 - 48;
        const effective = @min(@as(u32, @intCast(frag)), cap);
        return (effective & ~@as(u32, 3)) -| 2;
    }

    /// Wake a thread blocked in send without releasing the socket.
    pub fn shutdown(self: *SctpSender) void {
        if (self.sock) |sock| _ = c.usrsctp_shutdown(sock, 2); // SHUT_RDWR.
    }

    /// Close the sender socket and release one stack reference.
    pub fn close(self: *SctpSender) void {
        if (self.sock) |sock| {
            c.usrsctp_close(sock);
            self.sock = null;
            deinitStack();
        }
    }
};

/// usrsctp receiver with an opaque socket handle.
/// It supports sender takeover with tryAcceptNew() and promotePending().
pub const SctpReceiver = struct {
    /// Listen socket handle.
    /// Nullable so cancel() can release it before close().
    listen_sock: ?*c.struct_socket = null,
    /// Active association socket.
    conn_sock: ?*c.struct_socket = null,
    /// Pending takeover socket.
    pending_sock: ?*c.struct_socket = null,
    /// Peer address of the active association.
    /// Cleared by closeConn().
    peer_addr: ?SocketAddr = null,
    /// Peer address of the pending takeover association.
    pending_peer_addr: ?SocketAddr = null,
    /// Io context captured at initialization.
    io: std.Io = std.Io.failing,
    /// True while this receiver owns one stack reference.
    stack_acquired: bool = false,

    /// usrsctp receiver options.
    pub const Config = struct {
        /// Disable Nagle-style batching on accepted connections.
        nodelay: bool = true,
        /// Reserved for backend parity. The current backend ignores this field.
        rcvbuf_size: u32 = 0,
        /// Remote UDP encapsulation port. Zero leaves the peer port unset.
        udp_encaps_port: u16 = 0,
    };

    /// Bind and listen on `bind_addr`.
    /// `num_streams` is the requested inbound and outbound stream count.
    /// Call `accept()` to wait for a sender.
    /// The Io context must outlive the returned receiver.
    pub fn init(bind_addr: SocketAddr, num_streams: u16, cfg: Config, io: std.Io) !SctpReceiver {
        try initStack(0, io);
        errdefer deinitStack();

        const sock = c.usrsctp_socket(
            @intCast(bind_addr.family()),
            posix.SOCK.STREAM,
            c.IPPROTO_SCTP,
            null,
            null,
            0,
            null,
        ) orelse return error.SocketFailed;
        errdefer c.usrsctp_close(sock);

        var initmsg = std.mem.zeroes(c.sctp_initmsg);
        initmsg.sinit_num_ostreams = num_streams;
        initmsg.sinit_max_instreams = num_streams;
        if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_INITMSG, &initmsg, @sizeOf(c.sctp_initmsg)) != 0)
            return error.SetSockOptFailed;

        if (cfg.udp_encaps_port > 0) {
            // Configure the remote peer port for future associations. The
            // local UDP port is process-wide and is selected by initStack().
            var encaps = std.mem.zeroes(c.sctp_udpencaps);
            const wildcard = switch (bind_addr.ip) {
                .ip4 => SocketAddr.anyIp4(0),
                .ip6 => SocketAddr.parseIp6(.{0} ** 16, 0, 0),
            };
            var enc_sa: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
            var enc_sa_len: posix.socklen_t = 0;
            wildcard.toSockaddr(&enc_sa, &enc_sa_len);
            const ss_size = @min(@sizeOf(posix.sockaddr.storage), @sizeOf(@TypeOf(encaps.sue_address)));
            @memcpy(
                @as([*]u8, @ptrCast(&encaps.sue_address))[0..ss_size],
                @as([*]const u8, @ptrCast(&enc_sa))[0..ss_size],
            );
            encaps.sue_assoc_id = 0;
            encaps.sue_port = std.mem.nativeToBig(u16, cfg.udp_encaps_port);
            if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_REMOTE_UDP_ENCAPS_PORT, &encaps, @sizeOf(c.sctp_udpencaps)) != 0)
                return error.SetSockOptFailed;
        }

        const rcvinfo_on: c_int = 1;
        if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_RECVRCVINFO, &rcvinfo_on, @sizeOf(c_int)) != 0)
            return error.SetSockOptFailed;

        // SAFETY: toSockaddr() fills bind_sa before bind reads it.
        var bind_sa: posix.sockaddr.storage = undefined;
        var bind_sa_len: posix.socklen_t = 0;
        bind_addr.toSockaddr(&bind_sa, &bind_sa_len);
        if (c.usrsctp_bind(sock, sa(&bind_sa), bind_sa_len) != 0)
            return error.BindFailed;
        if (c.usrsctp_listen(sock, 1) != 0)
            return error.ListenFailed;

        return .{ .listen_sock = sock, .io = io, .stack_acquired = true };
    }

    /// Check for a new sender without blocking.
    /// Temporarily set the listen socket non-blocking and accept one connection.
    /// Restore blocking mode before returning. Store the result in pending_sock.
    /// Return true when a connection was captured.
    /// Call this only when no pending connection exists.
    pub fn tryAcceptNew(self: *SctpReceiver, cfg: Config) bool {
        if (self.pending_sock != null) return true;
        const ls = self.listen_sock orelse return false;
        if (c.usrsctp_set_non_blocking(ls, 1) != 0) return false;
        var addrlen: u32 = @sizeOf(posix.sockaddr.storage);
        var addr_buf: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
        const conn = c.usrsctp_accept(ls, sa(&addr_buf), &addrlen);
        if (c.usrsctp_set_non_blocking(ls, 0) != 0) {
            if (conn) |sock| c.usrsctp_close(sock);
            return false;
        }

        const sock = conn orelse return false;

        if (cfg.nodelay) {
            const one: u32 = 1;
            if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_NODELAY, &one, @sizeOf(@TypeOf(one))) != 0) {
                c.usrsctp_close(sock);
                return false;
            }
        }
        const rcvinfo_on: c_int = 1;
        if (c.usrsctp_setsockopt(sock, c.IPPROTO_SCTP, c.SCTP_RECVRCVINFO, &rcvinfo_on, @sizeOf(c_int)) != 0) {
            c.usrsctp_close(sock);
            return false;
        }

        self.pending_sock = sock;
        self.pending_peer_addr = SocketAddr.fromSockaddr(&addr_buf, addrlen) catch null;
        return true;
    }

    /// Close the active connection socket.
    /// Do not close the listen socket. Call this after the receive thread has
    /// stopped.
    pub fn closeConn(self: *SctpReceiver) void {
        self.shutdownConn();
        if (self.conn_sock) |s| {
            c.usrsctp_close(s);
            self.conn_sock = null;
        }
        self.peer_addr = null;
    }

    /// Wake a thread blocked in recv without releasing the socket.
    pub fn shutdownConn(self: *SctpReceiver) void {
        if (self.conn_sock) |s| _ = c.usrsctp_shutdown(s, 2); // SHUT_RDWR.
    }

    /// Wake threads blocked in accept or recv without releasing sockets.
    /// Call close() after the workers have exited.
    pub fn shutdown(self: *SctpReceiver) void {
        self.shutdownConn();
        if (self.listen_sock) |s| _ = c.usrsctp_shutdown(s, 2); // SHUT_RDWR.
    }

    /// Wake threads blocked in accept or recv. Call close() after the workers
    /// have exited to release the sockets.
    pub fn cancel(self: *SctpReceiver) void {
        self.shutdown();
    }

    /// Return true when a pending connection is waiting for promotion.
    pub fn hasPending(self: *const SctpReceiver) bool {
        return self.pending_sock != null;
    }

    /// Promote the pending connection to conn_sock.
    /// Call closeConn() first.
    pub fn promotePending(self: *SctpReceiver) !void {
        if (self.conn_sock != null or self.pending_sock == null) return error.InvalidState;
        self.conn_sock = self.pending_sock;
        self.pending_sock = null;
        self.peer_addr = self.pending_peer_addr;
        self.pending_peer_addr = null;
    }

    /// Accept one incoming SCTP association.
    /// Block until a sender connects.
    pub fn accept(self: *SctpReceiver, cfg: Config) !void {
        if (self.conn_sock != null or self.pending_sock != null) return error.InvalidState;
        const ls = self.listen_sock orelse return error.NotConnected;
        var addrlen: u32 = @sizeOf(posix.sockaddr.storage);
        var addr_buf: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
        const conn = c.usrsctp_accept(ls, sa(&addr_buf), &addrlen) orelse
            return error.AcceptFailed;
        errdefer c.usrsctp_close(conn);

        if (cfg.nodelay) {
            const one: u32 = 1;
            if (c.usrsctp_setsockopt(conn, c.IPPROTO_SCTP, c.SCTP_NODELAY, &one, @sizeOf(u32)) != 0)
                return error.SetSockOptFailed;
        }

        const rcvinfo_on: c_int = 1;
        if (c.usrsctp_setsockopt(conn, c.IPPROTO_SCTP, c.SCTP_RECVRCVINFO, &rcvinfo_on, @sizeOf(c_int)) != 0)
            return error.SetSockOptFailed;

        self.conn_sock = conn;
        self.peer_addr = SocketAddr.fromSockaddr(&addr_buf, addrlen) catch null;
    }

    /// Return the active peer address, or null when no association is active.
    /// The value is captured by accept() or promotePending().
    pub fn peerAddress(self: *const SctpReceiver) ?SocketAddr {
        return self.peer_addr;
    }

    /// Receive one SCTP message into `buf`.
    /// Return its stream ID and byte count.
    /// Block until data arrives or the connection closes.
    /// The buffer must be large enough for the message.
    pub fn recv(self: *const SctpReceiver, buf: []u8) !RecvResult {
        const conn = self.conn_sock orelse return error.NotConnected;

        var rcvinfo = std.mem.zeroes(c.sctp_rcvinfo);
        var infolen: u32 = @sizeOf(c.sctp_rcvinfo);
        var infotype: c_uint = 0;
        var msg_flags: c_int = 0;

        const rc = c.usrsctp_recvv(
            conn,
            buf.ptr,
            buf.len,
            null,
            null,
            &rcvinfo,
            &infolen,
            &infotype,
            &msg_flags,
        );
        if (rc <= 0) {
            if (rc == 0) return error.ConnectionClosed;
            return error.RecvFailed;
        }
        if (@as(usize, @intCast(rc)) > buf.len) return error.InvalidMessage;

        if ((msg_flags & posix.MSG.TRUNC) != 0 or
            (msg_flags & posix.MSG.EOR) == 0 or
            (msg_flags & c.MSG_NOTIFICATION) != 0)
        {
            return error.InvalidMessage;
        }
        if (infotype != c.SCTP_RECVV_RCVINFO or infolen < @sizeOf(c.sctp_rcvinfo)) {
            return error.MissingStreamInfo;
        }

        const stream_id: u16 = rcvinfo.rcv_sid;
        return .{ .stream_id = stream_id, .len = @intCast(rc) };
    }

    /// Close all pending, active, and listening sockets.
    /// Release the receiver's reference to the usrsctp stack.
    pub fn close(self: *SctpReceiver) void {
        if (self.pending_sock) |s| {
            c.usrsctp_close(s);
            self.pending_sock = null;
        }
        if (self.conn_sock) |s| {
            c.usrsctp_close(s);
            self.conn_sock = null;
        }
        if (self.listen_sock) |ls| {
            c.usrsctp_close(ls);
            self.listen_sock = null;
        }
        if (self.stack_acquired) {
            deinitStack();
            self.stack_acquired = false;
        }
    }
};

// ---------------------------------------------------------------------------
// Stack lifecycle tests exercise the global reference count in one process.
// Network round-trip tests use the peer helper on macOS loopback.
// The sender and receiver processes need separate UDP ports.
// ---------------------------------------------------------------------------

/// Test Io context used by sleep and lock primitives.
const test_io = std.testing.io;

/// Sleep for a test interval with the test Io context.
fn sleepMs(ms: i64) void {
    std.Io.sleep(test_io, std.Io.Duration.fromMilliseconds(ms), .awake) catch |e|
        std.log.warn("sleepMs sleep failed: {}", .{e});
}

test "acquireStack/releaseStack refcount" {
    // Start from a zero-reference state.
    deinitStack();

    // The first acquire initializes usrsctp and records the port.
    try acquireStack(9899, test_io);
    try std.testing.expectEqual(g_stack_refcount, 1);
    try std.testing.expectEqual(g_stack_port, 9899);

    // A matching port increments the count without reinitializing the stack.
    try acquireStack(9899, test_io);
    try std.testing.expectEqual(g_stack_refcount, 2);

    // Port zero increments the count without changing the stored port.
    try acquireStack(0, test_io);
    try std.testing.expectEqual(g_stack_refcount, 3);
    try std.testing.expectEqual(g_stack_port, 9899);

    // Each release decrements the count. usrsctp_finish runs at zero.
    releaseStack();
    try std.testing.expectEqual(g_stack_refcount, 2);
    releaseStack();
    try std.testing.expectEqual(g_stack_refcount, 1);
    releaseStack();
    try std.testing.expectEqual(g_stack_refcount, 0);

    // The stored port remains available for later state checks.
}

test "acquireStack port mismatch error" {
    deinitStack();

    // Initialize the stack with port 9899.
    try acquireStack(9899, test_io);
    defer releaseStack();

    // A different port must be rejected without disturbing the stack.
    try std.testing.expectError(error.PortMismatch, acquireStack(9900, test_io));
    // The failed acquire must not increment the count.
    try std.testing.expectEqual(g_stack_refcount, 1);

    // The same port and port zero are both valid.
    try acquireStack(9899, test_io);
    try acquireStack(0, test_io);
    try std.testing.expectEqual(g_stack_refcount, 3);

    // Release the remaining references.
    releaseStack();
    releaseStack();
}

test "SctpReceiver cancel is safe to call without a peer" {
    // usrsctp accept() waits on an internal condition.
    // Closing the listen socket does not reliably wake that condition.
    // This test checks that cancel() clears the handle and close() is safe.
    deinitStack();

    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(5099),
        2,
        .{},
        test_io,
    );

    receiver.cancel();
    try std.testing.expect(receiver.listen_sock != null);
    try std.testing.expect(receiver.conn_sock == null);

    // close() must be safe after cancel().
    receiver.close();
}
