/// Shared protocol sizing rules.
///
/// The writer sizes each WavPack block for the SCTP path. The reader uses the
/// same upper bound for its receive buffer.
const std = @import("std");

/// Maximum encoded block size accepted by the receiver.
pub const max_wire_block_bytes: u32 = 2 * 1024;

/// Number of PCM slots in the writer ring.
pub const pcm_ring_slots: u32 = 8;

/// Maximum interleaved i32 values accepted by one writer write.
/// Both senders use this capacity. Each front end may write smaller chunks.
pub const max_pcm_chunk_samples: usize = 16384;

/// Maximum interleaved i32 values produced by decoding one WavPack block.
///
/// WavpackStreamPackInit() clamps the default block size to 8000 frames
/// and a custom override is limited to 50..8000 frames. Stereo carries at
/// most 16000 values. 16384 leaves a small margin.
pub const max_decoded_samples: usize = 16384;

/// WavPack requires four-byte block alignment.
pub const block_alignment: u32 = 4;

/// Convert a path payload size to the final WavPack block byte limit.
/// The result is aligned down to four bytes and leaves two bytes of margin.
pub fn blockBytesForPayload(payload_bytes: u32) u32 {
    const mask: u32 = block_alignment - 1;
    return (payload_bytes & ~mask) -| 2;
}

test "blockBytesForPayload aligns and keeps margin" {
    try std.testing.expectEqual(1450, blockBytesForPayload(1452));
    try std.testing.expectEqual(1442, blockBytesForPayload(1444));
    try std.testing.expectEqual(0, blockBytesForPayload(1));
}

test "decoded sample bound covers the WavPack block limit" {
    // The packer clamps block_samples to 8000 frames. Stereo doubles that.
    try std.testing.expect(max_decoded_samples >= 8000 * 2);
    try std.testing.expect(pcm_ring_slots >= 1);
    try std.testing.expect(max_pcm_chunk_samples >= 2);
}
