// audio-frame-loop.goose - the hot loop of a realtime visualizer.
// Capture -> window -> FFT -> magnitudes -> display stems (sub, percussion
// from spectral flux, tonal, residual). Every buffer is sized once and
// reused; the frame loop allocates nothing.
import std;
import math;
import os;

const N = 1024;            // samples per frame
const HALF = 512;
const BINS = 64;           // displayed bins

var re: f32[N] = [0.0; N];
var im: f32[N] = [0.0; N];
var window: f32[N] = [0.0; N];
var twr: f32[HALF] = [0.0; HALF];
var twi: f32[HALF] = [0.0; HALF];
var mag: f32[BINS] = [0.0; BINS];
var prev_mag: f32[BINS] = [0.0; BINS];
var phase: f32 = 0.0;
var flux_mean: f32 = 0.0;
var tick: i64 = 0;
var rng_state: u64 = 88172645463325252;

struct Stems { sub: f32, percussion: f32, tonal: f32, residual: f32, onset: bool }

fn noise() -> f32 {
    rng_state = rng_state * 6364136223846793005 + 1442695040888963407;
    return (rng_state >> 40) * (1.0 / 16777216.0) - 0.5;
}

fn setup() {
    for i in N { window[i] = 0.5 - 0.5 * cos(6.283185307179586 * i / N) as f32; }
    for k in HALF {
        let a = 6.283185307179586 * (k as f64) / N;
        twr[k] = cos(a) as f32;
        twi[k] = -sin(a) as f32;
    }
}

fn fft() {
    var j = 0;
    for i in N {
        if i < j { swap(re[i], re[j]); swap(im[i], im[j]); }
        var bit = N >> 1;
        while (j & bit) != 0 { j ^= bit; bit >>= 1; }
        j ^= bit;
    }
    var size = 2;
    while size <= N {
        let half = size / 2;
        let step = N / size;
        var start = 0;
        while start < N {
            for k in half {
                let a = start + k;
                let b = a + half;
                let wr = twr[k * step];
                let wi = twi[k * step];
                let tr = wr * re[b] - wi * im[b];
                let ti = wr * im[b] + wi * re[b];
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr;          im[a] += ti;
            }
            start += size;
        }
        size *= 2;
    }
}

// Display-oriented split. Sub is the lowest band; tonal is bins whose level
// barely moved; percussion is positive spectral flux (an onset cue); the rest
// is residual. It is a visual heuristic, not source separation.
fn split() -> Stems {
    var flux: f32 = 0.0;
    var total: f32 = 0.0;
    for b in BINS {
        let d = mag[b] - prev_mag[b];
        if d > 0.0 { flux += d; }
        total += mag[b];
    }
    let onset = flux > 0.05 && flux > flux_mean * 1.6;
    flux_mean = flux_mean * 0.85 + flux * 0.15;

    var sub: f32 = 0.0;
    for b in 4 { sub += mag[b]; }
    var tonal: f32 = 0.0;
    for b in 4..BINS {
        if abs(mag[b] - prev_mag[b]) < mag[b] * 0.25 { tonal += mag[b]; }
    }
    var perc = min(flux * 2.0, total);
    for b in BINS { prev_mag[b] = mag[b]; }
    var residual = total - sub - tonal - perc;
    if residual < 0.0 { residual = 0.0; }
    return Stems { sub: sub, percussion: perc, tonal: tonal, residual: residual, onset: onset };
}

// One display frame. Fills mag[], updates the stem split, returns it.
fn frame() -> Stems {
    let env = if tick % 24 == 0 { 1.0 } else { 0.3 };
    for i in N {
        let t = phase + i * 0.031;
        re[i] = ((sin((t * 0.23) as f64) as f32) * 0.6 + (sin((t * 1.7) as f64) as f32) * 0.3 + noise() * 0.25) * env;
        re[i] *= window[i];
        im[i] = 0.0;
    }
    phase += 0.05;
    tick++;
    fft();
    for b in BINS { mag[b] = sqrt(re[b] * re[b] + im[b] * im[b]); }
    // The renderer reads mag[]; the next frame overwrites it in place.
    return split();
}

fn main() {
    setup();
    var times: i64[300] = [0; 300];
    var onsets = 0;
    var last = Stems { sub: 0.0, percussion: 0.0, tonal: 0.0, residual: 0.0, onset: false };
    for f in 300 {
        let t0 = clock_ns();
        last = frame();
        times[f] = clock_ns() - t0;
        if last.onset { onsets++; }
    }
    sort(times[..]) { a, b => a > b };
    print("frame p50=", times[150], "ns  p99=", times[3], "ns  max=", times[0], "ns");
    let sum = last.sub + last.percussion + last.tonal + last.residual;
    print("onsets=", onsets, "/300  stems: sub=", (last.sub * 100.0 / sum) as i64,
          "% perc=", (last.percussion * 100.0 / sum) as i64,
          "% tonal=", (last.tonal * 100.0 / sum) as i64,
          "% residual=", (last.residual * 100.0 / sum) as i64, "%");
}
