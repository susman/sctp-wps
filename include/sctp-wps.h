/*
 * sctp-wps C API.
 *
 * The library encodes interleaved PCM with WavPack-stream and transports the
 * encoded blocks over SCTP. Supported targets are Linux and macOS.
 *
 * This protocol is intended for a trusted network. SCTP checksums protect
 * against accidental corruption but do not authenticate peers or encrypt
 * audio. Applications that need hostile-network protection must add an
 * authenticated encrypted transport or restrict access at the network layer.
 */
#ifndef SCTP_WPS_H
#define SCTP_WPS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque writer handle. Keep its address stable after initialization. */
typedef struct swps_writer swps_writer_t;

/* WavPack encoding quality presets. */
#define SWPS_QUALITY_DEFAULT   0
#define SWPS_QUALITY_FAST      1
#define SWPS_QUALITY_HIGH      2
#define SWPS_QUALITY_VERY_HIGH 3

/* Joint-stereo modes for a stereo channel pair. */
#define SWPS_JS_AUTO      0
#define SWPS_JS_FORCE_ON  1
#define SWPS_JS_FORCE_OFF 2

/* Maximum supported channel count. */
#define SWPS_MAX_CHANNELS 2

/* Address-family selectors accepted by the init functions. */
#define SWPS_FAMILY_IP4 4
#define SWPS_FAMILY_IP6 6

/* WavPack encoder configuration.
 *
 * sample_rate is in samples per second. The default is 44100.
 * num_channels must be 1 or 2. The default is 2.
 * bits_per_sample must be 16 or 24. The default is 16.
 * channel_mask is a Microsoft-style mask. Zero selects an automatic mask.
 * quality is one of the SWPS_QUALITY_* values.
 * cross_decorr enables no-delay cross-channel decorrelation when nonzero.
 * joint_stereo is one of the SWPS_JS_* values.
 */
typedef struct {
    uint32_t sample_rate;
    uint16_t num_channels;
    uint8_t  bits_per_sample;
    uint8_t  _pad0;
    int32_t  channel_mask;
    uint8_t  quality;
    uint8_t  cross_decorr;
    uint8_t  joint_stereo;
    uint8_t  _pad1;
} swps_wp_config_t;

/* SCTP sender configuration.
 *
 * nodelay disables Nagle-style batching when nonzero. The default is 1.
 * udp_encaps_port selects the remote RFC 6951 UDP port on Linux.
 * Zero disables UDP encapsulation on Linux. The usrsctp sender uses 9899 when
 * this field is zero.
 * sndbuf_size sets SO_SNDBUF on Linux. Zero selects the system default.
 * The usrsctp backend currently ignores sndbuf_size.
 */
typedef struct {
    uint8_t  nodelay;
    uint8_t  _pad0;
    uint16_t udp_encaps_port;
    uint32_t sndbuf_size;
} swps_sctp_config_t;

/* Return the default WavPack encoder configuration. */
swps_wp_config_t swps_wp_config_default(void);

/* Return the default SCTP sender configuration. */
swps_sctp_config_t swps_sctp_config_default(void);

/* Allocate an uninitialized writer handle. Return NULL on allocation failure.
 * swps_writer_destroy() is safe before a successful init. */
swps_writer_t *swps_writer_create(void);

/* Initialize the writer and connect to the destination.
 *
 * wp_cfg and sctp_cfg must point to valid configurations.
 * ip must point to at least 16 address bytes.
 * Only the first 4 bytes are read for SWPS_FAMILY_IP4.
 * All 16 bytes are read for SWPS_FAMILY_IP6.
 * port is in native host byte order.
 * family must be SWPS_FAMILY_IP4 or SWPS_FAMILY_IP6.
 *
 * The call starts the writer pipeline after the SCTP association is ready.
 * Keep w at a stable address until swps_writer_deinit() returns.
 * Return 0 on success and -1 on failure.
 */
int swps_writer_init(swps_writer_t *w,
                     const swps_wp_config_t *wp_cfg,
                     const swps_sctp_config_t *sctp_cfg,
                     const uint8_t *ip,
                     uint16_t port,
                     uint8_t family);

/* Queue interleaved signed PCM values widened to int32_t.
 *
 * num_i32 is the total number of int32_t values. It is not a frame count.
 * It must be a multiple of the configured channel count.
 * samples is copied before this function returns and is not modified.
 * The call can block when the internal queue is full.
 * Return 0 on success and -1 on failure.
 */
int swps_writer_write(swps_writer_t *w, int32_t *samples, uint32_t num_i32);

/* Flush all samples already queued by the caller.
 *
 * Block until the encoder has emitted the final blocks and the network thread
 * has sent them. Return 0 on success and -1 on failure.
 */
int swps_writer_flush(swps_writer_t *w);

/* Check for a fatal error in a writer background thread.
 *
 * This function does not block on pipeline work. Return 0 when no error has
 * been recorded and -1 when a background error has been recorded.
 */
int swps_writer_check(swps_writer_t *w);

/* Stop the writer pipeline without freeing the handle.
 *
 * The handle can be initialized again after this call. Calls to
 * swps_writer_write() on a deinited writer return -1.
 */
void swps_writer_deinit(swps_writer_t *w);

/* Stop the writer pipeline and free the handle. */
void swps_writer_destroy(swps_writer_t *w);

/* Interrupt a writer init call blocked in connect().
 *
 * On Linux, close the in-progress SCTP socket. After this call, init returns
 * -1. The call is safe from another thread. It is a no-op for usrsctp because
 * usrsctp does not expose a cancellable file descriptor.
 */
void swps_writer_cancel_connect(swps_writer_t *w);

/* Acquire a reference to the process-wide usrsctp stack.
 *
 * local_port selects the local UDP encapsulation port. Zero selects 9899.
 * Pair every successful call with swps_stack_release(). The stack remains
 * initialized until the matching release calls finish.
 * This function is a no-op on Linux.
 * Return 0 on success and -1 on failure.
 */
int swps_stack_acquire(uint16_t local_port);

/* Release one reference acquired with swps_stack_acquire(). */
void swps_stack_release(void);

/* Opaque reader handle. Keep its address stable while it owns threads. */
typedef struct swps_reader swps_reader_t;

/* SCTP receiver configuration.
 *
 * nodelay disables Nagle-style batching on accepted associations when
 * nonzero. The default is 1.
 * udp_encaps_port is the remote peer's RFC 6951 UDP encapsulation port when
 * nonzero. Zero disables the per-peer setting on Linux. The usrsctp local
 * UDP port is selected by swps_stack_acquire(); this field selects the peer.
 * rcvbuf_size sets SO_RCVBUF on Linux. Zero selects the system default.
 * The usrsctp backend currently ignores rcvbuf_size.
 */
typedef struct {
    uint8_t  nodelay;
    uint8_t  _pad0;
    uint16_t udp_encaps_port;
    uint32_t rcvbuf_size;
} swps_sctp_recv_config_t;

/* Stream properties sent by the writer on SCTP stream 0.
 * Filled by swps_reader_recv_config() and swps_reader_next_session().
 */
typedef struct {
    uint32_t sample_rate;
    uint16_t num_channels;
    uint8_t  bits_per_sample;
    uint8_t  _pad;
} swps_stream_config_t;

/* Return the default SCTP receiver configuration. */
swps_sctp_recv_config_t swps_sctp_recv_config_default(void);

/* Allocate an uninitialized reader handle. Return NULL on allocation failure.
 * swps_reader_destroy() is safe before a successful init. */
swps_reader_t *swps_reader_create(void);

/* Initialize the reader, bind it to an address, and start listening.
 *
 * sctp_cfg must point to a valid receiver configuration.
 * ip must point to at least 16 address bytes.
 * Only the first 4 bytes are read for SWPS_FAMILY_IP4.
 * All 16 bytes are read for SWPS_FAMILY_IP6.
 * port is in native host byte order. Zero requests an ephemeral port.
 * family must be SWPS_FAMILY_IP4 or SWPS_FAMILY_IP6.
 *
 * Return 0 on success and -1 on failure.
 */
int swps_reader_init(swps_reader_t *r,
                     const swps_sctp_recv_config_t *sctp_cfg,
                     const uint8_t *ip,
                     uint16_t port,
                     uint8_t family);

/* Accept one incoming writer association.
 *
 * Block until a writer connects. The supplied configuration applies to the
 * accepted association. This call does not start the receive thread.
 * Call swps_reader_recv_config() next.
 * Return 0 on success and -1 on failure.
 */
int swps_reader_accept(swps_reader_t *r,
                       const swps_sctp_recv_config_t *sctp_cfg);

/* Read the writer's stream configuration from SCTP stream 0.
 *
 * Block until the control message arrives. Call this after accept and before
 * start. Return 0 on success and -1 on transport or protocol failure.
 */
int swps_reader_recv_config(swps_reader_t *r, swps_stream_config_t *out);

/* Start the reader background threads.
 *
 * buffer_blocks is the receive queue capacity in WavPack-stream blocks.
 * It must be between 1 and 65536. The decode thread pre-fills this queue before
 * the first read_frame call returns.
 * Return 0 on success and -1 on failure.
 */
int swps_reader_start(swps_reader_t *r, uint32_t buffer_blocks);

/* Receive and decode one buffered WavPack-stream block.
 *
 * Block until decoded PCM is available or the session ends.
 * Write interleaved signed int32_t values into out_buf.
 * out_buf_cap is the number of int32_t slots in out_buf.
 * On success, write the number of values produced to *out_len.
 * Return 0 on success and -1 on failure.
 */
int swps_reader_read_frame(swps_reader_t *r,
                           int32_t *out_buf,
                           uint32_t out_buf_cap,
                           uint32_t *out_len);

/* Poll for a new incoming writer without blocking.
 * Return 1 when a new writer is pending. Return 0 when none is pending.
 */
int swps_reader_poll_new_sender(swps_reader_t *r);

/* End the current session and move to the next writer.
 *
 * Promote a pending writer when swps_reader_poll_new_sender() found one.
 * Otherwise, block until a new writer connects. Read its stream configuration
 * into out. The reader is stopped after this call. Call swps_reader_start()
 * before reading audio from the new session.
 * Return 0 on success and -1 on failure.
 */
int swps_reader_next_session(swps_reader_t *r, swps_stream_config_t *out);

/* Stop all reader threads, close its sockets, and free the handle. */
void swps_reader_destroy(swps_reader_t *r);

/* Request shutdown of blocked reader operations. The destroy function joins
 * all reader threads and releases the resources. */
void swps_reader_cancel(swps_reader_t *r);

#ifdef __cplusplus
}
#endif

#endif /* SCTP_WPS_H */
