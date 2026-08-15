// SPDX-License-Identifier: GPL-3.0-or-later
//
// ft601_probe - host-side bring-up and throughput instrument for the FT601 on
// the Alchitry Ft+, talking to the chip through libusb with no FTDI D3XX.
//
// Three modes, in the order you need them during bring-up:
//
//   info    enumerate, dump descriptors and the endpoint map.  Needs no
//           gateware -- the FT601 enumerates whatever the fabric is doing.
//   config  read the chip configuration over vendor request 0xCF.  Tells you
//           the FIFO mode, channel count and clock the EEPROM is programmed
//           for.  Also needs no gateware.
//   bench   sustained bulk-IN read with a ring of N in-flight transfers.
//           Needs the fabric actually streaming.
//
// `bench --sweep` is the measurement that settles whether a transport is
// latency-bound or per-byte-bound.  Throughput that climbs with queue depth
// means round trips dominate and deeper pipelining pays.  Throughput that is
// flat against depth while a core sits pegged means the per-byte path (copies,
// TCP, virtual NIC) is the wall and pipelining will not rescue it.  Run the
// same sweep natively and over usbipd and the two curves separate the driver's
// behaviour from the transport's overhead.
//
// LICENSING NOTE.  This file is GPL-3.0-or-later rather than BSD-2-Clause like
// most of tools/.  The `struct ft60x_ctrlreq` layout and the fact that a read
// must be announced on endpoint 0x01 before it appears on 0x82 are not
// documented by FTDI; they come from the LambdaConcept pciescreamer driver by
// way of ufrisk/LeechCore-plugins (leechcore_ft601_driver_linux, GPLv3,
// contributed by Jeremie Boutoille / Synacktiv).  The FT_60XCONFIGURATION
// layout is separate -- that one *is* public FTDI D3XX API documentation.  If
// this file ever wants to be BSD-2, the session-request layout is the piece
// that needs deriving independently; everything else here is already clean.

#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include <libusb.h>

#define FTDI_VID                    0x0403

// The Ft+ enumerates as 601E, LeechCore hardcodes 601F.  Both are FT60x and the
// PID lives in a writable EEPROM, so it identifies the board's programming and
// not the silicon -- match on either and let --pid override.  (The Ft+ carries
// an FT601: rtl-side the bus is 32 bits wide, which the FT600 does not have.)
#define FTDI_PID_A                  0x601e
#define FTDI_PID_B                  0x601f

#define IFACE_COMMS                 0x00
#define IFACE_DATA                  0x01
#define EP_SESSION_OUT              0x01
#define EP_DATA_OUT                 0x02
#define EP_DATA_IN                  0x82

#define VENDOR_REQ_CONFIG           0xcf

#define MAX_DEPTH                   64

// Message protocol (docs/PROTOCOL.md).  A 32-bit little-endian header, len in
// [7:0] as payload blocks not counting the header, type in [15:8].
#define MSG_TYPE_IDLE               0x00    // heartbeat / filler, no payload use
#define MSG_TYPE_SEQ                0x10    // the verified counter stream
#define MSG_TYPE_BUS_ENABLE         0x11    // host->card: start/stop a capture
#define MSG_TYPE_BUS_EVENTS         0x12    // card->host: Apple bus events
#define MSG_TYPE_BUS_STATUS         0x13    // card->host: overflow / counts

// The card's watchdog is 1 s and is kicked by any message; 100 ms leaves a wide
// margin without putting meaningful traffic on the link.
#define HEARTBEAT_MS                100

// Announced on EP_SESSION_OUT before a read shows up on EP_DATA_IN.  Provenance
// as described in the licensing note above.
struct ft60x_ctrlreq {
    uint32_t idx;
    uint8_t  pipe;
    uint8_t  cmd;
    uint8_t  unk1;
    uint8_t  unk2;
    uint32_t len;
    uint32_t unk4;
    uint32_t unk5;
} __attribute__((packed));

// Public FTDI D3XX API layout.
struct ft60x_config {
    uint16_t VendorID;
    uint16_t ProductID;
    uint8_t  StringDescriptors[128];
    uint8_t  Reserved;
    uint8_t  PowerAttributes;
    uint16_t PowerConsumption;
    uint8_t  Reserved2;
    uint8_t  FIFOClock;
    uint8_t  FIFOMode;
    uint8_t  ChannelConfig;
    uint16_t OptionalFeatureSupport;
    uint8_t  BatteryChargingGPIOConfig;
    uint8_t  FlashEEPROMDetection;
    uint32_t MSIO_Control;
    uint32_t GPIO_Control;
} __attribute__((packed));

struct opts {
    int      pid;
    int      depth;
    size_t   xfer_size;
    double   seconds;
    bool     sweep;
    bool     session;
    bool     verify;
    bool     starve;            // snoop: deliberately stop heartbeating
    unsigned stall_ms;          // snoop: heartbeat but stop READING, to overflow
    bool     real_bus;          // snoop: capture the real Apple bus, not synth
    unsigned timeout_ms;
    const char *outfile;
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static double cpu_sec(void)
{
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6 +
           (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1e6;
}

static const char *speed_name(int speed)
{
    switch(speed) {
        case LIBUSB_SPEED_LOW:        return "low (1.5 Mbps)";
        case LIBUSB_SPEED_FULL:       return "full (12 Mbps)";
        case LIBUSB_SPEED_HIGH:       return "high (480 Mbps)";
        case LIBUSB_SPEED_SUPER:      return "SuperSpeed (5 Gbps)";
        case LIBUSB_SPEED_SUPER_PLUS: return "SuperSpeed+ (10 Gbps)";
        default:                      return "unknown";
    }
}

static bool pid_matches(const struct opts *o, uint16_t pid)
{
    if(o->pid >= 0) { return pid == (uint16_t)o->pid; }
    return pid == FTDI_PID_A || pid == FTDI_PID_B;
}

// Find and open the first matching FT60x.  Returns NULL and explains why not.
static libusb_device_handle *open_device(libusb_context *ctx, const struct opts *o)
{
    libusb_device **list;
    libusb_device_handle *handle = NULL;
    ssize_t n = libusb_get_device_list(ctx, &list);
    if(n < 0) {
        fprintf(stderr, "libusb_get_device_list: %s\n", libusb_strerror((int)n));
        return NULL;
    }

    int other_ftdi = 0;
    bool matched_but_unopenable = false;
    for(ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if(libusb_get_device_descriptor(list[i], &d)) { continue; }
        if(d.idVendor != FTDI_VID) { continue; }
        if(!pid_matches(o, d.idProduct)) { other_ftdi++; continue; }

        int err = libusb_open(list[i], &handle);
        if(err) {
            fprintf(stderr,
                "found %04x:%04x but could not open it: %s\n"
                "  usbfs permissions?  install 99-ft601.rules, or run under sudo.\n",
                d.idVendor, d.idProduct, libusb_strerror(err));
            handle = NULL;
            matched_but_unopenable = true;
            continue;
        }
        break;
    }

    if(!handle) {
        if(matched_but_unopenable) {
            // Already explained above; do not follow it with a "not found"
            // message that contradicts it.
        } else if(other_ftdi) {
            fprintf(stderr, "no matching FT60x (saw %d other FTDI device(s)).\n",
                other_ftdi);
        } else {
            fprintf(stderr,
                "no FTDI device on the bus at all.\n"
                "  under WSL the board must be handed over first:\n"
                "    usbipd attach --wsl --busid <id>\n");
        }
    }
    libusb_free_device_list(list, 1);
    return handle;
}

// ---------------------------------------------------------------------------
// info
// ---------------------------------------------------------------------------

static int cmd_info(libusb_device_handle *h)
{
    libusb_device *dev = libusb_get_device(h);
    struct libusb_device_descriptor d;
    int err = libusb_get_device_descriptor(dev, &d);
    if(err) {
        fprintf(stderr, "get_device_descriptor: %s\n", libusb_strerror(err));
        return 1;
    }

    unsigned char str[256];
    printf("device      %04x:%04x\n", d.idVendor, d.idProduct);
    printf("bcdUSB      %x.%02x\n", d.bcdUSB >> 8, d.bcdUSB & 0xff);
    printf("speed       %s\n", speed_name(libusb_get_device_speed(dev)));
    printf("bus/addr    %d/%d\n",
        libusb_get_bus_number(dev), libusb_get_device_address(dev));

    if(d.iManufacturer &&
       libusb_get_string_descriptor_ascii(h, d.iManufacturer, str, sizeof(str)) > 0) {
        printf("manufacturer %s\n", str);
    }
    if(d.iProduct &&
       libusb_get_string_descriptor_ascii(h, d.iProduct, str, sizeof(str)) > 0) {
        printf("product     %s\n", str);
    }
    if(d.iSerialNumber &&
       libusb_get_string_descriptor_ascii(h, d.iSerialNumber, str, sizeof(str)) > 0) {
        printf("serial      %s\n", str);
    }

    struct libusb_config_descriptor *cfg;
    err = libusb_get_active_config_descriptor(dev, &cfg);
    if(err) {
        fprintf(stderr, "get_active_config_descriptor: %s\n", libusb_strerror(err));
        return 1;
    }

    printf("\ninterfaces  %d\n", cfg->bNumInterfaces);
    for(int i = 0; i < cfg->bNumInterfaces; i++) {
        for(int a = 0; a < cfg->interface[i].num_altsetting; a++) {
            const struct libusb_interface_descriptor *id =
                &cfg->interface[i].altsetting[a];
            printf("  iface %d alt %d  class %02x  %d endpoint(s)\n",
                id->bInterfaceNumber, id->bAlternateSetting,
                id->bInterfaceClass, id->bNumEndpoints);
            for(int e = 0; e < id->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
                const char *dir = (ep->bEndpointAddress & 0x80) ? "IN " : "OUT";
                const char *type;
                switch(ep->bmAttributes & 0x03) {
                    case LIBUSB_TRANSFER_TYPE_BULK:      type = "bulk"; break;
                    case LIBUSB_TRANSFER_TYPE_INTERRUPT: type = "intr"; break;
                    case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: type = "iso"; break;
                    default:                             type = "ctrl"; break;
                }
                printf("    ep 0x%02x  %s  %-4s  wMaxPacketSize %u\n",
                    ep->bEndpointAddress, dir, type, ep->wMaxPacketSize);
            }
        }
    }
    libusb_free_config_descriptor(cfg);
    return 0;
}

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

static const char *fifo_mode_name(uint8_t m)
{
    switch(m) {
        case 0:  return "FT245 (synchronous 245 FIFO)";
        case 1:  return "FT600 (multi-channel)";
        default: return "unrecognised";
    }
}

static const char *channel_config_name(uint8_t c)
{
    switch(c) {
        case 0:  return "4 channels";
        case 1:  return "2 channels";
        case 2:  return "1 channel";
        case 3:  return "1 channel, OUT pipe only";
        case 4:  return "1 channel, IN pipe only";
        default: return "unrecognised";
    }
}

static const char *fifo_clock_name(uint8_t c)
{
    switch(c) {
        case 0:  return "100 MHz";
        case 1:  return "66 MHz";
        case 2:  return "50 MHz";
        case 3:  return "40 MHz";
        default: return "unrecognised";
    }
}

static int cmd_config(libusb_device_handle *h)
{
    struct ft60x_config cfg;
    memset(&cfg, 0, sizeof(cfg));

    int rc = libusb_control_transfer(h,
        LIBUSB_RECIPIENT_DEVICE | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_IN,
        VENDOR_REQ_CONFIG,
        1,      // wValue: read
        0,      // wIndex
        (unsigned char *)&cfg, sizeof(cfg),
        1000);
    if(rc < 0) {
        fprintf(stderr, "config read (vendor 0x%02x) failed: %s\n",
            VENDOR_REQ_CONFIG, libusb_strerror(rc));
        return 1;
    }
    if(rc != (int)sizeof(cfg)) {
        fprintf(stderr,
            "short config read: got %d bytes, expected %zu.\n"
            "  the struct layout may not match this chip's firmware.\n",
            rc, sizeof(cfg));
        return 1;
    }

    printf("VendorID              %04x\n", cfg.VendorID);
    printf("ProductID             %04x\n", cfg.ProductID);
    printf("PowerAttributes       %02x\n", cfg.PowerAttributes);
    printf("PowerConsumption      %u mA\n", cfg.PowerConsumption * 2);
    printf("FIFOClock             %02x  %s\n",
        cfg.FIFOClock, fifo_clock_name(cfg.FIFOClock));
    printf("FIFOMode              %02x  %s\n",
        cfg.FIFOMode, fifo_mode_name(cfg.FIFOMode));
    printf("ChannelConfig         %02x  %s\n",
        cfg.ChannelConfig, channel_config_name(cfg.ChannelConfig));
    printf("OptionalFeatureSupport %04x\n", cfg.OptionalFeatureSupport);
    printf("FlashEEPROMDetection  %02x\n", cfg.FlashEEPROMDetection);
    printf("MSIO_Control          %08x\n", cfg.MSIO_Control);
    printf("GPIO_Control          %08x\n", cfg.GPIO_Control);

    // The decodes above are a convenience; the raw bytes are what you compare
    // against FT_Prog or a known-good board when something disagrees.
    printf("\nraw:\n");
    const unsigned char *p = (const unsigned char *)&cfg;
    for(size_t i = 0; i < sizeof(cfg); i += 16) {
        printf("  %04zx  ", i);
        for(size_t j = 0; j < 16 && i + j < sizeof(cfg); j++) {
            printf("%02x ", p[i + j]);
        }
        printf("\n");
    }
    return 0;
}

// ---------------------------------------------------------------------------
// bench
// ---------------------------------------------------------------------------

struct slot {
    struct libusb_transfer *xfer;
    unsigned char          *buf;
    struct bench           *b;
    bool                    needs_resubmit;
    bool                    inflight;
    double                  submitted_at;
};

struct bench {
    libusb_device_handle *h;
    struct slot           slots[MAX_DEPTH];
    int                   depth;
    size_t                xfer_size;
    bool                  session;
    unsigned              timeout_ms;
    uint32_t              session_idx;

    volatile bool         stopping;
    uint64_t              bytes;
    uint64_t              completions;
    uint64_t              timeouts;
    uint64_t              errors;
    double                latency_sum;

    // Sequence checking against ft601_top's 32-bit counter.  Two categories,
    // kept apart because they are not equally conclusive:
    //
    //   intra  a word inside one transfer did not follow its predecessor.
    //          Always a real defect - buffer contents cannot be reordered.
    //   inter  the first word of a transfer did not follow the last word of
    //          the previous one.  Normally a real drop, but with depth > 1 an
    //          out-of-order completion would also produce it, so it is only
    //          unambiguous at depth 1.
    bool                  verify;
    bool                  have_prev;
    uint64_t              markers;        // IDLE frames seen (heartbeats)
    uint32_t              prev_word;

    // Frame parser state, carried ACROSS reads: a message may straddle any
    // transfer boundary, so this cannot be reset per buffer.
    bool                  synced;         // found a frame boundary yet?
    uint64_t              skipped;        // blocks discarded acquiring sync
    uint32_t              blocks_left;    // payload blocks still expected
    uint64_t              frame_errors;   // headers that made no sense
    uint64_t              intra_errors;
    uint64_t              inter_errors;
    uint32_t              first_bad_expect;
    uint32_t              first_bad_got;
    bool                  have_first_bad;
};

// Check one completed buffer against the expected counter sequence.
static void verify_buffer(struct bench *b, const unsigned char *buf, int len)
{
    int words = len / 4;
    if(words <= 0) { return; }

    // The wire is little-endian: ft_data[7:0] is the low byte, so byte 0 of the
    // buffer is the low byte of the word.  A plain little-endian load.  The
    // gateware's byte reversal and the matching swap that used to live here are
    // both gone; they were pcileech's wire format, not the chip's.
    const uint8_t *p = (const uint8_t *)buf;
    #define WORD_AT(i) ((uint32_t)p[(i)*4+0] <<  0 | (uint32_t)p[(i)*4+1] <<  8 | \
                        (uint32_t)p[(i)*4+2] << 16 | (uint32_t)p[(i)*4+3] << 24)

    // Parse frames, and verify the counter across the PAYLOAD only.
    //
    // No marker filtering by value.  The gateware no longer emits 0x66665555,
    // and filtering by value would have been wrong regardless: a real counter
    // word passes through 0x66665555 once per 32-bit wrap.  Heartbeats are
    // identified structurally, as IDLE frames, which is the whole reason the
    // padding became a frame.
    //
    // Parser state is carried across buffers - a message may straddle any read
    // boundary - so a desync here is permanent by design.  See docs/PROTOCOL.md
    // on why there is deliberately no resynchronisation.
    // ACQUIRE SYNC.  The gateware free-runs, so a read starts wherever the
    // chip's 1 KB packetiser happened to be - block 0 is mid-frame 15 times out
    // of 16.  The protocol has no sync word (docs/PROTOCOL.md, deliberately), so
    // there is nothing generic to lock onto; but this test knows exactly what its
    // own source emits, so it locks onto that.  Confirm a candidate by checking
    // the next header lands one full frame later, which makes a false lock about
    // 1 in 2^64 rather than 1 in 2^32.
    //
    // This is sync ACQUISITION in the test harness, not protocol resync.  A real
    // consumer gets its framing from request/response instead: the first block
    // after a request it made is a header by construction.
    #define SEQ_HDR   ((uint32_t)((MSG_TYPE_SEQ << 8) | 15u))
    #define SEQ_FRAME 16                        /* header + 15 payload */

    int start = 0;
    if(!b->synced) {
        for(int i = 0; i + SEQ_FRAME < words; i++) {
            if(WORD_AT(i) == SEQ_HDR && WORD_AT(i + SEQ_FRAME) == SEQ_HDR) {
                start        = i;
                b->synced    = true;
                b->skipped  += (uint64_t)i;
                b->blocks_left = 0;
                break;
            }
        }
        if(!b->synced) { b->skipped += (uint64_t)words; return; }
    }

    bool first_payload = true;      // first payload word in THIS buffer
    for(int i = start; i < words; i++) {
        uint32_t w = WORD_AT(i);

        if(b->blocks_left == 0) {
            // Header.  Little-endian: len in [7:0], type in [15:8].
            uint32_t len   = w & 0xffu;
            uint32_t mtype = (w >> 8) & 0xffu;

            if(mtype == MSG_TYPE_IDLE) {
                b->markers++;               // heartbeat or filler
            } else if(mtype != MSG_TYPE_SEQ) {
                b->frame_errors++;          // unknown type: we have lost sync
                if(!b->have_first_bad) {
                    b->first_bad_expect = MSG_TYPE_SEQ;
                    b->first_bad_got    = w;
                    b->have_first_bad   = true;
                }
            }
            b->blocks_left = len;
            continue;
        }

        // Payload block: this is the sequence under test.  A break on the
        // first payload word of a buffer is `inter` (normally a real drop, but
        // at depth > 1 an out-of-order completion looks the same); anywhere
        // else it is `intra`, which is always a real defect.
        b->blocks_left--;
        if(b->have_prev && w != b->prev_word + 1) {
            if(first_payload) b->inter_errors++;
            else              b->intra_errors++;
            if(!b->have_first_bad) {
                b->first_bad_expect = b->prev_word + 1;
                b->first_bad_got    = w;
                b->have_first_bad   = true;
            }
        }
        first_payload = false;
        b->prev_word  = w;
        b->have_prev  = true;
    }
    #undef WORD_AT
}

// Announce an upcoming read.  Synchronous by nature -- it is a serialisation
// point, which is part of what the sweep is measuring.  Kept out of the async
// callback so it cannot re-enter the event loop.
static int send_session_request(struct bench *b, size_t len)
{
    struct ft60x_ctrlreq req;
    int transferred = 0;

    memset(&req, 0, sizeof(req));
    req.idx  = ++b->session_idx;
    req.pipe = EP_DATA_IN;
    req.cmd  = 1;               // read
    req.len  = (uint32_t)len;

    int err = libusb_bulk_transfer(b->h, EP_SESSION_OUT,
        (unsigned char *)&req, sizeof(req), &transferred, b->timeout_ms);
    if(err) { return err; }
    return transferred == (int)sizeof(req) ? 0 : LIBUSB_ERROR_IO;
}

// Drain anything the chip still has staged, so consecutive runs are independent.
//
// A session request is a promise to read N bytes, and cancelling a transfer that
// already had one sent leaves the chip holding data nobody collected.  In
// practice that resolves on its own - runs measured back to back are repeatable
// to 0.1 MB/s with or without this - so treat it as hygiene between measurement
// points rather than a fix for anything.  It is cheap and it makes each point
// start from a known state.
//
// Deliberately NOT libusb_clear_halt.  On an endpoint that is not actually
// halted, CLEAR_FEATURE(ENDPOINT_HALT) resets the data toggle and desynchronises
// the chip rather than repairing it.  Draining by reading is the safe operation.
static void flush_pipe(libusb_device_handle *h, size_t bufsize)
{
    // NOTE: deliberately NOT calling libusb_clear_halt here.  On an endpoint
    // that is not actually halted, CLEAR_FEATURE(ENDPOINT_HALT) resets the data
    // toggle and desynchronises the chip rather than repairing it - it turned a
    // working link into a dead one.  Draining by reading is the safe operation.

    unsigned char *tmp = malloc(bufsize);
    if(!tmp) { return; }
    for(int i = 0; i < 64; i++) {
        int got = 0;
        int err = libusb_bulk_transfer(h, EP_DATA_IN, tmp, (int)bufsize, &got, 50);
        if(err == LIBUSB_ERROR_TIMEOUT && got == 0) { break; }
        if(err && err != LIBUSB_ERROR_TIMEOUT)      { break; }
    }
    free(tmp);
}

static void LIBUSB_CALL on_complete(struct libusb_transfer *xfer)
{
    struct slot *s = (struct slot *)xfer->user_data;
    struct bench *b = s->b;

    s->inflight = false;

    switch(xfer->status) {
        case LIBUSB_TRANSFER_COMPLETED:
            b->bytes += (uint64_t)xfer->actual_length;
            b->completions++;
            b->latency_sum += now_sec() - s->submitted_at;
            if(b->verify) { verify_buffer(b, xfer->buffer, xfer->actual_length); }
            break;
        case LIBUSB_TRANSFER_TIMED_OUT:
            // Expected when the fabric is not streaming.  Still counts as a
            // round trip, so it is worth reporting separately rather than
            // folding into errors.
            b->timeouts++;
            b->bytes += (uint64_t)xfer->actual_length;
            break;
        case LIBUSB_TRANSFER_CANCELLED:
            return;                 // shutting down, do not resubmit
        default:
            b->errors++;
            break;
    }

    if(!b->stopping) { s->needs_resubmit = true; }
}

static int submit_slot(struct bench *b, struct slot *s)
{
    if(b->session) {
        int err = send_session_request(b, b->xfer_size);
        if(err) {
            // A failing session request is worth surfacing immediately: it
            // usually means the chip is not in a mode that expects one.
            fprintf(stderr, "session request failed: %s\n", libusb_strerror(err));
            return err;
        }
    }
    libusb_fill_bulk_transfer(s->xfer, b->h, EP_DATA_IN,
        s->buf, (int)b->xfer_size, on_complete, s, b->timeout_ms);
    s->submitted_at = now_sec();
    int err = libusb_submit_transfer(s->xfer);
    if(err) { return err; }
    s->inflight = true;
    s->needs_resubmit = false;
    return 0;
}

struct result {
    double   mbps;
    double   wall;
    double   cpu;
    uint64_t bytes;
    uint64_t completions;
    uint64_t timeouts;
    uint64_t errors;
    double   mean_latency_ms;
    uint64_t intra_errors;
    uint64_t inter_errors;
    uint64_t frame_errors;
    uint64_t markers;
    uint32_t first_bad_expect;
    uint32_t first_bad_got;
    bool     have_first_bad;
};

static int run_once(libusb_device_handle *h, const struct opts *o, int depth,
                    struct result *out)
{
    struct bench b;
    memset(&b, 0, sizeof(b));
    b.h          = h;
    b.depth      = depth;
    b.xfer_size  = o->xfer_size;
    b.session    = o->session;
    b.timeout_ms = o->timeout_ms;
    b.verify     = o->verify;

    for(int i = 0; i < depth; i++) {
        b.slots[i].b   = &b;
        b.slots[i].buf = malloc(o->xfer_size);
        b.slots[i].xfer = libusb_alloc_transfer(0);
        if(!b.slots[i].buf || !b.slots[i].xfer) {
            fprintf(stderr, "out of memory at depth %d\n", depth);
            return 1;
        }
    }

    double cpu0  = cpu_sec();
    double wall0 = now_sec();

    for(int i = 0; i < depth; i++) {
        int err = submit_slot(&b, &b.slots[i]);
        if(err) {
            fprintf(stderr, "initial submit %d: %s\n", i, libusb_strerror(err));
            b.stopping = true;
            break;
        }
    }

    while(!b.stopping) {
        struct timeval tv = { .tv_sec = 0, .tv_usec = 20000 };
        int err = libusb_handle_events_timeout_completed(NULL, &tv, NULL);
        if(err && err != LIBUSB_ERROR_INTERRUPTED) {
            fprintf(stderr, "handle_events: %s\n", libusb_strerror(err));
            break;
        }
        if(now_sec() - wall0 >= o->seconds) { break; }

        // Service resubmits outside the callback so the synchronous session
        // request never runs inside the event loop.
        for(int i = 0; i < depth; i++) {
            if(!b.slots[i].needs_resubmit) { continue; }
            if(submit_slot(&b, &b.slots[i])) { b.stopping = true; break; }
        }
    }

    // Stop announcing first, then let anything already promised complete on its
    // own before resorting to cancellation.  Every transfer we cancel with a
    // session request outstanding is a promise the chip keeps waiting on.
    b.stopping = true;
    for(int guard = 0; guard < 100; guard++) {
        bool any = false;
        for(int i = 0; i < depth; i++) { if(b.slots[i].inflight) { any = true; } }
        if(!any) { break; }
        struct timeval tv = { .tv_sec = 0, .tv_usec = 10000 };
        libusb_handle_events_timeout_completed(NULL, &tv, NULL);
    }
    for(int i = 0; i < depth; i++) {
        if(b.slots[i].inflight) { libusb_cancel_transfer(b.slots[i].xfer); }
    }
    // Drain outstanding completions so no callback fires after we free.
    for(int guard = 0; guard < 200; guard++) {
        bool any = false;
        for(int i = 0; i < depth; i++) { if(b.slots[i].inflight) { any = true; } }
        if(!any) { break; }
        struct timeval tv = { .tv_sec = 0, .tv_usec = 10000 };
        libusb_handle_events_timeout_completed(NULL, &tv, NULL);
    }

    double wall = now_sec() - wall0;
    double cpu  = cpu_sec() - cpu0;

    // Collect anything still staged in the chip so the next point starts clean.
    flush_pipe(h, o->xfer_size);

    for(int i = 0; i < depth; i++) {
        libusb_free_transfer(b.slots[i].xfer);
        free(b.slots[i].buf);
    }

    out->wall        = wall;
    out->cpu         = cpu;
    out->bytes       = b.bytes;
    out->completions = b.completions;
    out->timeouts    = b.timeouts;
    out->errors      = b.errors;
    out->mbps        = wall > 0 ? (double)b.bytes / wall / (1024.0 * 1024.0) : 0.0;
    out->mean_latency_ms = b.completions
        ? (b.latency_sum / (double)b.completions) * 1000.0 : 0.0;
    out->markers          = b.markers;
    out->intra_errors     = b.intra_errors;
    out->inter_errors     = b.inter_errors;
    out->frame_errors     = b.frame_errors;
    out->first_bad_expect = b.first_bad_expect;
    out->first_bad_got    = b.first_bad_got;
    out->have_first_bad   = b.have_first_bad;
    return 0;
}

static int cmd_bench(libusb_device_handle *h, const struct opts *o)
{
    int err = libusb_claim_interface(h, IFACE_COMMS);
    if(err) {
        fprintf(stderr, "claim interface %d: %s\n", IFACE_COMMS, libusb_strerror(err));
        return 1;
    }
    err = libusb_claim_interface(h, IFACE_DATA);
    if(err) {
        fprintf(stderr, "claim interface %d: %s\n", IFACE_DATA, libusb_strerror(err));
        libusb_release_interface(h, IFACE_COMMS);
        return 1;
    }

    // Recover from however the previous process left the chip.
    flush_pipe(h, o->xfer_size);

    printf("transfer size %zu KiB, %.1f s per point, session requests %s, verify %s\n\n",
        o->xfer_size / 1024, o->seconds,
        o->session ? "on" : "off", o->verify ? "on" : "off");
    printf("%6s %10s %10s %8s %10s %8s %8s",
        "depth", "MB/s", "lat(ms)", "CPU%", "xfers", "t/outs", "errs");
    if(o->verify) { printf(" %8s %8s %8s %8s", "intra", "inter", "frame", "idle"); }
    printf("\n");

    int depths[] = { 1, 2, 4, 8, 16 };
    int ndepths = o->sweep ? (int)(sizeof(depths) / sizeof(depths[0])) : 1;
    if(!o->sweep) { depths[0] = o->depth; }

    uint64_t total_bytes = 0, total_seq_errors = 0;
    bool     shown_first_bad = false;
    for(int i = 0; i < ndepths; i++) {
        struct result r;
        memset(&r, 0, sizeof(r));
        if(run_once(h, o, depths[i], &r)) { break; }
        total_bytes += r.bytes;
        total_seq_errors += r.intra_errors + r.inter_errors + r.frame_errors;
        printf("%6d %10.1f %10.3f %8.1f %10" PRIu64 " %8" PRIu64 " %8" PRIu64,
            depths[i], r.mbps, r.mean_latency_ms,
            r.wall > 0 ? 100.0 * r.cpu / r.wall : 0.0,
            r.completions, r.timeouts, r.errors);
        if(o->verify) {
            printf(" %8" PRIu64 " %8" PRIu64 " %8" PRIu64 " %8" PRIu64,
                r.intra_errors, r.inter_errors, r.frame_errors, r.markers);
        }
        printf("\n");
        if(o->verify && r.have_first_bad && !shown_first_bad) {
            printf("       first break: expected %08x, got %08x\n",
                r.first_bad_expect, r.first_bad_got);
            shown_first_bad = true;
        }
        fflush(stdout);
    }

    if(total_bytes == 0) {
        printf("\nNo data moved.  The FT601 enumerates and accepts transfers whatever\n"
               "the fabric is doing, but bulk IN only produces bytes once the gateware\n"
               "is actually streaming -- ft600_fifo.sv is not in the build yet.\n"
               "`info` and `config` are the modes that work before that point.\n");
    } else {
        printf("\nReading the sweep: throughput rising with depth means round trips\n"
               "dominate.  Throughput flat against depth with CPU%% pegged means the\n"
               "per-byte path is the wall.  Compare native against usbipd to separate\n"
               "this driver's behaviour from the transport's.\n");
        if(o->verify) {
            if(total_seq_errors == 0) {
                printf("Sequence intact: every word followed its predecessor, so the\n"
                       "throughput above is of correct data and not of a lossy link.\n");
            } else {
                printf("\nWARNING: %" PRIu64 " sequence break(s).  The MB/s above is NOT a\n"
                       "valid link measurement - words were dropped or duplicated.  Any\n"
                       "'intra' count is conclusive; 'inter' at depth > 1 could also be\n"
                       "out-of-order completion, so re-run with --depth 1 to be sure.\n",
                       total_seq_errors);
            }
        }
    }

    libusb_release_interface(h, IFACE_DATA);
    libusb_release_interface(h, IFACE_COMMS);
    return 0;
}

// ---------------------------------------------------------------------------
// write
// ---------------------------------------------------------------------------

// Push a block at the FT601's OUT endpoint.  Exists purely as a bring-up probe
// for the other direction: if the gateware's ft_rxf goes low and its FSM enters
// RX while this runs, the FIFO bus between the chip and the FPGA is electrically
// alive and clocking.  That separates "the chip will not talk to the fabric at
// all" from "the chip will not accept writes specifically", which TXE# sitting
// high cannot distinguish on its own.
static int cmd_write(libusb_device_handle *h, const struct opts *o)
{
    int err = libusb_claim_interface(h, IFACE_COMMS);
    if(err) {
        fprintf(stderr, "claim interface %d: %s\n", IFACE_COMMS, libusb_strerror(err));
        return 1;
    }
    err = libusb_claim_interface(h, IFACE_DATA);
    if(err) {
        fprintf(stderr, "claim interface %d: %s\n", IFACE_DATA, libusb_strerror(err));
        libusb_release_interface(h, IFACE_COMMS);
        return 1;
    }

    unsigned char *buf = malloc(o->xfer_size);
    if(!buf) { fprintf(stderr, "out of memory\n"); return 1; }
    for(size_t i = 0; i < o->xfer_size; i++) { buf[i] = (unsigned char)(i & 0xff); }

    printf("writing %zu KiB to ep 0x%02x, repeatedly for %.1f s\n",
        o->xfer_size / 1024, EP_DATA_OUT, o->seconds);

    double   t0 = now_sec();
    uint64_t total = 0;
    int      rounds = 0, fails = 0;

    while(now_sec() - t0 < o->seconds) {
        int transferred = 0;
        err = libusb_bulk_transfer(h, EP_DATA_OUT, buf, (int)o->xfer_size,
                                   &transferred, o->timeout_ms);
        rounds++;
        total += (uint64_t)transferred;
        if(err) {
            fails++;
            if(fails <= 3) {
                fprintf(stderr, "  write failed: %s (%d bytes went)\n",
                    libusb_strerror(err), transferred);
            }
            if(err == LIBUSB_ERROR_NO_DEVICE) { break; }
        }
    }

    double wall = now_sec() - t0;
    printf("%d round(s), %d failure(s), %" PRIu64 " bytes in %.2f s = %.1f MB/s\n",
        rounds, fails, total, wall,
        wall > 0 ? (double)total / wall / (1024.0 * 1024.0) : 0.0);
    if(total == 0) {
        printf("Nothing was accepted.  The chip is refusing the OUT direction too,\n"
               "which points away from the gateware entirely.\n");
    } else {
        printf("The chip accepted the data.  Now check the gateware side: if ft_rxf\n"
               "never went low and the FSM never entered RX, the chip took the bytes\n"
               "over USB but did not present them on the FIFO bus.\n");
    }

    free(buf);
    libusb_release_interface(h, IFACE_DATA);
    libusb_release_interface(h, IFACE_COMMS);
    return 0;
}

// ---------------------------------------------------------------------------
// snoop - run a bus capture and write the events to a file
// ---------------------------------------------------------------------------
//
// The two-way half of the protocol.  The card is silent until asked, which is
// what makes framing free here: everything before BUS_ENABLE is single-block
// IDLE frames, so the first block of the first BUS_EVENTS frame is a header at a
// boundary we already know.  There is no sync search in this mode and there does
// not need to be - contrast cmd_bench, which attaches to a free-running
// transmitter and has to lock on.
//
// Heartbeats are not optional.  Stop sending them for a second and the card
// treats the host as gone, resets the FT601 and re-enumerates it; the handle
// here goes stale and the capture is over.  That is the design, not a hazard to
// work around - see docs/PROTOCOL.md.

static volatile sig_atomic_t snoop_stop = 0;
static void snoop_sigint(int sig) { (void)sig; snoop_stop = 1; }

// Send one host->card frame.  Header only; none of the host->card types carry
// payload yet.
static int send_msg(libusb_device_handle *h, uint8_t type, uint16_t free_bits,
                    unsigned timeout_ms)
{
    unsigned char buf[4];
    uint32_t w = ((uint32_t)free_bits << 16) | ((uint32_t)type << 8) | 0u;
    buf[0] = (unsigned char)(w & 0xff);
    buf[1] = (unsigned char)((w >> 8) & 0xff);
    buf[2] = (unsigned char)((w >> 16) & 0xff);
    buf[3] = (unsigned char)((w >> 24) & 0xff);

    int sent = 0;
    int err = libusb_bulk_transfer(h, EP_DATA_OUT, buf, 4, &sent, timeout_ms);
    if(err) { return err; }
    return sent == 4 ? 0 : LIBUSB_ERROR_IO;
}

struct snoop_state {
    FILE     *out;
    uint32_t  blocks_left;
    uint8_t   cur_type;
    uint64_t  events;
    uint64_t  idles;
    uint64_t  frames;
    uint64_t  bad_types;
    bool      overflow_seen;
    bool      status_seen;
    bool      status_enable;
    uint32_t  card_captured;

    // Sequence check over the synthetic source, which spreads a 24-bit counter
    // across the addr and data fields.  Proves the dump is complete rather than
    // merely non-empty.
    // Light decode, so a real capture says something about the machine rather
    // than only about the link.
    uint16_t  addr_lo;
    uint16_t  addr_hi;
    uint64_t  n_reads;
    uint64_t  n_writes;

    bool      verify;
    bool      have_prev;
    uint32_t  prev_seq;
    uint64_t  seq_breaks;
};

static uint32_t ev_seq(uint32_t ev)
{
    // addr = seq[15:0], data = seq[23:16]  (see rtl/synth_bus_events.sv)
    return (ev & 0xffffu) | (((ev >> 20) & 0xffu) << 16);
}

static void snoop_consume(struct snoop_state *st, const unsigned char *buf, int len)
{
    const uint8_t *p = (const uint8_t *)buf;
    int words = len / 4;

    for(int i = 0; i < words; i++) {
        uint32_t w = (uint32_t)p[i*4+0] | (uint32_t)p[i*4+1] << 8 |
                     (uint32_t)p[i*4+2] << 16 | (uint32_t)p[i*4+3] << 24;

        if(st->blocks_left == 0) {
            uint32_t l = w & 0xffu;
            st->cur_type    = (uint8_t)((w >> 8) & 0xffu);
            st->blocks_left = l;
            st->frames++;
            switch(st->cur_type) {
                case MSG_TYPE_IDLE:   st->idles++; break;
                case MSG_TYPE_BUS_EVENTS: break;
                case MSG_TYPE_BUS_STATUS:
                    if(w & (1u << 16)) { st->overflow_seen = true; }
                    st->status_enable = (w & (1u << 17)) != 0;
                    st->status_seen   = true;
                    break;
                default:
                    st->bad_types++;
                    break;
            }
            continue;
        }

        st->blocks_left--;

        if(st->cur_type == MSG_TYPE_BUS_EVENTS) {
            if(st->out) { fwrite(p + i*4, 4, 1, st->out); }
            if(st->events == 0) { st->addr_lo = 0xffffu; st->addr_hi = 0; }
            {
                uint16_t a = (uint16_t)(w & 0xffffu);
                if(a < st->addr_lo) { st->addr_lo = a; }
                if(a > st->addr_hi) { st->addr_hi = a; }
                if(w & (1u << 16)) { st->n_reads++; } else { st->n_writes++; }
            }
            st->events++;
            if(st->verify) {
                uint32_t s = ev_seq(w);
                if(st->have_prev && s != ((st->prev_seq + 1) & 0xffffffu)) {
                    if(st->seq_breaks < 5) {
                        fprintf(stderr, "  sequence break: expected %06x, got %06x\n",
                                (st->prev_seq + 1) & 0xffffffu, s);
                    }
                    st->seq_breaks++;
                }
                st->prev_seq  = s;
                st->have_prev = true;
            }
        } else if(st->cur_type == MSG_TYPE_BUS_STATUS) {
            st->card_captured = w;
        }
    }
}

static int cmd_snoop(libusb_device_handle *h, const struct opts *o)
{
    struct bench b;
    memset(&b, 0, sizeof(b));
    b.h = h; b.timeout_ms = o->timeout_ms;

    struct snoop_state st;
    memset(&st, 0, sizeof(st));

    // The sequence check only means anything against the synthetic source, which
    // encodes a counter.  Real bus traffic is whatever the machine did.
    st.verify = o->verify && !o->real_bus;
    if(o->verify && o->real_bus) {
        printf("note: --verify ignored, real bus traffic carries no sequence\n");
    }

    if(o->outfile) {
        st.out = fopen(o->outfile, "wb");
        if(!st.out) { perror(o->outfile); return 1; }
    }

    if(libusb_claim_interface(h, IFACE_COMMS) || libusb_claim_interface(h, IFACE_DATA)) {
        fprintf(stderr, "could not claim interfaces\n");
        if(st.out) { fclose(st.out); }
        return 1;
    }

    signal(SIGINT, snoop_sigint);

    if(o->starve) {
        printf("capture: %.1f s, NO HEARTBEATS (watchdog test)\n"
               "the card should reset the link at ~1 s and re-enumerate\n\n",
            o->seconds);
    } else {
        printf("capture: %.1f s from the %s source, heartbeat every %d ms,\n"
               "output %s, verify %s\n\n",
            o->seconds, o->real_bus ? "REAL Apple bus" : "synthetic",
            HEARTBEAT_MS, o->outfile ? o->outfile : "(discarded)",
            st.verify ? "on" : "off");
    }

    int rc = 0;
    // free[0] = enable, free[1] = source (0 synthetic, 1 real bus)
    uint16_t enable_flags = 0x0001 | (o->real_bus ? 0x0002 : 0x0000);
    if(send_msg(h, MSG_TYPE_BUS_ENABLE, enable_flags, o->timeout_ms)) {
        fprintf(stderr, "BUS_ENABLE failed - is the snoop bitstream loaded?\n");
        rc = 1;
        goto out;
    }

    unsigned char *buf = malloc(o->xfer_size);
    if(!buf) { rc = 1; goto out; }

    double t0 = now_sec();
    double next_hb = t0;
    uint64_t bytes = 0;

    if(o->stall_ms) {
        // Keep the watchdog fed but take nothing off the link.  Everything
        // downstream fills - the chip's buffers, the TX FIFO, then the event
        // FIFO - and the card must notice and stop rather than drop quietly.
        printf("stalling reads for %u ms (still heartbeating)...\n", o->stall_ms);
        double t_stall = now_sec();
        while((now_sec() - t_stall) * 1000.0 < (double)o->stall_ms) {
            if(send_msg(h, MSG_TYPE_IDLE, 0, o->timeout_ms)) { break; }
            struct timespec ts = { 0, 20L * 1000L * 1000L };
            nanosleep(&ts, NULL);
        }
        printf("resuming reads\n");
        next_hb = now_sec();
    }

    while(!snoop_stop && (now_sec() - t0) < o->seconds) {
        double now = now_sec();
        if(o->starve) {
            // Deliberately silent: the card must notice and reset the link.
        } else if(now >= next_hb) {
            if(send_msg(h, MSG_TYPE_IDLE, 0, o->timeout_ms)) {
                fprintf(stderr, "heartbeat failed - the card may have reset us\n");
                break;
            }
            next_hb = now + (double)HEARTBEAT_MS / 1000.0;
        }

        // Announce a read and take it.  Short reads are normal and expected:
        // an idle bus produces a 4-byte heartbeat packet and nothing more.
        if(send_session_request(&b, o->xfer_size)) { break; }

        int got = 0;
        int err = libusb_bulk_transfer(h, EP_DATA_IN, buf, (int)o->xfer_size,
                                       &got, HEARTBEAT_MS);
        if(got > 0) {
            bytes += (uint64_t)got;
            snoop_consume(&st, buf, got);
        }
        if(err && err != LIBUSB_ERROR_TIMEOUT && got == 0) {
            fprintf(stderr, "read failed: %s\n", libusb_strerror(err));
            break;
        }
        if(st.overflow_seen) {
            fprintf(stderr, "\nOVERFLOW reported by the card - capture stopped there.\n"
                            "The dump ends at that point rather than containing a\n"
                            "silent gap.  The host was not draining fast enough.\n");
            break;
        }
    }

    double wall = now_sec() - t0;

    // Clean stop: this is the path that does NOT reset the link.
    //
    // Then DRAIN.  Disabling discards the card's event FIFO, but events already
    // handed to the TX FIFO and the chip's 1 KB buffers are still in flight and
    // legitimately belong to this capture.  Walking away here leaves them on the
    // link, and the next capture reads the tail of this one - measured, as one
    // sequence break at the seam of a second run.
    //
    // The card sends a BUS_STATUS on disable; that frame is the end-of-capture
    // marker, and its payload is the card's own event count, which is the
    // independent check that nothing was lost between card and host.
    if(send_msg(h, MSG_TYPE_BUS_ENABLE, 0x0000, o->timeout_ms)) {
        fprintf(stderr, "clean stop failed\n");
    } else {
        st.status_seen = false;
        double t_drain = now_sec();
        while(!st.status_seen && (now_sec() - t_drain) < 1.0) {
            if(send_session_request(&b, o->xfer_size)) { break; }
            int got = 0;
            libusb_bulk_transfer(h, EP_DATA_IN, buf, (int)o->xfer_size, &got, 100);
            if(got > 0) { bytes += (uint64_t)got; snoop_consume(&st, buf, got); }
        }
        if(st.status_seen && !st.status_enable) {
            printf("\nclean stop acknowledged (capture off, link left up)\n");
        } else {
            printf("\nclean stop sent, but no acknowledgement arrived\n");
        }
    }

    printf("\n%" PRIu64 " events in %.2f s (%.0f/s), %" PRIu64 " frames, "
           "%" PRIu64 " idle\n",
        st.events, wall, wall > 0 ? (double)st.events / wall : 0.0,
        st.frames, st.idles);
    if(o->real_bus && st.events) {
        printf("\naddress range %04x..%04x, %" PRIu64 " reads / %" PRIu64 " writes\n",
            st.addr_lo, st.addr_hi, st.n_reads, st.n_writes);
    }
    printf("%.2f MB read, card captured %u\n",
        (double)bytes / (1024.0 * 1024.0), st.card_captured);

    // The card counts what it put into its FIFO; we count what came out the
    // other end.  They must agree, and that is a stronger statement than the
    // sequence check alone - it catches a whole frame going missing, which a
    // per-event check on a resynchronised stream could slide past.
    if(st.card_captured != 0) {
        if((uint64_t)st.card_captured == st.events) {
            printf("Counts agree: the card captured exactly what arrived.\n");
        } else {
            printf("\nWARNING: card captured %u but %" PRIu64 " arrived (difference %lld).\n",
                st.card_captured, st.events,
                (long long)st.card_captured - (long long)st.events);
            rc = 1;
        }
    }

    if(st.bad_types) {
        printf("\nWARNING: %" PRIu64 " unknown frame type(s) - framing was lost.\n",
            st.bad_types);
        rc = 1;
    }
    if(o->verify) {
        if(st.seq_breaks == 0 && st.events > 0) {
            printf("\nSequence intact: every event followed its predecessor, so the\n"
                   "dump is complete and not merely non-empty.\n");
        } else if(st.seq_breaks) {
            printf("\nWARNING: %" PRIu64 " sequence break(s) - events were LOST.\n",
                st.seq_breaks);
            rc = 1;
        }
    }

    free(buf);

out:
    if(st.out) { fclose(st.out); }
    libusb_release_interface(h, IFACE_DATA);
    libusb_release_interface(h, IFACE_COMMS);
    return rc;
}

// ---------------------------------------------------------------------------
// dump - print the first words of a read, as the frame parser sees them
// ---------------------------------------------------------------------------
//
// The parser has no sync word by design (docs/PROTOCOL.md), so it assumes the
// first block of a read is a header.  Whether that assumption holds is the
// difference between a working parser and 300 phantom sequence breaks, and it
// is not something a throughput figure will ever tell you.
static int cmd_dump(libusb_device_handle *h, const struct opts *o)
{
    struct bench b;
    memset(&b, 0, sizeof(b));
    b.h = h; b.timeout_ms = o->timeout_ms;

    const int want = 4096;
    unsigned char *buf = malloc(want);
    if(!buf) { return 1; }

    if(libusb_claim_interface(h, IFACE_COMMS) || libusb_claim_interface(h, IFACE_DATA)) {
        fprintf(stderr, "could not claim interfaces\n");
        free(buf); return 1;
    }

    if(send_session_request(&b, (size_t)want)) {
        fprintf(stderr, "session request failed\n");
        goto out;
    }

    int got = 0;
    int err = libusb_bulk_transfer(h, EP_DATA_IN, buf, want, &got, o->timeout_ms);
    if(err && got == 0) {
        fprintf(stderr, "read failed: %s\n", libusb_strerror(err));
        goto out;
    }

    printf("read %d bytes (%d blocks).  first 48 blocks, little-endian:\n\n", got, got / 4);
    const uint8_t *p = buf;
    for(int i = 0; i < 48 && i * 4 < got; i++) {
        uint32_t w = (uint32_t)p[i*4+0] | (uint32_t)p[i*4+1] << 8 |
                     (uint32_t)p[i*4+2] << 16 | (uint32_t)p[i*4+3] << 24;
        uint32_t len = w & 0xffu, ty = (w >> 8) & 0xffu;
        printf("  [%3d] %08x", i, w);
        if(ty == MSG_TYPE_SEQ && len == 15) { printf("   <- looks like a SEQ header (len=%u)", len); }
        else if(ty == MSG_TYPE_IDLE && len == 0 && w == 0) { printf("   <- heartbeat"); }
        printf("\n");
    }
    printf("\nIf block 0 is not a header, the parser starts mid-frame and cannot\n"
           "recover - the protocol has no sync word.\n");

out:
    libusb_release_interface(h, IFACE_DATA);
    libusb_release_interface(h, IFACE_COMMS);
    free(buf);
    return 0;
}

// ---------------------------------------------------------------------------
// zlp - does a transfer ending on a 1024-byte boundary terminate?
// ---------------------------------------------------------------------------

// pcileech-fpga inserts five magic DWORDs into every stream with this comment:
//
//   "FTDI have a bug ( in chip or driver ) which doesn't terminate transfer if
//    even multiple of 1024 bytes are transmitted."
//
// 1024 is wMaxPacketSize for SuperSpeed bulk, so a transfer of exactly N*1024
// has no short packet to end it and needs a zero-length packet instead.  Their
// workaround pads the stream by 20 bytes so the total is never a clean multiple.
//
// But that comment says "chip OR driver", and we replaced the driver - this is
// libusb, not FTDI's D3XX.  So the premise is worth testing rather than
// inheriting.
//
// The test: announce a read of N bytes on the session endpoint, then read into a
// buffer LARGER than N.  The chip should deliver N and terminate.  If it
// terminates we get a short transfer back promptly; if the bug bites, the read
// sits waiting for bytes that never come and times out.  Non-multiples of 1024
// are included as controls - those have a short packet and must always work.
static int cmd_zlp(libusb_device_handle *h, const struct opts *o)
{
    static const int lens[] = { 1024, 2048, 4096, 8192, 1020, 1028, 3000, 5120 };
    const int n = (int)(sizeof(lens) / sizeof(lens[0]));

    int err = libusb_claim_interface(h, IFACE_COMMS);
    if(err) { fprintf(stderr, "claim %d: %s\n", IFACE_COMMS, libusb_strerror(err)); return 1; }
    err = libusb_claim_interface(h, IFACE_DATA);
    if(err) { fprintf(stderr, "claim %d: %s\n", IFACE_DATA, libusb_strerror(err));
              libusb_release_interface(h, IFACE_COMMS); return 1; }

    size_t bufsz = 16384 + 8192;
    unsigned char *buf = malloc(bufsz);
    if(!buf) { fprintf(stderr, "out of memory\n"); return 1; }

    printf("announce N bytes, read into a larger buffer, see if it terminates\n\n");
    printf("%8s %10s %10s %8s  %s\n", "N", "mult1024", "got", "ms", "result");

    struct bench b;
    memset(&b, 0, sizeof(b));
    b.h = h; b.timeout_ms = o->timeout_ms;

    int failures = 0;
    for(int i = 0; i < n; i++) {
        flush_pipe(h, 65536);

        int want = lens[i];
        b.xfer_size = (size_t)want;
        if(send_session_request(&b, (size_t)want)) {
            printf("%8d %10s %10s %8s  session request failed\n",
                want, (want % 1024) ? "no" : "YES", "-", "-");
            failures++;
            continue;
        }

        int got = 0;
        double t0 = now_sec();
        // Deliberately ask for more than was announced.
        int rc = libusb_bulk_transfer(h, EP_DATA_IN, buf, want + 4096, &got, 1000);
        double ms = (now_sec() - t0) * 1000.0;

        const char *verdict;
        if(rc == 0)                            { verdict = "terminated cleanly"; }
        else if(rc == LIBUSB_ERROR_TIMEOUT && got == want) {
            verdict = "timed out, but all N arrived - NO ZLP";  failures++;
        } else if(rc == LIBUSB_ERROR_TIMEOUT)  { verdict = "TIMED OUT";  failures++; }
        else                                   { verdict = libusb_strerror(rc); failures++; }

        printf("%8d %10s %10d %8.1f  %s\n",
            want, (want % 1024) ? "no" : "YES", got, ms, verdict);
        fflush(stdout);
    }

    printf("\n");
    if(failures == 0) {
        printf("Every length terminated, including exact multiples of 1024.  The\n"
               "termination bug the reference works around does not reproduce through\n"
               "this libusb path, so it is a D3XX driver behaviour rather than silicon.\n");
    } else {
        printf("%d length(s) did not terminate cleanly.  If those are the multiples of\n"
               "1024, the bug is in the chip and the reference's padding is required\n"
               "here too.\n", failures);
    }

    free(buf);
    libusb_release_interface(h, IFACE_DATA);
    libusb_release_interface(h, IFACE_COMMS);
    return failures ? 1 : 0;
}

// ---------------------------------------------------------------------------

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s <info|config|bench|write|snoop|dump|zlp> [options]\n"
        "\n"
        "  --pid <hex>     match this product id instead of 601e/601f\n"
        "  --depth <n>     in-flight transfers for bench (default 4, max %d)\n"
        "  --size <kib>    transfer size in KiB (default 256)\n"
        "  --seconds <s>   duration per sweep point (default 3)\n"
        "  --sweep         run depths 1,2,4,8,16 instead of a single depth\n"
        "  --no-session    omit the session request (link will NOT work; for\n"
        "                  proving that it is required)\n"
        "  --verify        check the incoming counter sequence for gaps\n"
        "  -o, --output F  snoop: write captured bus events to F (raw 32-bit LE)\n"
        "  --stall <ms>    snoop: keep heartbeating but stop READING for <ms>, to\n"
        "                  overflow the card's event FIFO on purpose\n"
        "  --real          snoop: capture the real Apple bus instead of the\n"
        "                  synthetic source.  --verify does not apply: real bus\n"
        "                  traffic has no sequence to check.\n"
        "  --starve        snoop: enable a capture then STOP heartbeating, to\n"
        "                  exercise the card's 1 s watchdog.  The link resets and\n"
        "                  the device re-enumerates; that is the pass condition.\n"
        "  --timeout <ms>  per-transfer timeout (default 1000)\n",
        argv0, MAX_DEPTH);
}

int main(int argc, char **argv)
{
    struct opts o = {
        .pid = -1, .depth = 4, .xfer_size = 256 * 1024,
        // session ON by default: without it the FT601 never offers the fabric
        // write space, TXE# stays high and the link moves exactly zero bytes.
        .seconds = 3.0, .sweep = false, .session = true, .timeout_ms = 1000,
    };

    if(argc < 2) { usage(argv[0]); return 2; }
    const char *mode = argv[1];

    static struct option longopts[] = {
        { "pid",     required_argument, 0, 'p' },
        { "depth",   required_argument, 0, 'd' },
        { "size",    required_argument, 0, 's' },
        { "seconds", required_argument, 0, 'S' },
        { "sweep",   no_argument,       0, 'w' },
        { "session",    no_argument,    0, 'e' },
        { "no-session", no_argument,    0, 'E' },
        { "verify",  no_argument,       0, 'v' },
        { "output",  required_argument, 0, 'o' },
        { "starve",  no_argument,       0, 'K' },
        { "stall",   required_argument, 0, 'L' },
        { "real",    no_argument,       0, 'R' },
        { "timeout", required_argument, 0, 't' },
        { "help",    no_argument,       0, 'h' },
        { 0, 0, 0, 0 },
    };

    int c;
    optind = 2;
    while((c = getopt_long(argc, argv, "p:d:s:S:wevEt:o:KL:Rh", longopts, NULL)) != -1) {
        switch(c) {
            case 'p': o.pid = (int)strtol(optarg, NULL, 16); break;
            case 'd': o.depth = atoi(optarg); break;
            case 's': o.xfer_size = (size_t)atoi(optarg) * 1024; break;
            case 'S': o.seconds = atof(optarg); break;
            case 'w': o.sweep = true; break;
            case 'e': o.session = true; break;
            case 'E': o.session = false; break;
            case 'v': o.verify = true; break;
            case 'o': o.outfile = optarg; break;
            case 'K': o.starve = true; break;
            case 'L': o.stall_ms = (unsigned)atoi(optarg); break;
            case 'R': o.real_bus = true; break;
            case 't': o.timeout_ms = (unsigned)atoi(optarg); break;
            case 'h': usage(argv[0]); return 0;
            default:  usage(argv[0]); return 2;
        }
    }

    if(o.depth < 1 || o.depth > MAX_DEPTH) {
        fprintf(stderr, "depth must be 1..%d\n", MAX_DEPTH);
        return 2;
    }
    if(o.xfer_size == 0) {
        fprintf(stderr, "size must be nonzero\n");
        return 2;
    }

    int err = libusb_init(NULL);
    if(err) {
        fprintf(stderr, "libusb_init: %s\n", libusb_strerror(err));
        return 1;
    }

    libusb_device_handle *h = open_device(NULL, &o);
    if(!h) { libusb_exit(NULL); return 1; }

    int rc;
    if(!strcmp(mode, "info")) {
        rc = cmd_info(h);
    } else if(!strcmp(mode, "config")) {
        rc = cmd_config(h);
    } else if(!strcmp(mode, "bench")) {
        rc = cmd_bench(h, &o);
    } else if(!strcmp(mode, "write")) {
        rc = cmd_write(h, &o);
    } else if(!strcmp(mode, "snoop")) {
        rc = cmd_snoop(h, &o);
    } else if(!strcmp(mode, "dump")) {
        rc = cmd_dump(h, &o);
    } else if(!strcmp(mode, "zlp")) {
        rc = cmd_zlp(h, &o);
    } else {
        usage(argv[0]);
        rc = 2;
    }

    libusb_close(h);
    libusb_exit(NULL);
    return rc;
}
