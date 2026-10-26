// host.c -- terminal and screenshot plumbing for visualizer.goose.
//
// The visualizer renders into an RGB framebuffer in Goose. This sidecar puts
// the terminal into raw mode on the alternate screen, reports its size, reads
// keys without blocking, and writes the same framebuffer as a PNG. None of it
// is on the per-frame audio path except the size/key queries, which are ioctls
// and a non-blocking read.

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } gs_u8_slice;

static struct termios g_saved;
static int g_raw;
static int g_alt;
static volatile sig_atomic_t g_interrupted;

static void term_restore(void) {
    if (g_raw) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_saved);
        g_raw = 0;
    }
}

static void term_leave_now(void) {
    if (g_alt) {
        static const char seq[] = "\x1b[0m\x1b[?25h\x1b[?1049l";
        ssize_t n = write(STDOUT_FILENO, seq, sizeof(seq) - 1);
        (void)n;
        g_alt = 0;
    }
    term_restore();
}

static void term_atexit(void) { term_leave_now(); }

static void on_signal(int sig) {
    (void)sig;
    g_interrupted = 1;
}

int32_t term_install_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    atexit(term_atexit);
    return 0;
}

int32_t term_isatty(void) {
    return (isatty(STDIN_FILENO) && isatty(STDOUT_FILENO)) ? 1 : 0;
}

int32_t term_cols(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) return (int32_t)ws.ws_col;
    return 80;
}

int32_t term_rows(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0) return (int32_t)ws.ws_row;
    return 24;
}

// Enters the alternate screen, hides the cursor and switches stdin to raw,
// non-blocking mode. term_leave restores all of it; atexit and the signal
// handler restore it if the program exits another way.
int32_t term_enter(void) {
    if (g_alt) return 0;
    if (!term_isatty()) return 1;
    if (tcgetattr(STDIN_FILENO, &g_saved) != 0) return 1;
    struct termios t = g_saved;
    t.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    t.c_oflag &= ~OPOST;
    t.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    t.c_cflag &= ~(CSIZE | PARENB);
    t.c_cflag |= CS8;
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) != 0) return 1;
    g_raw = 1;
    static const char enter[] = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";
    ssize_t n = write(STDOUT_FILENO, enter, sizeof(enter) - 1);
    (void)n;
    g_alt = 1;
    g_interrupted = 0;
    return 0;
}

int32_t term_leave(void) {
    term_leave_now();
    return 0;
}

// The next byte typed, or -1. Raw mode has VMIN=0, so this never waits.
int32_t term_key(void) {
    unsigned char c;
    ssize_t n = read(STDIN_FILENO, &c, 1);
    if (n == 1) return (int32_t)c;
    return -1;
}

int32_t term_interrupted(void) { return g_interrupted ? 1 : 0; }

// Writes an RGB framebuffer (w*h*3 bytes) as a PNG. Returns 1 on success.
int32_t host_write_png(gs_u8_slice path, int32_t w, int32_t h, gs_u8_slice rgb) {
    char name[4096];
    if (path.len <= 0 || path.len >= (int64_t)sizeof(name) || w <= 0 || h <= 0) return 0;
    if (rgb.len < (int64_t)w * (int64_t)h * 3) return 0;
    memcpy(name, path.data, (size_t)path.len);
    name[path.len] = 0;
    return stbi_write_png(name, w, h, 3, rgb.data, w * 3) ? 1 : 0;
}
