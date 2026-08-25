/// Linux kernel SCTP backend.
///
/// Uses native SCTP sockets with protocol number 132.
/// Socket operations use raw `std.os.linux` syscalls because Zig 0.16 no
/// longer exposes these wrappers from `std.posix`.
/// SCTP send and receive operations match the kernel `msghdr` cmsg layout.
///
/// The Linux `sctp` kernel module must be loaded.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const SocketAddr = @import("sctp.zig").SocketAddr;
const ConnectState = @import("connect_state.zig").ConnectState;

/// IANA protocol number for SCTP (RFC 4960).
pub const IPPROTO_SCTP: u32 = 132;

// ---------------------------------------------------------------------------
// Raw syscall helpers.
//
// These wrappers translate Linux syscall results into Zig errors.
// Linux encodes a failed syscall as a negative errno in the usize result.
// Only errors relevant to this module receive distinct mappings.
// ---------------------------------------------------------------------------

fn sysSocket(domain: u32, sock_type: u32, protocol: u32) !posix.fd_t {
    const rc = linux.socket(domain, sock_type, protocol);
    return unwrapFd(rc, .{
        .ACCES = error.PermissionDenied,
        .ADDRINUSE = error.AddressInUse,
        .MFILE = error.ProcessFdQuotaExceeded,
        .NFILE = error.SystemFdQuotaExceeded,
        .NOBUFS = error.SystemResources,
        .NOMEM = error.SystemResources,
        .PROTONOSUPPORT = error.ProtocolNotSupported,
    }, error.SocketFailed);
}

fn sysBind(fd: posix.fd_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    const rc = linux.bind(fd, addr, len);
    try unwrapVoid(rc, .{
        .ACCES = error.PermissionDenied,
        .ADDRINUSE = error.AddressInUse,
        .ADDRNOTAVAIL = error.AddressNotAvailable,
        .INVAL = error.InvalidArgument,
        .NOBUFS = error.SystemResources,
        .NOMEM = error.SystemResources,
    }, error.BindFailed);
}

fn sysListen(fd: posix.fd_t, backlog: u32) !void {
    const rc = linux.listen(fd, backlog);
    try unwrapVoid(rc, .{
        .ADDRINUSE = error.AddressInUse,
        .INVAL = error.InvalidArgument,
        .NOBUFS = error.SystemResources,
        .OPNOTSUPP = error.OperationNotSupported,
    }, error.ListenFailed);
}

fn sysConnect(fd: posix.fd_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    const rc = linux.connect(fd, addr, len);
    try unwrapVoid(rc, .{
        .ACCES = error.PermissionDenied,
        .ADDRINUSE = error.AddressInUse,
        .ADDRNOTAVAIL = error.AddressNotAvailable,
        .AFNOSUPPORT = error.AddressFamilyNotSupported,
        .AGAIN = error.WouldBlock,
        .ALREADY = error.WouldBlock,
        .CONNREFUSED = error.ConnectionRefused,
        .INVAL = error.InvalidArgument,
        .NETUNREACH = error.NetworkUnreachable,
        .HOSTUNREACH = error.NetworkUnreachable,
        .NOTSOCK = error.NotASocket,
        .PROTOTYPE = error.ProtocolNotSupported,
        .TIMEDOUT = error.TimedOut,
    }, error.ConnectFailed);
}

fn sysAccept(fd: posix.fd_t, addr: ?*posix.sockaddr, len: ?*posix.socklen_t) !posix.fd_t {
    const rc = linux.accept(fd, addr, len);
    return unwrapFd(rc, .{
        .AGAIN = error.WouldBlock,
        .BADF = error.FileDescriptorInvalid,
        .CONNABORTED = error.ConnectionAborted,
        .FAULT = error.InvalidAddress,
        .INVAL = error.InvalidArgument,
        .MFILE = error.ProcessFdQuotaExceeded,
        .NFILE = error.SystemFdQuotaExceeded,
        .NOBUFS = error.SystemResources,
        .NOMEM = error.SystemResources,
        .OPNOTSUPP = error.OperationNotSupported,
    }, error.AcceptFailed);
}

fn sysShutdown(fd: posix.fd_t, how: i32) void {
    _ = linux.shutdown(fd, how);
}

fn sysClose(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

const ErrnoMap = struct {
    inline fn get(comptime map: anytype, e: linux.E) ?anyerror {
        const fields = std.meta.fields(@TypeOf(map));
        inline for (fields) |f| {
            if (@field(linux.E, f.name) == e) return @field(map, f.name);
        }
        return null;
    }
};

fn unwrapFd(rc: usize, comptime map: anytype, fallback: anyerror) !posix.fd_t {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return @intCast(signed);
    const err = linux.errno(rc);
    if (ErrnoMap.get(map, err)) |e| return e;
    return fallback;
}

fn unwrapVoid(rc: usize, comptime map: anytype, fallback: anyerror) !void {
    const signed: isize = @bitCast(rc);
    if (signed == 0) return;
    const err = linux.errno(rc);
    if (ErrnoMap.get(map, err)) |e| return e;
    return fallback;
}

// ---------------------------------------------------------------------------
// SCTP socket option constants from linux/sctp.h.
// ---------------------------------------------------------------------------
const SCTP_NODELAY: u32 = 3; // Disable Nagle-style batching.
const SCTP_INITMSG: u32 = 2; // Set stream counts for new associations.
const SCTP_REMOTE_UDP_ENCAPS_PORT: u32 = 132; // RFC 6951 UDP port.

// Standard socket option constants from linux/socket.h.
const SOL_SOCKET: u32 = 1; // Generic socket option level.
const SO_SNDBUF: u32 = 7; // Send buffer size in bytes.

/// Mirror of struct sctp_initmsg.
/// It requests inbound and outbound stream counts during the SCTP handshake.
/// Set it with SCTP_INITMSG before connect() or listen().
const SctpInitMsg = extern struct {
    sinit_num_ostreams: u16,
    sinit_max_instreams: u16,
    sinit_max_attempts: u16,
    sinit_max_init_timeo: u16,
};

/// Mirror of struct sctp_udpencaps from RFC 6951.
/// `sue_port` is in network byte order. The standard port is 9899.
const SctpUdpEncaps = extern struct {
    sue_assoc_id: i32,
    sue_address: posix.sockaddr.storage,
    sue_port: u16, // Network byte order.
};

/// Mirror of struct sctp_sndrcvinfo from linux/sctp.h.
/// This legacy structure has broad kernel support.
/// Only `sinfo_stream` is used. The other fields are zeroed.
const SctpSndRcvInfo = extern struct {
    sinfo_stream: u16,
    sinfo_ssn: u16,
    sinfo_flags: u16,
    sinfo_pr_policy: u16,
    sinfo_ppid: u32,
    sinfo_context: u32,
    sinfo_timetolive: u32,
    sinfo_tsn: u32,
    sinfo_cumtsn: u32,
    sinfo_assoc_id: i32,
};

/// cmsg type for SCTP_SNDRCV from linux/sctp.h.
const SCTP_SNDRCV: c_int = 1;

/// Linux control-message header used by sendmsg() and recvmsg().
/// Define it locally so SCTP-specific ancillary data can be constructed.
const cmsghdr = extern struct {
    len: usize,
    level: c_int,
    type: c_int,

    fn data(self: *cmsghdr) [*]u8 {
        const hdr_ptr: [*]u8 = @ptrCast(self);
        return hdr_ptr + cmsgAlign(@sizeOf(cmsghdr));
    }
};

/// Alignment required for a control-message header.
const CMSG_ALIGN = @alignOf(usize);

/// Round `len` up to the control-message alignment boundary.
fn cmsgAlign(len: usize) usize {
    return std.mem.alignForward(usize, len, CMSG_ALIGN);
}

/// Return the control-message length for a payload of `data_len` bytes.
/// The result excludes trailing padding.
fn cmsgLen(data_len: usize) usize {
    return cmsgAlign(@sizeOf(cmsghdr)) + data_len;
}

/// Return the storage required for a control message and its trailing padding.
fn cmsgSpace(data_len: usize) usize {
    return cmsgAlign(cmsgLen(data_len));
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// SCTP sender for a one-to-one association.
/// Call `init()` before sending data on a negotiated stream.
pub const SctpSender = struct {
    /// Connected Linux SCTP socket.
    fd: posix.fd_t = -1,
    /// Io context retained for interface parity with the usrsctp backend.
    /// The Linux raw-syscall path does not use it.
    io: std.Io = std.Io.failing,

    /// Linux SCTP sender options.
    pub const Config = struct {
        /// Disable Nagle-style batching when true.
        nodelay: bool = true,
        /// SO_SNDBUF size in bytes. Zero selects the kernel default.
        sndbuf_size: u32 = 0,
        /// Remote RFC 6951 UDP port. Zero disables encapsulation.
        udp_encaps_port: u16 = 0,
    };

    /// Create, configure, and connect an SCTP socket to `dest`.
    /// `num_streams` is the requested inbound and outbound stream count.
    ///
    /// Socket setup sequence:
    ///   1. Create a STREAM socket with IPPROTO_SCTP.
    ///   2. Set SCTP_INITMSG with the requested stream counts.
    ///   3. Set SCTP_NODELAY when configured.
    ///   4. Set SO_SNDBUF when configured.
    ///   5. Set the RFC 6951 port when configured.
    ///   6. Call the blocking connect syscall.
    ///
    /// When non-null, `cancel_state` coordinates cancellation of the blocking
    /// connect syscall with the descriptor owner.
    ///
    /// Capture `io` for API parity with the usrsctp backend.
    /// The context must outlive the returned sender.
    pub fn init(dest: SocketAddr, num_streams: u16, cfg: Config, cancel_state: ?*ConnectState, io: std.Io) !SctpSender {
        if (cancel_state) |state| state.begin();
        const fd = try sysSocket(dest.family(), posix.SOCK.STREAM, IPPROTO_SCTP);
        var owns_fd = true;
        errdefer if (owns_fd) sysClose(fd);

        // Request the desired inbound and outbound stream counts.
        const initmsg = SctpInitMsg{
            .sinit_num_ostreams = num_streams,
            .sinit_max_instreams = num_streams,
            .sinit_max_attempts = 0,
            .sinit_max_init_timeo = 0,
        };
        try posix.setsockopt(fd, IPPROTO_SCTP, SCTP_INITMSG, std.mem.asBytes(&initmsg));

        if (cfg.nodelay) {
            try posix.setsockopt(fd, IPPROTO_SCTP, SCTP_NODELAY, std.mem.asBytes(&@as(u32, 1)));
        }

        if (cfg.sndbuf_size > 0) {
            try posix.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, std.mem.asBytes(&cfg.sndbuf_size));
        }

        if (cfg.udp_encaps_port > 0) {
            var encaps = std.mem.zeroes(SctpUdpEncaps);
            const wildcard = switch (dest.ip) {
                .ip4 => SocketAddr.anyIp4(0),
                .ip6 => SocketAddr.parseIp6(.{0} ** 16, 0, 0),
            };
            var encaps_addr_len: posix.socklen_t = 0;
            wildcard.toSockaddr(&encaps.sue_address, &encaps_addr_len);
            encaps.sue_assoc_id = 0;
            encaps.sue_port = std.mem.nativeToBig(u16, cfg.udp_encaps_port);
            try posix.setsockopt(fd, IPPROTO_SCTP, SCTP_REMOTE_UDP_ENCAPS_PORT, std.mem.asBytes(&encaps));
        }

        // Publish the fd immediately before the only blocking operation.
        if (cancel_state) |state| {
            if (!state.publish(fd)) {
                const claimed = state.claimFd();
                if (claimed == fd) sysClose(fd);
                owns_fd = false;
                return error.ConnectCanceled;
            }
        }

        // SAFETY: toSockaddr() fills sa before connect reads it.
        var sa: posix.sockaddr.storage = undefined;
        var sa_len: posix.socklen_t = 0;
        dest.toSockaddr(&sa, &sa_len);

        if (cancel_state) |state| {
            var connect_error: ?anyerror = null;
            sysConnect(fd, @ptrCast(&sa), sa_len) catch |err| {
                connect_error = err;
            };
            if (!state.finish(connect_error == null, fd)) {
                const claimed = state.claimFd();
                if (claimed == fd) sysClose(fd);
                owns_fd = false;
                return error.ConnectCanceled;
            }
            if (connect_error) |err| return err;
            owns_fd = false;
        } else {
            try sysConnect(fd, @ptrCast(&sa), sa_len);
        }

        return .{
            .fd = fd,
            .io = io,
        };
    }

    /// Send data on a specific SCTP stream.
    /// The kernel reads directly from the caller's buffer during sendmsg().
    /// Stream selection uses an SCTP_SNDRCV control message.
    /// The buffer must remain valid until this call returns.
    pub fn send(self: *const SctpSender, stream_id: u16, data: []const u8) !void {
        if (self.fd == -1) return error.NotConnected;
        // Build the SCTP_SNDRCV control message to select the stream.
        const iov = [1]posix.iovec_const{.{
            .base = data.ptr,
            .len = data.len,
        }};

        // Use the legacy SCTP_SNDRCV message supported by the kernel API.
        const cmsg_space_val = comptime cmsgSpace(@sizeOf(SctpSndRcvInfo));
        var cmsg_buf: [cmsg_space_val]u8 align(CMSG_ALIGN) = std.mem.zeroes([cmsg_space_val]u8);

        const cmsg: *cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
        cmsg.level = @intCast(IPPROTO_SCTP);
        cmsg.type = SCTP_SNDRCV;
        cmsg.len = cmsgLen(@sizeOf(SctpSndRcvInfo));

        const sinfo: *SctpSndRcvInfo = @ptrCast(@alignCast(cmsg.data()));
        sinfo.* = std.mem.zeroes(SctpSndRcvInfo);
        sinfo.sinfo_stream = stream_id;

        const msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg.len,
            .flags = 0,
        };

        const rc = linux.sendmsg(self.fd, &msg, linux.MSG.NOSIGNAL);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            const err: linux.E = linux.errno(rc);
            return switch (err) {
                .INVAL => error.InvalidArgument,
                .AGAIN => error.WouldBlock,
                .CONNRESET => error.ConnectionResetByPeer,
                .PIPE => error.BrokenPipe,
                .NOBUFS, .NOMEM => error.SystemResources,
                .NETUNREACH, .HOSTUNREACH => error.NetworkUnreachable,
                else => error.SendFailed,
            };
        }
        const sent: usize = @intCast(signed);
        if (sent != data.len) return error.PartialSend;
    }

    /// Wake a thread blocked in sendmsg() without releasing the descriptor.
    pub fn shutdown(self: *SctpSender) void {
        if (self.fd != -1) sysShutdown(self.fd, 2); // SHUT_RDWR.
    }

    /// Cancel a blocking connect and close the descriptor claimed by the
    /// cancellation operation.
    pub fn cancelConnect(state: *ConnectState) void {
        if (state.cancel()) |fd| sysClose(fd);
    }

    /// Estimate the maximum WavPack block payload for the path.
    ///
    /// Use IP_MTU because SCTP path discovery may not be complete at connect.
    /// The SCTP fragmentation point can be too large at that time.
    ///
    /// The IPv4 overhead estimate is 20 bytes for IP, 12 bytes for SCTP, and
    /// 16 bytes for the DATA chunk. The total is 48 bytes.
    ///
    /// Cap the effective MTU at 1500 bytes. This prevents large loopback MTUs
    /// from producing high-latency blocks and keeps tests near Ethernet paths.
    ///
    /// Align the result down to four bytes and subtract two for WavPack
    /// alignment. Return 1200 when the MTU query fails.
    pub fn maxSegSize(self: *const SctpSender) u32 {
        if (self.fd == -1) return 1200;
        // IP_MTU gives the route MTU without waiting for SCTP path discovery.
        const IPPROTO_IP: u32 = 0;
        const IP_MTU: u32 = 14;
        var mtu: i32 = 0;
        var optlen: posix.socklen_t = @sizeOf(i32);
        const rc = linux.syscall5(
            .getsockopt,
            @as(usize, @intCast(self.fd)),
            @as(usize, IPPROTO_IP),
            @as(usize, IP_MTU),
            @intFromPtr(&mtu),
            @intFromPtr(&optlen),
        );
        const signed: isize = @bitCast(rc);
        // Subtract the IPv4, SCTP, and DATA chunk headers.
        const overhead: i32 = 48;
        if (signed != 0 or mtu <= overhead) return 1200;
        // Cap loopback's large MTU at an Ethernet-like value.
        const effective_mtu: i32 = @min(mtu, 1500);
        const payload: u32 = @intCast(effective_mtu - overhead);
        // Match WavPack's alignment requirement.
        return (payload & ~@as(u32, 3)) -| 2;
    }

    /// Close the sender socket.
    pub fn close(self: *SctpSender) void {
        if (self.fd == -1) return;
        sysClose(self.fd);
        self.fd = -1;
    }
};

// SCTP socket options for the receiver.
const SO_RCVBUF: u32 = 8; // Receive buffer size.
const SCTP_RECVRCVINFO: u32 = 32; // Enable SCTP_RCVINFO on recvmsg.
const SCTP_RCVINFO: c_int = 3; // cmsg type containing the stream ID.
const MSG_NOTIFICATION: c_int = 0x8000;

/// Mirror of struct sctp_rcvinfo from RFC 6458.
/// Only `rcv_sid` is used. It identifies the SCTP stream.
const SctpRcvInfo = extern struct {
    rcv_sid: u16, // Stream ID for this message.
    rcv_ssn: u16,
    rcv_flags: u16,
    _pad: u16,
    rcv_ppid: u32,
    rcv_tsn: u32,
    rcv_cumtsn: u32,
    rcv_context: u32,
    rcv_assoc_id: i32,
};

/// Result of one recvmsg call.
/// It contains the SCTP stream ID and the number of bytes written.
pub const RecvResult = struct {
    /// SCTP stream ID for the message.
    stream_id: u16,
    /// Number of bytes written into the receive buffer.
    len: usize,
};

/// SCTP receiver for one-to-one associations.
/// It can accept a pending connection while another session is active.
pub const SctpReceiver = struct {
    /// Listening socket.
    listen_fd: posix.fd_t = -1,
    /// Active association socket. -1 means none.
    conn_fd: posix.fd_t = -1,
    /// Pending takeover socket. -1 means none.
    pending_fd: posix.fd_t = -1,
    /// Peer address of the active association.
    /// Cleared by closeConn().
    peer_addr: ?SocketAddr = null,
    /// Peer address of the pending takeover association.
    pending_peer_addr: ?SocketAddr = null,
    /// Io context retained for API parity with the usrsctp backend.
    io: std.Io = std.Io.failing,

    /// Linux SCTP receiver options.
    pub const Config = struct {
        /// Disable Nagle-style batching on accepted connections.
        nodelay: bool = true,
        /// SO_RCVBUF size in bytes. Zero selects the kernel default.
        rcvbuf_size: u32 = 0,
        /// Remote RFC 6951 UDP port. Zero disables encapsulation.
        udp_encaps_port: u16 = 0,
    };

    /// Bind and listen on `bind_addr`.
    /// `num_streams` is the requested inbound and outbound stream count.
    /// SO_REUSEADDR permits quick restarts after a previous session.
    /// Call `accept()` to wait for a sender.
    ///
    /// Capture `io` for API parity with the usrsctp backend.
    /// The context must outlive the returned receiver.
    pub fn init(bind_addr: SocketAddr, num_streams: u16, cfg: Config, io: std.Io) !SctpReceiver {
        const fd = try sysSocket(bind_addr.family(), posix.SOCK.STREAM, IPPROTO_SCTP);
        errdefer sysClose(fd);

        // Allow immediate address reuse after a restart.
        try posix.setsockopt(fd, SOL_SOCKET, 2, std.mem.asBytes(&@as(u32, 1))); // Enable SO_REUSEADDR.

        const initmsg = SctpInitMsg{
            .sinit_num_ostreams = num_streams,
            .sinit_max_instreams = num_streams,
            .sinit_max_attempts = 0,
            .sinit_max_init_timeo = 0,
        };
        try posix.setsockopt(fd, IPPROTO_SCTP, SCTP_INITMSG, std.mem.asBytes(&initmsg));

        if (cfg.rcvbuf_size > 0) {
            try posix.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, std.mem.asBytes(&cfg.rcvbuf_size));
        }

        if (cfg.udp_encaps_port > 0) {
            var encaps = std.mem.zeroes(SctpUdpEncaps);
            const wildcard = switch (bind_addr.ip) {
                .ip4 => SocketAddr.anyIp4(0),
                .ip6 => SocketAddr.parseIp6(.{0} ** 16, 0, 0),
            };
            var encaps_addr_len: posix.socklen_t = 0;
            wildcard.toSockaddr(&encaps.sue_address, &encaps_addr_len);
            encaps.sue_assoc_id = 0;
            encaps.sue_port = std.mem.nativeToBig(u16, cfg.udp_encaps_port);
            try posix.setsockopt(fd, IPPROTO_SCTP, SCTP_REMOTE_UDP_ENCAPS_PORT, std.mem.asBytes(&encaps));
        }

        // SAFETY: toSockaddr() fills sa before bind reads it.
        var sa: posix.sockaddr.storage = undefined;
        var sa_len: posix.socklen_t = 0;
        bind_addr.toSockaddr(&sa, &sa_len);
        try sysBind(fd, @ptrCast(&sa), sa_len);
        try sysListen(fd, 5);

        return .{
            .listen_fd = fd,
            .io = io,
        };
    }

    /// Check for a new sender without blocking.
    /// Accept and configure one ready connection into pending_fd.
    /// Return true when a pending connection was captured.
    /// Call this only when no pending connection exists.
    pub fn tryAcceptNew(self: *SctpReceiver, cfg: Config) bool {
        if (self.pending_fd != -1) return true;
        var pfd = [1]posix.pollfd{.{
            .fd = self.listen_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const n = posix.poll(&pfd, 0) catch return false;
        if (n == 0) return false;
        if (pfd[0].revents & posix.POLL.IN == 0) return false;

        // Capture the pending peer address.
        // SAFETY: sysAccept fills addr before any field is read.
        var addr: posix.sockaddr.storage = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const conn = sysAccept(self.listen_fd, @ptrCast(&addr), &addrlen) catch return false;

        if (cfg.nodelay) {
            posix.setsockopt(conn, IPPROTO_SCTP, SCTP_NODELAY, std.mem.asBytes(&@as(u32, 1))) catch {
                sysClose(conn);
                return false;
            };
        }
        posix.setsockopt(conn, IPPROTO_SCTP, SCTP_RECVRCVINFO, std.mem.asBytes(&@as(u32, 1))) catch {
            sysClose(conn);
            return false;
        };

        self.pending_fd = conn;
        self.pending_peer_addr = SocketAddr.fromSockaddr(&addr, addrlen) catch null;
        return true;
    }

    /// Close the active connection socket.
    /// Do not close the listening socket.
    /// Call this after the receive thread has stopped.
    pub fn closeConn(self: *SctpReceiver) void {
        self.shutdownConn();
        if (self.conn_fd != -1) {
            sysClose(self.conn_fd);
            self.conn_fd = -1;
        }
        self.peer_addr = null;
    }

    /// Wake a thread blocked in recvmsg() without releasing the descriptor.
    pub fn shutdownConn(self: *SctpReceiver) void {
        if (self.conn_fd != -1) sysShutdown(self.conn_fd, 2); // SHUT_RDWR.
    }

    /// Wake threads blocked in accept() or recvmsg() without releasing any
    /// descriptor. Call close() after the workers have exited.
    pub fn shutdown(self: *SctpReceiver) void {
        self.shutdownConn();
        if (self.listen_fd != -1) sysShutdown(self.listen_fd, 2); // SHUT_RDWR.
    }

    /// Return true when a pending connection is waiting for promotion.
    pub fn hasPending(self: *const SctpReceiver) bool {
        return self.pending_fd != -1;
    }

    /// Promote the pending connection to conn_fd.
    /// Call closeConn() first.
    pub fn promotePending(self: *SctpReceiver) !void {
        if (self.conn_fd != -1 or self.pending_fd == -1) return error.InvalidState;
        self.conn_fd = self.pending_fd;
        self.pending_fd = -1;
        self.peer_addr = self.pending_peer_addr;
        self.pending_peer_addr = null;
    }

    /// Accept one incoming SCTP association and block until it connects.
    /// Configure SCTP_NODELAY and enable SCTP_RCVINFO for stream IDs.
    pub fn accept(self: *SctpReceiver, cfg: Config) !void {
        if (self.conn_fd != -1 or self.pending_fd != -1) return error.InvalidState;
        // SAFETY: sysAccept fills addr before any field is read.
        var addr: posix.sockaddr.storage = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const conn = try sysAccept(self.listen_fd, @ptrCast(&addr), &addrlen);
        errdefer sysClose(conn);

        if (cfg.nodelay) {
            try posix.setsockopt(conn, IPPROTO_SCTP, SCTP_NODELAY, std.mem.asBytes(&@as(u32, 1)));
        }

        // Enable SCTP_RCVINFO in recvmsg ancillary data.
        try posix.setsockopt(conn, IPPROTO_SCTP, SCTP_RECVRCVINFO, std.mem.asBytes(&@as(u32, 1)));

        self.conn_fd = conn;
        self.peer_addr = SocketAddr.fromSockaddr(&addr, addrlen) catch null;
    }

    /// Return the active peer address, or null when no association is active.
    /// The value is captured by accept() or promotePending().
    pub fn peerAddress(self: *const SctpReceiver) ?SocketAddr {
        return self.peer_addr;
    }

    /// Receive one SCTP message into `buf`.
    /// Return its stream ID from SCTP_RCVINFO and its byte count.
    /// Block until data arrives or the connection closes.
    /// The buffer must be large enough for the message.
    pub fn recv(self: *const SctpReceiver, buf: []u8) !RecvResult {
        if (self.conn_fd == -1) return error.NotConnected;
        var iov = [1]posix.iovec{.{
            .base = buf.ptr,
            .len = buf.len,
        }};

        const cmsg_space_val = comptime cmsgSpace(@sizeOf(SctpRcvInfo));
        var cmsg_buf: [cmsg_space_val]u8 align(CMSG_ALIGN) = undefined;

        var msg = posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_space_val,
            .flags = 0,
        };

        const rc = linux.recvmsg(self.conn_fd, &msg, 0);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) {
            if (signed == 0) return error.ConnectionClosed;
            return error.RecvFailed;
        }
        const len: usize = @intCast(signed);
        if (len > buf.len) return error.InvalidMessage;

        if ((msg.flags & (linux.MSG.TRUNC | linux.MSG.CTRUNC)) != 0 or
            (msg.flags & MSG_NOTIFICATION) != 0 or
            (msg.flags & linux.MSG.EOR) == 0)
        {
            return error.InvalidMessage;
        }

        // Parse SCTP_RCVINFO to obtain the stream ID.
        var stream_id: u16 = 0;
        if (msg.controllen >= @sizeOf(cmsghdr)) {
            const cmsg: *cmsghdr = @ptrCast(@alignCast(@as([*]u8, @ptrCast(msg.control))));
            if (cmsg.level == IPPROTO_SCTP and
                cmsg.type == SCTP_RCVINFO and
                cmsg.len >= cmsgLen(@sizeOf(SctpRcvInfo)) and
                cmsg.len <= msg.controllen)
            {
                const info: *const SctpRcvInfo = @ptrCast(@alignCast(cmsg.data()));
                stream_id = info.rcv_sid;
            } else {
                return error.MissingStreamInfo;
            }
        } else {
            return error.MissingStreamInfo;
        }

        return .{
            .stream_id = stream_id,
            .len = len,
        };
    }

    /// Wake a thread blocked in accept() or recv(). Call close() after the
    /// worker has exited to release the descriptors.
    pub fn cancel(self: *SctpReceiver) void {
        self.shutdown();
    }

    /// Close all pending, active, and listening sockets.
    pub fn close(self: *SctpReceiver) void {
        if (self.pending_fd != -1) {
            sysClose(self.pending_fd);
            self.pending_fd = -1;
        }
        if (self.conn_fd != -1) {
            sysClose(self.conn_fd);
            self.conn_fd = -1;
        }
        if (self.listen_fd != -1) {
            sysClose(self.listen_fd);
            self.listen_fd = -1;
        }
        self.peer_addr = null;
        self.pending_peer_addr = null;
    }
};

// Linux backend tests.
/// Skip the test when the kernel cannot create an SCTP socket.
fn requireSctp() !void {
    const fd = sysSocket(posix.AF.INET, posix.SOCK.STREAM, IPPROTO_SCTP) catch
        return error.SkipZigTest;
    sysClose(fd);
}

/// Retrieve the port assigned to an SCTP listen socket after binding to port 0.
fn getBoundPort(fd: posix.fd_t) !u16 {
    // SAFETY: getsockname fills sa before any field is read.
    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const rc = linux.getsockname(fd, @ptrCast(&sa), &sa_len);
    if (@as(isize, @bitCast(rc)) < 0) return error.GetSockNameFailed;
    const addr = try SocketAddr.fromSockaddr(&sa, sa_len);
    return addr.getPort();
}

test "sender/receiver loopback" {
    try requireSctp();

    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(0),
        2,
        .{},
        std.testing.io,
    );
    defer receiver.close();

    const port = try getBoundPort(receiver.listen_fd);

    // Accept in a background thread.
    const AcceptThread = struct {
        fn run(recv: *SctpReceiver) void {
            recv.accept(.{}) catch {};
        }
    };
    const at = try std.Thread.spawn(.{}, AcceptThread.run, .{&receiver});

    // Connect sender.
    var sender = try SctpSender.init(
        SocketAddr.loopbackIp4(port),
        2,
        .{},
        null,
        std.testing.io,
    );
    defer sender.close();
    at.join();

    // Send one message and receive it.
    const payload = "hello";
    try sender.send(0, payload);

    var buf: [256]u8 = undefined;
    const result = try receiver.recv(&buf);
    try std.testing.expectEqual(result.stream_id, 0);
    try std.testing.expectEqual(result.len, payload.len);
    try std.testing.expectEqualSlices(u8, payload, buf[0..result.len]);
}

test "multi-stream send/receive" {
    try requireSctp();

    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(0),
        4,
        .{},
        std.testing.io,
    );
    defer receiver.close();

    const port = try getBoundPort(receiver.listen_fd);

    const at = try std.Thread.spawn(.{}, struct {
        fn run(recv: *SctpReceiver) void {
            recv.accept(.{}) catch {};
        }
    }.run, .{&receiver});

    var sender = try SctpSender.init(
        SocketAddr.loopbackIp4(port),
        4,
        .{},
        null,
        std.testing.io,
    );
    defer sender.close();
    at.join();

    // Send one message on each stream.
    try sender.send(0, "aaa");
    try sender.send(1, "bbb");
    try sender.send(2, "ccc");

    // Collect all three. Cross-stream order is not guaranteed.
    var got: [3]struct { stream_id: u16, data: [3]u8 } = undefined;
    var buf: [256]u8 = undefined;
    for (0..3) |i| {
        const r = try receiver.recv(&buf);
        got[i].stream_id = r.stream_id;
        @memcpy(&got[i].data, buf[0..3]);
    }

    // Verify the data and stream ID for each message.
    const expected = [_]struct { id: u16, data: []const u8 }{
        .{ .id = 0, .data = "aaa" },
        .{ .id = 1, .data = "bbb" },
        .{ .id = 2, .data = "ccc" },
    };
    for (expected) |exp| {
        var found = false;
        for (got) |g| {
            if (g.stream_id == exp.id and std.mem.eql(u8, &g.data, exp.data)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "cancel unblocks accept" {
    try requireSctp();

    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(0),
        2,
        .{},
        std.testing.io,
    );
    // cancel() closes the file descriptors.

    const at = try std.Thread.spawn(.{}, struct {
        fn run(recv: *SctpReceiver) void {
            recv.accept(.{}) catch {};
        }
    }.run, .{&receiver});

    // Sleep through the test Io context before canceling the receiver.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    receiver.cancel();
    at.join(); // This would hang if cancel did not wake accept().
    receiver.close();
}

test "SctpSender maxSegSize respects 1500 MTU cap on loopback" {
    try requireSctp();

    // Start a receiver so the sender has a peer to connect to.
    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(0),
        2,
        .{},
        std.testing.io,
    );
    defer receiver.close();
    const port = try getBoundPort(receiver.listen_fd);

    const at = try std.Thread.spawn(.{}, struct {
        fn run(recv: *SctpReceiver) void {
            recv.accept(.{}) catch {};
        }
    }.run, .{&receiver});

    var sender = try SctpSender.init(
        SocketAddr.loopbackIp4(port),
        2,
        .{},
        null,
        std.testing.io,
    );
    defer sender.close();
    at.join();

    const mss = sender.maxSegSize();
    // The effective loopback MTU must use the 1500-byte cap.
    // The resulting payload is at most 1450 bytes after overhead and alignment.
    try std.testing.expect(mss <= 1450);
    try std.testing.expect(mss >= 1200); // The fallback value is 1200.
}

test "SctpSender maxSegSize stays within path bounds" {
    try requireSctp();

    // A live socket cannot reliably force the IP_MTU fallback.
    // Exercise the public query on a connected loopback socket instead.
    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(0),
        2,
        .{},
        std.testing.io,
    );
    defer receiver.close();
    const port = try getBoundPort(receiver.listen_fd);

    const at = try std.Thread.spawn(.{}, struct {
        fn run(recv: *SctpReceiver) void {
            recv.accept(.{}) catch {};
        }
    }.run, .{&receiver});

    var sender = try SctpSender.init(
        SocketAddr.loopbackIp4(port),
        2,
        .{},
        null,
        std.testing.io,
    );
    defer sender.close();
    at.join();

    // The normal result is bounded by the effective payload cap.
    // The fallback result is 1200.
    const mss = sender.maxSegSize();
    try std.testing.expect(mss >= 1200);
    try std.testing.expect(mss <= 1500 - 48);
}

test "SctpReceiver recv extracts stream_id using SCTP_RCVINFO cmsg" {
    try requireSctp();

    var receiver = try SctpReceiver.init(
        SocketAddr.loopbackIp4(0),
        4,
        .{},
        std.testing.io,
    );
    defer receiver.close();
    const port = try getBoundPort(receiver.listen_fd);

    const at = try std.Thread.spawn(.{}, struct {
        fn run(recv: *SctpReceiver) void {
            recv.accept(.{}) catch {};
        }
    }.run, .{&receiver});

    var sender = try SctpSender.init(
        SocketAddr.loopbackIp4(port),
        4,
        .{},
        null,
        std.testing.io,
    );
    defer sender.close();
    at.join();

    // Send on streams 0, 1, and 2 and verify each received ID.
    try sender.send(0, "zero");
    try sender.send(1, "one!");
    try sender.send(2, "two!!");

    var buf: [16]u8 = undefined;
    var seen_streams = [_]bool{ false, false, false };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const r = try receiver.recv(&buf);
        // Use the payload to identify the expected stream ID.
        const payload = buf[0..r.len];
        const observed_id: u16 = switch (payload[0]) {
            'z' => 0,
            'o' => 1,
            't' => 2,
            else => 99,
        };
        try std.testing.expectEqual(observed_id, r.stream_id);
        if (observed_id < 3) seen_streams[observed_id] = true;
    }
    // Confirm that all three stream IDs were observed.
    for (seen_streams) |s| try std.testing.expect(s);
}
