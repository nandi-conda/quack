# Goose sample project (pixi)

A minimal [pixi](https://pixi.sh) project that installs the **Goose compiler**
from the `nandi-testing` channel and runs two small programs with it.

Goose is a memory-safe systems language with no heap allocator, garbage
collector, or lifetime annotations. It compiles to C and can run programs
in-process through a bundled TinyCC backend. This package is the compiler,
not the unrelated "goose" AI agent.

- Package page: <https://prefix.dev/channels/nandi-testing/packages/goose>
- Package: `goose` `2026.3.post100` (`hb0f4dca_0`)
- Channel: <https://prefix.dev/nandi-testing> (plus `conda-forge` for anything else)
- Platform: **linux-64 only**

## Prerequisites

- Linux x86_64 with glibc 2.28 or newer (this lock file records `__glibc=2.28`).
- [pixi](https://pixi.sh) 0.83 or newer:

  ```bash
  curl -fsSL https://pixi.sh/install.sh | bash
  ```

- For in-process runs (`pixi run demo`, `pixi run iteration`) the host needs
  system C library headers: `libc6-dev` on Debian/Ubuntu, `glibc-devel` on
  Fedora/RHEL. The same applies to `pixi run stack-stats`.
- For native builds (`pixi run build`, `pixi run run-native`,
  `pixi run run-iteration-native`) the host needs a C compiler (`gcc` or
  `clang`) on `PATH`. Run `pixi run toolchain` to see what Goose found.

Both demos were verified with gcc 15.2.0 on the host.

## Install

From this directory:

```bash
pixi install
```

`pixi.toml` already contains both channels and the package, so no other setup
is needed. `pixi.lock` pins the exact solution.

To recreate the dependencies from scratch instead:

```bash
pixi workspace channel add --prepend https://prefix.dev/nandi-testing
pixi add goose
```

## What the demos show

`demo.goose` is a language warm-up: a struct, recursion, growable arrays,
slices, and printing.

`iteration.goose` is the heap-less worker/service shape:

- each pass builds a request line in a loop-local growable buffer;
- `handle()` parses it with a stack-local normalization buffer and returns a
  flat record, so both scratch buffers are freed at scope exit with no
  allocator call;
- the newest six records live in a fixed-capacity ring backed by a `reusable`
  pool. When the ring is full, the oldest slot is freed and immediately reused;
- the final line reports `pool slots=6`, showing the steady state never grows.

`pixi run stack-stats` adds `-DGS_STACK_STATS=1` and reports the
compiler-assigned data stacks at exit:

```text
goose stack stats: main: 3 data stacks, 5 regions (reserving 2 GB each); budget 32 TB for 16376, main program 5, no workers
```

The reservation is address space, not committed memory; it is the upper bound
for all dynamic data. This is the pattern for request-, job-, frame-, or
batch-scoped work. Per-unit scratch belongs in locals; state that outlives one
unit must be bounded up front and pooled.

## Run

```bash
pixi run demo                   # basic demo, in-process
pixi run iteration              # heap-less request/ring demo, in-process
pixi run check                  # typecheck both programs
pixi run build                  # build native ./demo and ./iteration
pixi run run-native             # build, then run ./demo
pixi run run-iteration-native   # build, then run ./iteration
pixi run stack-stats            # iteration demo + data-stack high-water mark
pixi run version                # Goose runtime version
pixi run toolchain              # C compiler, cmake, git, GOOSE_HOME
```

Direct use works too:

```bash
pixi run goose demo.goose
pixi run goose iteration.goose
pixi run goose build iteration.goose && ./iteration
```

Expected output of `pixi run demo`:

```text
Goose demo: primes and Fibonacci
primes below 30: [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
count=10 largest=29
fib(0..9): [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
sum(fib)=88
```

Expected output of `pixi run iteration`:

```text
Goose heap-less request loop: 6-entry ring in a reusable pool
req 3: GET /api/items/3 200 623 -> hash=2894808507 ring=4/6 pool slots=4
req 7: GET /api/items/0 200 771 -> hash=2911586126 ring=6/6 pool slots=6
req 11: GET /api/items/4 200 919 -> hash=2978696602 ring=6/6 pool slots=6
req 15: GET /api/items/1 200 1067 -> hash=2928363745 ring=6/6 pool slots=6
req 19: GET /api/items/5 200 1215 -> hash=2995474221 ring=6/6 pool slots=6
req 23: GET /api/items/2 200 1363 -> hash=2878030888 ring=6/6 pool slots=6
-- newest first --
  /api/items/2 status=200 bytes=1363 hash=2878030888
  /api/items/1 status=200 bytes=1326 hash=2928363745
  /api/items/0 status=200 bytes=1289 hash=2911586126
  /api/items/6 status=200 bytes=1252 hash=2945141364
  /api/items/5 status=200 bytes=1215 hash=2995474221
  /api/items/4 status=200 bytes=1178 hash=2978696602
pool slots=6 (capacity 6, no growth)
```

Goose prints parse/typecheck progress lines on stderr before the program
output. `pixi run demo` and `pixi run iteration` keep the compiler's exit code.

## Resolved versions

`pixi list` after `pixi install`:

| Package | Version | Build |
| --- | --- | --- |
| goose | 2026.3.post100 | hb0f4dca_0 |
| libstdcxx | 16.2.0 | h934c35e_7 |
| libgcc | 16.2.0 | ha9f2e26_7 |
| libgomp | 16.2.0 | he0feb66_7 |
| _openmp_mutex | 4.5 | 20_gnu |

All five resolve from the `nandi-testing` channel. The package declares
`libstdcxx >=16` and `libgcc >=16`; the channel also carries those builds, so
they win over conda-forge at the default channel priority.

`goose version` reports:

```text
goose runtime a5dbd11b6309
```

## Platform caveats

- **linux-64 only.** There is no osx-64, osx-arm64, win-64, or linux-aarch64
  build of `goose` in this channel. `pixi.toml` therefore declares only
  `platforms = ["linux-64"]`; adding another platform makes the solve fail.
- The in-process TinyCC backend borrows the host glibc headers. Without
  `libc6-dev`/`glibc-devel`, `pixi run demo` and `pixi run iteration` fail
  while compiling the generated C; `goose check` still works.
- `goose build` delegates to the host C compiler and needs `gcc`/`clang`.
  It writes the generated C and runtime objects under `GOOSE_HOME`
  (default `~/.goose`), not into this directory.
- Only one version (`2026.3.post100`) is currently published in the channel.

## Files

- `pixi.toml` — channels, platform, dependency, and tasks.
- `pixi.lock` — exact resolved environment.
- `demo.goose` — language warm-up: structs, recursion, loops, slices, printing.
- `iteration.goose` — heap-less request loop: per-request scratch on a data
  stack plus a bounded ring of recent records in a `reusable` pool.
- `README.md` — this file.
