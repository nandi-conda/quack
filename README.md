# Goose sample project (pixi)

A minimal [pixi](https://pixi.sh) project that installs the **Goose compiler**
from the `nandi-testing` channel and runs a small program with it.

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

- For in-process runs (`pixi run demo`) the host needs system C library
  headers: `libc6-dev` on Debian/Ubuntu, `glibc-devel` on Fedora/RHEL.
- For native builds (`pixi run build`, `pixi run run-native`) the host needs a
  C compiler (`gcc` or `clang`) on `PATH`. Run `pixi run toolchain` to see what
  Goose found.

The demo was verified with gcc 15.2.0 on the host.

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

## Run

```bash
pixi run demo        # compile and run demo.goose in-process with TinyCC
pixi run check       # typecheck only
pixi run build       # build a native ./demo executable
pixi run run-native  # build, then run ./demo
pixi run version     # Goose runtime version
pixi run toolchain   # C compiler, cmake, git, GOOSE_HOME that Goose sees
```

Direct use works too:

```bash
pixi run goose demo.goose
pixi run goose build demo.goose && ./demo
```

Expected output:

```text
Goose demo: primes and Fibonacci
primes below 30: [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
count=10 largest=29
fib(0..9): [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
sum(fib)=88
```

Goose prints parse/typecheck progress lines on stderr before the program
output. `pixi run demo` keeps the compiler's exit code.

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
  `libc6-dev`/`glibc-devel`, `pixi run demo` fails while compiling the
  generated C; `goose check` still works.
- `goose build` delegates to the host C compiler and needs `gcc`/`clang`.
  It writes the generated C and runtime objects under `GOOSE_HOME`
  (default `~/.goose`), not into this directory.
- Only one version (`2026.3.post100`) is currently published in the channel.

## Files

- `pixi.toml` — channels, platform, dependency, and tasks.
- `pixi.lock` — exact resolved environment.
- `demo.goose` — demo source: structs, recursion, loops, slices, printing.
- `README.md` — this file.
