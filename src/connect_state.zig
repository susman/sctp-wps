const std = @import("std");

/// Atomic ownership state for a blocking connect operation.
///
/// The descriptor is published separately from the state. Cancellation first
/// claims the connecting state and then claims the descriptor, so the thread
/// that created the descriptor can tell whether it still owns it.
pub const ConnectState = struct {
    pub const idle: u8 = 0;
    pub const connecting: u8 = 1;
    pub const connected: u8 = 2;
    pub const canceled: u8 = 3;

    state: u8 = idle,
    fd: std.posix.fd_t = -1,

    pub fn begin(self: *ConnectState) void {
        @atomicStore(std.posix.fd_t, &self.fd, -1, .seq_cst);
        @atomicStore(u8, &self.state, connecting, .seq_cst);
    }

    /// Publish a descriptor. Return false when cancellation already won.
    pub fn publish(self: *ConnectState, fd: std.posix.fd_t) bool {
        @atomicStore(std.posix.fd_t, &self.fd, fd, .seq_cst);
        return @atomicLoad(u8, &self.state, .seq_cst) == connecting;
    }

    /// Finish the operation and claim the descriptor for the caller.
    /// Return false when cancellation claimed the operation.
    pub fn finish(self: *ConnectState, success: bool, fd: std.posix.fd_t) bool {
        const next = if (success) connected else idle;
        if (@cmpxchgStrong(u8, &self.state, connecting, next, .seq_cst, .seq_cst) != null) {
            return false;
        }

        const claimed = @atomicRmw(std.posix.fd_t, &self.fd, .Xchg, -1, .seq_cst);
        std.debug.assert(claimed == fd);
        return true;
    }

    /// Claim the descriptor after cancellation has won the state race.
    pub fn claimFd(self: *ConnectState) std.posix.fd_t {
        return @atomicRmw(std.posix.fd_t, &self.fd, .Xchg, -1, .seq_cst);
    }

    /// Request cancellation. Return the descriptor if this call owns it.
    pub fn cancel(self: *ConnectState) ?std.posix.fd_t {
        if (@cmpxchgStrong(u8, &self.state, connecting, canceled, .seq_cst, .seq_cst) != null) {
            return null;
        }

        const fd = self.claimFd();
        return if (fd == -1) null else fd;
    }
};

test "ConnectState cancellation claims the descriptor once" {
    var state = ConnectState{};
    state.begin();
    try std.testing.expect(state.publish(42));
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), state.cancel().?);
    try std.testing.expect(state.cancel() == null);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), state.claimFd());
}

test "ConnectState completion transfers descriptor ownership" {
    var state = ConnectState{};
    state.begin();
    try std.testing.expect(state.publish(42));
    try std.testing.expect(state.finish(true, 42));
    try std.testing.expect(state.cancel() == null);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), state.claimFd());
}
