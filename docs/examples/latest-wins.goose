// latest-wins.goose - the UI side of a realtime pipeline: take every frame
// that is ready, keep only the newest, never build a backlog.
//
//   pixi run goose build docs/examples/latest-wins.goose
//   ./docs/examples/latest-wins
import std;
import os;

struct Spectrum { bins: f32[64] }

fn newest(out: Spectrum&) -> bool {
    var got = false;
    loop {
        let next, ok = qpoll<Spectrum>();
        if !ok { return got; }
        out = next;                    // copy the flat frame into the caller
        got = true;
    }
}

thread_fn capture() {
    var n = 0;
    loop {
        var s = Spectrum { bins: [0.0; 64] };
        for i in 64 { s.bins[i] = n + i; }
        qput(s);                       // full queue: this frame is dropped
        n++;
    }
}

fn main() {
    qlimit<Spectrum>(2);
    thread_spawn(capture);
    var latest = Spectrum { bins: [0.0; 64] };
    var frames = 0;
    for f in 200 {
        if newest(latest) { frames++; }
        sleep_ms(1);
    }
    print("rendered ", frames, " of 200 ticks; newest bin0=", latest.bins[0]);
}
