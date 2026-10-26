# Verified Goose examples for the heap-less guide

These programs accompany [`../heap-less-app-guide.md`](../heap-less-app-guide.md). Each was checked and run with the packaged compiler from `prefix.dev/nandi-testing` (`goose` `2026.3.post100`, runtime `a5dbd11b6309`, linux-64, gcc 15.2.0).

| File | Shows | Run | Observed |
| --- | --- | --- | --- |
| `request-loop.goose` | request-scoped parsing, per-request buffers, routing table | `pixi run goose request-loop.goose < requests.txt` | 4,000,000 lines: `requests=4000000 bytes=9143083428545 not_found=571429`, 11 MiB peak RSS |
| `fanout.goose` | fixed worker pool, bounded queues, admission control | `pixi run goose build fanout.goose && ./fanout` | `workers=8 submitted=2056 refused=197944` |
| `latest-wins.goose` | drop-stale-frame consumer for realtime pipelines | `pixi run goose build latest-wins.goose && ./latest-wins` | `rendered 199 of 200 ticks` |
| `audio-frame-loop.goose` | fixed-size 1024-point FFT frame loop with a display stem split (sub, percussion from spectral flux, tonal, residual) | `pixi run goose build audio-frame-loop.goose && ./audio-frame-loop` | `frame p50=43620ns ...` / `onsets=13/300  stems: sub=59% perc=5% tonal=31% residual=3%` |
| `minihttp.goose` + `net.c` + `minihttp.build` | heap-less HTTP server over a C socket shim | `pixi run goose build minihttp.goose && ./minihttp` | serves 127.0.0.1:18080; 20k connections, 1.8 MiB RSS, 4.2 GiB VmPeak |
| `pool-generations.goose` | reusable pool with generation handles | `pixi run goose build pool-generations.goose && ./pool-generations` | `stale handle: false value=0` / `fresh handle: true value=99` |
| `rule-vm.goose` | verifying sandbox for untrusted bytecode | `pixi run goose rule-vm.goose` | `max(41, 7) = 41` / `rejected: branch into data at 12` |

Sample input for `request-loop.goose` (one request per line, method, path, size):

```text
GET /api/v1/items/42 512
POST /api/v1/orders 128
GET /nope 10
```

Notes:

- `request-loop.goose` and `rule-vm.goose` run in-process (TinyCC). The threaded examples (`fanout`, `latest-wins`), `audio-frame-loop`, and `minihttp` need `goose build`.
- The sidecar is named after the **root** file (`minihttp.build` beside `minihttp.goose`), not after `net.c`.
- `net.c` uses POSIX sockets and binds to loopback only. It is a shim for the guide, not a hardened server: no timeouts, no TLS, no partial-write handling beyond a loop, one connection at a time.
- Build outputs are ignored by the local `.gitignore`. Remove them with `git clean -fX docs/examples`.
