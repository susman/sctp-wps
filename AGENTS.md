# sctp-wps development notes

## Build Commands

```bash
# First-time only: initialize submodules
git submodule update --init --recursive

# Build the library and install the header
zig build --release=fast -Dtarget=native
# Output: zig-out/lib/libsctp-wps.a, zig-out/include/sctp-wps.h

# Run unit and network tests
zig build test
```

## Architecture

- **Language**: Zig 0.16.0.
- **C bindings**: TranslateC imports the WavPack-stream and usrsctp headers.
- **Purpose**: Encode PCM with WavPack-stream and transport it over SCTP.
- **Submodules**: `wavpack-stream/` and `usrsctp/`.
- **Linux dependency**: The native build can use system WavPack-stream or the submodule.
- **Non-Linux dependency**: The build compiles WavPack-stream and usrsctp from the submodules.

### Dual SCTP Backend

`src/sctp.zig` selects the backend at compile time:
- **Linux**: raw `std.os.linux` syscalls with kernel SCTP - `src/sctp_linux.zig`.
- **Non-Linux**: usrsctp userspace SCTP - `src/sctp_usrsctp.zig`.

Both backends expose matching `SctpSender` and `SctpReceiver` APIs. UDP encapsulation and cancellation behavior is backend-specific.

### Threading Model

**Writer** (3 threads):
1. The caller thread pushes PCM into `pcm_queue`.
2. The encode thread pops PCM, encodes it with WavPack, and passes blocks to `BlockHandoff`.
3. The network thread sends blocks on SCTP stream 1.

**Reader** (3 threads):
1. The caller thread pops decoded PCM from `pcm_out_queue` with `readFrame()`.
2. The receive thread reads WavPack blocks from SCTP and pushes them to `block_queue`.
3. The decode thread decodes blocks and pushes PCM to `pcm_out_queue`.

**SCTP streams**: Stream 0 carries control metadata. Stream 1 carries audio blocks.

## Testing

- Network tests require SCTP support. They return without running when support is unavailable.
- Cross-process tests use `src/peer.zig`, built as `sctp-wps-peer`.
- The peer executable path is injected as `build_options.peer_path` at compile time.
- Peer tests include `"SctpSender/SctpReceiver loopback with peer"`, `"Writer -> Reader lossless round-trip with peer (cross-platform)"`, `"mono audio round-trip with peer"`, and `"peer buffering pre-fill"`.
- Linux also has an in-process test named `"Writer -> Reader lossless round-trip over loopback"`.

## Key Constraints

- WavPack-stream `terminate-block-at-byte-size` supports S16/S24 PCM with 1 or 2 channels.
- Block sizing uses an effective 1500-byte MTU cap on loopback. This keeps tests close to the target network profile.
- `Writer` and `Reader` must stay at stable addresses while initialized or running.
- WavPack stores an internal pointer to the `Encoder` inside `Writer`.
- On Linux, enable UDP encapsulation with `sudo sysctl -w net.sctp.udp_port=9899` when testing against a UDP endpoint.

## C API Entry Points

`include/sctp-wps.h`:
- Config: `swps_wp_config_default`, `swps_sctp_config_default`, `swps_sctp_recv_config_default`.
- Writer: `swps_writer_create`, `swps_writer_init`, `swps_writer_write`, `swps_writer_flush`, `swps_writer_check`, `swps_writer_deinit`, `swps_writer_destroy`, `swps_writer_cancel_connect`.
- Reader: `swps_reader_create`, `swps_reader_init`, `swps_reader_accept`, `swps_reader_recv_config`, `swps_reader_start`, `swps_reader_read_frame`, `swps_reader_poll_new_sender`, `swps_reader_next_session`, `swps_reader_cancel`, `swps_reader_destroy`.
- Stack: `swps_stack_acquire` and `swps_stack_release`. They manage the usrsctp reference count. They are no-ops on Linux.

## Zig API

`src/root.zig` exports `Writer`, `Reader`, `StreamConfig`, `SwpsStreamConfig`, `WpConfig`, `SctpConfig`, and `SctpRecvConfig`. It also exports the `wpstream` and `sctp` modules.
