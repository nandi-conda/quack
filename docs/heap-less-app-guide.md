# Heap-less application design with Goose

*Which applications fit a language with no heap allocator, no garbage collector, and no per-object lifetime — and which do not.*

This guide is about **Goose** (the compiler packaged as `goose` `2026.3.post100` in prefix.dev's `nandi-testing` channel), not the Go language and not the "goose" AI agent. It assumes you have read enough Goose to recognize a `struct`, a slice, and a `thread_fn`.

Two definitions matter for everything below:

- **Heap-less** here means what Goose actually does: dynamic memory exists, but it lives on compiler-managed **data stacks** and is released when its scope ends. There is no `malloc`, no free list, no garbage collector, no reference counting, and no destructors.
- **No allocator** does not mean "no dynamic data" or "only fixed-size arrays". It means there is no general-purpose allocator and no per-object lifetime: a request, a frame, a file, or a connection is the unit of allocation, and the unit of release is a closing brace.

That distinction is the whole design story. A Goose program has an unbounded *shape* of dynamic data (arrays grow, strings concatenate, trees link) but a bounded *amount* per live scope: each stack's reservation is a compile-time constant (2 GB by default, settable with `--stack-reserve`), and exceeding it is a clean abort rather than more growth. Application categories differ in how naturally they map their work onto scopes.

```goose
// A data stack in practice: growth is a pointer bump, release is one store.
for round in 3 {
    var scratch: u8[>..] = [];
    for i in 100000 { scratch.push((i % 256) as! u8); }
    print("round ", round, ": ", scratch.len, " bytes");
}   // the free: the stack top goes back to where it was
```

## 1. Executive summary

**Strong fits** — workloads made of independent units (requests, packets, frames, files, records) whose state can die at the end of the unit, with bounded per-unit size:

- network data planes: TCP/HTTP proxies, L4/L7 load balancers, gateways, DNS servers, protocol translators, caches
- realtime audio/DSP and visualisation, game and simulation loops, sensor acquisition, telemetry aggregation
- CLI tools, build tooling, compilers, parsers, serializers, linters, code generators
- storage engines and embedded databases: WAL readers, columnar scans, index builders, snapshot/restore
- sandboxes for untrusted *data or bytecode*: rule engines, filters, protocol codecs, plugin VMs
- security-sensitive parsers and auditors that benefit from memory safety plus bounded memory
- multi-tenant services where a worker per tenant and bounded queues give structural isolation

**Poor fits** — workloads whose live state is an unbounded, irregularly shaped, long-lived object graph, or that depend on dynamic loading and a large runtime ecosystem:

- application backends with ORM/session/document state of unbounded cardinality
- dynamic plugin systems that must load new Goose code at runtime
- protocols that require unbounded buffering or per-subscriber queues chosen at runtime
- deep recursion that needs growable scratch per frame
- hard realtime with a required worst-case execution time (WCET) certificate
- bare-metal MCUs without an MMU and a POSIX-like OS layer
- teams that need today's networking/TLS/database ecosystem without writing C shims

**Three caveats up front** (all expanded later):

1. The heap-less guarantee stops at the FFI boundary. A C library you call can allocate; Goose cannot bound its memory.
2. "No GC pauses" is not "no latency spikes". First-touch page faults, the OS scheduler, and `trim_memory` still cost time.
3. The packaged compiler is `linux-64` only and its standard library has **no networking or subprocess API in v1**. Sockets and `fork` come from `extern fn` declarations and a small C file.

## 2. The memory model in one page

Goose has three places for data:

| Where | What lives there | Freed by |
| --- | --- | --- |
| Registers / native call stack | fixed-size locals, scalars, small structs | returning from the function |
| Static data | string literals, compile-time constants, globals | never (program exit) |
| **N data stacks** | every variable-size or resizable value: arrays, strings, structs with variable fields | the closing brace of the owning scope, in one store |

A data stack is a large address-space reservation with a bump pointer. `N` is the maximum number of resizable values that are live at the same time, computed once at compile time. Three growable arrays alive at once get three stacks; a stack is reused as soon as its scope ends. You never write a stack annotation — the language has no syntax for stacks.

The rules that follow, and that shape every application decision:

- **One resizable value per stack, always on top.** Growth is a pointer bump with no capacity check, and nothing ever moves.
- **Freeing is O(1) regardless of size.** A structure with a million elements costs one store to release, including everything nested in it.
- **Values are built in place.** `items.push(parse(line))` writes the parsed record directly into the array; returning a growable array by value does not copy it.
- **Records are inline and packed.** A record with variable-size fields is a contiguous run of bytes with no pointers; a string, an array of strings, and a record holding both are each one block.
- **Links can be narrower than pointers.** `T&<u32>` is a 1/2/4-byte self-relative offset; structures built from them are position-independent, so save = write bytes, load = read bytes plus a verification pass.
- **Memory safety is unconditional.** Every index is bounds-checked (and the compiler elides checks it can prove), every reference has a static root, and there is no `unsafe`. The other aborts — division by zero, capacity overflow, relative-offset overflow, failed `assert`, data-stack exhaustion — are clean aborts with a message.
- **Threads share no memory.** A `thread_fn` is compiled as a separate program with its own data stacks and its own copies of globals. Values cross through typed queues as *flat* values (no references or slices at any depth), by `memcpy`. There are no locks, atomics, or memory orderings.
- **The world is closed at compile time.** Whole-program compilation, no separate compilation, no shared libraries of Goose code, no function pointers, no escaping closures, no dynamic dispatch beyond enum tags.

Those last two bullets decide several categories by themselves.

### What the model buys, mechanically

| Property | Mechanism | Consequence for an application |
| --- | --- | --- |
| No collector | no GC threads, no write barriers, no finalizers | no stop-the-world or incremental GC pause; no collector CPU tax |
| No allocator | bump pointer per stack | no `malloc` lock contention, no fragmentation, no free-list walk |
| Scope = lifetime | top reset at scope exit | per-request teardown cost independent of request size |
| Memory never moves | bump growth in place | references stay valid across millions of pushes; no reallocation copies |
| Inline records | packed, pointer-free layout | fewer cache misses, less memory traffic, less memory per record |
| Relative links | 1–4 byte offsets | compact graphs; position-independent snapshots; verified loads |
| Checked memory | bounds checks, static roots, no `unsafe` | hostile input cannot become a wild pointer; parser bugs abort, not corrupt |
| Share-nothing workers | separate programs, typed queues | no data races or lock contention; a contained worker's abort is recoverable |
| Closed world | whole-program compile | no dynamic dispatch or runtime type info; small binaries; dead code removed |
| Emits C | one C file per program | cross-compiles with any C toolchain; calls C and is called from C |

## 3. Why heap-less matters: latency, capacity, and trust

### 3.1 Latency

Without a heap there is no allocation latency, no collection pause, no finalizer, and no allocator lock shared between threads. In a request or frame loop, the remaining latency sources are the program's own work, first-touch page faults on newly grown stack pages, and the operating system.

Measured on this machine with the packaged compiler, native `-O2` builds, on a shared VM (illustrative, not a benchmark suite):

| Workload | Result |
| --- | --- |
| Parse + route + format one request line, 200k iterations | p50 70 ns, p99 110–120 ns, p999 130–150 ns, max 28–58 µs |
| 1024-point real FFT + 1024-sample synthesis + 64 magnitudes, 300 frames | p50 42–44 µs, p99 80–120 µs, max 110–270 µs |

The p50-to-p999 spread is about 2×. The rare multi-microsecond maximum is the OS (scheduler, page fault, interrupt), not a collector: there is no collector to have a maximum. That shape — a tight body with rare OS outliers — is what makes heap-less code attractive for tail-sensitive work.

What heap-less does **not** remove, and what a latency budget must still include:

- **First-touch page faults.** Growing a data stack commits pages; the kernel zeroes them, and the fault takes the process's `mmap` lock. A frame that touches a new 1 MB buffer pays for 256 pages. Reuse avoids the cost after warm-up; `trim_memory` brings it back.
- **Kernel scheduling and interrupts.** No collector means no collector pause, not no preemption.
- **Syscalls and blocking inside `extern fn`.** A read, write, or TLS handshake is as slow as the OS and the library make it.
- **No allocator contention, but still kernel contention.** Removing user-space `malloc` removes one source of cross-thread serialisation; page faults and syscalls can still contend in the kernel.

That is why the practical rule for latency-sensitive code is: preallocate, pre-touch, keep the hot path free of I/O and FFI, and measure on the target.

### 3.2 Capacity

Because release is a scope exit, steady-state memory is a **high-water mark of concurrently live scopes**, not a cumulative allocation total.

| Measurement | Result |
| --- | --- |
| Same request-loop binary, 2 MB input vs 115 MB input (73k vs 4M requests) | **11 MiB peak RSS in both cases** |
| Heap-less HTTP server, 20,000 sequential connections | **1.8 MiB peak RSS**, 4.2 GiB peak virtual size |
| Empty program that sleeps | 1.9 MiB RSS, 4.1 GiB virtual size (2 data stacks × 2 GB reservation) |
| Same program with `--stack-reserve 64M` | 1.9 MiB RSS, 136 MiB virtual size |

The virtual-size figure surprises people. Each data stack *reserves* 2 GB of address space by default and commits only what it touches. On 64-bit Linux that is cheap; in a container with `RLIMIT_AS`, a strict overcommit policy, or a 32-bit target it is not. `--stack-reserve` (minimum 64 KB) is the knob, and the runtime halves a reservation the platform refuses, down to 1 MB.

The other side of the same coin: exhaustion is a **hard abort**, not a slow path.

```text
goose runtime error: data stack overflow: a value on main's data stacks grew past
the 64 KB reserved for it; --stack-reserve or -DGS_STACK_RESERVE raises the
reservation, up to 256 TB
```

Capacity planning is therefore explicit: `goose --stacks program.goose` reports each function's stack count and the thread cap; `-DGS_STACK_STATS=1` reports actual use at exit; `os.trim_memory()` returns unused pages to the OS after a large workload.

### 3.3 Trust

Memory safety without `unsafe` changes what a bug in a parser can do. Malformed input yields a bounds check, a failed `assert`, or a clean abort — not a wild write or a use-after-free. There is no allocator metadata to corrupt and no freed object to reuse. For code that faces hostile bytes (network protocols, file formats, rule engines), that removes an entire exploit class.

Two limits on that claim:

- It applies to Goose code. Whatever a C library does behind an `extern fn` is C's problem.
- Safety is not integrity. `from_bytes` verifies that an image is *well formed* (framing, tags, lengths, links); it does not verify that the bytes are the ones you wrote. Checksums and authentication are the program's job.


## 4. Category guide

The table is a map; the subsections explain the reasons and the friction.

| Category | Fit | Reason it fits | Main friction |
| --- | --- | --- | --- |
| Network proxies / load balancers / gateways | Strong | per-connection scope, bounded buffers, no GC tail, memory safety on hostile bytes | sockets, epoll, TLS via C shim; no async; one queue per type |
| DNS / cache servers | Strong | per-packet scope, flat records, bounded memory under flood, fast lookups | UDP/DNS wire framing via C shim; no stdlib networking |
| Realtime audio / DSP / visualisation | Strong | no GC or allocator in the hot path, per-frame scratch, fixed buffers | audio/gfx packages not in this build; callback thread rules; no WCET |
| Game / simulation loops | Strong | fixed-step budget, entity pools, byte-identical snapshots | FP determinism across builds; gfx package not in this build |
| Sensor / telemetry acquisition | Strong | bounded ring buffers, monotonic clock, no allocation per sample | no RTOS integration; OS jitter; flush policy |
| Protocol gateways / translators | Strong | per-message scope, safe parsers, bounded queues | blocking I/O; C shim per transport |
| CLI / build tooling | Strong | peak RSS = largest file, 0.65 ms startup, single binary | no subprocess API in v1; whole-program build per tool |
| Compilers / parsers / serializers | Strong | zero-copy slices, built-in-place records, verified images | variable-size arrays not indexable; recursion restrictions |
| Databases / storage engines / caches | Good | inline rows, narrow links, snapshot/verify, O(1) reset | no mmap/async I/O/locking in stdlib; single writer; eviction is yours |
| Sandboxes for untrusted logic | Good (data/bytecode) | verified interpreter, fixed stack, no allocator to exhaust, memory safety | you write the VM; no dynamic Goose plugins; no wasm target today |
| Security-sensitive services / audit | Good | no `unsafe`, bounded memory, whole-program review | no crypto/TLS in stdlib; no constant-time guarantees; abort = availability risk |
| Multi-tenant isolation | Conditional | one worker per tenant, share-nothing, bounded queues | coarse accounting; one queue per type; worker count capped by address space |
| Dynamic app backends, editors, unbounded graphs | Poor | — | per-object lifetimes, unbounded cardinality, ecosystem |

### 4.1 Network proxies, load balancers, gateways, DNS

**Fit signature.** A stream of independent messages, each with a bounded size; per-message work that is CPU-light (parse, route, rewrite, forward); state that is either per-connection or a small routing/health table.

**Why heap-less matters.**

- Per-connection memory is a high-water mark. With bounded queues and buffers, a proxy under a connection flood reaches a plateau and refuses work instead of growing until the OOM killer acts.
- Teardown cost is one store per connection, no matter how much was parsed.
- There is no collector to pause the data plane, and no allocator lock to serialise worker threads. On a many-core box, the usual allocator contention between request threads disappears because there is no allocator.
- The bytes are hostile. Bounds checks and no-`unsafe` turn parser bugs into aborts, which a supervisor can contain (`thread_spawn_contained`) instead of a memory-corruption incident.

**Goose shape.** One scope per connection or per request; fixed request buffer; a routing table that is built once and only read afterwards; workers own disjoint connection sets; queues carry flat events between stages. A verified example (`docs/examples/minihttp.goose` plus a small `net.c` shim) accepts TCP connections and serves them with 1.8 MiB RSS:

```goose
struct Reply { status: u8[..16], body: u8[..64] }

fn route(method: u8[:], path: u8[:]) -> Reply {
    if method == "GET" && path == "/healthz" { return Reply { "200 OK", "ok" }; }
    if method == "GET" && starts_with(path, "/api/items/") { return Reply { "200 OK", "{\"item\":1}" }; }
    return Reply { "404 Not Found", "no such route" };
}

// One connection: request bytes, fields and response die at the closing brace.
fn serve(fd: i64) {
    var req: u8[..8192] = [0; 8192];
    let n = gs_read(fd, req[0], req.len);
    if n <= 0 { return; }
    let text = req[..n];
    let line_end = find(text, "\r\n");
    if line_end < 0 { return; }
    let line = text[..line_end];
    let sp1 = find(line, " ");
    if sp1 < 0 { return; }
    let sp2 = find(line[sp1 + 1..], " ");
    if sp2 < 0 { return; }
    let rep = route(line[..sp1], line[sp1 + 1..sp1 + 1 + sp2]);

    var out: u8[>..] = [];
    out.append("HTTP/1.1 "); out.append(rep.status); out.append("\r\n");
    out.append("Content-Length: "); format(out, rep.body.len); out.append("\r\n");
    out.append("Connection: close\r\n\r\n");
    out.append(rep.body);
    var sent = 0;
    while sent < out.len {
        let w = gs_write(fd, out[sent], out.len - sent);
        if w <= 0 { return; }
        sent += w;
    }
}
```

The other side is a sidecar (`minihttp.build`) naming the C, and declarations that match C's ABI:

```goose
extern fn gs_listen(port: i32, backlog: i32) -> i64;
extern fn gs_accept(fd: i64) -> i64;
extern fn gs_read(fd: i64, buf: u8&, cap: i64) -> i64;      // uint8_t *
extern fn gs_write(fd: i64, buf: const u8&, len: i64) -> i64;
extern fn gs_close(fd: i64) -> i64;
```

**Constraints and trade-offs.**

- **Networking is not in the standard library (v1).** You supply sockets, `accept`, `read`/`write`, `epoll`, `sendfile`, and TLS through `extern fn` and a C file, or through an `extern "lib"` block that loads an existing shared library. The docs are explicit: subprocesses and networking "arrive as extern fns when a program needs them".
- **No async/await and no event loop in-language.** A blocking `accept` loop plus one connection at a time is simple but serial. For concurrency you either put an `epoll` loop in the C shim and hand ready fds to workers, or run N worker threads, each owning its own connections. File descriptors are just `i64`, so they can cross a typed queue.
- **One queue per message type.** `qput`/`qget` are selected by type, not by connection or tenant. A dynamic set of per-connection queues is not expressible; the topology is static.
- **`qput` never blocks.** When a bounded queue is full it returns `false`, and an ignored return value drops the message. That is a fine drop policy for metrics, and a bug for request payloads. The verified `fanout` example shows the shape: 200k offered jobs, 2,056 accepted, 197,944 refused, because 1,024-slot queues impose admission control.
- **TLS and HTTP/2 libraries allocate.** The heap-less guarantee stops at their API. Your RSS becomes a function of their behaviour plus your bounded buffers.
- **Address space.** Each data stack reserves 2 GB by default; a proxy process with several live stacks plus workers can show tens of GB of VSZ. Set `--stack-reserve` deliberately in containers and on 32-bit targets.

**Verdict.** A strong fit for a data plane you control end to end, especially on Linux with a small C shim. A weak fit if you need a batteries-included HTTP/TLS stack today.

### 4.2 Realtime: audio, DSP, visualisation, simulation, acquisition, fan-out

This is the category where heap-less matters most directly, and where the caveats are most often glossed over. "No GC" is necessary but not sufficient for realtime.

**Fit signature.** A periodic loop with a fixed period (a 64-sample audio block, a 16.7 ms video frame, a 1 kHz control tick); bounded work per iteration; buffers whose maximum size is known; a tolerance for dropping late frames but not for long pauses.

**Why heap-less matters.**

- There is no collector competing for CPU, no stop-the-world pause, no finalizer, and no allocation in the callback path. The per-iteration cost is the code you wrote.
- Scratch buffers become free at the end of each iteration, so the loop reuses warm pages instead of allocating per frame. Reuse is also the low-jitter choice: `trim_memory` would hand pages back, and the next frame pays page faults again.
- Workers share no memory, so there is no lock to inherit priority or cause unbounded blocking. The only cross-thread path is a typed queue with a fixed limit.
- Snapshots and replay are byte-oriented. Self-relative links make structures position-independent, so a simulation state can be written and verified without pointer fixups.

**The frame contract.** Every realtime Goose program in this category has the same four rules:

1. **Size everything at startup.** Arrays, FFT twiddles, windows, ring buffers, maximum message size. The hot path contains no `push` whose count depends on input, no growth, and no `str`.
2. **One scope per frame.** Anything a frame needs is a local of the frame function; anything shared across frames is a global fixed array or a reusable pool.
3. **Bound the work.** A frame with a data-dependent loop (parsing, variable-size FFT, number of voices) needs an explicit budget and a documented drop or degrade policy.
4. **Bound the queues.** `qlimit<T>(n)` and a drain-to-newest policy on the consumer side; never an unbounded backlog between capture and render.

A verified 1024-point FFT frame loop (`docs/examples/audio-frame-loop.goose`) runs in 42–44 µs p50 native, against a 21 ms audio block at 48 kHz:

```goose
const N = 1024; const HALF = 512; const BINS = 64;
var re: f32[N] = [0.0; N];      // all buffers live in globals,
var im: f32[N] = [0.0; N];      // sized once, reused every frame
var window: f32[N] = [0.0; N];
var twr: f32[HALF] = [0.0; HALF];
var twi: f32[HALF] = [0.0; HALF];
var mag: f32[BINS] = [0.0; BINS];
var phase: f32 = 0.0;

fn frame() -> i64 {
    for i in N {                                  // "capture" + window
        let t = phase + i * 0.031;
        re[i] = (sin(t as f64) as f32) * 0.6 + (sin((t * 1.7) as f64) as f32) * 0.3;
        re[i] *= window[i];
        im[i] = 0.0;
    }
    phase += 0.05;
    fft();                                        // in-place, fixed scratch
    var peak_bin = 0;
    var peak: f32 = 0.0;
    for b in BINS {
        let v = sqrt(re[b] * re[b] + im[b] * im[b]);
        mag[b] = v;
        if v > peak { peak = v; peak_bin = b; }
    }
    return peak_bin;                              // renderer reads mag[] in place
}
```

**Audio and MIDI specifics.**

- **Device callbacks versus Goose threads.** A C audio driver calls *you* on its own thread. Goose's exported functions are explicitly **not thread-safe** and must be called from the thread that called `goose_init`. So do not hand a Goose `export fn` to an audio callback. The workable shape is: the C shim owns the callback and writes samples into a lock-free ring buffer (or SDL's audio stream queue); Goose drains that ring from its own frame loop with an `extern fn`. Alternatively make the audio device the owner and pull blocks from C each frame.
- **Block budget.** 48 kHz × 64 samples = 1.33 ms; × 256 = 5.3 ms. The FFT above (1024 samples ≈ 21 ms of audio) leaves large headroom, but the synthesis and rendering must fit the *display* period, not the audio period, unless they run in the callback.
- **No allocation in the callback is not enough.** A first-touch page fault inside the callback is still a dropout. Pre-touch buffers during setup (write one byte per page), or make the buffers globals so they are committed at startup.
- **MIDI** is a byte stream: parse messages into a fixed event array per block, then apply them to fixed voice structs. No per-note allocation.
- **Denormals and FP flags** are the C compiler's business; Goose does not set fast-math. If your DSP depends on flushing denormals, do it explicitly.

**The visualizer instance (live capture → FFT → render).** A concrete, current example: a realtime audio visualizer. The architecture that fits Goose:

```
[C audio callback] --ring buffer--> [Goose frame loop]
                                     drain -> window -> FFT -> magnitudes
                                     -> renderer (gfx/SDL via extern)
```

- Capture and analysis are one stage if the renderer is fast enough; then the whole visualizer is a single-threaded frame loop with no queue at all. This is the simplest and lowest-jitter design.
- If capture must be independent (e.g. it blocks on a device), put it in a `thread_fn` that owns the device and sends a **flat** `Spectrum` struct (a fixed `f32[64]`) through a queue with `qlimit<Spectrum>(2)`. The UI drains to the newest frame and drops the rest:

```goose
struct Spectrum { bins: f32[64] }

fn newest(out: Spectrum&) -> bool {
    var got = false;
    loop {
        let next, ok = qpoll<Spectrum>();
        if !ok { return got; }
        out = next;          // copy the flat frame into the caller's buffer
        got = true;
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
    print("rendered ", frames, " of 200 ticks");
}
```

Verified output: `rendered 199 of 200 ticks`. Two slots plus a drain-to-newest consumer means the visualizer always draws the freshest frame the producer managed to enqueue, and a slow renderer never accumulates a backlog.

- The renderer should read the magnitude buffer in place and finish before the next frame overwrites it (single-threaded), or own a double buffer. There is no shared GPU buffer with the producer unless both live in the same program; workers are separate programs with separate memory.
- **Graphics and audio packages are not in this conda build.** The `nandi-testing` package ships 12 core modules (`std`, `os`, `math`, `json`, `csv`, `regex`, `binary`, `base64`, `dictionary`, `vec`, `ffi`, `exception`). The `gfx`, `audio`, `ui`, and `physics` packages described in the docs are separate and are compiled into the official release archives, not this package. For this build, SDL3 comes through `extern "SDL3" { ... }` (a shared-library block), or you ship the packages' C.

**Game and simulation loops.**

- Fixed timestep: accumulate real time, run N fixed steps, render once. Each step's scratch dies at the step's closing brace.
- Entity storage: one grow-only array per entity type plus a free list in a reusable pool. Handles are `u32` indices with a generation counter, so a stale handle is detected instead of silently reading a reused slot (Goose makes stale-slot reads safe but not correct).
- Snapshots: self-relative links plus `to_bytes`/`from_bytes` give replayable state that loads with verification. Caveat: floating-point contraction and library differences mean bit-identical replay is realistic **within one build and platform**, not across compilers.
- Rendering: the gfx package is outside this build; a FFI path to SDL3 or a custom renderer is the alternative.

**Sensor and telemetry acquisition.**

- A ring buffer of fixed-size samples, filled by a C shim that timestamps at capture (`clock_ns` is monotonic), drained and batched by Goose.
- Bounded batch buffers, atomic file append (`write_file_atomic` for snapshots, `append_file` for logs), and an explicit policy for what to drop when the disk or network is slower than the sensor.
- No allocation per sample means the acquisition loop's cost is independent of uptime.

**Protocol gateways and live fan-out.**

- Translating between two protocols (Modbus ↔ MQTT, binary ↔ JSON, serial ↔ TCP) is per-message work with bounded buffers: a strong fit.
- **Live fan-out to a dynamic audience is not a fit** for Goose's queue model. Queues are per *type*, not per subscriber, and a message is consumed by one receiver. Broadcasting to N subscribers chosen at runtime needs a C event loop with per-subscriber buffers, or a statically declared set of channel types (one struct per channel). State this in the design before choosing Goose.

**What does not fit: hard realtime.**

Goose gives you **no WCET, no scheduling control, no priorities, no interrupts, and no RTOS integration**. A heap-less program removes collector and allocator pauses; it does not remove:

- page faults on first touch of a new stack page (bounded only by your `--stack-reserve` and your warm-up)
- kernel scheduling delay, IRQ handling, SMT and cache interference
- blocking libc calls inside your `extern fn`s
- `abort` on overflow, failed `assert`, or data-stack exhaustion — a stopped process, not a missed deadline

For a hard deadline you need an RTOS or PREEMPT_RT, a measured worst case, and memory locked and pre-faulted. Goose can be the DSP or control logic inside such a task, with all buffers preallocated, no FFI in the hot path, and `--stack-reserve` set so exhaustion is impossible by construction. Without that engineering, call it **soft realtime**: excellent jitter in practice, no guarantee on paper.

**Realtime checklist.**

- [ ] every hot-path buffer is fixed-size and allocated before the loop
- [ ] no `push` with an input-dependent count in the hot path
- [ ] no `str`/`format` per sample or per frame (format into a pre-sized buffer if you must)
- [ ] `--stacks` and `-DGS_STACK_STATS=1` used to size reserves; `--stack-reserve` set deliberately
- [ ] buffers pre-touched, `trim_memory` kept out of the loop
- [ ] audio callback owns its ring in C; no Goose `export fn` on a foreign thread
- [ ] queues bounded, consumer drains to newest, drop policy documented
- [ ] worst-case per-frame work measured, not assumed
- [ ] abort policy decided (contained worker, supervisor restart, or fail the process)

### 4.3 Edge, appliance, and embedded services

**Fit signature.** A Linux-class device (gateway, router, kiosk, camera, PLC-adjacent box, set-top) with a fixed memory budget, no package manager at runtime, and a long unattended lifetime.

**Why heap-less matters.** No collector means no heap growth over months; no allocator means no fragmentation over millions of events; a high-water memory profile can be validated on the bench and expected in the field. Single static-ish binary, small startup cost, and memory safety on whatever the device's network port receives.

**Constraints.**

- "Embedded" here means **Linux/Windows/macOS-class**, not bare metal. The runtime needs an OS layer for address-space reservation (`mmap`/`VirtualAlloc`), threads with TLS, files, and stdio. A Cortex-M with no MMU is a porting project, not a flag.
- The conda package is `linux-64` only. The compiler emits C, so other targets are a cross-compile of the generated C with the vendor toolchain, provided the runtime's OS layer has a port.
- The default 2 GB reservation per data stack is virtual, but a device with strict overcommit or a 32-bit address space needs `--stack-reserve` (down to 64 KB). The runtime halves a refused reservation, but the compiler's assumptions and your sizing should be explicit.
- Stack exhaustion is a clean abort. Size reserves from `--stacks` and `GS_STACK_STATS`, and decide whether a supervisor restarts the process.

**Verdict.** Strong for appliances and edge gateways with a Linux BSP; poor for MCUs and bare-metal firmware today.

### 4.4 CLI tools and build tooling

**Fit signature.** Short-lived processes over a bounded input (a file, a directory tree, a stream), where peak memory should track the largest item rather than the total.

**Why heap-less matters.**

- Peak RSS is a property of the largest file/record, not of how many were processed: verified 11 MiB peak on both 2 MB and 115 MB inputs for the same streaming loop.
- No warm-up, no collector, 70 KB binaries, ~0.65 ms per exec on this machine (including fork/exec from Python). Startup-sensitive tools (shell prompts, formatters, git hooks) feel fast.
- Text processing is byte-slice based: `split` returns views into the input, `csv::each_record` passes field slices without copying, `json::parse` builds a node tree in one array plus a decoded-text buffer.

**Constraints.**

- **No subprocess API in v1.** A build tool that runs `cc` needs `extern fn fork/exec/posix_spawn/waitpid` and a C shim; the same for `popen`.
- **Whole-program compilation.** One binary per tool, no dynamic plugins; a plugin architecture must be an interpreted data format.
- Resource accounting is per scope: if the tool must hold all results (e.g. sorting), memory grows with the input — by design, and visibly in the type.
- UTF-8 is bytes; there is no Unicode case folding or grapheme library. Keep text handling byte-oriented or call a C library.

**Verdict.** One of the best fits, especially for compilers, formatters, linters, code generators, and data converters. The subprocess gap is a small, well-contained C shim.

### 4.5 Compilers, parsers, serializers

**Fit signature.** A bounded input document, a tree or table built from it, and a pass structure where each phase's scratch dies at the phase boundary.

**Why heap-less matters.**

- Every token is a slice into the input (zero copy); every record is built directly in its destination (no temporary tree node per reduction).
- Peak memory is proportional to the *result*, not to allocation churn. No collector work during parsing, so parse time scales with bytes, not with live objects.
- `from_bytes` turns an untrusted file into a verified in-memory structure with no pointer fixups: a natural fit for caches, indexes, and save files.
- The compiled output is one C file per program, so a Goose-based compiler integrates with existing C build systems.

**Constraints.**

- Arrays of variable-size elements can be iterated but not indexed. You choose compact-and-sequential or indexable-with-an-index-array. ASTs with parent pointers need relative refs or an index array.
- Recursive functions cannot keep growable data across a recursive call. Recursive-descent parsers must keep their state in the entry function (or a struct of references to its locals) and pass scratch in. The docs call this out as the main structural change.
- No escaping closures or function pointers; generics and function blocks cover most combinator-style code, monomorphised and inlined.
- Error handling across frames uses `return err from load`, which keeps intermediate signatures plain but requires the call graph to be statically inside a handler.

**Verdict.** Strong. This is close to the language's home turf.

### 4.6 Databases, storage engines, caches

**Fit signature.** Rows or keys of bounded size, indexes built once or in batches, scans over files or memory maps, snapshots that must load safely.

**Why heap-less matters.**

- A row is a contiguous record; a table is one array, so a scan streams through cache instead of chasing pointers.
- Relative links make compact on-disk structures (a 12-byte BST node including two links) and position-independent images: `to_bytes` writes, `from_bytes` verifies and loads. No serializer, no schema, no pointer fixups.
- Freeing a whole table or index is one store; dropping a database at shutdown is constant-time.
- The standard `dictionary` is an open-addressing table over a grow-shrink array, with no per-entry allocation: good for in-memory indexes and routing tables.

**Constraints.**

- `mmap`, `pread`/`pwrite`, file locking, `fsync` policy, and `io_uring` are not in the stdlib; `os` gives whole-file read/write, append, atomic replace, and directory listing. Serious storage work starts with a C shim.
- No async I/O and no background compaction thread with shared state. Concurrency is partition-by-worker with flat messages, or one writer plus readers in separate processes.
- Eviction and free-space management are yours. A reusable pool gives O(1) alloc/free, but reusing a slot while a stale handle exists is a logic bug (safe, not correct); generation counters are the fix.
- Arrays of `varint` records are sequential, not indexable; keep a second array of offsets or references.
- `from_bytes` verifies safety, not integrity: add checksums or signatures where corruption matters.

**Verdict.** Good fit for embedded engines, readers, index builders, and snapshot formats; conditional for a general-purpose multi-writer database.

### 4.7 Sandboxing untrusted logic (including the WASM/plugin question)

**Fit signature.** A host that must run *someone else's logic* with hard bounds on memory and time: policy rules, filters, expression evaluators, smart-contract-like state machines, plugin bytecode, protocol codecs.

**Why heap-less matters.**

- There is no allocator for untrusted code to exhaust, no heap metadata to corrupt, and no `unsafe` to escape through.
- A verifier can reject bad code before it runs; a fixed stack and a step budget bound the rest. Memory safety is a language property, so a bug in the interpreter cannot become a wild write.
- Deterministic data layout and byte-identical snapshots make auditable decisions reproducible.

A verified example (`docs/examples/rule-vm.goose`, about 150 lines) is a rule VM: it verifies opcodes, immediates, branch targets, instruction boundaries, stack depth, and a maximum depth of 64 before executing, then runs with a fixed `i64[64]` stack and a step budget. Forward-only branches make termination a static property. Hostile bytecode is rejected with a reason:

```text
max(41, 7) = 41
rejected: branch into data at 12
```

**The WASM and plugin reality check.**

- **Goose does not currently ship a `wasm32` target.** The compiler emits C, so a WASI build is a porting project (the runtime needs address-space reservation, TLS, stdio), not a compiler flag. Treat "Goose guest in a WASM sandbox" as a direction, not a verified capability of `2026.3.post100`.
- **There is no dynamic loading of Goose code.** Whole-program compilation, no shared libraries of Goose, no function pointers. A plugin system whose plugins are Goose source is not expressible.
- **`extern "lib" { ... }` loads native shared libraries**, which is the opposite of a sandbox: it is trusted native code with full process privileges.
- **`export fn` embeds Goose in a C/C++/Rust host**: one statically linked Goose program, called from the host thread. That is a good way to ship a verified policy engine inside a larger product, but it is not per-plugin isolation.
- Where Goose *is* a sandbox today: untrusted **data and bytecode**, interpreted by verified Goose code. That covers rule engines, filters, packet classifiers, and configuration languages.

**Verdict.** Strong for data/bytecode sandboxes; not a fit for dynamically loaded native plugins or arbitrary-code isolation.

### 4.8 Security-sensitive services and audit

**Fit signature.** Parsers for hostile input, authorization gateways, token/certificate handling, log scrubbers, audit pipelines, anything where memory corruption is the threat model.

**Why heap-less matters.** No `unsafe`, no use-after-free, no double-free, no heap overflow, no allocator metadata to overwrite. Memory is bounded, so OOM-based denial of service is a capacity decision rather than an attacker-controlled outcome. Whole-program compilation means the reviewable artifact is one C file per program, with no dynamic dispatch to trace.

**Constraints.**

- No crypto or TLS in the stdlib. Use vetted C libraries through `extern fn`; their internal allocations are outside the guarantee.
- The language does not promise constant-time code. Do not write crypto primitives in Goose unless you can verify the generated code and the compiler's optimisations.
- `abort` is fail-closed but is also an availability event. Decide per service whether a bad request aborts the process, a contained worker, or returns an error.
- The FFI boundary is trusted. A C shim with a length bug reintroduces the vulnerability class you left.

**Verdict.** Good fit, provided security-critical primitives stay in audited C and the abort policy is explicit.

### 4.9 Multi-tenant isolation and resource accounting

**Fit signature.** A small number of tenants, each with a worker or process, a known peak working set, and messages that are flat (IDs, counts, fixed-size records).

**Why heap-less matters.** Each worker is a separate program with its own data stacks and globals: one tenant cannot read or corrupt another's memory, and there is no shared heap to leak through. A contained worker's abort ends only that worker and reports a message. Memory accounting is structural: a worker's high-water mark is the sum of its stacks' high-water marks, which `GS_STACK_STATS` can report.

**Constraints.**

- Granularity is coarse: per-worker high-water, not per-request billing. If you need per-tenant quotas inside one worker, you implement accounting over fixed-capacity pools.
- The number of workers is capped by address space (`hardware_threads()` is clamped by the 32 TB budget / 2 GB per region ≈ 16k regions, minus what each worker needs). Thousands of tenants per process is not the design point; dozens to hundreds is.
- Queues are per type, not per tenant; messages need a tenant id and filtering, or a statically declared channel per tenant.
- There is no shared cache between workers. Duplicate it, or put it in one owner worker and route through queues (copying flat data).

**Verdict.** Conditional but useful: a natural fit for a handful of noisy neighbours that must not share a heap, not for a serverless platform with thousands of tenants per process.

### 4.10 Deterministic-latency and replayable workloads

**Fit signature.** Market-data and trading gateways, test harnesses, replay debuggers, deterministic simulations, consensus/state-machine steps, and audit pipelines where the *same input must produce the same output* and the per-unit work must not vary with collector or allocator history.

**Why heap-less matters.**

- There is no collector whose timing depends on heap shape, and no allocator whose address reuse depends on history. The work per unit is the code you wrote.
- Data layout is deterministic: hashes are fixed functions (no per-process hash seed, so dictionary iteration order for the same insertions is reproducible), records are packed, and there are no pointer values inside a serialized image.
- `to_bytes` / `from_bytes` give byte-identical state images that load with verification. Self-relative links mean an image is valid at any address, so replay does not depend on where it is mapped.
- Whole-program compilation means the exact code is the artifact you audited; no plugin or JIT changes the instruction stream at runtime.

**Constraints.**

- OS scheduling and thread interleaving are still nondeterministic. Workers with typed queues make the communication explicit, which helps, but it does not make a multi-threaded schedule reproducible. For strict replay, use one thread and feed events from a log.
- Floating-point contraction can differ across C compilers and optimisation levels. Bit-identical replay is realistic within one build; across compilers, pin the flags and verify.
- ASLR changes addresses, but addresses do not appear in relative-link images or in packed records. Determinism here is about *data*, not virtual addresses.
- Wall-clock timestamps (`time_ns`) are not reproducible; monotonic `clock_ns` differs per run. Capture timestamps as input, not as something the replay computes.
- A deterministic program can still miss a deadline. Determinism of output and determinism of latency are different claims.

**Verdict.** Strong, with the caveat that "deterministic" must be defined precisely: deterministic layout, bytes, and work per unit are language properties; deterministic scheduling is not.


## 5. Where heap-less is a poor fit

These are not edge cases to engineer around. They are shapes where the model fights the problem, and the honest answer is another language or a different architecture.

**1. Long-lived, irregular object graphs.** A document editor, a CAD model, a social graph, an ORM identity map, a session store with unbounded cardinality. These have per-object lifetimes that are not nested, sizes that are not bounded, and mutation patterns that reuse and discard individual nodes. Goose can express them with pools and relative links, but every edge becomes an index or offset and every free becomes manual. The stale-slot rule makes reuse a logic hazard rather than a memory-safety one; that is better, but it is still work the language will not do for you. *Instead:* a GC or ownership-based language for the object graph; keep Goose for the bounded, per-request part.

**2. Dynamically loaded plugins written in Goose.** Whole-program compilation means there is no separate compilation, no shared libraries of Goose code, and no function pointers. A plugin architecture whose plugins are Goose source does not exist. *Instead:* define plugins as data or bytecode interpreted by a verified VM (section 4.7), or load trusted native libraries with `extern "lib"` (not a sandbox).

**3. Unbounded buffering.** Accepting arbitrarily large uploads, buffering a slow consumer without limit, or supporting a protocol with an unbounded window requires memory proportional to the peer's behaviour. Goose gives you fixed reservations, grow-only arrays within a scope, and queues that refuse. *Instead:* stream with a bounded buffer and spool to disk; or put the unbounded buffer in a C library and accept that the guarantee ends there.

**4. Dynamic pub/sub and per-subscriber queues.** Queues are selected by message *type*, not by connection or subscriber; a message is consumed once. A live fan-out service with subscribers joining and leaving at runtime, each with its own backlog, is not expressible in the queue model. *Instead:* a C event loop with per-subscriber buffers; or a fixed, statically declared set of channels.

**5. Deep recursion with growable per-frame state.** Recursive functions cannot keep growable data across a recursive call. Recursive-descent parsers, tree walkers that build results per level, and divide-and-conquer algorithms need their scratch hoisted into the entry function or a pool. *Instead:* restructure with an explicit stack array (which is often better anyway), or use a language where each frame can allocate.

**6. Fine-grained lifetimes with high churn.** An LRU cache with arbitrary eviction, a connection pool with per-object state, a task graph where nodes complete out of order. A reusable pool gives O(1) alloc/free and generation tags catch stale handles, but eviction policy, compaction, and memory reuse become your code. If the churn is the workload, a GC or a real allocator is doing valuable work for you.

**7. The ecosystem-dependent backend.** HTTP frameworks, TLS, OAuth, gRPC, database drivers, message queues, observability SDKs, schema validation. Every one of these is a C (or C-ABI) library with its own allocator and its own threading. You can call them, but the heap-less property applies only to the Goose code between calls; RSS and tail latency are then dominated by the library. *Instead:* use Goose for a bounded component (a parser, a policy engine, a data plane shim) inside a larger service, not for the whole service.

**8. Teams that need maturity and hiring today.** The compiler is about thirty thousand lines of C++, the language is new, the standard library is small, the package in this channel is `linux-64` only, and v1 has deliberate omissions (no moves for resizable values, one resizable per struct, no labeled `break`, no namespace privacy, no subprocesses or networking). That is a real adoption cost, independent of the memory model.

**9. Bare-metal and no-MMU targets.** The runtime reserves address space for data stacks and relies on an OS layer (mmap/VirtualAlloc, threads with TLS, stdio). A Cortex-M-class device is a porting project. *Instead:* C or Rust on the MCU, with Goose on the gateway.

**10. Hard realtime with a WCET requirement.** No collector is not a worst-case bound. Page faults, syscalls, libc locking, interrupts, and scheduling all remain. If a missed deadline is a safety failure, you need an RTOS/RT kernel, memory locking, and a measured worst case; Goose can be a component but cannot supply the certificate.

**11. 32-bit address spaces with default settings.** A 2 GB reservation per data stack does not fit a 32-bit process with several stacks. It is tunable (`--stack-reserve`, minimum 64 KB) and the runtime halves refused reservations, but this is a design constraint to plan for, not a detail.

If two or more of items 1–7 describe the core of your product, Goose is probably the wrong tool. If one describes a component and the rest of the product is bounded, per-unit work, it can be an excellent tool for that component.

## 6. Patterns that make heap-less natural

### 6.1 Make the scope the unit of work

Choose the scope first: a request, a packet, a frame, a file, a batch, a job. Everything that unit needs is a local of that scope; everything that outlives it is a global fixed array, a grow-only array that only grows at startup, or a reusable pool. The code then reads like the problem.

In `docs/examples/request-loop.goose`, the line, the parsed fields, the response, and the route lookup all die at the end of the loop body. Counters live outside. There is no explicit free anywhere.

### 6.2 Preallocate and reuse; keep allocation out of the hot path

Size buffers at startup, then refill them with `clear()` and `resize()`. A grow-only array keeps its capacity when cleared, so the loop reuses warm pages. `pending.clear(); read_file(p, pending);` is a full file read into the same buffer every iteration.

Caveat: static buffers move the cost from allocation to **first touch**. They do not bound the work per iteration, and they do not make a page fault free. Pre-touch large buffers during setup; keep `trim_memory` out of the loop.

### 6.3 Reusable pools with generation handles

When objects must outlive a scope and have independent lifetimes, use a grow-only slot array plus a free list. Since a pool slot is reused, a stale handle would read another object's data; a generation counter turns that into a detected error. Note that a struct can hold only one resizable field, so a pool is naturally two values passed together:

```goose
struct Slot { gen: u32, live: bool, value: i64 }

fn pool_alloc(slots: Slot[>..]&, free: i64[>..]&, v: i64) -> u64 {
    var idx = 0;
    if free.len > 0 {
        idx = free.pop();
    } else {
        idx = slots.len;
        slots.push(Slot { gen: 1, live: true, value: v });
        return (1 as u64 << 32) | (idx as u64);
    }
    slots[idx].live = true;
    slots[idx].value = v;
    slots[idx].gen++;                     // invalidates older handles
    return ((slots[idx].gen as u64) << 32) | (idx as u64);
}

fn pool_get(slots: Slot[>..]&, h: u64) -> i64, bool {
    let idx = (h & 0xffffffff) as i64;
    if idx >= slots.len { return 0, false; }
    let s = slots[idx];
    if !s.live || s.gen != (h >> 32) as u32 { return 0, false; }
    return s.value, true;
}
```

Verified: allocating three slots, freeing the middle one, reallocating it, then reading the old handle prints `stale: false 0` and `fresh: true 99`. The full version is `docs/examples/pool-generations.goose`.

### 6.4 Index arrays for variable-size records

A table of records with variable-size fields is compact and cache-friendly but sequential: you can iterate it, not index it. Keep a second array of indices (or references) beside it, and sort that. This is the documented idiom, and it is usually cheaper than making every record fixed-size.

### 6.5 Bound every queue and decide what "full" means

`qlimit<T>(n)` plus an explicit policy is the difference between a service that degrades and one that dies. Three policies are useful:

- **Refuse** (admission control): return `false` to the source; count it. Verified in `fanout.goose`: 200,000 offered, 2,056 accepted, 197,944 refused under a 1,024-slot limit.
- **Drop newest** (metrics, frames): call `qput` and ignore `false`; the consumer sees an older sample.
- **Drain to newest** (UI): `qpoll` until empty, keep the last value. Verified in `latest-wins.goose`: `rendered 199 of 200 ticks`.

There is no blocking `qput` and no queue per connection; design around that.

### 6.6 Partition, do not share

Replace shared state with worker partitions: each worker owns its connections, its tenant's data, or its shard. Messages are flat values (IDs, counts, fixed arrays), copied by `memcpy`. This removes locks and races by construction, and it makes memory accounting per worker. The cost is duplicated read-only state (each worker has its own copy of globals) and no shared cache.

### 6.7 Snapshot and verify instead of pointer graphs

For persistence, IPC, or plugin data, prefer a byte image over a live pointer graph. `to_bytes` writes a framed image; `from_bytes` verifies framing, tags, lengths, and links before the bytes become a value. Tampering with the framing is rejected:

```goose
struct Row { key: u32, hits: i64 }

fn main() {
    var rows: Row[>..] = [];
    for i in 5 { rows.push(Row { key: i as u32, hits: i * 10 }); }
    var img: u8[>..] = rows.to_bytes();
    var back, ok = from_bytes<Row[>..]>(img);
    print(ok, " ", back.len, " ", back[3].hits);   // true 5 30
    img[0] = 200;                                  // corrupt the framing
    var bad, bok = from_bytes<Row[>..]>(img);
    print(bok, " ", bad.len);                      // false 0
}
```

Remember: safety, not integrity. Add a checksum if the difference matters.

### 6.8 Put the OS at one boundary

Keep sockets, serial ports, audio devices, `mmap`, subprocesses, and TLS in one small C shim with a narrow, flat interface (`i64` handles, `u8&` buffers, `const u8[:]` slices). Everything above it is checked Goose. This is also the only place where "heap-less" stops being true, so it is the place to audit for allocation, blocking, and thread-safety.

### 6.9 Measure the budget, do not guess it

| Question | Tool |
| --- | --- |
| How many data stacks does each function need? | `goose --stacks prog.goose` (runs the program) |
| How much did each thread program actually use? | build with `-DGS_STACK_STATS=1` |
| How much address space does a stack reserve? | `--stack-reserve 64M`, then check `VmPeak` |
| Which bounds checks remain? | `--bce-lines` |
| What does the generated C look like? | `-o prog.c`, or `--standalone` for the whole runtime |
| Which C toolchain and GOOSE_HOME? | `goose toolchain` |

## 7. Decision checklist

Answer these before starting. Three or more "no" answers in the first eight mean the fit is weak.

1. Is the work made of **independent units** (request, packet, frame, file, record)?
2. Is the **maximum size of one unit** known and modest (kilobytes to a few megabytes)?
3. Can the unit's state **die at the end of the unit**, with long-lived state small and table-shaped?
4. Is **peak memory** allowed to be a high-water mark rather than a function of total work?
5. Is the **hot path free of external libraries** that allocate, or are you willing to accept their behaviour?
6. Do you control the **transport/OS boundary** enough to write a small C shim (or use an existing one)?
7. Is **soft realtime** enough, or do you have a separate plan for hard deadlines?
8. Is a **static topology** of stages and queues acceptable (no dynamic subscribers)?
9. Is the **team** prepared for a young language with a small ecosystem?
10. Is the **target** a 64-bit OS with virtual memory (or can you set `--stack-reserve`)?
11. Can you **measure** stack counts, RSS, and frame time on the real hardware?
12. Is **`abort` on exhaustion** an acceptable failure mode, or do you need graceful degradation?

## 8. Notes on this compiler build

- Package: `goose` `2026.3.post100`, build `hb0f4dca_0`, channel `https://prefix.dev/nandi-testing`, platform `linux-64`, glibc ≥ 2.28, `libstdcxx`/`libgcc` ≥ 16. `goose version` reports runtime `a5dbd11b6309`.
- Standard library in this package: 12 modules — `std`, `os`, `math`, `json`, `csv`, `regex`, `binary`, `base64`, `dictionary`, `vec`, `ffi`, `exception`. The `gfx`, `audio`, `ui`, and `physics` packages documented upstream are **not** in this build.
- Running `goose prog.goose` compiles and runs in-process with TinyCC; it needs the C library headers and cannot run threads. `goose build prog.goose` uses a real C compiler (`gcc`/`clang`) and is required for threads, `export fn` use from C, and `--standalone`.
- `--stack-reserve` accepts 64 KB to 256 TB, default 2 GB. The runtime halves a reservation the platform refuses, down to 1 MB.
- `--debug` turns on overflow, range, and tag checks that name the source line; release builds wrap signed overflow. Validate control and DSP code with `--debug`, and do not rely on wraparound semantics in release.
- C of your own goes in a sidecar named after the root file: `minihttp.build` beside `minihttp.goose`, with `c_sources = ["net.c"];`. For embedding, `goose --standalone --header prog.h -o prog.c prog.goose` produces a C file and header; the host calls `goose_init(argc, argv)` once, then exported functions from that same thread only.

## 9. Sources and verification

Language and runtime documentation:

- Repository and overview: <https://github.com/aardappel/goose>
- Tutorial (memory model, threads, C interop, limitations): <https://aardappel.github.io/goose/docs/tutorial.html>
- Language reference (data stacks, pools, queues, serialization, extern/export): <https://aardappel.github.io/goose/docs/reference.html>
- Standard library (os, dictionary, json, csv, binary, regex): <https://aardappel.github.io/goose/docs/stdlib.html>
- Packages, sidecars, C integration: <https://aardappel.github.io/goose/docs/packages.html>
- Implementation notes (stack budget, bounds-check elimination): <https://aardappel.github.io/goose/docs/implementation.html>
- Package page: <https://prefix.dev/channels/nandi-testing/packages/goose>

The project's published benchmark claims (3.3× idiomatic C++, 1.16× hand-optimised C++, 1.12× best safe Rust, less memory) come from those pages; they are not independently reproduced here. The numbers in this guide are my own measurements of the code in `docs/examples/`, on a shared Linux x86-64 VM with gcc 15.2.0, built with `goose build` at `-O2` and measured with `/proc/<pid>/status` and `getrusage(RUSAGE_CHILDREN)`:

| Measurement | How |
| --- | --- |
| 11 MiB peak RSS for 2 MB and 115 MB inputs | `request-loop` native binary, `ru_maxrss` |
| 1.8 MiB RSS / 4.2 GiB VmPeak / 20k connections in 2.12 s | `minihttp` native binary, `/proc/<pid>/status`, Python loopback client |
| 70 ns p50 / 110–120 ns p99 request parse | 200k iterations of `handle()` in-process, `clock_ns` |
| 42–44 µs p50 FFT frame | 300 frames, `audio-frame-loop`, 5 runs |
| 0.65 ms per exec, 70 KB binary | 500 executions of a hello program, from Python |
| 2,056 accepted / 197,944 refused | `fanout` with `qlimit` 1,024 and a 200k burst |

Treat them as order-of-magnitude evidence, not benchmarks: the VM is shared and the workloads are small. The structural claims (scope-free, no collector, bounded queues, verified loads, abort on exhaustion) are properties of the language and runtime, and they are what the design advice rests on.

## 10. Running the examples

All examples live in `docs/examples/` and were checked and run with the packaged compiler. With the project's pixi environment:

```bash
pixi run goose docs/examples/request-loop.goose < requests.txt
pixi run goose docs/examples/rule-vm.goose
pixi run goose build docs/examples/fanout.goose && ./docs/examples/fanout
pixi run goose build docs/examples/audio-frame-loop.goose && ./docs/examples/audio-frame-loop
pixi run goose build docs/examples/latest-wins.goose && ./docs/examples/latest-wins
pixi run goose build docs/examples/minihttp.goose && ./docs/examples/minihttp   # listens on 127.0.0.1:18080
pixi run goose build docs/examples/pool-generations.goose && ./docs/examples/pool-generations
```

`request-loop.goose` reads request lines of the form `GET /path bytes` from stdin and prints counters. `minihttp.goose` needs `net.c` and `minihttp.build` in the same directory; the sidecar must be named after the root file. `fanout.goose` and the other threaded examples need `goose build`, not a JIT run.

The sample project at the repository root adds two smaller demos in the same style: `iteration.goose` (a request loop with a bounded reusable pool ring; `pixi run iteration`) and `realtime.goose` (a fixed-cadence loop with a deliberately slow consumer and a bounded outbox; `pixi run realtime`). `pixi run stack-stats` and `pixi run realtime-stack-stats` print the compiler-assigned data stacks and regions at exit.
