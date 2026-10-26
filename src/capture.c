// capture.c -- live multi-channel audio capture for visualizer.goose.
//
// miniaudio opens the default capture device (ALSA, PulseAudio, JACK, ...)
// with the device's native channel count and delivers interleaved f32 frames
// on its own thread. The callback deinterleaves into one fixed, preallocated
// single-producer/single-consumer ring per channel; the Goose loop drains each
// channel with cap_read(ch, dst). Nothing in the callback allocates, locks or
// waits.
//
// The number of channels is the device's native count, clamped to
// CAP_MAX_CHANNELS. A mono device is the degenerate one-channel case. The Null
// backend is miniaudio's last-resort device when the machine has no audio
// hardware (containers, CI); it still runs the callback, so the rings and the
// hot loop are exercised, it just delivers silence. cap_is_null() lets the
// program say so and fall back to its synthetic source.

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_GENERATION
#define MA_NO_WAV
#define MA_NO_FLAC
#define MA_NO_MP3
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Slices cross the extern boundary as { data, len } (Goose spec section 7.10).
typedef struct { const uint8_t *data; int64_t len; } gs_u8_slice;
typedef struct { float *data; int64_t len; } gs_f32_slice;

// Must match CH_MAX in visualizer.goose. 32768 frames at 48 kHz is 0.68 s of
// slack per channel. The rings are static: part of the library image, so the
// callback never asks an allocator for space.
#define CAP_MAX_CHANNELS 8
#define CAP_RING 32768

static float g_ring[CAP_MAX_CHANNELS][CAP_RING];
static atomic_ullong g_written[CAP_MAX_CHANNELS];
static atomic_ullong g_read[CAP_MAX_CHANNELS];
static atomic_ullong g_overflow[CAP_MAX_CHANNELS];
static unsigned long long g_overflow_seen[CAP_MAX_CHANNELS];

static ma_context g_ctx;
static ma_device g_dev;
static int g_ctx_ok;
static int g_open;
static int g_is_null;
static int g_channels;
static int g_native_channels;
static char g_name[256];
static char g_err[256];

void cap_close(void);

static void capture_cb(ma_device *dev, void *out, const void *in, ma_uint32 frames) {
    (void)out;
    const float *src = (const float *)in;
    const ma_uint32 native = dev->capture.channels;
    unsigned long long w[CAP_MAX_CHANNELS];
    const int n = g_channels;

    for (int c = 0; c < n; c++) {
        w[c] = atomic_load_explicit(&g_written[c], memory_order_relaxed);
        unsigned long long r = atomic_load_explicit(&g_read[c], memory_order_acquire);
        if (w[c] - r > CAP_RING - frames) {
            g_overflow_seen[c]++;
            atomic_store_explicit(&g_overflow[c], g_overflow_seen[c], memory_order_relaxed);
        }
    }

    for (ma_uint32 i = 0; i < frames; i++) {
        for (int c = 0; c < n; c++) {
            float s = 0.0f;
            if ((ma_uint32)c < native) s = src[i * native + (ma_uint32)c];
            g_ring[c][(w[c] + i) % CAP_RING] = s;
        }
    }

    for (int c = 0; c < n; c++) {
        atomic_store_explicit(&g_written[c], w[c] + frames, memory_order_release);
    }
}

static int ensure_context(void) {
    if (g_ctx_ok) return 1;
    ma_context_config cfg = ma_context_config_init();
    ma_result res = ma_context_init(NULL, 0, &cfg, &g_ctx);
    if (res != MA_SUCCESS) {
        snprintf(g_err, sizeof(g_err), "context: %s", ma_result_description(res));
        return 0;
    }
    g_ctx_ok = 1;
    return 1;
}

static int contains_ci(const char *hay, const char *needle) {
    if (!needle[0]) return 1;
    for (; *hay; hay++) {
        const char *h = hay;
        const char *n = needle;
        while (*h && *n) {
            char a = *h, b = *n;
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) break;
            h++; n++;
        }
        if (!*n) return 1;
    }
    return 0;
}

// Opens the default capture device, or the first one whose name contains
// `name`. `channels` 0 asks for the device's native channel count; a positive
// value requests exactly that many (miniaudio converts). The result is capped
// at CAP_MAX_CHANNELS. Returns 0 on success, 1 when a device cannot be opened,
// 2 when it opens but will not start. cap_error() has the reason.
int cap_open(gs_u8_slice name, int32_t rate, int32_t period, int32_t channels) {
    if (g_open) cap_close();
    g_name[0] = 0;
    g_err[0] = 0;
    g_is_null = 0;
    g_channels = 0;
    g_native_channels = 0;
    if (!ensure_context()) return 1;

    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.format = ma_format_f32;
    if (channels > 0) {
        if (channels > CAP_MAX_CHANNELS) channels = CAP_MAX_CHANNELS;
        cfg.capture.channels = (ma_uint32)channels;
    } else {
        cfg.capture.channels = 0;   // native channel count
    }
    cfg.sampleRate = (ma_uint32)(rate > 0 ? rate : 48000);
    cfg.periodSizeInFrames = (ma_uint32)(period > 0 ? period : 512);
    cfg.dataCallback = capture_cb;

    char wanted[256];
    wanted[0] = 0;
    if (name.len > 0) {
        int64_t n = name.len < (int64_t)sizeof(wanted) - 1 ? name.len : (int64_t)sizeof(wanted) - 1;
        memcpy(wanted, name.data, (size_t)n);
        wanted[n] = 0;

        ma_device_info *caps = NULL;
        ma_uint32 cap_count = 0;
        if (ma_context_get_devices(&g_ctx, NULL, NULL, &caps, &cap_count) != MA_SUCCESS) {
            snprintf(g_err, sizeof(g_err), "cannot enumerate capture devices");
            return 1;
        }
        int found = 0;
        for (ma_uint32 i = 0; i < cap_count; i++) {
            if (contains_ci(caps[i].name, wanted)) {
                cfg.capture.pDeviceID = &caps[i].id;
                snprintf(g_name, sizeof(g_name), "%s", caps[i].name);
                found = 1;
                break;
            }
        }
        if (!found) {
            snprintf(g_err, sizeof(g_err), "no capture device matches '%.200s'", wanted);
            return 1;
        }
    }

    ma_result res = ma_device_init(&g_ctx, &cfg, &g_dev);
    if (res != MA_SUCCESS) {
        snprintf(g_err, sizeof(g_err), "device init: %s", ma_result_description(res));
        return 1;
    }

    g_native_channels = (int)g_dev.capture.channels;
    if (g_native_channels < 1) g_native_channels = 1;
    g_channels = g_native_channels;
    if (g_channels > CAP_MAX_CHANNELS) g_channels = CAP_MAX_CHANNELS;

    g_is_null = strcmp(ma_get_backend_name(g_dev.pContext->backend), "Null") == 0;
    if (g_name[0] == 0) {
        ma_device_get_name(&g_dev, ma_device_type_capture, g_name, sizeof(g_name), NULL);
    }

    // Reset the rings before the callback can produce into them.
    for (int c = 0; c < CAP_MAX_CHANNELS; c++) {
        atomic_store(&g_written[c], 0);
        atomic_store(&g_read[c], 0);
        atomic_store(&g_overflow[c], 0);
        g_overflow_seen[c] = 0;
    }

    res = ma_device_start(&g_dev);
    if (res != MA_SUCCESS) {
        snprintf(g_err, sizeof(g_err), "device start: %s", ma_result_description(res));
        ma_device_uninit(&g_dev);
        g_channels = 0;
        return 2;
    }

    g_open = 1;
    return 0;
}

// Copies at most dst.len frames of channel `ch` into dst. Non-blocking: zero
// means no audio has arrived since the last call.
int64_t cap_read(int32_t ch, gs_f32_slice dst) {
    if (!g_open || ch < 0 || ch >= g_channels || dst.len <= 0) return 0;
    unsigned long long w = atomic_load_explicit(&g_written[ch], memory_order_acquire);
    unsigned long long r = atomic_load_explicit(&g_read[ch], memory_order_relaxed);
    if (w < r) r = w;
    // If the reader fell more than one ring behind, skip the overwritten
    // frames and return the newest window instead of stale samples.
    if (w - r > CAP_RING) r = w - CAP_RING;
    unsigned long long avail = w - r;
    if (avail > (unsigned long long)dst.len) avail = (unsigned long long)dst.len;
    if (avail == 0) return 0;

    size_t start = (size_t)(r % CAP_RING);
    size_t first = CAP_RING - start;
    if (first > avail) first = (size_t)avail;
    memcpy(dst.data, g_ring[ch] + start, first * sizeof(float));
    if (avail > first) {
        memcpy(dst.data + first, g_ring[ch], (size_t)(avail - first) * sizeof(float));
    }
    atomic_store_explicit(&g_read[ch], r + avail, memory_order_release);
    return (int64_t)avail;
}

int64_t cap_overflow(void) {
    unsigned long long total = 0;
    for (int c = 0; c < g_channels; c++) {
        total += atomic_load_explicit(&g_overflow[c], memory_order_relaxed);
    }
    return (int64_t)total;
}
int64_t cap_ring_frames(void) { return CAP_RING; }
int32_t cap_channels(void) { return g_channels; }
int32_t cap_native_channels(void) { return g_native_channels; }
int32_t cap_max_channels(void) { return CAP_MAX_CHANNELS; }
int32_t cap_is_null(void) { return g_is_null ? 1 : 0; }
uint64_t cap_backend(void) { return g_open ? (uint64_t)(uintptr_t)ma_get_backend_name(g_dev.pContext->backend) : 0; }
uint64_t cap_name(void) { return (uint64_t)(uintptr_t)g_name; }
uint64_t cap_error(void) { return (uint64_t)(uintptr_t)g_err; }

void cap_close(void) {
    if (!g_open) return;
    ma_device_uninit(&g_dev);
    g_open = 0;
    g_is_null = 0;
    g_channels = 0;
}

// Prints the capture devices miniaudio found. Used by --list.
int32_t cap_list(void) {
    if (!ensure_context()) {
        printf("audio context: %s\n", g_err);
        return 0;
    }
    ma_device_info *caps = NULL;
    ma_uint32 cap_count = 0;
    if (ma_context_get_devices(&g_ctx, NULL, NULL, &caps, &cap_count) != MA_SUCCESS) {
        printf("cannot enumerate capture devices\n");
        return 0;
    }
    printf("capture devices: %u\n", (unsigned)cap_count);
    for (ma_uint32 i = 0; i < cap_count; i++) {
        printf("  [%u] %s%s\n", (unsigned)i, caps[i].name, caps[i].isDefault ? " (default)" : "");
    }
    if (cap_count == 0) printf("  (none; the Null backend will deliver silence)\n");
    fflush(stdout);
    return (int32_t)cap_count;
}
