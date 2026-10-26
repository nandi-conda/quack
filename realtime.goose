// realtime.goose - a fixed-cadence loop with bounded, zero-heap telemetry.
//
// The timer is simulated: tick k has a logical deadline of k * PERIOD_NS.
// Every tick does a fixed amount of work in stack-local scratch, then offers
// a sample to a bounded outbox. The outbox is a `reusable` pool ring; when it
// is full the sample is dropped and counted (backpressure), never queued by
// growing memory. A slower consumer drains one sample every DRAIN_EVERY ticks,
// so the ring fills, drops, frees, and reuses slots without ever growing.
//
// Run in-process:  goose realtime.goose
// Build:           goose build realtime.goose && ./realtime

import std;
import os;

const TICKS = 300;
const PERIOD_NS: i64 = 1000000;   // 1 ms simulated cadence
const WORK = 1024;                // bytes of scratch work per tick
const RING_CAP = 16;
const DRAIN_EVERY = 4;

struct Sample {
    tick: i64,
    compute_ns: i64,
    check: u32,
}

// The only long-lived dynamic state: a bounded telemetry outbox.
reusable var outbox: Sample[>..] = [];

// Per-tick body. Everything it builds is local to this call and is gone when
// it returns; the returned Sample is a flat value copied to the caller.
fn handle_tick(tick: i64) -> Sample {
    let start = clock_ns();

    // Fixed work: fill a data-stack scratch buffer and hash it.
    var scratch: u8[>..] = [];
    for i in WORK {
        scratch.push(((tick * 31 + i * 17) % 251) as u8);
    }
    var check: u32 = 2166136261;
    for b in scratch {
        check = (check ^ b) * 16777619;
    }

    return Sample { tick: tick, compute_ns: clock_ns() - start, check: check };
}

fn main() {
    print("Goose realtime loop: ", TICKS, " ticks @ ", PERIOD_NS,
          " ns simulated cadence, work=", WORK, " bytes");

    var slots: i64[RING_CAP] = [-1; RING_CAP];   // ring position -> pool slot
    var head = 0;        // oldest queued sample
    var count = 0;       // queued samples
    var accepted = 0;
    var dropped = 0;     // backpressure: ring was full
    var drained = 0;
    var total_ns: i64 = 0;
    var min_ns: i64 = 0;
    var max_ns: i64 = 0;
    var overruns = 0;    // compute exceeded the simulated period

    for tick in TICKS {
        let deadline = tick * PERIOD_NS;   // logical time, not a wall-clock sleep
        let s = handle_tick(tick);         // stack scratch dies here

        // Produce: if the outbox is full, drop this sample and keep cadence.
        if count == RING_CAP {
            dropped++;
        } else {
            let slot = outbox.alloc_index(s);
            slots[(head + count) % RING_CAP] = slot;
            count++;
            accepted++;
        }

        // Consume: a deliberately slower sink drains one sample every few ticks.
        if tick % DRAIN_EVERY == 0 && count > 0 {
            outbox.free(slots[head]);
            slots[head] = -1;
            head = (head + 1) % RING_CAP;
            count--;
            drained++;
        }

        // Latency summary over every tick, including dropped samples.
        if tick == 0 {
            min_ns = s.compute_ns;
            max_ns = s.compute_ns;
        }
        total_ns += s.compute_ns;
        if s.compute_ns < min_ns { min_ns = s.compute_ns; }
        if s.compute_ns > max_ns { max_ns = s.compute_ns; }
        if s.compute_ns > PERIOD_NS { overruns++; }

        if tick % 50 == 0 {
            print("tick ", tick, " deadline=", deadline, " ns compute=",
                  s.compute_ns, " ns queue=", count, "/", RING_CAP);
        }
    }

    print("accepted=", accepted, " dropped=", dropped, " drained=", drained,
          " queued=", count);
    print("pool slots=", outbox.len, "/", RING_CAP, " (high-water, never grows)");
    print("compute ns: min=", min_ns, " avg=", total_ns / TICKS,
          " max=", max_ns, " overruns=", overruns);
}
