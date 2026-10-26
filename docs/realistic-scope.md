# Realistic scope for heap-less Goose

*What this repository can ship now, what needs C or fixed pools, what is not worth doing heap-less, and what to build next.*

Scope: `goose` `2026.3.post100` (runtime `a5dbd11b6309`), linux-64, gcc 15.2.0. Every claim below points at a file in this repository or at a result measured from it on 2026-10-26. The numbers come from a shared VM and are order-of-magnitude evidence, not a benchmark suite. The commands are repeated in [section 6](#6-verification).

## 1. The short answer

With heap-less Goose you can realistically ship **single-purpose Linux binaries** where all of these hold:

- work arrives in independent units: a request, frame, packet, file, record, job;
- the maximum size of one unit is known and modest;
- the unit's state can die when the unit ends;
- peak memory may be a high-water mark, not a function of total work;
- soft realtime is enough;
- you accept a few hundred lines of hand-written C at the OS edge.

This repository already demonstrates that shape end to end:

| What is already real | Measured here |
| --- | --- |
| Live-capture audio visualizer at 30–60 fps | `visualizer.goose`, 2.6–2.7 ms per 960x540 frame native stereo, 5.6 ms at 8 channels, 7.3 MiB RSS |
| FFT and display stem split per frame | `docs/examples/audio-frame-loop.goose`, 43.6 us p50, 64.8 us p99, 83.2 us max |
| Serial HTTP service over a 33-line socket shim | `docs/examples/minihttp.goose`, 20,000 sequential connections at 1.8 MiB RSS, flat |
| Request loop with input-independent memory | `docs/examples/request-loop.goose`, 11 MiB peak RSS at both 2 MB and 115 MB input (guide) |
| Bounded pools and queues that never grow | `iteration.goose`, `realtime.goose`, `docs/examples/pool-generations.goose` |
| Verified bytecode sandbox | `docs/examples/rule-vm.goose`, rejects bad branches before execution |
| Small static binaries | 70–75 KB for the three samples, 483 KB for the visualizer including vendored audio and PNG code |

What is **not** demonstrated, and should not be assumed: audio playback, a concurrent network service, TLS, subprocesses, storage I/O, windowed graphics, hard realtime, or a bounded RSS when a C library allocates.

The practical next wins, in order, are a verification harness, audio output, HTTP hardening, measured cadence and lateness, a parser with a hostile corpus, a CLI with a small `fork/exec` shim, and a storage/snapshot tool. Section 5 gives estimates and acceptance tests.

## 2. What you can build now, and the file that proves it

| Capability | Evidence in this repository | Already proven | Gap to a product |
| --- | --- | --- | --- |
| Realtime audio analysis and visualisation | `visualizer.goose` (1,661 lines), `src/capture.c` (278), `src/host.c` (128), `docs/examples/audio-frame-loop.goose` (133) | 48 kHz capture with the device's native channel count into one fixed SPSC ring per channel; 2048-point FFT; 64 bands; four display buses; 960x540 software framebuffer; ANSI and PNG output; 30/60 fps pacing; synthetic fallback when no device exists | Audio output; device loss and resampling on real hardware; a windowed UI; true source separation |
| Bounded request loops | `docs/examples/request-loop.goose` (55), `iteration.goose` (88) | Per-request line, fields and response die at scope exit; 70 ns p50 parse, route and format (guide); 11 MiB peak RSS independent of input size; a 6-slot ring reaches `pool slots=6` and never grows | Sockets and HTTP framing (see `minihttp`); keep-alive; concurrency |
| Fixed-cadence producers | `realtime.goose` (108), `docs/examples/latest-wins.goose` (41), the pace loop in `visualizer.goose` | Bounded outbox with drop-on-full and a drain-to-newest consumer; 300 logical 1 ms ticks at 9–10 us compute; 16/16 high-water; 199 of 200 ticks rendered | Sub-millisecond pacing; lateness histograms; device-driven blocks instead of a manual clock |
| Parsers and hostile bytes | `request-loop.goose`, `rule-vm.goose` (148), the route function in `minihttp.goose` | Zero-copy slices; bounds-checked access; a verifier that checks opcodes, immediates, branch targets, stack depth and a 64-slot maximum before execution; rejection with a reason | A fuzz corpus; wider format coverage; an explicit abort-versus-error policy per service |
| Small network data planes over a C shim | `docs/examples/minihttp.goose` (60) plus `net.c` (33); `docs/examples/fanout.goose` (49) | Five POSIX socket calls behind `extern fn`; a serial accept loop at 1.8 MiB RSS; a fixed worker pool with bounded job and result queues and admission control (2,056 accepted, 197,944 refused) | Keep-alive, timeouts, epoll or N workers; TLS; partial-write stress; per-connection limits |
| CLI and build tooling | `demo.goose` (58) as a 70 KB binary; argument parsing in `visualizer.goose`; `os` file I/O; `pixi run check` | Whole-program 70–75 KB binaries; 0.19 s native build and about 0.05 s for an in-process compile and run of `demo.goose`, both including pixi overhead on this host; `args()` and whole-file reads and writes | A subprocess (`fork/exec/waitpid`) shim, roughly 60–120 lines of C; process supervision |
| Sandboxes for untrusted bytecode | `docs/examples/rule-vm.goose` | Verification before execution, a fixed `i64[64]` stack, a step budget, forward-only branches | Fuzzing; resource accounting; a host API; dynamic plugins remain out of scope |
| Independent lifetimes with pools | `docs/examples/pool-generations.goose` (59), the `ChannelState` and history pools in `visualizer.goose` | O(1) allocation and free, generation tags that detect stale handles, high-water equal to capacity | Eviction policy, compaction, and per-tenant accounting are your code |

In product terms, the following are realistic now, each as one binary:

- a line-in audio meter, recorder or visualizer appliance on a Linux box;
- a health, metrics or webhook endpoint at modest concurrency; a small protocol gateway; a per-message translator;
- a batch log parser, validator and aggregator whose memory tracks the largest record;
- a formatter, linter, validator or code generator over bounded files;
- a rule or policy sandbox for untrusted data;
- a sensor gateway with a fixed ring and a batched uploader;
- a read-only index, snapshot or archive tool.

Each of those is one process with a bounded working set, not a platform. The following are **not** in that list even though they are nearby: a general web application backend, a plugin host, a DAW, a windowed game, and a multi-tenant server.

## 3. What needs C or a static pool

### 3.1 The sidecar budget in this repository

The hand-written C is small even where the vendored library is large.

| File | Lines | Bytes | What it does | On the hot path? |
| --- | ---: | ---: | --- | --- |
| `docs/examples/net.c` | 33 | 1,035 | `listen`, `accept`, `read`, `write`, `close` over POSIX sockets | Yes, blocking calls |
| `src/capture.c` | 278 | 10,189 | miniaudio context and device setup, device enumeration, one fixed SPSC ring per channel, atomic indices, overflow counters, Null-backend detection, query functions | The callback only writes into fixed rings |
| `src/host.c` | 128 | 3,802 | Raw terminal mode, alternate screen, terminal size, non-blocking key read, PNG write, signal and exit restore | No, only per-frame ioctls and a key read |
| **Total hand-written** | **439** | **15,026** | | |
| `vendor/miniaudio.h` | 95,864 | 4,108,168 | Vendored audio device and backend loading | Not your code |
| `vendor/stb_image_write.h` | 1,724 | 71,221 | Vendored PNG encoder | Not your code |

Three patterns are worth copying:

- **Flat boundary.** Slices cross as `{const uint8_t *data, int64_t len}`; handles are `i64` or `i32`. No structs with pointers cross the boundary.
- **Fixed rings and atomics.** `capture.c` uses `static float g_ring[CAP_MAX_CHANNELS][CAP_RING]` and `atomic_ullong` read/write indices with acquire/release. The callback does no allocation, locking or waiting. The audio device owns the thread; Goose drains the ring.
- **Allocation only at setup or teardown.** The PNG writer inside stb allocates while writing the file, never in the frame loop. miniaudio may allocate while opening a device; the capture callback itself does not allocate.

The FFI boundary is where the heap-less guarantee stops. A C library you call can allocate and its RSS is outside the model. That is a design choice, not a bug, but it belongs in the capacity plan.

The packaged build has no networking or subprocess API in its standard library, and the `gfx`, `audio`, `ui` and `physics` packages are not included. Those two gaps are why this sidecar budget exists.

### 3.2 Static pools in Goose

A pool replaces dynamic allocation for state that outlives one unit. The repo has four sizes of the same pattern:

| Pattern | File | Cost |
| --- | --- | --- |
| Ring of recent records | `iteration.goose` | About 20 Goose lines: `slots: i64[RING]`, `reusable var recent`, `alloc_index`, `free`, wrap the head |
| Bounded outbox with drop-on-full | `realtime.goose` | About 25 lines plus drop and drain counters |
| Pool with generation handles | `docs/examples/pool-generations.goose` | 59 lines total; generation logic is about 35 of them |
| Per-channel state and 96-column history, preallocated to the compile-time maximum | `visualizer.goose` | `ChannelState` pool with `CH_MAX = 8` slots and a `Snap` history pool with `HIST = 96`; allocate once at startup, free the oldest before reuse |

A first bounded ring costs about 40–80 lines of Goose including its slot array and counters; the pool calls themselves are about 20, and generation handles add about 30. There is no C involved. The compiler reports the cost in address space: `pixi run stack-stats` shows 3 data stacks and 5 regions for `iteration.goose`, while `pixi run viz-stack-stats` shows 11 stacks and 16 regions for the visualizer. The default reservation is 2 GB of virtual address space per stack; `--stack-reserve` accepts 64 KB to 256 TB. The visualizer task passes `--stack-reserve 64M`, so its 11 stacks reserve about 704 MB instead of 22 GB.

### 3.3 What a new sidecar costs

Estimates are for one person who knows this codebase; they are not measurements.

| Capability | Hand-written C | Notes | Existing evidence |
| --- | ---: | --- | --- |
| HTTP hardening: socket timeouts, keep-alive, partial writes | +20–40 lines | `setsockopt` for receive and send timeouts; keep-alive is a Goose-side request loop; the partial-write loop already exists | `net.c` is 33 lines |
| Nonblocking or epoll data plane | +120–250 lines | Readiness sets, nonblocking accept, per-connection buffers, backpressure; the largest jump in this table | None in the repo |
| N workers, each owning connections | +0–10 lines | `fanout.goose` shows the Goose side; each worker needs the listening fd (passed through a queue) or its own socket with `SO_REUSEPORT`, then serves its connections. Requires `goose build`, because the JIT cannot run `thread_fn` | `fanout.goose` |
| Audio playback or duplex | +80–150 lines | A second ring, a playback device or a duplex device, an underrun counter; callback still allocation-free | `capture.c` is capture-only |
| Subprocess for CLI and build tools | +60–120 lines | `fork`, `exec`, two pipes, `waitpid`; process groups, signals and pipe deadlock are the risk | None in the repo |
| Storage: `pread`, `pwrite`, `fsync`, `mmap` | +40–120 lines | Crash consistency, fsync policy and file locking remain Goose-side design work | `os` offers whole-file read and write, append and atomic replace only |
| Serial or GPIO | +50–150 lines | `termios`, `ioctl`, or a vendor SDK | None in the repo |
| TLS | Not a shim | Use OpenSSL or mbedTLS through `extern "lib"`; both allocate, so RSS is not bounded by your code | None |
| Windowed graphics | +100–300 lines of glue | SDL3 through `extern "lib"`; the `gfx`, `audio`, `ui` and `physics` packages are not in this build | Terminal and PNG only |

The rule of thumb: if the capability is a handle plus a buffer plus a loop, it is a sidecar. If it needs per-object lifetime or unbounded buffering, it is not.

## 4. What is a poor fit, or not worth doing heap-less

| Shape | Why it fights the model | Evidence in this repo | Instead |
| --- | --- | --- | --- |
| Full web application backend: ORM, sessions, identity map, document state | Per-object lifetimes, unbounded cardinality, irregular graphs | No example, because the model does not provide them | A GC or ownership language for the application; Goose for a bounded parser, policy or data-plane component |
| TLS-terminating gateway, HTTP/2, gRPC | The library allocates and owns threads; the heap-less guarantee covers only your glue | `minihttp` has no TLS and is loopback-only | Accept the library's RSS, or terminate TLS in a separate process and keep Goose for routing |
| Dynamic plugin host or hot reload | Whole-program compilation, no shared Goose libraries, no function pointers | `rule-vm.goose` is the only supported plugin shape: bytecode interpreted by verified Goose | Define plugins as data or bytecode, not as Goose code |
| Per-subscriber pub/sub with per-subscriber backlogs | Queues are selected by message type, not by subscriber; one consumer per message | `fanout.goose` refuses 197,944 of 200,000 jobs under a 1,024-slot limit; that is admission control, not delivery | A C event loop with per-subscriber buffers, or a fixed set of declared channels |
| Unbounded uploads, unbounded buffering of a slow consumer | Memory would track the peer's behaviour | `latest-wins.goose` deliberately drops stale frames; `realtime.goose` drops on a full outbox | Stream with a bounded buffer and spool to disk; accept an abort or a refused request |
| Hard realtime, a DAW plugin, a required WCET | No scheduling control, no priorities, no interrupts, no WCET; page faults and the kernel remain | `realtime.goose` uses a simulated clock; the visualizer is paced at 30–60 fps, not sample rate | An RTOS or PREEMPT_RT with locked, pre-faulted memory; Goose may be a component |
| Windowed GPU UI or a game with graphics | The `gfx` package is not in this build; there is no window system integration | `visualizer.goose` renders ANSI and PNG; `pixi run toolchain` reports `built in: no packages` and no cmake | Terminal or PNG today; SDL3 through `extern "lib"` is possible but costs C glue and the package gap remains |
| Neural stem separation or general ML inference | Model weights, tensor arenas, BLAS and GPU libraries; the output quality needs training tooling | The README explicitly excludes Demucs; the four buses are display heuristics, not separation | Keep the visual heuristic; run a real separator offline or in another process |
| Editor, CAD, social graph, large object graphs | Fine-grained lifetimes and high churn are the workload | None | A GC or ownership language |
| Thousands of tenants per process | Worker count is bounded by address space; each stack reserves virtual memory | 11 stacks at 64 MB is 704 MB; the default is 2 GB per stack | Dozens to hundreds of workers, or processes with explicit `--stack-reserve` |
| A WASM plugin sandbox | No `wasm32` target; the runtime needs address-space reservation and thread-local storage | The guide documents this as a port, not a flag | Interpret bytecode in a verified Goose VM |
| "Rewrite the backend in Goose" | The ecosystem gap is real: 12 standard modules, no networking or subprocesses | `pixi run toolchain`; the guide's section 5 | Keep Goose for the bounded component that benefits |

Two of those deserve a nuance rather than a flat "no":

- A **TLS proxy** is possible today with an `extern "lib"` block. It is not a heap-less proxy; it is a heap-less router with an allocating TLS library attached. If that is acceptable, it is a product. If the bounded-memory property is the reason you chose Goose, it is not.
- A **small fixed neural model** could run in a static arena. The missing pieces are the inference code, the weights and the tooling; that is weeks of work, not days, and the current four-bus display is a better return for the effort.

## 5. Ranked next steps

Effort is person-days for one developer who knows the code. "Size" is new code, not counting vendored headers.

| Rank | Work | Why now | Effort | Size | Acceptance test |
| ---: | --- | --- | ---: | --- | --- |
| 1 | **Verification harness**: a `pixi run verify` task that builds and runs every example and sample, checks the expected substrings, runs `check`, and records stack stats and benchmark bounds | Every claim in this repository depends on manual runs; a compiler or channel change should fail loudly, not silently stale the docs | 0.5–1 day | a small verification script plus a task; no new Goose | One command, non-zero on a broken example, under about 90 s on this host |
| 2 | **Audio output and duplex**: a `playback.goose` and `src/audio.c`, or extend `capture.c` with a playback or duplex device and a second ring | The flagship demo analyses audio but cannot play it; output exercises the callback boundary in the other direction and makes the project an audio application, not only a meter | 1.5–2 days | C +80–150 lines, Goose +100–150 | A tone or passthrough at 48 kHz, an underrun counter (target zero over 10 minutes), allocation-free callback, synthetic fallback in CI |
| 3 | **HTTP hardening**: keep-alive, receive and send timeouts, N worker connections or an epoll loop, a connection limit, graceful overload | `minihttp` is serial and closes after one request; the network category is the biggest gap between the guide's claims and the code | 1.5–2 days | C +20–200 lines depending on epoll, Goose +60–120 | 100 concurrent clients, flat RSS under 5 MiB, p99 recorded, clean refusal when the limit is hit |
| 4 | **Real cadence and lateness**: replace the simulated timer in `realtime.goose` with `clock_ns` pacing, add a sub-millisecond block mode, and report lateness p50/p99/max and missed deadlines | The visualizer already paces at 30–60 fps with `sleep_ms`, but there is no evidence for a 1 ms tick or a 1.33 ms audio block; the demo should say what it actually achieves | 1 day | Goose +80–150; optional C +20–40 for `clock_nanosleep` | A 10-minute run with a reported lateness distribution and an explicit statement that this is soft realtime |
| 5 | **Parser with a hostile corpus**: an HTTP header or JSON parser, a malformed-input corpus, named errors, a `from_bytes` snapshot round trip and a checksum | Parsers are the language's strongest fit and the existing rule VM shows verification rather than parsing throughput; this turns the security story into a test | 1 day | Goose 250–400, no C | 10,000 malformed inputs, zero aborts, every rejection named, snapshot reload verified |
| 6 | **CLI with a subprocess shim**: `spawn.c` plus a small runner, formatter or linter that invokes `gcc` or `goose check` | The binary and startup numbers are already good; the missing piece is one shim, and the CLI category then has a real artifact instead of an inference | 2 days | C +60–120, Goose 200–400 | Runs the repo's own check over every file, bounded output, no zombies, non-zero on failure |
| 7 | **Rule-VM fuzzing and limits**: random and deliberately invalid bytecode, budget assertions, a disassembler, a small host API | Turns "verified sandbox" from a demo into a tested property and documents the rejection reasons | 1 day | Goose 150–250, no C | 100,000 random programs, no aborts, every rejection classified, step and stack bounds asserted |
| 8 | **Storage and snapshot**: append-only log, replay, `write_file_atomic`, a `pread` shim if needed, checksummed images | Storage is a good fit but has no artifact yet; it is also the highest-effort item, so it comes last | 2–3 days | C +40–120, Goose 300–500 | Kill and replay without loss, checksum mismatch rejected, scan memory tracks the largest record |

Ranking rationale: the harness first because it protects every other claim; audio output second because it completes the one shipped product; HTTP third because it closes the largest gap in the network category; cadence fourth because it is cheap and makes the realtime claim honest; the parser fifth because it is the strongest language fit; CLI sixth because it opens a category with one small shim; rule-VM fuzzing seventh because it deepens an existing demo; storage last because it has the highest cost and the least evidence of demand.

Do **not** spend the next block on: a windowed renderer, a TLS proxy, neural separation, a plugin loader, or multi-tenancy. Each needs a library or a guarantee this build does not have, and none of them strengthens the claims the repository already makes.

## 6. Verification

All commands below were run on 2026-10-26 with the pinned package. Native `./visualizer` rows assume a preceding `pixi run build-viz`. `pixi run version` reports `goose runtime a5dbd11b6309`; `pixi run toolchain` reports gcc 15.2.0, no cmake, and `built in: no packages`.

| Command | Observed |
| --- | --- |
| `pixi run check` | All four root programs typecheck |
| `pixi run goose demo.goose` | Primes below 30, count 10, `sum(fib)=88` as documented |
| `pixi run goose iteration.goose` | `pool slots=6 (capacity 6, no growth)` |
| `pixi run goose realtime.goose` | `accepted=91 dropped=209 drained=75 queued=16`; compute min 9,110 ns, avg 9,965 ns, max 90,580 ns, overruns 0 |
| `pixi run goose docs/examples/request-loop.goose < requests.txt` | With a generated 4,000-line file: `requests=4000 bytes=1918934 not_found=572` |
| `pixi run goose build docs/examples/fanout.goose && ./docs/examples/fanout` | `workers=8 submitted=2056 refused=197944` |
| `pixi run goose build docs/examples/latest-wins.goose && ./docs/examples/latest-wins` | `rendered 199 of 200 ticks` |
| `pixi run goose build docs/examples/audio-frame-loop.goose && ./docs/examples/audio-frame-loop` | `frame p50=43640ns p99=64770ns max=83180ns`; `onsets=13/300`; stems sub 59%, perc 5%, tonal 31%, residual 3% |
| `pixi run goose build docs/examples/pool-generations.goose && ./docs/examples/pool-generations` | `stale handle: false value=0`; `fresh handle: true value=99` |
| `pixi run goose docs/examples/rule-vm.goose` | `max(41, 7) = 41`; `rejected: branch into data at 12` |
| `pixi run goose build docs/examples/minihttp.goose && ./docs/examples/minihttp` | Serves `HTTP/1.1 200 OK`; 20,000 sequential connections with `VmHWM 1,880 kB` and `VmPeak 4,199,160 kB`, flat before and after |
| `pixi run viz-bench` (JIT, stereo, 960x540) | `avg_ms=10.0 min_ms=8.5 max_ms=14.0`; 99 frames/s implied headroom |
| `./visualizer --synthetic --channels 2 --bench --frames 600` (native) | `avg_ms=2.6 min_ms=2.2 max_ms=6.4`; 374 frames/s; `VmHWM 7,336 kB`, `VmPeak 1,070,300 kB` at `--stack-reserve 64M` |
| `./visualizer --synthetic --channels 8 --bench --frames 600` (native) | `avg_ms=5.6 min_ms=4.3 max_ms=8.4`; 175 frames/s |
| `pixi run viz-bench-8ch` (JIT) | `avg_ms=15.1 min_ms=12.1 max_ms=21.4`; 65 frames/s |
| `pixi run screenshot` | `wrote screenshots/visualizer.png (960x540)` |
| `pixi run stack-stats` | `main: 3 data stacks, 5 regions (reserving 2 GB each)` |
| `pixi run viz-stack-stats` | `main: 11 data stacks, 16 regions (reserving 64 MB each)` |
| Native binary sizes | `demo` 70,224 B; `iteration` 74,448 B; `realtime` 74,704 B; `visualizer` 483,016 B |
| Generated C sizes | `demo.c` 67,853 B; `audio-frame-loop.c` 120,102 B; `visualizer.c` 353,078 B |

The guide's larger measurements were not all repeated in full. The 4-million-line request case and 20,000 connections in 2.12 s are in [the guide's sources table](heap-less-app-guide.md#9-sources-and-verification); the smaller runs above reproduce their shape and their expected output. The `request-loop` binary at 11 MiB peak RSS for both 2 MB and 115 MB inputs is from the guide and was not re-measured here.

**Not verified, and therefore not claimed:** live capture on real audio hardware (this host has no `/dev/snd`; miniaudio's Null backend is what runs), 8-channel live capture, TLS, 100 concurrent HTTP clients, PNG pixel identity across runs, non-Linux targets, and any WCET. `pixi run toolchain` reports `cmake: not found on PATH`, so a windowed `gfx` build is not available here.

## 7. What would change this assessment

Revisit the ranking if any of these lands in the channel or the repository:

- a compiler build with the `gfx`, `audio`, `ui` or `physics` packages, plus cmake and the SDL development libraries;
- standard-library networking or a subprocess API, which would remove the two most common sidecars;
- a `wasm32` target or a way to run `thread_fn` under the in-process backend;
- a TLS library with bounded memory, or an async I/O layer that fits the data-stack model;
- a real audio device in CI, which would make the capture path testable end to end.

Until then, the honest position is the one this repository already supports: **single-purpose, bounded, soft-realtime Linux tools with a small C edge** — and not a general application platform.

## 8. Related documents

- [Heap-less application design with Goose](heap-less-app-guide.md): the category-by-category analysis and the language model behind this assessment.
- [Verified Goose examples](examples/README.md): the seven programs and their expected output.
- [Project README](../README.md): the four root programs, the visualizer, and the pixi tasks.
