// capture.c -- live audio capture for visualizer.goose, a C sidecar.
//
// miniaudio opens the default capture device (ALSA, PulseAudio, JACK, ...)
// and delivers f32 mono frames on its own thread. The callback writes into a
// fixed, preallocated single-producer/single-consumer ring; the Goose loop
// drains it with cap_read. Nothing in the callback allocates, locks or waits.
//
// The null backend is miniaudio's last-resort device when the machine has no
// audio hardware (containers, CI). It still runs the callback, so the ring and
// the hot loop are exercised; it just delivers silence. cap_is_null() lets the
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

// 32768 frames at 48 kHz is 0.68 s of slack. The ring is static: it is part
// of the library image, so the callback never asks an allocator for space.
#define CAP_RING 32768

static float g_ring[CAP_RING];
static atomic_ullong g_written;
static atomic_ullong g_read;
static atomic_ullong g_overflow;

static ma_context g_ctx;
static ma_device g_dev;
static int g_ctx_ok;
static int g_open;
static int g_is_null;
static char g_name[256];
static char g_err[256];
static unsigned long long g_overflow_seen;

void cap_close(void);

static void capture_cb(ma_device *dev, void *out, const void *in, ma_uint32 frames) {
    (void)out;
    const float *src = (const float *)in;
    const ma_uint32 channels = dev->capture.channels;
    unsigned long long w = atomic_load_explicit(&g_written, memory_order_relaxed);
    unsigned long long r = atomic_load_explicit(&g_read, memory_order_acquire);

    if (w - r > CAP_RING - frames) {
        // The consumer is behind by more than the ring. Overwrite the oldest
        // frames and count it; the visualizer is allowed to skip stale audio.
        g_overflow_seen++;
        atomic_store_explicit(&g_overflow, g_overflow_seen, memory_order_relaxed);
    }

    if (channels == 1) {
        for (ma_uint32 i = 0; i < frames; i++) {
            g_ring[(w + i) % CAP_RING] = src[i];
        }
    } else {
        // Requested mono; this is the safety net if a backend ignores it.
        for (ma_uint32 i = 0; i < frames; i++) {
            float s = 0.0f;
            for (ma_uint32 c = 0; c < channels; c++) s += src[i * channels + c];
            g_ring[(w + i) % CAP_RING] = s / (float)channels;
        }
    }
    atomic_store_explicit(&g_written, w + frames, memory_order_release);
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
// `name`. Returns 0 on success, 1 when a device cannot be opened, 2 when it
// opens but will not start. cap_error() has the reason.
int cap_open(gs_u8_slice name, int32_t rate, int32_t period) {
    if (g_open) cap_close();
    g_name[0] = 0;
    g_err[0] = 0;
    g_is_null = 0;
    if (!ensure_context()) return 1;

    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = 1;
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

    g_is_null = strcmp(ma_get_backend_name(g_dev.pContext->backend), "Null") == 0;
    if (g_name[0] == 0) {
        ma_device_get_name(&g_dev, ma_device_type_capture, g_name, sizeof(g_name), NULL);
    }

    // Reset the ring before the callback can produce into it.
    atomic_store(&g_written, 0);
    atomic_store(&g_read, 0);
    atomic_store(&g_overflow, 0);
    g_overflow_seen = 0;

    res = ma_device_start(&g_dev);
    if (res != MA_SUCCESS) {
        snprintf(g_err, sizeof(g_err), "device start: %s", ma_result_description(res));
        ma_device_uninit(&g_dev);
        return 2;
    }

    g_open = 1;
    return 0;
}

// Copies at most dst.len frames from the ring into dst. Non-blocking: zero
// means no audio has arrived since the last call.
int64_t cap_read(gs_f32_slice dst) {
    if (!g_open || dst.len <= 0) return 0;
    unsigned long long w = atomic_load_explicit(&g_written, memory_order_acquire);
    unsigned long long r = atomic_load_explicit(&g_read, memory_order_relaxed);
    if (w < r) r = w;
    // If the reader fell more than one ring behind, skip the overwritten
    // frames and return the newest window instead of stale bytes.
    if (w - r > CAP_RING) r = w - CAP_RING;
    unsigned long long avail = w - r;
    if (avail > (unsigned long long)dst.len) avail = (unsigned long long)dst.len;
    if (avail == 0) return 0;

    size_t start = (size_t)(r % CAP_RING);
    size_t first = CAP_RING - start;
    if (first > avail) first = (size_t)avail;
    memcpy(dst.data, g_ring + start, first * sizeof(float));
    if (avail > first) {
        memcpy(dst.data + first, g_ring, (size_t)(avail - first) * sizeof(float));
    }
    atomic_store_explicit(&g_read, r + avail, memory_order_release);
    return (int64_t)avail;
}

int64_t cap_overflow(void) { return (int64_t)atomic_load(&g_overflow); }
int64_t cap_ring_frames(void) { return CAP_RING; }
int32_t cap_is_null(void) { return g_is_null ? 1 : 0; }
uint64_t cap_backend(void) { return g_open ? (uint64_t)(uintptr_t)ma_get_backend_name(g_dev.pContext->backend) : 0; }
uint64_t cap_name(void) { return (uint64_t)(uintptr_t)g_name; }
uint64_t cap_error(void) { return (uint64_t)(uintptr_t)g_err; }

void cap_close(void) {
    if (!g_open) return;
    ma_device_uninit(&g_dev);
    g_open = 0;
    g_is_null = 0;
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
