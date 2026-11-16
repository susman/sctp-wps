const std = @import("std");

/// Atomic ownership state for a blocking connect operation.
///
/// The descriptor is published separately from the state. Cancellation first
/// claims the connecting state and then claims the descriptor, so the thread
/// that created the descriptor can tell whether it still owns it.
pub const ConnectState = struct {
    pub const State = enum(u8) { idle, connecting, connected, canceled };

    state: std.atomic.Value(State) = .init(.idle),
    fd: std.atomic.Value(std.posix.fd_t) = .init(-1),

    /// Reset to the idle state without writing the struct as a whole.
    /// This is safe while another thread is calling cancel().
    pub fn reset(self: *ConnectState) void {
        self.state.store(.idle, .seq_cst);
        self.fd.store(-1, .seq_cst);
    }

    /// Mark a new connect operation as starting.
    /// Return false when cancellation already won.
    pub fn begin(self: *ConnectState) bool {
        self.fd.store(-1, .seq_cst);
        return self.state.cmpxchgStrong(.idle, .connecting, .seq_cst, .seq_cst) == null;
    }

    /// Publish a descriptor. Return false when cancellation already won.
    pub fn publish(self: *ConnectState, fd: std.posix.fd_t) bool {
        self.fd.store(fd, .seq_cst);
        return self.state.load(.seq_cst) == .connecting;
    }

    /// Finish the operation and claim the descriptor for the caller.
    /// Return false when cancellation claimed the operation.
    pub fn finish(self: *ConnectState, success: bool, fd: std.posix.fd_t) bool {
        const next: State = if (success) .connected else .idle;
        if (self.state.cmpxchgStrong(.connecting, next, .seq_cst, .seq_cst) != null) {
            return false;
        }

        const claimed = self.fd.swap(-1, .seq_cst);
        std.debug.assert(claimed == fd);
        return true;
    }

    /// Claim the descriptor after cancellation has won the state race.
    pub fn claimFd(self: *ConnectState) std.posix.fd_t {
        return self.fd.swap(-1, .seq_cst);
    }

    /// Request cancellation. Return the descriptor if this call owns it.
    pub fn cancel(self: *ConnectState) ?std.posix.fd_t {
        const current = self.state.load(.seq_cst);
        if (current == .idle) {
            _ = self.state.cmpxchgStrong(.idle, .canceled, .seq_cst, .seq_cst);
            return null;
        }
        if (current != .connecting) return null;
        if (self.state.cmpxchgStrong(.connecting, .canceled, .seq_cst, .seq_cst) != null) {
            return null;
        }

        const fd = self.claimFd();
        return if (fd == -1) null else fd;
    }
};

test "ConnectState cancellation claims the descriptor once" {
    var state = ConnectState{};
    try std.testing.expect(state.begin());
    try std.testing.expect(state.publish(42));
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), state.cancel().?);
    try std.testing.expect(state.cancel() == null);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), state.claimFd());
}

test "ConnectState cancellation before begin blocks the operation" {
    var state = ConnectState{};
    try std.testing.expect(state.cancel() == null);
    try std.testing.expect(!state.begin());
}

test "ConnectState completion transfers descriptor ownership" {
    var state = ConnectState{};
    try std.testing.expect(state.begin());
    try std.testing.expect(state.publish(42));
    try std.testing.expect(state.finish(true, 42));
    try std.testing.expect(state.cancel() == null);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), state.claimFd());
}
