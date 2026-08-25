# SCTP-WPS: WavPack-stream transport for near-real-time PCM

`sctp-wps` encodes interleaved PCM with WavPack-stream and sends the encoded blocks over SCTP. Each connection uses one SCTP association with two streams. Stream 0 carries a control message. Stream 1 carries audio blocks.

The protocol is intended for a trusted network. SCTP checksums detect accidental corruption but do not authenticate peers or encrypt audio. Restrict access at the network layer or place the connection inside an authenticated encrypted tunnel when hostile peers are possible.

The control message contains the sample rate, channel count, and bit depth. The audio path supports one or two channels. It supports signed 16-bit and 24-bit PCM. The API represents samples as interleaved signed `int32_t` values.

Supported platforms:

- Linux with the kernel SCTP stack.
- macOS with the usrsctp userspace stack.

The Linux backend is selected for Linux targets. The usrsctp backend is selected for non-Linux targets. macOS is the tested non-Linux target.

The implementation uses the `terminate-block-at-byte-size` feature from WavPack-stream 0.2.0. The writer sizes blocks for the SCTP path. This keeps each encoded block within one SCTP data chunk for the supported network profile.

## Building

The project uses Zig 0.16.0. The WavPack-stream and usrsctp repositories are submodules.

```bash
git clone https://github.com/susman/sctp-wps
cd sctp-wps
git submodule update --init --recursive
zig build --release=fast -Dtarget=native
```

The build installs `zig-out/lib/libsctp-wps.a` and `zig-out/include/sctp-wps.h`.

On macOS, the static library contains WavPack-stream and usrsctp. On Linux, the build first checks for a system `wavpack-stream` package with `pkg-config`. If it finds one, the installed archive keeps that library as a link dependency. Otherwise, the build compiles the WavPack-stream submodule into the archive.

Build a universal macOS archive with `-Dmacos-universal`. A macOS host needs `lipo`. A Linux host needs `llvm-lipo` in `PATH`.

### Running Tests

```bash
zig build test
```

Network tests need SCTP support. Tests that need a network stack return without running when the platform lacks the required SCTP support.

## C API

Include `sctp-wps.h` and link with `libsctp-wps.a`. The API exposes opaque writer and reader handles. Functions return zero on success and `-1` on failure unless documented otherwise.

Default configurations come from `swps_wp_config_default()`, `swps_sctp_config_default()`, and `swps_sctp_recv_config_default()`.

Address arguments use a 16-byte address buffer, a host-order port, and a family value. Use family 4 for IPv4. Only the first four address bytes are read for IPv4. Use family 6 for IPv6. All sixteen bytes are read for IPv6.

Writer lifecycle:

```text
create -> init -> write/flush loop -> deinit or destroy
```

`swps_writer_write()` accepts interleaved signed `int32_t` values. The value count must be a multiple of the configured channel count. `swps_writer_flush()` waits until buffered audio has reached the network. `swps_writer_check()` reports errors from background threads without blocking.

`swps_writer_deinit()` stops the pipeline and keeps the allocation. The handle can be initialized again. `swps_writer_destroy()` also frees the handle. Keep the handle at a stable address while it is initialized.

Reader lifecycle:

```text
create -> init -> accept -> recv_config -> start -> read_frame loop -> destroy
```

`swps_reader_start()` takes a pre-fill depth in WavPack-stream blocks. `swps_reader_read_frame()` writes one decoded block of interleaved `int32_t` values to the supplied buffer. The output capacity is measured in values, not frames. `swps_reader_cancel()` wakes blocked reader operations; `swps_reader_destroy()` then joins workers and releases resources.

The reader supports sender takeover. Call `swps_reader_poll_new_sender()` while the current session is active. If it returns 1, call `swps_reader_next_session()`. The transition stops the current session, reads the new stream configuration, and leaves the reader stopped. Call `swps_reader_start()` again.

The usrsctp stack is process-wide. Call `swps_stack_acquire()` before a sequence of repeated setup and teardown operations when the stack must stay alive. Pair every acquire with `swps_stack_release()`. Both functions are no-ops on Linux. The receiver and sender UDP encapsulation setting selects the remote peer port; the usrsctp local port is selected by `swps_stack_acquire()`.

## Examples

The example programs are in `examples/`. Build the library first.

When the native Linux build used the vendored WavPack-stream sources, build both programs with:

```bash
zig cc -o sender examples/sender.c -Iinclude -Lzig-out/lib -lsctp-wps -lm
zig cc -o receiver examples/receiver.c -Iinclude -Lzig-out/lib -lsctp-wps -lm
```

When the native Linux build used a system WavPack-stream library, add `-lwavpack-stream`:

```bash
zig cc -o sender examples/sender.c -Iinclude -Lzig-out/lib -lsctp-wps -lwavpack-stream -lm
zig cc -o receiver examples/receiver.c -Iinclude -Lzig-out/lib -lsctp-wps -lwavpack-stream -lm
```

The examples accept numeric IPv4 addresses. They do not resolve hostnames or accept IPv6 addresses. The sender reads raw interleaved S24_LE PCM from standard input. The receiver writes raw interleaved S24_LE PCM to standard output.

### Usage

The receiver example uses SCTP-over-UDP. On Linux, enable the kernel encapsulation port first:

```bash
sudo sysctl -w net.sctp.udp_port=9899
./receiver 5000
```

The sender uses plain SCTP on Linux by default. Pass `-udp` when sending to the example receiver.

```bash
sox input.wav -t raw -r 48000 -b 24 -e signed-integer -c 2 - | \
    ./sender 192.168.1.2 5000 -rate 48000 -channels 2 -udp

./receiver 5000 | sox -t raw -r 48000 -b 24 -e signed-integer -c 2 - output.wav
./receiver 5000 | aplay -f S24_3LE -r 48000 -c 2
```

Sender options are `-rate N`, `-channels N`, and `-udp`. The default rate is 48000. The default channel count is 2.

Receiver options are `-bind ADDR` and `-buffer N`. The default bind address is `0.0.0.0`. The default buffer depth is 60 WavPack-stream blocks.

On macOS, the usrsctp backend always uses UDP encapsulation on port 9899. The sender ignores the `-udp` distinction on that platform. The receiver selects port 9899 automatically.

### Cross-platform Notes

Linux and macOS examples can communicate when both endpoints use UDP encapsulation. Set the Linux sysctl before starting the receiver. Use `-udp` on the Linux sender.

## Zig API

The root module in `src/root.zig` exports `Writer`, `Reader`, `StreamConfig`, `WpConfig`, `SctpConfig`, `SctpRecvConfig`, and `SwpsStreamConfig`. It also exports the lower-level `wpstream` and `sctp` modules.

The Zig API uses Zig error unions. `Writer.write()` copies the caller's samples before returning. `Reader.readFrame()` copies one decoded block into the caller's buffer. Keep `Writer` and `Reader` at stable addresses until `deinit()` returns. Do not call lifecycle methods concurrently with each other.
