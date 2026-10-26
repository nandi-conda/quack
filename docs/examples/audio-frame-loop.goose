// audio-frame-loop.goose - the hot loop of a realtime visualizer.
// Capture -> window -> FFT -> magnitude, with every buffer sized once and
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
var phase: f32 = 0.0;

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

// One display frame. Returns the loudest bin, and fills mag[] for the renderer.
fn frame() -> i64 {
    for i in N {
        let t = phase + i * 0.031;
        re[i] = (sin(t as f64) as f32) * 0.6 + (sin((t * 1.7) as f64) as f32) * 0.3;
        re[i] *= window[i];
        im[i] = 0.0;
    }
    phase += 0.05;
    fft();
    var peak_bin = 0;
    var peak: f32 = 0.0;
    for b in BINS {
        let v = sqrt(re[b] * re[b] + im[b] * im[b]);
        mag[b] = v;
        if v > peak { peak = v; peak_bin = b; }
    }
    // The renderer reads mag[]; the next frame overwrites it in place.
    return peak_bin;
}

fn main() {
    setup();
    var times: i64[300] = [0; 300];
    var peaks: i64[300] = [0; 300];
    for f in 300 {
        let t0 = clock_ns();
        peaks[f] = frame();
        times[f] = clock_ns() - t0;
    }
    sort(times[..]) { a, b => a > b };
    print("frame p50=", times[150], "ns  p99=", times[3], "ns  max=", times[0], "ns");
    print("peak bin last frame=", peaks[299], "  first bin mag=", mag[1]);
}
