const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
pub const ConnectState = @import("connect_state.zig").ConnectState;

/// Compile-time platform dispatch for SCTP transport.
///
/// Linux uses the kernel backend. Other targets use the usrsctp backend.
/// Both backends export SctpSender, SctpReceiver, RecvResult, and
/// IPPROTO_SCTP. UDP encapsulation and cancellation details remain backend-specific.
const backend = if (builtin.os.tag == .linux)
    @import("sctp_linux.zig")
else
    @import("sctp_usrsctp.zig");

/// SCTP protocol number exported by the selected backend.
pub const IPPROTO_SCTP = backend.IPPROTO_SCTP;
/// SCTP sender type exported by the selected backend.
pub const SctpSender = backend.SctpSender;
/// SCTP receiver type exported by the selected backend.
pub const SctpReceiver = backend.SctpReceiver;
/// Result returned by a receive operation.
pub const RecvResult = backend.RecvResult;

/// IP-family socket address used throughout sctp-wps.
///
/// The type wraps `std.Io.net.IpAddress` and supports POSIX sockaddr conversion.
/// Both the Linux and usrsctp backends use it.
///
/// It supports IPv4 and IPv6. Construct addresses with `parseIp4()` or
/// `parseIp6()`. Convert POSIX addresses with `fromSockaddr()`.
pub const SocketAddr = struct {
    /// IP address and host-order port.
    ip: std.Io.net.IpAddress,

    /// Construct an IPv4 address from four raw address bytes.
    /// Store the port in host byte order.
    pub fn parseIp4(ip: [4]u8, port: u16) SocketAddr {
        return .{ .ip = .{ .ip4 = .{ .bytes = ip, .port = port } } };
    }

    /// Construct an IPv6 address from sixteen raw address bytes.
    /// `zone` is the scope ID for a link-local address. Use zero for global addresses.
    pub fn parseIp6(ip: [16]u8, port: u16, zone: u32) SocketAddr {
        return .{ .ip = .{ .ip6 = .{
            .port = port,
            .bytes = ip,
            .flow = 0,
            .interface = if (zone == 0) .none else .{ .index = zone },
        } } };
    }

    /// Construct an IPv4 loopback address, 127.0.0.1.
    pub fn loopbackIp4(port: u16) SocketAddr {
        return parseIp4(.{ 127, 0, 0, 1 }, port);
    }

    /// Construct the IPv4 wildcard address, 0.0.0.0.
    pub fn anyIp4(port: u16) SocketAddr {
        return parseIp4(.{ 0, 0, 0, 0 }, port);
    }

    /// Return the port in host byte order.
    pub fn getPort(self: SocketAddr) u16 {
        return self.ip.getPort();
    }

    /// Set the port in host byte order.
    pub fn setPort(self: *SocketAddr, port: u16) void {
        self.ip.setPort(port);
    }

    /// Return the POSIX address family constant.
    pub fn family(self: SocketAddr) u16 {
        return switch (self.ip) {
            .ip4 => posix.AF.INET,
            .ip6 => posix.AF.INET6,
        };
    }

    /// Convert a POSIX `sockaddr_storage` to a SocketAddr.
    /// Validate `len` against the address family.
    /// Return error.UnsupportedAddressFamily for non-IP families.
    /// The storage buffer must have the alignment provided by its POSIX type.
    pub fn fromSockaddr(sa: *const posix.sockaddr.storage, len: posix.socklen_t) !SocketAddr {
        if (len < @sizeOf(@TypeOf(sa.family))) return error.InvalidAddress;
        const lf = sa.family;
        if (lf == posix.AF.INET) {
            if (len < @sizeOf(posix.sockaddr.in)) return error.InvalidAddress;
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(sa));
            const ip4_bytes: [4]u8 = @bitCast(in.addr);
            return parseIp4(ip4_bytes, std.mem.bigToNative(u16, in.port));
        }
        if (lf == posix.AF.INET6) {
            if (len < @sizeOf(posix.sockaddr.in6)) return error.InvalidAddress;
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(sa));
            return parseIp6(in6.addr, std.mem.bigToNative(u16, in6.port), in6.scope_id);
        }
        return error.UnsupportedAddressFamily;
    }

    /// Write this address into a POSIX `sockaddr_storage` buffer.
    /// Store the valid address length in `out_len`.
    /// The result can be passed to bind(), connect(), or sendto().
    pub fn toSockaddr(self: SocketAddr, out: *posix.sockaddr.storage, out_len: *posix.socklen_t) void {
        switch (self.ip) {
            .ip4 => |a| {
                const out_in: *posix.sockaddr.in = @ptrCast(@alignCast(out));
                out_in.* = .{
                    .family = posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, a.port),
                    .addr = @bitCast(a.bytes),
                    .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                };
                out_len.* = @sizeOf(posix.sockaddr.in);
            },
            .ip6 => |a| {
                const out_in6: *posix.sockaddr.in6 = @ptrCast(@alignCast(out));
                out_in6.* = .{
                    .family = posix.AF.INET6,
                    .port = std.mem.nativeToBig(u16, a.port),
                    .flowinfo = a.flow,
                    .addr = a.bytes,
                    .scope_id = a.interface.index,
                };
                out_len.* = @sizeOf(posix.sockaddr.in6);
            },
        }
    }

    /// Return the corresponding POSIX sockaddr length in bytes.
    pub fn getOsSockLen(self: SocketAddr) posix.socklen_t {
        return switch (self.ip) {
            .ip4 => @sizeOf(posix.sockaddr.in),
            .ip6 => @sizeOf(posix.sockaddr.in6),
        };
    }
};

/// Acquire a reference to the SCTP stack.
/// On usrsctp, initialize the singleton on the first call and increment its
/// reference count. The stack stays alive until matching releaseStack() calls.
/// On Linux, this function is a no-op.
///
/// `io` backs the usrsctp stack mutex operations.
pub fn acquireStack(local_port: u16, io: std.Io) !void {
    if (@hasDecl(backend, "acquireStack")) try backend.acquireStack(local_port, io);
}

/// Release one reference to the SCTP stack.
/// On usrsctp, shut down the singleton when the count reaches zero.
/// On Linux, this function is a no-op.
pub fn releaseStack() void {
    if (@hasDecl(backend, "releaseStack")) backend.releaseStack();
}

/// Cancel a blocking sender connect when the selected backend supports it.
pub fn cancelConnect(state: *ConnectState) void {
    if (@hasDecl(backend, "cancelConnect")) backend.cancelConnect(state);
}

test {
    _ = backend;
}
