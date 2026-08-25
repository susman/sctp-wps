const std = @import("std");

/// C bindings for WavPack-stream.
/// The build creates them with TranslateC from `src/c/wavpack-stream.zig.h`.
pub const c = @import("wpstream_c");

/// WavPack block header.
/// It occupies the first 12 bytes of every encoded block.
/// Supported targets are little-endian.
///
/// Wire layout:
///   [0..4]   ck_id - magic bytes "wpsb".
///   [4..6]   ck_size - bytes after the first six bytes.
///   [6..8]   block_samples - samples per channel in this block.
///   [8..12]  flags - block property bitmask.
///
/// The total block size is `ck_size + 6` bytes.
/// The `ck_size` field delimits blocks in a contiguous buffer.
pub const BlockHeader = extern struct {
    /// The four-byte "wpsb" block identifier.
    ck_id: [4]u8,
    /// Block size minus the first six bytes.
    ck_size: u16,
    /// Number of samples per channel in this block.
    block_samples: u16,
    /// Block property flags.
    flags: u32,

    /// Flag set when the block contains one channel.
    pub const MONO_FLAG: u32 = 4;
};

/// Parse one little-endian WavPack block header from the beginning of a buffer.
/// The buffer may contain additional blocks after the parsed block.
pub fn parseBlockHeader(data: []const u8) !BlockHeader {
    if (data.len < @sizeOf(BlockHeader)) return error.InvalidBlock;
    if (!std.mem.eql(u8, data[0..4], "wpsb")) return error.InvalidBlock;

    const ck_size = std.mem.readInt(u16, data[4..6], .little);
    const total_size = @as(usize, ck_size) + 6;
    if (total_size < @sizeOf(BlockHeader) or total_size > data.len) {
        return error.InvalidBlock;
    }

    return .{
        .ck_id = data[0..4].*,
        .ck_size = ck_size,
        .block_samples = std.mem.readInt(u16, data[6..8], .little),
        .flags = std.mem.readInt(u32, data[8..12], .little),
    };
}

/// Parse and validate one complete little-endian WavPack block.
pub fn validateBlock(data: []const u8) !BlockHeader {
    const header = try parseBlockHeader(data);
    if (@as(usize, header.ck_size) + 6 != data.len) return error.InvalidBlock;
    return header;
}

/// WavPack encoding quality preset.
/// Higher quality can improve compression at a higher CPU cost.
pub const QualityMode = enum {
    default,
    fast,
    high,
    very_high,
};

/// Controls joint-stereo processing for a stereo pair.
/// Joint stereo uses left and right channel correlation for compression.
pub const JointStereoMode = enum {
    auto,
    force_on,
    force_off,
};

/// Lossless subset of WavPack CONFIG_* flags.
/// The packed layout provides type-safe bitfield access.
/// Hybrid and lossy flags are intentionally excluded.
/// Each field names its C define and hexadecimal value.
pub const ConfigFlags = packed struct(i32) {
    _reserved0: u4 = 0, // Bits 0-3. Bit 3 is the excluded hybrid flag.
    joint_stereo: bool = false, // Bit 4: CONFIG_JOINT_STEREO, 0x10.
    cross_decorr: bool = false, // Bit 5: CONFIG_CROSS_DECORR, 0x20.
    _reserved6: u3 = 0, // Bits 6-8.
    fast: bool = false, // Bit 9: CONFIG_FAST_FLAG, 0x200.
    _reserved10: bool = false, // Bit 10.
    high: bool = false, // Bit 11: CONFIG_HIGH_FLAG, 0x800.
    very_high: bool = false, // Bit 12: CONFIG_VERY_HIGH_FLAG, 0x1000.
    _reserved13: u3 = 0, // Bits 13-15.
    joint_override: bool = false, // Bit 16: CONFIG_JOINT_OVERRIDE, 0x10000.
    _reserved17: u15 = 0, // Bits 17-31.
};

/// WavPack encoder configuration.
/// It controls the PCM format, compression quality, and block size.
/// Writer computes `block_bytes` from the SCTP maximum segment size.
pub const Config = struct {
    /// Sample rate in samples per second.
    sample_rate: u32 = 44100,
    /// Number of channels. The transport supports 1 and 2.
    num_channels: u16 = 2,
    /// Bits per sample. The transport supports 16 and 24.
    bits_per_sample: u8 = 16,
    /// Microsoft-style channel mask.
    /// Zero derives 0x4 for mono and 0x3 for stereo.
    channel_mask: i32 = 0,
    /// Compression quality preset.
    quality: QualityMode = .default,
    /// Maximum encoded block size in bytes.
    /// Zero lets the encoder choose. A nonzero value limits each block.
    block_bytes: i32 = 0,
    /// Joint-stereo mode for stereo input.
    joint_stereo: JointStereoMode = .auto,
    /// Enable no-delay cross-channel decorrelation when true.
    cross_decorr: bool = false,

    /// Validate values that are narrowed into the C configuration structure.
    pub fn validate(self: Config) !void {
        if (self.sample_rate == 0 or self.sample_rate > 2_147_483_647) {
            return error.UnsupportedConfig;
        }
        if (self.num_channels < 1 or self.num_channels > 2) {
            return error.UnsupportedConfig;
        }
        if (self.bits_per_sample != 16 and self.bits_per_sample != 24) {
            return error.UnsupportedConfig;
        }
        if (self.block_bytes < 0 or
            (self.block_bytes != 0 and (self.block_bytes < 256 or self.block_bytes > 16384)))
        {
            return error.UnsupportedConfig;
        }
    }

    /// Build the WavPack CONFIG_* bitmask from the typed fields.
    fn toFlags(self: Config) i32 {
        var f: ConfigFlags = .{};
        switch (self.quality) {
            .default => {},
            .fast => f.fast = true,
            .high => f.high = true,
            .very_high => f.very_high = true,
        }
        if (self.cross_decorr) f.cross_decorr = true;
        switch (self.joint_stereo) {
            .auto => {},
            .force_on => {
                f.joint_stereo = true;
                f.joint_override = true;
            },
            .force_off => {
                f.joint_stereo = false;
                f.joint_override = true;
            },
        }
        return @bitCast(f);
    }

    /// Resolve the Microsoft-style channel mask.
    /// Use an explicit mask unchanged. Otherwise derive it from the channel count.
    fn resolveChannelMask(self: Config) i32 {
        if (self.channel_mask != 0) return self.channel_mask;
        return switch (self.num_channels) {
            1 => 0x4,
            2 => 0x3,
            else => unreachable,
        };
    }
};

/// Callback invoked for each completed WavPack block.
/// `ctx` is the opaque pointer stored in `Encoder.user_ctx`.
/// `data` starts with a `BlockHeader`.
/// The slice is valid only during the callback. Copy it when needed later.
/// Return true to continue encoding. Return false to abort.
pub const BlockOutputFn = *const fn (ctx: ?*anyopaque, data: []const u8) bool;

/// WavPack-stream encoding context.
/// It wraps the C WavpackContext and sends blocks to BlockOutputFn.
///
/// Keep the Encoder at a stable address after `init()`.
/// The C library stores a pointer to this struct for the callback.
pub const Encoder = struct {
    /// Opaque WavPack C context.
    wpc: ?*c.WavpackContext = null,
    /// Callback for completed encoded blocks.
    block_output: BlockOutputFn,
    /// Opaque callback context.
    user_ctx: ?*anyopaque,

    /// Initialize the encoder in place with `cfg`.
    /// The Encoder must already be at its final memory location.
    ///
    /// `bytes_per_sample` is `ceil(bits_per_sample / 8)`.
    /// The total sample count is -1 for streaming mode.
    pub fn init(self: *Encoder, cfg: Config) !void {
        if (self.wpc != null) return error.AlreadyInitialized;
        try cfg.validate();

        const wpc = c.WavpackStreamOpenFileOutput(&blockoutTrampoline, @ptrCast(self), null) orelse
            return error.WavpackOpenFailed;
        self.wpc = wpc;
        errdefer {
            _ = c.WavpackStreamCloseFile(wpc);
            self.wpc = null;
        }

        var wpcfg = std.mem.zeroes(c.WavpackStreamConfig);
        wpcfg.sample_rate = @intCast(cfg.sample_rate);
        wpcfg.num_channels = @intCast(cfg.num_channels);
        wpcfg.bits_per_sample = @intCast(cfg.bits_per_sample);
        wpcfg.bytes_per_sample = @intCast((@as(u16, cfg.bits_per_sample) + 7) / 8);
        wpcfg.flags = cfg.toFlags();
        wpcfg.block_bytes = cfg.block_bytes;
        wpcfg.channel_mask = cfg.resolveChannelMask();

        if (c.WavpackStreamSetConfiguration64(wpc, &wpcfg, -1, null) == 0) {
            return error.WavpackConfigFailed;
        }

        if (c.WavpackStreamPackInit(wpc) == 0) {
            return error.WavpackPackInitFailed;
        }
    }

    /// Feed interleaved PCM values widened to i32 into the encoder.
    /// The buffer length must be a multiple of `num_channels`.
    /// The callback runs for each completed block.
    pub fn packSamples(self: *Encoder, sample_buffer: []i32) !void {
        const wpc = self.wpc orelse return error.NotInitialized;
        const channels_raw = c.WavpackStreamGetNumChannels(wpc);
        if (channels_raw <= 0) return error.WavpackConfigFailed;
        const channels: usize = @intCast(channels_raw);
        if (sample_buffer.len % channels != 0) return error.InvalidSampleCount;
        const frame_count = sample_buffer.len / channels;
        if (frame_count > std.math.maxInt(u32)) return error.InputTooLarge;

        if (c.WavpackStreamPackSamples(
            wpc,
            sample_buffer.ptr,
            @intCast(frame_count),
        ) == 0) {
            return error.WavpackPackFailed;
        }
    }

    /// Flush samples remaining in the encoder.
    /// The callback receives the final blocks. Call this after the last
    /// `packSamples()` so all audio data is emitted.
    pub fn flush(self: *Encoder) !void {
        const wpc = self.wpc orelse return error.NotInitialized;
        if (c.WavpackStreamFlushSamples(wpc) == 0) {
            return error.WavpackFlushFailed;
        }
    }

    /// Close the C encoder context and release its resources.
    pub fn deinit(self: *Encoder) void {
        if (self.wpc) |wpc| {
            _ = c.WavpackStreamCloseFile(wpc);
            self.wpc = null;
        }
    }

    /// Bridge the C blockout callback to BlockOutputFn.
    /// The C library calls this once for each encoded block.
    fn blockoutTrampoline(id: ?*anyopaque, data: ?*anyopaque, bcount: i32) callconv(.c) c_int {
        const encoder: *Encoder = @ptrCast(@alignCast(id orelse return 0));
        if (bcount <= 0) return 0;
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        const len: usize = @intCast(bcount);

        const ok = encoder.block_output(encoder.user_ctx, bytes[0..len]);
        return if (ok) 1 else 0;
    }
};

/// Stateless WavPack block decoder.
/// Each method opens a temporary C decoder context, performs its operation,
/// and closes the context. Each WavPack-stream block is self-contained.
pub const Decoder = struct {
    /// Validate a block and enable WavPack checksum verification before opening
    /// the raw decoder. The vendored raw-decoder API disables checksums itself.
    fn openRawDecoder(frame_data: []const u8) !*c.WavpackContext {
        _ = try validateBlock(frame_data);

        const verify_buf = try std.heap.c_allocator.dupe(u8, frame_data);
        defer std.heap.c_allocator.free(verify_buf);
        if (c.WavpackStreamVerifySingleBlock(verify_buf.ptr, 1) == 0) {
            return error.InvalidBlock;
        }

        return c.WavpackStreamOpenRawDecoder(
            @constCast(frame_data.ptr),
            @intCast(frame_data.len),
            null,
            0,
            0, // Detect the version from the block header.
            null,
            0,
            0,
        ) orelse return error.WavpackDecodeFailed;
    }

    /// Decode one block into interleaved i32 PCM values.
    ///
    /// `frame_data` is one encoded WavPack block.
    ///
    /// `out_buf` receives the decoded values.
    /// Return the total number of values written.
    /// Return error.BufferTooSmall when the buffer is too small.
    pub fn decodeFrame(frame_data: []const u8, out_buf: []i32) !u32 {
        const wpc = try openRawDecoder(frame_data);
        defer _ = c.WavpackStreamCloseFile(wpc);

        const channels_raw = c.WavpackStreamGetNumChannels(wpc);
        if (channels_raw <= 0) return error.InvalidBlock;
        const num_channels: usize = @intCast(channels_raw);
        const frame_samples = c.WavpackStreamGetNumSamplesInFrame(wpc);
        if (frame_samples == 0) return 0;

        const frame_samples_usize: usize = @intCast(frame_samples);
        if (frame_samples_usize > out_buf.len / num_channels) return error.BufferTooSmall;

        const unpacked = c.WavpackStreamUnpackSamples(wpc, out_buf.ptr, frame_samples);
        if (unpacked > frame_samples) return error.InvalidBlock;
        return @intCast(@as(usize, unpacked) * num_channels);
    }

    /// Read the channel count from a block without decoding audio.
    pub fn getNumChannels(frame_data: []const u8) !u32 {
        const wpc = try openRawDecoder(frame_data);
        defer _ = c.WavpackStreamCloseFile(wpc);

        const channels = c.WavpackStreamGetNumChannels(wpc);
        if (channels <= 0) return error.InvalidBlock;
        return @intCast(channels);
    }

    /// Read the sample rate from a block without decoding audio.
    pub fn getSampleRate(frame_data: []const u8) !u32 {
        const wpc = try openRawDecoder(frame_data);
        defer _ = c.WavpackStreamCloseFile(wpc);

        const sample_rate = c.WavpackStreamGetSampleRate(wpc);
        if (sample_rate == 0) return error.InvalidBlock;
        return sample_rate;
    }

    /// Read the bit depth from a block without decoding audio.
    pub fn getBitsPerSample(frame_data: []const u8) !u32 {
        const wpc = try openRawDecoder(frame_data);
        defer _ = c.WavpackStreamCloseFile(wpc);

        const bits = c.WavpackStreamGetBitsPerSample(wpc);
        if (bits <= 0) return error.InvalidBlock;
        return @intCast(bits);
    }
};

test "BlockHeader layout" {
    try std.testing.expectEqual(@sizeOf(BlockHeader), 12);
}

test "parseBlockHeader validates complete wire blocks" {
    var block = [_]u8{
        'w', 'p', 's', 'b',
        6,   0,   0,   0,
        0,   0,   0,   0,
    };
    const parsed = try parseBlockHeader(&block);
    try std.testing.expectEqual(@as(u16, 6), parsed.ck_size);
    try std.testing.expectEqual(@as(u16, 0), parsed.block_samples);

    block[0] = 'x';
    try std.testing.expectError(error.InvalidBlock, parseBlockHeader(&block));
    block[0] = 'w';
    try std.testing.expectError(error.InvalidBlock, parseBlockHeader(block[0..11]));

    var trailing: [13]u8 = undefined;
    @memcpy(trailing[0..12], &block);
    trailing[12] = 0;
    try std.testing.expectError(error.InvalidBlock, validateBlock(&trailing));

    std.mem.writeInt(u16, block[4..6], 7, .little);
    try std.testing.expectError(error.InvalidBlock, parseBlockHeader(&block));
}

test "Encoder round-trip" {
    const testing = std.testing;

    const Ctx = struct {
        blocks_received: u32 = 0,
        total_bytes: usize = 0,

        fn onBlock(ctx_ptr: ?*anyopaque, data: []const u8) bool {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return false));
            ctx.blocks_received += 1;
            ctx.total_bytes += data.len;
            // Verify the block identifier.
            if (data.len >= 4) {
                std.testing.expectEqualSlices(u8, "wpsb", data[0..4]) catch return false;
            }
            return true;
        }
    };

    var ctx = Ctx{};
    var encoder = Encoder{
        // SAFETY: Encoder.init() assigns wpc before any method reads it.
        .wpc = null,
        .block_output = &Ctx.onBlock,
        .user_ctx = @ptrCast(&ctx),
    };
    try encoder.init(.{
        .sample_rate = 44100,
        .num_channels = 2,
        .bits_per_sample = 16,
        .quality = .high,
    });
    defer encoder.deinit();

    // Generate 44100 stereo frames, or 88200 i32 values.
    var samples: [88200]i32 = undefined;
    for (0..44100) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        samples[i * 2] = val;
        samples[i * 2 + 1] = val;
    }

    try encoder.packSamples(&samples);
    try encoder.flush();

    try testing.expect(ctx.blocks_received > 0);
    try testing.expect(ctx.total_bytes > 0);
}

test "ConfigFlags bitcast" {
    const testing = std.testing;

    try testing.expectEqual(@as(i32, @bitCast(ConfigFlags{ .joint_stereo = true })), 0x10);
    try testing.expectEqual(@as(i32, @bitCast(ConfigFlags{ .cross_decorr = true })), 0x20);
    try testing.expectEqual(@as(i32, @bitCast(ConfigFlags{ .fast = true })), 0x200);
    try testing.expectEqual(@as(i32, @bitCast(ConfigFlags{ .high = true })), 0x800);
    try testing.expectEqual(@as(i32, @bitCast(ConfigFlags{ .very_high = true })), 0x1000);
    try testing.expectEqual(@as(i32, @bitCast(ConfigFlags{ .joint_override = true })), 0x10000);

    // Verify Config.toFlags combines correctly.
    const cfg = Config{ .quality = .high, .cross_decorr = true };
    const flags = cfg.toFlags();
    try testing.expect(flags & 0x800 != 0);
    try testing.expect(flags & 0x20 != 0);
}

test "Encoder rejects non-frame-aligned input" {
    var encoder = Encoder{
        .wpc = null,
        .block_output = struct {
            fn onBlock(_: ?*anyopaque, _: []const u8) bool {
                return true;
            }
        }.onBlock,
        .user_ctx = null,
    };
    try encoder.init(.{ .num_channels = 2 });
    defer encoder.deinit();

    var odd = [_]i32{1};
    try std.testing.expectError(error.InvalidSampleCount, encoder.packSamples(&odd));
}

test "Decoder rejects malformed block framing" {
    const allocator = std.testing.allocator;
    var input = [_]i32{ 1, 2, 3, 4 };
    var frame_buf = try encodeToBuffer(allocator, .{ .num_channels = 2 }, &input);
    defer frame_buf.deinit(allocator);

    var invalid = try allocator.dupe(u8, frame_buf.items);
    defer allocator.free(invalid);
    invalid[0] = 'x';
    var output: [4]i32 = undefined;
    try std.testing.expectError(error.InvalidBlock, Decoder.decodeFrame(invalid, &output));

    invalid[0] = 'w';
    invalid[4] +%= 1;
    try std.testing.expectError(error.InvalidBlock, Decoder.decodeFrame(invalid, &output));
}

test "Encoder-Decoder round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Collect encoded blocks into a contiguous frame buffer.
    var frame_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_buf.deinit(allocator);

    const Ctx = struct {
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,

        fn onBlock(ctx_ptr: ?*anyopaque, data: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return false));
            self.buf.appendSlice(self.alloc, data) catch return false;
            return true;
        }
    };

    var ctx = Ctx{ .buf = &frame_buf, .alloc = allocator };
    var encoder = Encoder{
        // SAFETY: Encoder.init() assigns wpc before any method reads it.
        .wpc = null,
        .block_output = &Ctx.onBlock,
        .user_ctx = @ptrCast(&ctx),
    };
    try encoder.init(.{
        .sample_rate = 44100,
        .num_channels = 2,
        .bits_per_sample = 16,
    });
    defer encoder.deinit();

    // Generate 1024 stereo frames of a sine wave.
    const num_frames = 1024;
    const num_channels = 2;
    var input: [num_frames * num_channels]i32 = undefined;
    for (0..num_frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        input[i * 2] = val;
        input[i * 2 + 1] = val;
    }

    try encoder.packSamples(&input);
    try encoder.flush();
    try testing.expect(frame_buf.items.len > 0);

    // Decode each block in the contiguous buffer.
    var output: [num_frames * num_channels]i32 = undefined;
    var total_decoded: u32 = 0;
    var offset: usize = 0;

    while (offset < frame_buf.items.len) {
        const header = try parseBlockHeader(frame_buf.items[offset..]);
        const block_total_size: usize = @as(usize, header.ck_size) + 6;
        const frame_end = offset + block_total_size;
        const decoded = try Decoder.decodeFrame(frame_buf.items[offset..frame_end], output[total_decoded..]);
        total_decoded += decoded;
        offset = frame_end;
    }

    try testing.expectEqual(total_decoded, num_frames * num_channels);

    // Verify exact lossless reconstruction.
    for (0..total_decoded) |i| {
        try testing.expectEqual(input[i], output[i]);
    }
}

/// Encode samples and return all blocks in one contiguous buffer.
/// The caller must deinit the returned ArrayList.
fn encodeToBuffer(allocator: std.mem.Allocator, cfg: Config, input: []i32) !std.ArrayListUnmanaged(u8) {
    const Ctx = struct {
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,

        fn onBlock(ctx_ptr: ?*anyopaque, data: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return false));
            self.buf.appendSlice(self.alloc, data) catch return false;
            return true;
        }
    };

    var frame_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer frame_buf.deinit(allocator);

    var ctx = Ctx{ .buf = &frame_buf, .alloc = allocator };
    var encoder = Encoder{
        // SAFETY: Encoder.init() assigns wpc before any method reads it.
        .wpc = null,
        .block_output = &Ctx.onBlock,
        .user_ctx = @ptrCast(&ctx),
    };
    try encoder.init(cfg);
    defer encoder.deinit();

    try encoder.packSamples(input);
    try encoder.flush();
    return frame_buf;
}

/// Decode all blocks from a contiguous block buffer.
fn decodeAllFrames(frame_buf: []const u8, output: []i32) !u32 {
    var total_decoded: u32 = 0;
    var offset: usize = 0;

    while (offset < frame_buf.len) {
        const header = try parseBlockHeader(frame_buf[offset..]);
        const block_total_size: usize = @as(usize, header.ck_size) + 6;
        const frame_end = offset + block_total_size;
        const decoded = try Decoder.decodeFrame(frame_buf[offset..frame_end], output[total_decoded..]);
        total_decoded += decoded;
        offset = frame_end;
    }
    return total_decoded;
}

test "mono encode/decode round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const num_samples = 1024;
    var input: [num_samples]i32 = undefined;
    for (0..num_samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        input[i] = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
    }

    var frame_buf = try encodeToBuffer(allocator, .{
        .sample_rate = 44100,
        .num_channels = 1,
        .bits_per_sample = 16,
    }, &input);
    defer frame_buf.deinit(allocator);

    var output: [num_samples]i32 = undefined;
    const total = try decodeAllFrames(frame_buf.items, &output);
    try testing.expectEqual(total, num_samples);
    for (0..num_samples) |i| try testing.expectEqual(input[i], output[i]);
}

test "24-bit encode/decode round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const num_frames = 1024;
    var input: [num_frames * 2]i32 = undefined;
    for (0..num_frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 48000.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 8388000.0);
        input[i * 2] = val;
        input[i * 2 + 1] = val;
    }

    var frame_buf = try encodeToBuffer(allocator, .{
        .sample_rate = 48000,
        .num_channels = 2,
        .bits_per_sample = 24,
    }, &input);
    defer frame_buf.deinit(allocator);

    var output: [num_frames * 2]i32 = undefined;
    const total = try decodeAllFrames(frame_buf.items, &output);
    try testing.expectEqual(total, num_frames * 2);
    for (0..total) |i| try testing.expectEqual(input[i], output[i]);
}

test "block_bytes limits block size" {
    const testing = std.testing;

    const BlockCtx = struct {
        max_block_size: usize = 0,
        block_count: u32 = 0,

        fn onBlock(ctx_ptr: ?*anyopaque, data: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return false));
            self.block_count += 1;
            if (data.len > self.max_block_size) self.max_block_size = data.len;
            return true;
        }
    };

    var ctx = BlockCtx{};
    var encoder = Encoder{
        // SAFETY: Encoder.init() assigns wpc before any method reads it.
        .wpc = null,
        .block_output = &BlockCtx.onBlock,
        .user_ctx = @ptrCast(&ctx),
    };

    const target_block_bytes: i32 = 512;
    try encoder.init(.{
        .sample_rate = 44100,
        .num_channels = 2,
        .bits_per_sample = 16,
        .block_bytes = target_block_bytes,
    });
    defer encoder.deinit();

    // Encode enough samples to produce multiple blocks.
    var samples: [44100 * 2]i32 = undefined;
    for (0..44100) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        samples[i * 2] = val;
        samples[i * 2 + 1] = val;
    }
    try encoder.packSamples(&samples);
    try encoder.flush();

    // The data must produce multiple blocks.
    try testing.expect(ctx.block_count > 1);
    // No block may exceed the target size.
    try testing.expect(ctx.max_block_size <= @as(usize, @intCast(target_block_bytes)));
}

test "Decoder metadata queries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var input: [512 * 2]i32 = undefined;
    for (0..512) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        input[i * 2] = val;
        input[i * 2 + 1] = val;
    }

    var frame_buf = try encodeToBuffer(allocator, .{
        .sample_rate = 44100,
        .num_channels = 2,
        .bits_per_sample = 16,
    }, &input);
    defer frame_buf.deinit(allocator);

    // Find the first encoded block.
    const ck_size = std.mem.readInt(u16, frame_buf.items[4..6], .little);
    const frame_end = @as(usize, ck_size) + 6;
    const first_frame = frame_buf.items[0..frame_end];

    try testing.expectEqual(try Decoder.getNumChannels(first_frame), 2);
    try testing.expectEqual(try Decoder.getSampleRate(first_frame), 44100);
    try testing.expectEqual(try Decoder.getBitsPerSample(first_frame), 16);
}

test "Config.resolveChannelMask" {
    const testing = std.testing;
    try testing.expectEqual((Config{ .num_channels = 1 }).resolveChannelMask(), 0x4);
    try testing.expectEqual((Config{ .num_channels = 2 }).resolveChannelMask(), 0x3);
    // Explicit mask takes priority.
    try testing.expectEqual((Config{ .num_channels = 2, .channel_mask = 0x3F }).resolveChannelMask(), 0x3F);
}

test "Config.toFlags joint_stereo modes" {
    const testing = std.testing;
    const force_on = (Config{ .joint_stereo = .force_on }).toFlags();
    try testing.expect(force_on & 0x10 != 0); // Joint-stereo bit.
    try testing.expect(force_on & 0x10000 != 0); // Joint override bit.

    const force_off = (Config{ .joint_stereo = .force_off }).toFlags();
    try testing.expect(force_off & 0x10 == 0); // Joint-stereo bit is clear.
    try testing.expect(force_off & 0x10000 != 0); // Joint override bit is set.

    const auto_flags = (Config{ .joint_stereo = .auto }).toFlags();
    try testing.expect(auto_flags & 0x10 == 0);
    try testing.expect(auto_flags & 0x10000 == 0);
}

test "Encoder block_bytes zero uses encoder default" {
    const testing = std.testing;

    const Ctx = struct {
        max_block_size: usize = 0,
        block_count: u32 = 0,

        fn onBlock(ctx_ptr: ?*anyopaque, data: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr orelse return false));
            self.block_count += 1;
            if (data.len > self.max_block_size) self.max_block_size = data.len;
            return true;
        }
    };

    var ctx_zero = Ctx{};
    var enc_zero = Encoder{
        // SAFETY: Encoder.init() assigns wpc before any method reads it.
        .wpc = null,
        .block_output = &Ctx.onBlock,
        .user_ctx = @ptrCast(&ctx_zero),
    };
    try enc_zero.init(.{
        .sample_rate = 44100,
        .num_channels = 2,
        .bits_per_sample = 16,
        .block_bytes = 0, // Let the encoder choose.
    });
    defer enc_zero.deinit();

    // Use the same data as the block-size test with automatic block sizing.
    var samples: [44100 * 2]i32 = undefined;
    for (0..44100) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const val: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
        samples[i * 2] = val;
        samples[i * 2 + 1] = val;
    }
    try enc_zero.packSamples(&samples);
    try enc_zero.flush();

    // The encoder must emit at least one block.
    // The C library chooses the exact default block size.
    try testing.expect(ctx_zero.block_count > 0);
    try testing.expect(ctx_zero.max_block_size > 0);
}

test "Decoder empty frame returns 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Encoding zero samples can emit no block or one empty block.
    // Either result must decode to zero samples.
    var empty_input: [0]i32 = .{};
    var frame_buf = try encodeToBuffer(allocator, .{
        .sample_rate = 44100,
        .num_channels = 2,
        .bits_per_sample = 16,
    }, &empty_input);
    defer frame_buf.deinit(allocator);

    var output: [16]i32 = undefined;
    const decoded = try decodeAllFrames(frame_buf.items, &output);
    try testing.expectEqual(decoded, 0);

    // decodeFrame must also handle a hand-built zero-sample block.
    var manual: [@sizeOf(BlockHeader)]u8 = undefined;
    @memcpy(manual[0..4], "wpsb");
    std.mem.writeInt(u16, manual[4..6], 6, .little); // Header-only block.
    std.mem.writeInt(u16, manual[6..8], 0, .little); // Zero samples.
    std.mem.writeInt(u32, manual[8..12], 0, .little);

    // The C decoder may reject a body-less block.
    // Both rejection and a zero result are valid here.
    var out2: [16]i32 = undefined;
    if (Decoder.decodeFrame(&manual, &out2)) |n| {
        try testing.expectEqual(n, 0);
    } else |_| {
        // Rejecting the synthetic empty block is also valid.
        // The test only requires that decoding does not crash.
    }
}
