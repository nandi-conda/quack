// visualizer.goose -- a realtime stem-aware audio visualizer.
//
//   pixi run viz                 live capture, ANSI truecolor in the terminal
//   pixi run run-viz-native      the same, as a native executable
//   pixi run screenshot          offscreen render, writes screenshots/visualizer.png
//   pixi run viz-bench           headless hot-loop benchmark
//
// Capture lives in src/capture.c (a C sidecar): miniaudio opens the default
// device and its callback writes into a fixed single-producer/single-consumer
// ring. Everything after that is Goose: a Hann window, an in-place radix-2
// FFT, four perceptual stem lanes, a waveform, and a stem-tinted spectrogram,
// all drawn into a software RGB framebuffer that is either converted to ANSI
// half-blocks for the terminal or written as a PNG.
//
// Stems: SUB is 30-180 Hz; DRUM is high-band spectral flux with a transient
// envelope and high-frequency ratio; SYNTH is prominent harmonic peaks in the
// mid/high range; OTHER is the broadband residual. Tuning knobs are the Hz
// edges at the top of this file, the 1.6x peak-prominence test, the flux
// threshold/adaptive baseline in analyze(), and the attack/release taus in
// main().
//
// The hot loop allocates nothing:
//   * every buffer below is a fixed-size or fixed-capacity array in main or a
//     data-stack-scoped value passed down by slice;
//   * the FFT runs in place on re/im, its tables are built once at startup;
//   * band levels, stem envelopes, peak holds and the framebuffer are
//     preallocated;
//   * the spectrogram history is a `reusable` pool with a hard HIST bound:
//     its slots are allocated once at startup, and a full ring frees the
//     oldest before allocating the new one, so its length never grows.
// There is no allocator anywhere in Goose, and the C capture callback is a
// fixed-ring write with no malloc, lock or wait.

import std;
import math;
import os;
import ffi;

// ---- C sidecar (src/capture.c, src/host.c) --------------------------------
extern fn cap_open(name: const u8[:], rate: i32, period: i32) -> i32;
extern fn cap_read(dst: f32[:]) -> i64;
extern fn cap_overflow() -> i64;
extern fn cap_is_null() -> i32;
extern fn cap_backend() -> u64;
extern fn cap_name() -> u64;
extern fn cap_error() -> u64;
extern fn cap_list() -> i32;
extern fn cap_close();

extern fn term_install_signals() -> i32;
extern fn term_isatty() -> i32;
extern fn term_enter() -> i32;
extern fn term_leave() -> i32;
extern fn term_cols() -> i32;
extern fn term_rows() -> i32;
extern fn term_key() -> i32;
extern fn term_interrupted() -> i32;

extern fn host_write_png(path: const u8[:], w: i32, h: i32, rgb: const u8[:]) -> i32;

// ---- shape of the demo ----------------------------------------------------
const SR = 48000;             // capture rate, frames per second
const WIN = 2048;             // FFT window, 42.7 ms; 23.4 Hz per bin
const BANDS = 64;             // log-spaced spectrum/spectrogram bands
const STEMS = 4;              // sub, drums, synth, other
const HIST = 96;              // history columns kept in the reusable pool
const MAX_W = 960;            // offscreen render bound
const MAX_H = 540;
const FB_MAX = MAX_W * MAX_H * 3;
const FRAME_MAX = 1024 * 1024; // worst-case ANSI frame at the maximum size
const MAX_COLS = 200;
const MAX_ROWS = 60;
const READ_MAX = 4096;        // captures drained per frame

const STEM_SUB = 0;
const STEM_DRUM = 1;
const STEM_SYNTH = 2;
const STEM_OTHER = 3;

// Stem band edges, in Hz. These are the main tuning knobs: move the split
// between sub and mid here, and the flux range decides what counts as a
// percussive high-frequency attack.
const SUB_HZ_LO = 30.0;
const SUB_HZ_HI = 180.0;
const MID_HZ_HI = 2000.0;
const HIGH_HZ_HI = 16000.0;
const FLUX_HZ_LO = 1500.0;
const TONAL_HZ_HI = 8000.0;

// stem_edges indices (FFT bins, filled once by build_tables).
const SE_SUB_LO = 0;
const SE_SUB_HI = 1;
const SE_MID_HI = 2;
const SE_HIGH_HI = 3;
const SE_FLUX_LO = 4;
const SE_FLUX_HI = 5;
const SE_TONAL_HI = 6;
const SE_COUNT = 7;

// 5x7 pixel font for the lane labels. Only the letters the labels use are
// defined; everything else renders blank.
const FONT_W = 5;
const FONT_H = 7;
const FONT_BYTES = 128 * FONT_W;

// One frame in the bounded history pool: the spectrum for the waterfall and
// the stem levels for the lane sparklines and stem-tinted waterfall.
struct Snap {
    levels: f32[BANDS],
    stems: f32[STEMS],
}

reusable var history: Snap[>..] = [];

// Synthetic source state, used when there is no capture device.
var synth_rng: u32 = 0x9E3779B9;

// The first frame has no previous magnitudes, so it must not report a huge
// flux onset. flux_avg adapts to the steady flux floor so note changes and
// noise do not fire the percussion blinker.
var flux_ready: bool = false;
var flux_seen: bool = false;
var flux_avg: f32 = 0.0;

// ---- small helpers --------------------------------------------------------
fn bit_reverse(i: i64, bits: i64) -> i64 {
    var x = i;
    var r = 0;
    for k in bits {
        r = (r << 1) | (x & 1);
        x >>= 1;
    }
    return r;
}

fn lerp8(a: i64, b: i64, t: f32) -> u8 {
    return (a + (b - a) * t) as u8;
}

// A compact heat ramp: deep blue, cyan, green, yellow, red.
fn heat(t: f32) -> u8, u8, u8 {
    let x = clamp(t, 0.0, 1.0);
    if x < 0.18 {
        let k = x / 0.18;
        return lerp8(2, 0, k), lerp8(6, 40, k), lerp8(20, 130, k);
    } else if x < 0.40 {
        let k = (x - 0.18) / 0.22;
        return 0, lerp8(40, 180, k), lerp8(130, 220, k);
    } else if x < 0.60 {
        let k = (x - 0.40) / 0.20;
        return 0, lerp8(180, 255, k), lerp8(220, 120, k);
    } else if x < 0.80 {
        let k = (x - 0.60) / 0.20;
        return lerp8(0, 255, k), lerp8(255, 210, k), lerp8(120, 35, k);
    }
    let k = (x - 0.80) / 0.20;
    return 255, lerp8(210, 55, k), lerp8(35, 25, k);
}

fn px(fb: u8[:], w: i64, h: i64, x: i64, y: i64, r: u8, g: u8, b: u8) {
    if x < 0 || y < 0 || x >= w || y >= h { return; }
    let i = (y * w + x) * 3;
    fb[i] = r;
    fb[i + 1] = g;
    fb[i + 2] = b;
}

fn hline(fb: u8[:], w: i64, h: i64, y: i64, r: u8, g: u8, b: u8) {
    if y < 0 || y >= h { return; }
    var i = y * w * 3;
    for x in w {
        fb[i] = r;
        fb[i + 1] = g;
        fb[i + 2] = b;
        i += 3;
    }
}

fn fill_rect(fb: u8[:], w: i64, h: i64, x0: i64, y0: i64, x1: i64, y1: i64,
             r: u8, g: u8, b: u8) {
    var ax = x0;
    var ay = y0;
    var bx = x1;
    var by = y1;
    if ax < 0 { ax = 0; }
    if ay < 0 { ay = 0; }
    if bx >= w { bx = w - 1; }
    if by >= h { by = h - 1; }
    if ax > bx || ay > by { return; }
    for y in ay..by + 1 {
        var i = (y * w + ax) * 3;
        for x in ax..bx + 1 {
            fb[i] = r;
            fb[i + 1] = g;
            fb[i + 2] = b;
            i += 3;
        }
    }
}

fn clamp01(x: f32) -> f32 {
    if x < 0.0 { return 0.0; }
    if x > 1.0 { return 1.0; }
    return x;
}

// Frame-rate independent one-pole coefficient: 1 - exp(-dt/tau).
fn coef(dt: f64, tau: f64) -> f32 {
    return (1.0 - exp(-dt / tau)) as f32;
}

// Energy -> 0..1 with a 60 dB window. ref is the magnitude of a full-scale
// sine after the Hann window (N/4).
fn db_level(x: f32, ref: f32) -> f32 {
    let db = 20.0 * log10(x / ref + 0.000001);
    return clamp01((db + 60.0) / 60.0);
}

fn stem_label(s: i64, short: bool) -> const u8[:] {
    if s == STEM_SUB { return "SUB"; }
    if s == STEM_DRUM { if short { return "DRM"; } return "DRUM"; }
    if s == STEM_SYNTH { if short { return "SYN"; } return "SYNTH"; }
    if short { return "OTH"; }
    return "OTHER";
}

// Lane colours: sub blue, drums amber, synth cyan/green, other violet.
fn stem_color(s: i64) -> u8, u8, u8 {
    if s == STEM_SUB { return 80, 140, 255; }
    if s == STEM_DRUM { return 255, 150, 60; }
    if s == STEM_SYNTH { return 60, 235, 190; }
    return 190, 110, 255;
}

fn set_glyph(font: u8[:], ch: u8, c0: u8, c1: u8, c2: u8, c3: u8, c4: u8) {
    let base = (ch as i64) * FONT_W;
    font[base] = c0;
    font[base + 1] = c1;
    font[base + 2] = c2;
    font[base + 3] = c3;
    font[base + 4] = c4;
}

// 5x7 column-major glyphs, bit 0 = top row. Only the label letters are set.
fn setup_font(font: u8[:]) {
    set_glyph(font, 'S', 0x46, 0x49, 0x49, 0x49, 0x31);
    set_glyph(font, 'U', 0x3F, 0x40, 0x40, 0x40, 0x3F);
    set_glyph(font, 'B', 0x7F, 0x49, 0x49, 0x49, 0x36);
    set_glyph(font, 'D', 0x7F, 0x41, 0x41, 0x41, 0x3E);
    set_glyph(font, 'R', 0x7F, 0x09, 0x19, 0x29, 0x46);
    set_glyph(font, 'M', 0x7F, 0x02, 0x0E, 0x02, 0x7F);
    set_glyph(font, 'Y', 0x03, 0x04, 0x78, 0x04, 0x03);
    set_glyph(font, 'N', 0x7F, 0x02, 0x04, 0x08, 0x7F);
    set_glyph(font, 'T', 0x01, 0x01, 0x7F, 0x01, 0x01);
    set_glyph(font, 'H', 0x7F, 0x08, 0x08, 0x08, 0x7F);
    set_glyph(font, 'E', 0x7F, 0x49, 0x49, 0x49, 0x41);
    set_glyph(font, 'O', 0x3E, 0x41, 0x41, 0x41, 0x3E);
}

fn draw_text(fb: u8[:], w: i64, h: i64, x0: i64, y0: i64,
             text: const u8[:], font: u8[:], r: u8, g: u8, b: u8, scale: i64) {
    var x = x0;
    for ci in text.len {
        let ch = text[ci] as i64;
        if ch < 128 {
            let base = ch * FONT_W;
            for col in FONT_W {
                let bits = font[base + col] as i64;
                for row in FONT_H {
                    if ((bits >> row) & 1) != 0 {
                        let px0 = x + col * scale;
                        let py0 = y0 + row * scale;
                        fill_rect(fb, w, h, px0, py0,
                                  px0 + scale - 1, py0 + scale - 1, r, g, b);
                    }
                }
            }
        }
        x += (FONT_W + 1) * scale;
    }
}

// ---- DSP ------------------------------------------------------------------
fn build_tables(window: f32[:], cos_t: f32[:], sin_t: f32[:], bitrev: i64[:],
                band_lo: i64[:], band_hi: i64[:], stem_edges: i64[:]) {
    let n = window.len;
    for i in n {
        let a = TAU * i / (n - 1);
        window[i] = (0.5 - 0.5 * cos(a)) as f32;
    }
    for k in n / 2 {
        let a = -TAU * k / n;
        cos_t[k] = cos(a) as f32;
        sin_t[k] = sin(a) as f32;
    }
    var bits = 0;
    var x = n;
    while x > 1 {
        bits += 1;
        x >>= 1;
    }
    for i in n { bitrev[i] = bit_reverse(i, bits); }

    // 40 Hz .. 16 kHz, logarithmically spaced: about ten bands per decade.
    let bin_hz = SR as f64 / n;
    let fmin = 40.0;
    let fmax = 16000.0;
    for b in BANDS {
        let f0 = fmin * pow(fmax / fmin, b as f64 / BANDS);
        let f1 = fmin * pow(fmax / fmin, (b + 1) as f64 / BANDS);
        var lo = (f0 / bin_hz) as i64;
        var hi = (f1 / bin_hz) as i64;
        if lo < 1 { lo = 1; }
        if hi <= lo { hi = lo + 1; }
        if hi > n / 2 { hi = n / 2; }
        band_lo[b] = lo;
        band_hi[b] = hi;
    }

    // Stem split, in bins. Keep the edges ordered and inside the usable
    // positive-frequency range.
    var slo = (SUB_HZ_LO / bin_hz) as i64;
    var shi = (SUB_HZ_HI / bin_hz) as i64;
    var mhi = (MID_HZ_HI / bin_hz) as i64;
    var hhi = (HIGH_HZ_HI / bin_hz) as i64;
    var flo = (FLUX_HZ_LO / bin_hz) as i64;
    var thi = (TONAL_HZ_HI / bin_hz) as i64;
    if slo < 1 { slo = 1; }
    if shi <= slo { shi = slo + 1; }
    if mhi <= shi { mhi = shi + 1; }
    if hhi <= mhi { hhi = mhi + 1; }
    if hhi > n / 2 { hhi = n / 2; }
    if flo <= shi { flo = shi + 1; }
    if flo >= hhi { flo = hhi - 1; }
    if thi <= shi { thi = shi + 1; }
    if thi >= hhi { thi = hhi - 1; }
    stem_edges[SE_SUB_LO] = slo;
    stem_edges[SE_SUB_HI] = shi;
    stem_edges[SE_MID_HI] = mhi;
    stem_edges[SE_HIGH_HI] = hhi;
    stem_edges[SE_FLUX_LO] = flo;
    stem_edges[SE_FLUX_HI] = hhi;
    stem_edges[SE_TONAL_HI] = thi;
}

// In-place iterative radix-2 Cooley-Tukey FFT. cos_t/sin_t hold the negative
// twiddles for k in 0..n/2, so a forward transform reads them directly.
fn fft(re: f32[:], im: f32[:], cos_t: f32[:], sin_t: f32[:], bitrev: i64[:]) {
    let n = re.len;
    for i in n {
        let j = bitrev[i];
        if i < j {
            let tr = re[i]; re[i] = re[j]; re[j] = tr;
            let ti = im[i]; im[i] = im[j]; im[j] = ti;
        }
    }
    var size = 2;
    while size <= n {
        let half = size / 2;
        let step = n / size;
        var base = 0;
        while base < n {
            for k in half {
                let tw = k * step;
                let wr = cos_t[tw];
                let wi = sin_t[tw];
                let a = base + k;
                let b = a + half;
                let br = re[b];
                let bi = im[b];
                let tr = br * wr - bi * wi;
                let ti = br * wi + bi * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
            base += size;
        }
        size *= 2;
    }
}

// Fills the window, runs the FFT, updates the spectrogram bands and fills the
// four stem targets. Returns (rms, peak amplitude, onset strength).
fn analyze(samples: f32[:], shead: i64,
           window: f32[:], re: f32[:], im: f32[:],
           cos_t: f32[:], sin_t: f32[:], bitrev: i64[:],
           band_lo: i64[:], band_hi: i64[:],
           levels: f32[:], mag: f32[:], prev_mag: f32[:],
           stem_edges: i64[:], stem_target: f32[:],
           band_att: f32, band_rel: f32, flux_avg_coef: f32) -> f32, f32, f32 {
    let n = samples.len;
    var rms: f32 = 0.0;
    var peak: f32 = 0.0;
    for i in n {
        let s = samples[(shead + i) % n];
        let a = abs(s);
        if a > peak { peak = a; }
        rms += s * s;
        re[i] = s * window[i];
        im[i] = 0.0;
    }
    rms = sqrt(rms / n);

    fft(re, im, cos_t, sin_t, bitrev);

    // One magnitude array feeds the bands, the stem energies and the flux.
    let ref = n as f32 / 4.0;   // full-scale sine after a Hann window
    for k in 1..n / 2 {
        mag[k] = sqrt(re[k] * re[k] + im[k] * im[k]);
    }

    for b in BANDS {
        var mx: f32 = 0.0;
        for k in band_lo[b]..band_hi[b] {
            if mag[k] > mx { mx = mag[k]; }
        }
        // A gentle tilt lifts the high bands, which fall off in most music.
        let tilt = b as f32 * 0.32;
        let db = 20.0 * log10(mx / ref + 0.000001) + tilt;
        let target = clamp01((db + 70.0) / 70.0);
        let c = if target > levels[b] { band_att } else { band_rel };
        levels[b] += (target - levels[b]) * c;
    }

    // --- stem energies -----------------------------------------------------
    var e_sub: f32 = 0.0;
    for k in stem_edges[SE_SUB_LO]..stem_edges[SE_SUB_HI] { e_sub += mag[k]; }
    var e_mid: f32 = 0.0;
    for k in stem_edges[SE_SUB_HI]..stem_edges[SE_MID_HI] { e_mid += mag[k]; }
    var e_high: f32 = 0.0;
    for k in stem_edges[SE_MID_HI]..stem_edges[SE_HIGH_HI] { e_high += mag[k]; }
    let e_midhigh = e_mid + e_high;

    // Tonal energy: prominent local maxima, not every noise ripple. A
    // 1.6x neighbour ratio is the harmonic/percussive split knob.
    var e_peak: f32 = 0.0;
    for k in stem_edges[SE_SUB_HI] + 1..stem_edges[SE_TONAL_HI] {
        let m = mag[k];
        if m > ref * 0.02 && m > mag[k - 1] * 1.6 && m > mag[k + 1] * 1.6 {
            e_peak += m;
        }
    }

    // Spectral flux over the high range: positive frame-to-frame changes.
    var flux: f32 = 0.0;
    if flux_ready {
        for k in stem_edges[SE_FLUX_LO]..stem_edges[SE_FLUX_HI] {
            let d = mag[k] - prev_mag[k];
            if d > 0.0 { flux += d; }
        }
    }
    for k in stem_edges[SE_FLUX_LO]..stem_edges[SE_FLUX_HI] {
        prev_mag[k] = mag[k];
    }
    flux_ready = true;

    let hf_ratio = e_high / (e_midhigh + 0.000001);

    // Adaptive onset: subtract the slowly adapting flux floor, so a steady
    // tonal shimmer or noise bed does not register as a drum hit.
    let flux_norm = flux / ref;
    var onset: f32 = 0.0;
    if flux_ready {
        if !flux_seen {
            flux_avg = flux_norm;
            flux_seen = true;
        } else {
            let novelty = flux_norm - flux_avg * 1.4;
            onset = clamp01((novelty - 0.03) / 0.45);
            flux_avg += (flux_norm - flux_avg) * flux_avg_coef;
        }
    }
    var other_e = e_midhigh - e_peak * 0.9 - flux * 0.25;
    if other_e < 0.0 { other_e = 0.0; }

    stem_target[STEM_SUB] = db_level(e_sub, ref * 4.0);
    stem_target[STEM_DRUM] = clamp01(onset * (0.45 + 0.55 * hf_ratio) + hf_ratio * 0.10);
    stem_target[STEM_SYNTH] = db_level(e_peak, ref * 2.0);
    stem_target[STEM_OTHER] = db_level(other_e, ref * 64.0);
    return rms, peak, onset;
}

// ---- synthetic source -----------------------------------------------------
fn synth_rand() -> f32 {
    synth_rng ^= synth_rng << 13;
    synth_rng ^= synth_rng >> 17;
    synth_rng ^= synth_rng << 5;
    return (synth_rng / 4294967295.0 * 2.0 - 1.0) as f32;
}

// A four-bar riff with a kick, a bass, a detuned lead and a slow sweep. It is
// deterministic, so a screenshot at the same frame is reproducible.
fn synth_sample(t: f64) -> f32 {
    let beat = t % 0.5;
    let kick = exp(-beat * 9.0);
    let bar = ((t / 2.0) as i64) % 4;
    var root = 110.0;
    if bar == 1 { root = 98.0; }
    else if bar == 2 { root = 130.81; }
    else if bar == 3 { root = 87.31; }
    let lead = sin(TAU * root * t) * 0.28
             + sin(TAU * root * 2.0 * t + 0.3) * 0.18
             + sin(TAU * root * 3.0 * t + 0.7) * 0.10
             + sin(TAU * root * 4.0 * t) * 0.07
             + sin(TAU * root * 6.0 * t + 1.3) * 0.04;
    let bass = sin(TAU * root * 0.5 * t) * 0.40 * (0.35 + 0.65 * kick);
    let sweep_f = 2400.0 + 2100.0 * sin(TAU * t / 8.0);
    let sweep = sin(TAU * sweep_f * t) * 0.10;
    let shimmer = (sin(TAU * 3400.0 * t) * 0.035
                 + sin(TAU * 5600.0 * t + 1.1) * 0.025
                 + sin(TAU * 9100.0 * t + 2.0) * 0.015)
                * (0.5 + 0.5 * sin(TAU * t / 3.0));
    let hat_beat = t % 0.25;
    let hat = if hat_beat < 0.05 {
        synth_rand() as f64 * 0.12 * exp(-hat_beat * 40.0)
    } else { 0.0 };
    let click = if beat < 0.03 { 0.35 * (1.0 - beat / 0.03) } else { 0.0 };
    let noise = synth_rand() as f64 * 0.010;
    var s = (lead + bass + sweep + shimmer + hat + click + noise) as f32;
    if s > 1.0 { s = 1.0; }
    else if s < -1.0 { s = -1.0; }
    return s;
}

// ---- framebuffer drawing --------------------------------------------------
fn fill_bg(fb: u8[:], w: i64, h: i64, lanes_h: i64, wave_y1: i64, spec_y0: i64) {
    for y in h {
        var r: i64 = 4;
        var g: i64 = 7;
        var b: i64 = 18;
        if y < lanes_h {
            let t = y as f32 / lanes_h;
            r = 4 + (t * 7.0) as i64;
            g = 7 + (t * 9.0) as i64;
            b = 18 + (t * 18.0) as i64;
        } else if y < wave_y1 {
            r = 5; g = 9; b = 20;
        } else if y >= spec_y0 {
            let denom = max(1, h - spec_y0) as f32;
            let t = (y - spec_y0) / denom;
            r = 3 + (t * 4.0) as i64;
            g = 5 + (t * 7.0) as i64;
            b = 13 + (t * 12.0) as i64;
        }
        let rr = r as u8;
        let gg = g as u8;
        let bb = b as u8;
        var i = y * w * 3;
        for x in w {
            fb[i] = rr;
            fb[i + 1] = gg;
            fb[i + 2] = bb;
            i += 3;
        }
    }
    hline(fb, w, h, spec_y0 - 1, 24, 38, 68);
}

// Four labelled stem lanes. Each lane has a current-level meter, a peak-hold
// marker, and a sparkline of its own level over the history pool. The drum
// lane also shows a small hit blinker.
fn draw_stem_lanes(fb: u8[:], w: i64, h: i64, lane_h: i64,
                   stem_level: f32[:], stem_peak: f32[:],
                   slots: i64[:], head: i64, count: i64,
                   hit_flash: f32, font: u8[:]) {
    let short = w < 64;
    for s in STEMS {
        let y0 = s * lane_h;
        if y0 >= h { return; }
        var y1 = y0 + lane_h - 1;
        if y1 >= h { y1 = h - 1; }
        let cr, cg, cb = stem_color(s);

        fill_rect(fb, w, h, 0, y0, w - 1, y1, cr / 9, cg / 9, cb / 9);
        fill_rect(fb, w, h, 0, y0, 1, y1, cr / 2, cg / 2, cb / 2);
        if s + 1 < STEMS && y1 + 1 < h { hline(fb, w, h, y1, 26, 32, 44); }

        let label = stem_label(s, short);
        var fscale = lane_h / 20;
        if fscale < 1 { fscale = 1; }
        if fscale > 3 { fscale = 3; }
        if lane_h >= FONT_H * fscale {
            let ly = y0 + (lane_h - FONT_H * fscale) / 2;
            draw_text(fb, w, h, 4, ly, label, font, cr, cg, cb, fscale);
        }

        let label_w = label.len * (FONT_W + 1) * fscale - fscale;
        var mx0 = 4 + label_w + 4;
        let meter_w = max(8, w / 8);
        var mx1 = mx0 + meter_w - 1;
        if mx1 > w - 4 { mx1 = w - 4; }
        var sx0 = mx1 + 4;
        var sx1 = w - 4;
        if sx0 > sx1 { sx0 = sx1; }

        var bar_h = lane_h * 45 / 100;
        if bar_h < 4 { bar_h = 4; }
        if bar_h > lane_h - 3 { bar_h = lane_h - 3; }
        if bar_h < 1 { bar_h = 1; }
        var my0 = y0 + (lane_h - bar_h) / 2;
        var my1 = my0 + bar_h - 1;
        if my1 > y1 { my1 = y1; }

        if mx1 >= mx0 {
            fill_rect(fb, w, h, mx0, my0, mx1, my1, 14, 19, 29);
            let fill_w = ((mx1 - mx0 + 1) * stem_level[s]) as i64;
            var x = mx0;
            while x < mx0 + fill_w && x <= mx1 {
                let t = (x - mx0) as f32 / max(1, mx1 - mx0);
                let rr = (cr * (0.35 + 0.65 * t)) as u8;
                let gg = (cg * (0.35 + 0.65 * t)) as u8;
                let bb = (cb * (0.35 + 0.65 * t)) as u8;
                fill_rect(fb, w, h, x, my0, x, my1, rr, gg, bb);
                x += 1;
            }
            let px_x = mx0 + ((mx1 - mx0) * stem_peak[s]) as i64;
            if px_x >= mx0 && px_x <= mx1 {
                var py0 = my0 - 1;
                var py1 = my1 + 1;
                if py0 < y0 { py0 = y0; }
                if py1 > y1 { py1 = y1; }
                fill_rect(fb, w, h, px_x, py0, px_x, py1, 255, 235, 190);
            }
        }

        // Sparkline: time on x, this stem's level on y, max over each pixel
        // so a one-frame transient survives downsampling.
        if count > 0 && sx1 > sx0 {
            let sy0 = y0 + 1;
            let sy1 = y1 - 1;
            if sy1 > sy0 {
                fill_rect(fb, w, h, sx0, sy0, sx1, sy1, 8, 12, 20);
                let span = sx1 - sx0;
                for x in sx0..sx1 + 1 {
                    var k0 = ((x - sx0) * count) / (span + 1);
                    var k1 = (((x - sx0) + 1) * count) / (span + 1);
                    if k1 <= k0 { k1 = k0 + 1; }
                    if k0 >= count { k0 = count - 1; }
                    if k1 > count { k1 = count; }
                    var v: f32 = 0.0;
                    for k in k0..k1 {
                        let slot = slots[(head + k) % HIST];
                        let sv = history[slot].stems[s];
                        if sv > v { v = sv; }
                    }
                    if v > 0.01 {
                        let hh = (v * (sy1 - sy0)) as i64;
                        let yy0 = sy1 - hh;
                        // A dim area plus a bright envelope line: readable
                        // without turning a sustained level into a solid block.
                        let rr = (cr * (0.06 + 0.18 * v)) as u8;
                        let gg = (cg * (0.06 + 0.18 * v)) as u8;
                        let bb = (cb * (0.06 + 0.18 * v)) as u8;
                        fill_rect(fb, w, h, x, yy0, x, sy1, rr, gg, bb);
                        fill_rect(fb, w, h, x, yy0, x, yy0, cr, cg, cb);
                    }
                }
            }
        }

        if s == STEM_DRUM && hit_flash > 0.03 && lane_h >= 5 {
            var bs = lane_h / 8;
            if bs < 5 { bs = 5; }
            if bs > 10 { bs = 10; }
            if bs > lane_h - 2 { bs = lane_h - 2; }
            let bx = w - bs - 4;
            let by = y0 + (lane_h - bs) / 2;
            let rr = (140.0 + 115.0 * hit_flash) as u8;
            let gg = (55.0 + 170.0 * hit_flash) as u8;
            let bb = (15.0 + 210.0 * hit_flash) as u8;
            fill_rect(fb, w, h, bx - 1, by - 1, bx + bs, by + bs, 40, 26, 10);
            fill_rect(fb, w, h, bx, by, bx + bs - 1, by + bs - 1, rr, gg, bb);
        }
    }
}

fn draw_wave(fb: u8[:], w: i64, h: i64, y0: i64, y1: i64,
             samples: f32[:], shead: i64, gain: f32) {
    let hh = y1 - y0;
    if hh < 3 { return; }
    let mid = y0 + hh / 2;
    hline(fb, w, h, mid, 14, 50, 44);
    for x in w {
        let i0 = x * samples.len / w;
        var i1 = (x + 1) * samples.len / w;
        if i1 <= i0 { i1 = i0 + 1; }
        var mn: f32 = 0.0;
        var mx: f32 = 0.0;
        for k in i0..i1 {
            let s = samples[(shead + k) % samples.len] * gain;
            if s < mn { mn = s; }
            if s > mx { mx = s; }
        }
        let a = (hh / 2 - 1) as f32;
        var ya = mid - (mx * a) as i64;
        var yb = mid - (mn * a) as i64;
        if ya < y0 { ya = y0; }
        if yb > y1 - 1 { yb = y1 - 1; }
        let amp = max(abs(mx), abs(mn));
        let r, g, bl = heat(0.22 + amp * 0.62);
        var yy = ya;
        while yy <= yb {
            px(fb, w, h, x, yy, r, g, bl);
            yy += 1;
        }
    }
}

fn draw_spectro(fb: u8[:], w: i64, h: i64, y0: i64, spec_h: i64,
                sub_bands: i64, slots: i64[:], head: i64, count: i64) {
    if count <= 0 || spec_h <= 0 { return; }
    let sr, sg, sb = stem_color(STEM_SUB);
    let dr, dg, db = stem_color(STEM_DRUM);
    let yr, yg, yb = stem_color(STEM_SYNTH);
    let or_, og, ob = stem_color(STEM_OTHER);
    for k in count {
        let slot = slots[(head + k) % HIST];
        let x0 = k * w / count;
        var x1 = (k + 1) * w / count;
        if x1 <= x0 { x1 = x0 + 1; }
        if x1 > w { x1 = w; }

        // Mid/high bands take the colour of whichever stem is loudest in this
        // history frame; low bands stay sub-blue. Picking the dominant stem
        // keeps the waterfall readable instead of blending to grey.
        let wd = history[slot].stems[STEM_DRUM];
        let ws = history[slot].stems[STEM_SYNTH];
        let wo = history[slot].stems[STEM_OTHER];
        var mr: f32 = 35.0;
        var mg: f32 = 42.0;
        var mb: f32 = 58.0;
        if wd >= ws && wd >= wo && wd > 0.03 {
            mr = dr; mg = dg; mb = db;
        } else if ws >= wo && ws > 0.03 {
            mr = yr; mg = yg; mb = yb;
        } else if wo > 0.03 {
            mr = or_; mg = og; mb = ob;
        }

        for yy in spec_h {
            let b = ((spec_h - 1 - yy) * BANDS) / spec_h;
            let v = history[slot].levels[b];
            let dim = 0.10 + 0.90 * v;
            var rr = (mr * dim) as u8;
            var gg = (mg * dim) as u8;
            var bb = (mb * dim) as u8;
            if b < sub_bands {
                rr = (sr * dim) as u8;
                gg = (sg * dim) as u8;
                bb = (sb * dim) as u8;
            }
            var i = ((y0 + yy) * w + x0) * 3;
            for x in x0..x1 {
                fb[i] = rr;
                fb[i + 1] = gg;
                fb[i + 2] = bb;
                i += 3;
            }
        }
    }
}

fn draw_scene(fb: u8[:], w: i64, h: i64,
              stem_level: f32[:], stem_peak: f32[:],
              samples: f32[:], shead: i64,
              slots: i64[:], head: i64, count: i64,
              hit_flash: f32, sub_bands: i64, font: u8[:]) {
    var lane_h = (h * 56 / 100) / STEMS;
    if lane_h < 8 { lane_h = 8; }
    if lane_h * STEMS > h - 8 { lane_h = max(2, (h - 8) / STEMS); }
    let lanes_h = lane_h * STEMS;

    var wave_y1 = lanes_h + h * 9 / 100;
    if wave_y1 < lanes_h + 3 { wave_y1 = lanes_h + 3; }
    if wave_y1 > h - 2 { wave_y1 = h - 2; }
    if wave_y1 < lanes_h + 1 { wave_y1 = lanes_h + 1; }

    fill_bg(fb, w, h, lanes_h, wave_y1, wave_y1);
    draw_stem_lanes(fb, w, h, lane_h, stem_level, stem_peak,
                    slots, head, count, hit_flash, font);
    draw_wave(fb, w, h, lanes_h, wave_y1, samples, shead, 1.0);
    draw_spectro(fb, w, h, wave_y1, h - wave_y1, sub_bands, slots, head, count);
}

// ---- terminal output ------------------------------------------------------
fn render_terminal<B>(frame: B&, fb: u8[:], w: i64, h: i64,
                   cols: i64, rows: i64, head: u8[:], foot: u8[:]) {
    frame.resize(0);
    frame.append("\x1b[H");
    frame.append("\x1b[2m");
    frame.append(head);
    frame.append("\x1b[0m\x1b[K\r\n");

    let cell_rows = rows - 2;
    for cy in cell_rows {
        let ty = cy * 2;
        let by = ty + 1;
        for cx in cols {
            let ti = (ty * w + cx) * 3;
            let r0 = fb[ti];
            let g0 = fb[ti + 1];
            let b0 = fb[ti + 2];
            var r1: u8 = 0;
            var g1: u8 = 0;
            var b1: u8 = 0;
            if by < h {
                let bi = (by * w + cx) * 3;
                r1 = fb[bi];
                g1 = fb[bi + 1];
                b1 = fb[bi + 2];
            }
            format(frame, "\x1b[38;2;", r0, ";", g0, ";", b0,
                   "m\x1b[48;2;", r1, ";", g1, ";", b1, "m");
            frame.append("▀");
        }
        frame.append("\x1b[0m");
        if cy + 1 < cell_rows { frame.append("\r\n"); }
    }
    frame.append("\x1b[0m\x1b[K\r\n");
    frame.append("\x1b[2m");
    frame.append(foot);
    frame.append("\x1b[0m\x1b[K");
    write_stdout(frame);
}

fn usage() {
    print("Goose realtime audio visualizer");
    print("");
    print("  pixi run viz                 live capture in the terminal");
    print("  pixi run run-viz-native      same, native build");
    print("  pixi run screenshot          write screenshots/visualizer.png");
    print("  pixi run viz-bench           headless hot-loop benchmark");
    print("");
    print("options (after --):");
    print("  --synthetic       skip capture, use the built-in test signal");
    print("  --live            use capture even on the Null (silent) backend");
    print("  --device NAME     pick a capture device by name substring");
    print("  --list            list capture devices and exit");
    print("  --seconds S       stop after S seconds");
    print("  --frames N        stop after N rendered frames");
    print("  --fps N           target frame rate (default 30)");
    print("  --png PATH        offscreen render, write PATH as a PNG");
    print("  --width N         offscreen width (default 960)");
    print("  --height N        offscreen height (default 540)");
    print("  --bench           headless benchmark, no window or PNG");
    print("  --help            this text");
    print("");
    print("keys: q quit, s toggle synthetic/live, p pause, space clear peaks");
    print("lanes: SUB low, DRUM flux/HF transients, SYNTH harmonic peaks, OTHER residual");
}

fn clamp_i(x: i64, lo: i64, hi: i64) -> i64 {
    if x < lo { return lo; }
    if x > hi { return hi; }
    return x;
}

// ---- main -----------------------------------------------------------------
fn main() {
    term_install_signals();

    let av = args();
    var opt_synth = false;
    var opt_live = false;
    var opt_list = false;
    var opt_bench = false;
    var opt_help = false;
    var opt_seconds: f64 = 0.0;
    var opt_frames: i64 = 0;
    var opt_fps: i64 = 30;
    var opt_w: i64 = 960;
    var opt_h: i64 = 540;
    var png_path: const u8[:] = "";
    var dev_name: const u8[:] = "";

    var ai = 1;
    while ai < av.len {
        let a = av[ai];
        if a == "--synthetic" { opt_synth = true; }
        else if a == "--live" { opt_live = true; }
        else if a == "--list" { opt_list = true; }
        else if a == "--bench" { opt_bench = true; }
        else if a == "--help" || a == "-h" { opt_help = true; }
        else if a == "--device" {
            ai += 1;
            if ai < av.len { dev_name = av[ai]; }
        } else if a == "--seconds" {
            ai += 1;
            if ai < av.len {
                let v, ok = parse_flt(av[ai]);
                if ok { opt_seconds = v; }
            }
        } else if a == "--frames" {
            ai += 1;
            if ai < av.len {
                let v, ok = parse_int(av[ai]);
                if ok { opt_frames = v; }
            }
        } else if a == "--fps" {
            ai += 1;
            if ai < av.len {
                let v, ok = parse_int(av[ai]);
                if ok { opt_fps = clamp_i(v, 1, 240); }
            }
        } else if a == "--png" {
            ai += 1;
            if ai < av.len { png_path = av[ai]; }
        } else if a == "--width" {
            ai += 1;
            if ai < av.len {
                let v, ok = parse_int(av[ai]);
                if ok { opt_w = clamp_i(v, 160, MAX_W); }
            }
        } else if a == "--height" {
            ai += 1;
            if ai < av.len {
                let v, ok = parse_int(av[ai]);
                if ok { opt_h = clamp_i(v, 90, MAX_H); }
            }
        } else {
            print("unknown option: ", a);
            usage();
            return;
        }
        ai += 1;
    }

    if opt_help {
        usage();
        return;
    }
    if opt_list {
        cap_list();
        return;
    }

    // ---- startup tables, built once -------------------------------------
    var window: f32[WIN] = [0.0; WIN];
    var cos_t: f32[WIN / 2] = [0.0; WIN / 2];
    var sin_t: f32[WIN / 2] = [0.0; WIN / 2];
    var bitrev: i64[WIN] = [0; WIN];
    var band_lo: i64[BANDS] = [0; BANDS];
    var band_hi: i64[BANDS] = [0; BANDS];
    var stem_edges: i64[SE_COUNT] = [1; SE_COUNT];
    build_tables(window[..], cos_t[..], sin_t[..], bitrev[..],
                 band_lo[..], band_hi[..], stem_edges[..]);

    var samples: f32[WIN] = [0.0; WIN];
    var re: f32[WIN] = [0.0; WIN];
    var im: f32[WIN] = [0.0; WIN];
    var mag: f32[WIN / 2] = [0.0; WIN / 2];
    var prev_mag: f32[WIN / 2] = [0.0; WIN / 2];
    var levels: f32[BANDS] = [0.0; BANDS];
    var stem_target: f32[STEMS] = [0.0; STEMS];
    var stem_level: f32[STEMS] = [0.0; STEMS];
    var stem_peak: f32[STEMS] = [0.0; STEMS];
    var scratch: f32[..READ_MAX] = [0.0; READ_MAX];
    var slots: i64[HIST] = [-1; HIST];
    var hist_head: i64 = 0;
    var hist_count: i64 = 0;
    var font: u8[..FONT_BYTES] = [0; FONT_BYTES];
    setup_font(font[..]);

    var sub_bands: i64 = 0;
    while sub_bands < BANDS && band_lo[sub_bands] < stem_edges[SE_SUB_HI] {
        sub_bands += 1;
    }

    // Frame-rate independent smoothing. These taus are the main readability
    // knobs: attack is how fast a lane rises, release is how slowly it falls.
    let dt = 1.0 / opt_fps as f64;
    let band_att = coef(dt, 0.020);
    let band_rel = coef(dt, 0.250);
    var stem_att: f32[STEMS] = [0.0; STEMS];
    var stem_rel: f32[STEMS] = [0.0; STEMS];
    stem_att[STEM_SUB] = coef(dt, 0.020);
    stem_rel[STEM_SUB] = coef(dt, 0.300);
    stem_att[STEM_DRUM] = coef(dt, 0.006);
    stem_rel[STEM_DRUM] = coef(dt, 0.160);
    stem_att[STEM_SYNTH] = coef(dt, 0.020);
    stem_rel[STEM_SYNTH] = coef(dt, 0.350);
    stem_att[STEM_OTHER] = coef(dt, 0.030);
    stem_rel[STEM_OTHER] = coef(dt, 0.400);
    let stem_peak_decay = (dt * 0.55) as f32;
    let hit_decay = exp(-dt / 0.110) as f32;
    let flux_avg_coef = coef(dt, 0.70);
    var hit_flash: f32 = 0.0;
    var hit_count: i64 = 0;
    var hit_cooldown: i64 = 0;
    var onset_sum: f32 = 0.0;
    var onset_max: f32 = 0.0;

    // Preallocate the whole history pool once. After this the hot loop only
    // recycles slots, so the pool length is constant from the first frame.
    for i in HIST {
        slots[i] = history.alloc_index(Snap { levels: [0.0; BANDS], stems: [0.0; STEMS] });
    }

    var fb: u8[..FB_MAX] = [0; FB_MAX];
    var frame: u8[..FRAME_MAX] = [0; FRAME_MAX];
    var head: u8[..512] = [0; 512];
    var foot: u8[..256] = [0; 256];

    // ---- capture ---------------------------------------------------------
    var cap_err: u8[..256] = [0; 256];
    cap_err.resize(0);
    var using_capture = false;
    var have_device = false;

    if !opt_synth {
        let rc = cap_open(dev_name, SR, 256);
        if rc == 0 {
            have_device = true;
            if cap_is_null() == 1 {
                if opt_live {
                    print("capture backend is Null (no audio hardware): capturing silence (--live)");
                } else {
                    print("capture backend is Null (no audio hardware): using synthetic source");
                    cap_close();
                    have_device = false;
                }
            } else {
                using_capture = true;
                print("capture: ", ffi::cstr(cap_name()), " via ", ffi::cstr(cap_backend()));
            }
        } else {
            cap_err.append(ffi::cstr(cap_error()));
            print("capture unavailable: ", cap_err, " -- using synthetic source");
        }
    }
    if opt_synth { using_capture = false; }
    else if opt_live && have_device { using_capture = true; }

    let headless = opt_bench || png_path.len > 0;
    if !headless && term_isatty() == 0 {
        print("stdout is not a terminal.");
        print("Use --png PATH (offscreen PNG) or --bench, or run from a real terminal.");
        if have_device { cap_close(); }
        return;
    }

    var fw = opt_w;
    var fh = opt_h;
    var cols: i64 = 0;
    var rows: i64 = 0;
    if headless {
        fw = clamp_i(opt_w, 160, MAX_W);
        fh = clamp_i(opt_h, 90, MAX_H);
    } else {
        cols = clamp_i(term_cols(), 40, MAX_COLS);
        rows = clamp_i(term_rows(), 10, MAX_ROWS);
        fw = cols;
        fh = (rows - 2) * 2;
        if term_enter() != 0 {
            print("cannot enter raw terminal mode");
            if have_device { cap_close(); }
            return;
        }
    }

    var target_frames = opt_frames;
    if target_frames <= 0 {
        if png_path.len > 0 { target_frames = 90; }
        else if opt_bench { target_frames = 240; }
    }
    var paused = false;
    var synth_t: f64 = 0.0;
    var shead: i64 = 0;
    var frames_done: i64 = 0;
    var audio_frames: i64 = 0;
    var last_cols = cols;
    var last_rows = rows;
    // Prime the synthetic window so the first FFT has no zero-padding click.
    if !using_capture {
        for i in WIN * 2 {
            samples[shead] = synth_sample(synth_t);
            shead = (shead + 1) % WIN;
            synth_t += 1.0 / SR;
        }
    }

    var start_ns = clock_ns();
    var next_ns = start_ns;
    var period_ns = 1000000000 / opt_fps;
    var work_ema: f64 = 1000000.0;
    var bench_total: i64 = 0;
    var bench_min: i64 = 0;
    var bench_max: i64 = 0;
    var last_rms: f32 = 0.0;
    var last_peak: f32 = 0.0;

    loop {
        let frame_start = clock_ns();

        // ---- ingest audio (fixed ring; no allocation) --------------------
        if !paused {
            if using_capture {
                // Drain in bounded batches. At low fps the ring can hold more
                // than one scratch buffer; keep only the newest WIN frames.
                var reads = 0;
                var got = cap_read(scratch[..]);
                while got > 0 && reads < 32 {
                    for k in got {
                        samples[shead] = scratch[k];
                        shead = (shead + 1) % WIN;
                    }
                    audio_frames += got;
                    reads += 1;
                    got = cap_read(scratch[..]);
                }
            } else {
                // Generate exactly SR/fps samples, in fixed-size chunks.
                var remaining = SR / opt_fps;
                while remaining > 0 {
                    var chunk = remaining;
                    if chunk > READ_MAX { chunk = READ_MAX; }
                    for k in chunk {
                        samples[shead] = synth_sample(synth_t);
                        shead = (shead + 1) % WIN;
                        synth_t += 1.0 / SR;
                    }
                    audio_frames += chunk;
                    remaining -= chunk;
                }
            }
        }

        // ---- analysis ----------------------------------------------------
        if !paused {
            let rms, peak, onset = analyze(samples[..], shead,
                                           window[..], re[..], im[..],
                                           cos_t[..], sin_t[..], bitrev[..],
                                           band_lo[..], band_hi[..],
                                           levels[..], mag[..], prev_mag[..],
                                           stem_edges[..], stem_target[..],
                                           band_att, band_rel, flux_avg_coef);
            last_rms = rms;
            last_peak = peak;
            onset_sum += onset;
            if onset > onset_max { onset_max = onset; }

            if onset > 0.30 && hit_cooldown == 0 {
                hit_flash = 1.0;
                hit_count += 1;
                hit_cooldown = max(1, opt_fps / 10);   // 100 ms refractory
            }
            if hit_cooldown > 0 { hit_cooldown -= 1; }

            // One-pole attack/release per stem. Peak hold falls at a fixed
            // rate per second, so it reads the same at 30 and 60 fps.
            for s in STEMS {
                let t = stem_target[s];
                let c = if t > stem_level[s] { stem_att[s] } else { stem_rel[s] };
                stem_level[s] += (t - stem_level[s]) * c;
                if stem_level[s] > stem_peak[s] {
                    stem_peak[s] = stem_level[s];
                } else {
                    stem_peak[s] -= stem_peak_decay;
                    if stem_peak[s] < stem_level[s] { stem_peak[s] = stem_level[s]; }
                }
            }
            hit_flash *= hit_decay;
            if hit_flash < 0.002 { hit_flash = 0.0; }

            // Bounded history ring. The pool is already at capacity; a full
            // ring frees the oldest slot and immediately allocates its reuse.
            var slot = slots[(hist_head + hist_count) % HIST];
            if hist_count == HIST {
                history.free(slots[hist_head]);
                hist_head = (hist_head + 1) % HIST;
                hist_count -= 1;
                slot = history.alloc_index(Snap { levels: levels, stems: stem_level });
            } else {
                for b in BANDS { history[slot].levels[b] = levels[b]; }
                for st in STEMS { history[slot].stems[st] = stem_level[st]; }
            }
            slots[(hist_head + hist_count) % HIST] = slot;
            hist_count += 1;
        }

        // ---- render ------------------------------------------------------
        // Follow terminal resizes: rebuild at the new size before drawing.
        if !headless {
            let cols_now = clamp_i(term_cols(), 40, MAX_COLS);
            let rows_now = clamp_i(term_rows(), 10, MAX_ROWS);
            if cols_now != last_cols || rows_now != last_rows {
                last_cols = cols_now;
                last_rows = rows_now;
                fw = cols_now;
                fh = (rows_now - 2) * 2;
                write_stdout("\x1b[2J");
            }
        }
        let fw3 = fw * fh * 3;
        draw_scene(fb[0..fw3], fw, fh, stem_level[..], stem_peak[..],
                   samples[..], shead, slots[..], hist_head, hist_count,
                   hit_flash, sub_bands, font[..]);

        let work_ns = clock_ns() - frame_start;
        work_ema = work_ema * 0.90 + work_ns * 0.10;

        if headless {
            if opt_bench {
                bench_total += work_ns;
                if frames_done == 0 || work_ns < bench_min { bench_min = work_ns; }
                if work_ns > bench_max { bench_max = work_ns; }
            }
        } else {
            let rms_db = (20.0 * log10(last_rms + 0.000001)) as i64;
            let pk_db = (20.0 * log10(last_peak + 0.000001)) as i64;
            let wms = (work_ema / 1000000.0) as i64;
            let wds = ((work_ema / 100000.0) as i64) % 10;
            head.resize(0);
            let src = if using_capture { "LIVE" } else { "SYNTH" };
            if last_cols >= 70 {
                format(head, " GOOSE STEMS  ", src, "  ", opt_fps, "fps  ",
                       wms, ".", wds, "ms  rms ", rms_db, "dB  pk ", pk_db, "dB");
            } else {
                format(head, " GS STEMS ", src, " ", opt_fps, "fps ", rms_db, "dB");
            }
            foot.resize(0);
            if last_cols >= 76 {
                format(foot, " q quit  s src  p pause  spc clear  ring ",
                       hist_count, "/", HIST, "  pool ", history.len,
                       "  hits ", hit_count, "  drop ", cap_overflow());
            } else {
                foot.append(" q quit  s src  p pause");
            }
            render_terminal(frame, fb[0..fw3], fw, fh, last_cols, last_rows, head[..], foot[..]);
        }

        frames_done += 1;

        // ---- stop conditions --------------------------------------------
        if term_interrupted() == 1 { break; }
        if target_frames > 0 && frames_done >= target_frames { break; }
        if opt_seconds > 0.0 {
            let elapsed = (clock_ns() - start_ns) as f64 / 1000000000.0;
            if elapsed >= opt_seconds { break; }
        }
        if !headless {
            let k = term_key();
            if k == 113 || k == 81 || k == 27 || k == 3 { break; }   // q Q Esc Ctrl-C
            else if k == 115 || k == 83 {
                if have_device { using_capture = !using_capture; }
            }
            else if k == 112 || k == 80 { paused = !paused; }
            else if k == 32 {
                for s in STEMS { stem_peak[s] = 0.0; }
            }
        }

        // ---- pace --------------------------------------------------------
        if !headless {
            next_ns += period_ns;
            let now = clock_ns();
            if next_ns > now {
                let wait_ms = (next_ns - now) / 1000000;
                if wait_ms > 0 { sleep_ms(wait_ms); }
            } else {
                next_ns = now;
            }
        }
    }

    // ---- finish ----------------------------------------------------------
    if !headless { term_leave(); }
    if have_device { cap_close(); }

    if png_path.len > 0 {
        let ok = host_write_png(png_path, fw as i32, fh as i32, fb[0..(fw * fh * 3)]);
        if ok == 1 {
            print("wrote ", png_path, " (", fw, "x", fh, ")");
        } else {
            print("could not write ", png_path);
        }
    }
    if opt_bench {
        let avg = bench_total / max(1, frames_done);
        print("bench: frames=", frames_done, " size=", fw, "x", fh,
              " avg_ms=", avg / 1000000, ".", (avg % 1000000) / 100000,
              " min_ms=", bench_min / 1000000, ".", (bench_min % 1000000) / 100000,
              " max_ms=", bench_max / 1000000, ".", (bench_max % 1000000) / 100000,
              " pool=", history.len, "/", HIST, " audio_s=", audio_frames / SR);
        print("       stems sub=", (stem_level[STEM_SUB] * 100.0) as i64,
              " drum=", (stem_level[STEM_DRUM] * 100.0) as i64,
              " synth=", (stem_level[STEM_SYNTH] * 100.0) as i64,
              " other=", (stem_level[STEM_OTHER] * 100.0) as i64,
              " hits=", hit_count,
              " onset_avg=", ((onset_sum / max(1, frames_done)) * 100.0) as i64,
              " onset_max=", (onset_max * 100.0) as i64);
        if avg > 0 {
            print("       implied headroom: ", 1000000000 / avg, " frames/s (analysis+render only)");
        }
    }
}
