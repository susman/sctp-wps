/*
 * Read interleaved raw S24_LE PCM from stdin and send it to a destination.
 *
 * Usage: sender <host> <port> [OPTIONS]
 *   -rate N       Sample rate (default: 48000)
 *   -channels N   Channel count (default: 2)
 *   -udp          Use SCTP-over-UDP on UDP port 9899
 *
 * The input must be signed, little-endian, interleaved 24-bit PCM.
 * Each sample occupies three bytes.
 * The host must be a numeric IPv4 address.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <poll.h>
#include <errno.h>
#include <limits.h>

#include "sctp-wps.h"

/* Number of frames submitted in one write call. */
#define CHUNK_FRAMES 4096

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s <host> <port> [OPTIONS]\n"
        "  -rate N       Sample rate (default 48000)\n"
        "  -channels N   Channel count (default 2)\n"
        "  -udp          Use SCTP-over-UDP on UDP port 9899\n"
        "\n"
        "Reads raw interleaved S24_LE PCM from stdin.\n",
        prog);
    exit(1);
}

/* Sign-extend a packed 24-bit sample to int32_t. */
static int32_t sign_extend_24(uint32_t v)
{
    if (v & 0x00800000u) v |= 0xff000000u;
    return (int32_t)v;
}

static int parse_unsigned(const char *text, unsigned long max, unsigned long *out)
{
    char *end = NULL;
    unsigned long value;

    if (!text || text[0] == '-') return -1;
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno == ERANGE || end == text || *end != '\0' || value > max)
        return -1;
    *out = value;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) usage(argv[0]);

    const char *host      = argv[1];
    unsigned long port_arg;
    int         port;
    uint32_t    rate      = 48000;
    int         channels  = 2;
    int         udp       = 0;

    if (parse_unsigned(argv[2], 65535, &port_arg) != 0 || port_arg == 0) {
        fprintf(stderr, "Invalid port: %s\n", argv[2]);
        return 1;
    }
    port = (int)port_arg;

    for (int i = 3; i < argc; i++) {
        unsigned long value;
        if (!strcmp(argv[i], "-rate") && i + 1 < argc) {
            if (parse_unsigned(argv[++i], INT32_MAX, &value) != 0 || value == 0) {
                fprintf(stderr, "Invalid sample rate: %s\n", argv[i]);
                return 1;
            }
            rate = (uint32_t)value;
        } else if (!strcmp(argv[i], "-channels") && i + 1 < argc) {
            if (parse_unsigned(argv[++i], 2, &value) != 0 || value == 0) {
                fprintf(stderr, "Channels must be 1 or 2, got %s\n", argv[i]);
                return 1;
            }
            channels = (int)value;
        }
        else if (!strcmp(argv[i], "-udp"))                      udp      = 1;
        else usage(argv[0]);
    }

    /* Store the destination address in the C API's 16-byte buffer. */
    uint8_t ip[16];
    memset(ip, 0, sizeof(ip));
    uint8_t family = SWPS_FAMILY_IP4;

    struct in_addr addr4;
    if (inet_pton(AF_INET, host, &addr4) == 1) {
        /* IPv4 uses the first four bytes of the address buffer. */
        memcpy(ip, &addr4, 4);
        family = SWPS_FAMILY_IP4;
    } else {
        fprintf(stderr, "Invalid host address. Only IPv4 is supported in this example: %s\n", host);
        return 1;
    }

    /* Configure the WavPack encoder. */
    swps_wp_config_t wp = swps_wp_config_default();
    wp.sample_rate     = rate;
    wp.num_channels    = (uint16_t)channels;
    wp.bits_per_sample = 24;
    wp.quality         = 3; /* Use the very-high quality preset. */
    wp.joint_stereo    = 1;

    swps_sctp_config_t sctp = swps_sctp_config_default();
    if (udp) sctp.udp_encaps_port = 9899;
#ifdef __APPLE__
    /* usrsctp requires RFC 6951 UDP encapsulation on macOS. */
    sctp.udp_encaps_port = 9899;
#endif

    swps_writer_t *w = swps_writer_create();
    if (!w) {
        fprintf(stderr, "OOM allocating writer\n");
        return 1;
    }

    fprintf(stderr,
            "Connecting to %s:%d rate=%u ch=%d bits=24 udp=%s\n",
            host, port, rate, channels,
#ifdef __APPLE__
            "yes"
#else
            udp ? "yes" : "no"
#endif
    );

    if (swps_writer_init(w, &wp, &sctp, ip, (uint16_t)port, family) != 0) {
        fprintf(stderr, "Connection failed\n");
        swps_writer_destroy(w);
        return 1;
    }

    fprintf(stderr, "Connected\n");

    const int  chunk_i32s = CHUNK_FRAMES * channels;
    const int  chunk_bytes = chunk_i32s * 3;
    uint8_t *raw = malloc((size_t)chunk_bytes);
    int32_t *ibuf = malloc(sizeof(int32_t) * (size_t)chunk_i32s);
    if (!raw || !ibuf) {
        fprintf(stderr, "OOM allocating buffers\n");
        free(raw); free(ibuf);
        swps_writer_destroy(w);
        return 1;
    }

    size_t total_frames = 0;
    int    ret          = 0;

    size_t raw_len = 0;
    const size_t frame_bytes = (size_t)channels * 3;

    while (!feof(stdin)) {
        struct pollfd pfd = { .fd = STDIN_FILENO, .events = POLLIN };
        int r = poll(&pfd, 1, 500);
        if (r < 0) {
            if (errno == EINTR) continue;
            perror("poll stdin");
            ret = 1;
            break;
        }
        if (r == 0) {
            /* Check the connection after 500 ms without input. */
            if (swps_writer_check(w) != 0) {
                fprintf(stderr, "Connection lost.\n");
                ret = 1;
            }
            /* Stop on error. Otherwise poll again without busy-waiting. */
            if (ret) break;
            continue;
        }

        size_t n = fread(raw + raw_len, 1, (size_t)chunk_bytes - raw_len, stdin);
        raw_len += n;
        if (n == 0) {
            if (ferror(stdin)) {
                perror("stdin read");
                ret = 1;
            }
            break;
        }

        const size_t usable = raw_len - raw_len % frame_bytes;
        if (usable == 0) continue;

        /* Convert each packed S24_LE sample to a right-justified int32_t. */
        uint32_t num_samp = (uint32_t)(usable / 3);
        for (uint32_t i = 0; i < num_samp; i++) {
            uint32_t v = (uint32_t)raw[i*3] |
                        ((uint32_t)raw[i*3 + 1] << 8) |
                        ((uint32_t)raw[i*3 + 2] << 16);
            ibuf[i] = sign_extend_24(v);
        }

        if (swps_writer_write(w, ibuf, num_samp) != 0) {
            fprintf(stderr, "Encode/send error after %zu frames\n", total_frames);
            ret = 1;
            raw_len = 0;
            break;
        }

        total_frames += num_samp / (size_t)channels;
        raw_len -= usable;
        if (raw_len > 0) memmove(raw, raw + usable, raw_len);
    }

    if (raw_len != 0) {
        fprintf(stderr, "Incomplete PCM frame at end of input\n");
        ret = 1;
    }

    if (swps_writer_flush(w) != 0)
        fprintf(stderr, "Warning: flush error\n");

    fprintf(stderr, "Done. Sent %zu frames.\n", total_frames);

    free(raw);
    free(ibuf);
    swps_writer_destroy(w);
    return ret;
}
