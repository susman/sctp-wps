/// Control channel protocol constants and message layout.
const std = @import("std");

/// Little-endian integer representation of the four-byte "SWPS" identifier.
/// The current supported targets are little-endian.
pub const ctrl_magic: u32 = std.mem.readInt(u32, "SWPS", .little);
/// Current control message version.
pub const ctrl_version: u8 = 1;

/// The writer sends a 16-byte control message after association setup.
/// The reader uses it to configure the stream.
///
/// Wire layout on supported little-endian targets:
///   [0..4]   magic: ctrl_magic
///   [4]      version: ctrl_version
///   [5..8]   padding
///   [8..12]  sample_rate
///   [12..14] num_channels
///   [14]     bits_per_sample
///   [15]     padding
///
/// SCTP stream 0 is reserved for control. Stream 1 is for audio data.
pub const CtrlMsg = extern struct {
    /// Message identifier.
    magic: u32,
    /// Message version.
    version: u8,
    /// Reserved padding.
    _pad0: [3]u8,
    /// Sample rate in samples per second.
    sample_rate: u32,
    /// Number of interleaved channels.
    num_channels: u16,
    /// Bits per sample.
    bits_per_sample: u8,
    /// Reserved padding.
    _pad1: u8,

    /// Serialize the control message in its little-endian wire format.
    pub fn encode(self: CtrlMsg) [@sizeOf(CtrlMsg)]u8 {
        var out: [@sizeOf(CtrlMsg)]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], self.magic, .little);
        out[4] = self.version;
        @memcpy(out[5..8], &self._pad0);
        std.mem.writeInt(u32, out[8..12], self.sample_rate, .little);
        std.mem.writeInt(u16, out[12..14], self.num_channels, .little);
        out[14] = self.bits_per_sample;
        out[15] = self._pad1;
        return out;
    }

    /// Parse one complete control message from its little-endian wire format.
    pub fn decode(data: []const u8) !CtrlMsg {
        if (data.len != @sizeOf(CtrlMsg)) return error.InvalidControlMessage;
        return .{
            .magic = std.mem.readInt(u32, data[0..4], .little),
            .version = data[4],
            ._pad0 = data[5..8].*,
            .sample_rate = std.mem.readInt(u32, data[8..12], .little),
            .num_channels = std.mem.readInt(u16, data[12..14], .little),
            .bits_per_sample = data[14],
            ._pad1 = data[15],
        };
    }
};

test "CtrlMsg layout size" {
    try std.testing.expectEqual(@sizeOf(CtrlMsg), 16);
}

test "CtrlMsg round-trip serialization" {
    const msg = CtrlMsg{
        .magic = ctrl_magic,
        .version = ctrl_version,
        ._pad0 = .{ 0, 0, 0 },
        .sample_rate = 48000,
        .num_channels = 2,
        .bits_per_sample = 24,
        ._pad1 = 0,
    };
    const bytes = msg.encode();
    const expected = [_]u8{
        'S',  'W',  'P', 'S', 1, 0, 0,  0,
        0x80, 0xbb, 0,   0,   2, 0, 24, 0,
    };
    try std.testing.expectEqualSlices(u8, &expected, &bytes);

    const parsed = try CtrlMsg.decode(&bytes);
    try std.testing.expectEqual(ctrl_magic, parsed.magic);
    try std.testing.expectEqual(ctrl_version, parsed.version);
    try std.testing.expectEqual(@as(u32, 48000), parsed.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), parsed.num_channels);
    try std.testing.expectEqual(@as(u8, 24), parsed.bits_per_sample);
}
