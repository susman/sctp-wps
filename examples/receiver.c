/*
 * Accept a writer, decode WavPack-stream blocks, and write interleaved raw
 * S24_LE PCM to stdout.
 *
 * The writer sends the sample rate, channel count, and bit depth on the
 * control stream. This example emits S24_LE output and expects 24-bit input.
 * On Linux, the kernel UDP encapsulation port must be set to 9899.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <limits.h>

#include <arpa/inet.h>

#include "sctp-wps.h"

/* Maximum int32_t values in one decoded block. */
#define MAX_FRAME_I32S (8192 * SWPS_MAX_CHANNELS)

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s <port> [OPTIONS]\n"
        "  -bind ADDR   Numeric IPv4 bind address           (default: 0.0.0.0)\n"
        "  -buffer N    WavPack-stream block buffer depth  (default: 60)\n"
        "\n"
        "Writes raw interleaved S24_LE PCM to stdout.\n"
        "The Linux kernel UDP encapsulation port must be 9899.\n"
        "Examples: %s 5000 | sox -t raw -b 24 -e signed-integer -r 48000 -c 2 - -t alsa hw:0,0\n"
        "          %s 5000 > out-raw.pcm\n",
        prog, prog, prog);
    exit(1);
}

/* Detect the configured SCTP UDP encapsulation port.
 * Return the port when enabled, or 0 when disabled. */
static uint16_t detect_udp_encap(void)
{
#ifdef __APPLE__
    /* usrsctp UDP encapsulation is required on macOS. */
    return 9899;
#else
    /* Read the Linux kernel SCTP UDP encapsulation setting. */
    const char *path = "/proc/sys/net/sctp/udp_port";
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int val = 0;
    if (fscanf(f, "%d", &val) != 1) val = 0;
    fclose(f);
    return val > 0 ? (uint16_t)val : 0;
#endif
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
    if (argc < 2) usage(argv[0]);

    unsigned long port_arg;
    int         port;
    const char *bind_addr  = "0.0.0.0";
    uint32_t    buffer     = 60;

    if (parse_unsigned(argv[1], 65535, &port_arg) != 0 || port_arg == 0) {
        fprintf(stderr, "Invalid port: %s\n", argv[1]);
        return 1;
    }
    port = (int)port_arg;

    for (int i = 2; i < argc; i++) {
        unsigned long value;
        if (!strcmp(argv[i], "-bind") && i + 1 < argc) {
            bind_addr = argv[++i];
        } else if (!strcmp(argv[i], "-buffer") && i + 1 < argc) {
            if (parse_unsigned(argv[++i], UINT32_MAX, &value) != 0 || value == 0) {
                fprintf(stderr, "Invalid buffer depth: %s\n", argv[i]);
                return 1;
            }
            buffer = (uint32_t)value;
        }
        else usage(argv[0]);
    }

    uint16_t udp_port = detect_udp_encap();
    if (!(udp_port > 0)) {
        fprintf(stderr, "Enable SCTP UDP encap port: net.sctp.udp_port=9899\n");
        exit(1);
    }

    /* Store the IPv4 bind address in the C API's 16-byte buffer. */
    uint8_t ip[16];
    memset(ip, 0, sizeof(ip));
    uint8_t family = SWPS_FAMILY_IP4;

    struct in_addr addr4;
    if (inet_pton(AF_INET, bind_addr, &addr4) == 1) {
        memcpy(ip, &addr4, 4);
        family = SWPS_FAMILY_IP4;
    } else {
        fprintf(stderr, "Invalid bind address. Only IPv4 is supported in this example: %s\n", bind_addr);
        return 1;
    }

    swps_sctp_recv_config_t sctp_cfg = swps_sctp_recv_config_default();
    sctp_cfg.udp_encaps_port = udp_port;

    swps_reader_t *r = swps_reader_create();
    if (!r) {
        fprintf(stderr, "OOM allocating reader\n");
        return 1;
    }

    if (swps_reader_init(r, &sctp_cfg,
                         ip, (uint16_t)port, family) != 0) {
        fprintf(stderr, "Failed to bind SCTP listener on %s:%d\n", bind_addr, port);
        swps_reader_destroy(r);
        return 1;
    }

    fprintf(stderr, "Listening on %s:%d ...\n", bind_addr, port);

    int32_t *buf = malloc(sizeof(int32_t) * MAX_FRAME_I32S);
    uint8_t *pcm = malloc((size_t)MAX_FRAME_I32S * 3);
    if (!buf || !pcm) {
        fprintf(stderr, "OOM allocating buffers\n");
        free(buf); free(pcm);
        swps_reader_destroy(r);
        return 1;
    }

    swps_stream_config_t stream_cfg;
    int ret = 0;

    /* Accept and process sessions until a fatal error occurs. */
    for (;;) {
        /* Wait for the next sender. */
        if (swps_reader_next_session(r, &stream_cfg) != 0) {
            fprintf(stderr, "Error awaiting next sender\n");
            ret = 1;
            break;
        }

        if (stream_cfg.num_channels < 1 || stream_cfg.num_channels > SWPS_MAX_CHANNELS) {
            fprintf(stderr, "Invalid channel count from sender: %u\n",
                    stream_cfg.num_channels);
            ret = 1;
            break;
        }
        if (stream_cfg.bits_per_sample != 24) {
            fprintf(stderr, "Only 24-bit streams are supported by this example, got %u\n",
                    stream_cfg.bits_per_sample);
            ret = 1;
            break;
        }

        fprintf(stderr, "New sender: rate=%u ch=%u bits=%u\n",
                stream_cfg.sample_rate, stream_cfg.num_channels,
                stream_cfg.bits_per_sample);

        if (swps_reader_start(r, buffer) != 0) {
            fprintf(stderr, "Failed to start recv thread\n");
            ret = 1;
            break;
        }

        fprintf(stderr, "Receiving\n");

        uint32_t out_len = 0;
        while (swps_reader_read_frame(r, buf, MAX_FRAME_I32S, &out_len) == 0) {
            /* Write the low three little-endian bytes of each sample. */
            for (uint32_t i = 0; i < out_len; i++) {
                pcm[i*3 + 0] = (uint8_t)(buf[i] >> 0);
                pcm[i*3 + 1] = (uint8_t)(buf[i] >> 8);
                pcm[i*3 + 2] = (uint8_t)(buf[i] >> 16);
            }

            if (fwrite(pcm, 1, (size_t)out_len * 3, stdout) != (size_t)out_len * 3) {
                if (ferror(stdout))
                    fprintf(stderr, "stdout write error\n");
                ret = 1;
                break;
            }
        }

        if (!ret) {
            fprintf(stderr, "Sender disconnected.\n");
            fflush(stdout);
        }

        if (ret) break;
    }

    free(buf);
    free(pcm);
    swps_reader_destroy(r);
    return ret;
}
