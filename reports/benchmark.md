# Full-game benchmark

**25.409 seconds median** to solve a new game, across five fresh
processes. Range: **25.195–25.877 seconds**. No failures.

Measured 2026-10-25 on an **Apple M5**, **32 GiB RAM**, macOS 26.6.2
(arm64, 10 logical CPUs), using `nightly-2026-10-25-72704da`
and `basic-cli` 0.26.0. This is a single-threaded solver under normal desktop
load, not an isolated benchmark machine.

## Work and timing boundary

The timed command is the compiled binary's `solve`, with all 15 categories
unused and no upper points. The Roc harness uses a monotonic clock. Timing includes process startup,
all dynamic programming work, result printing, and the small startup overhead
of the `/usr/bin/time` wrapper that supplies child CPU usage. Each invocation starts with an empty
memo; there is no policy table or memo saved between runs. OS executable pages
can already be cached. Compilation, downloads, and profiling are excluded.

Every timed run must return **248.4399893778553** expected points and exactly
**947,711** memoized turn-boundary states. The harness rejects a nonzero exit,
unexpected output, or an incorrect score/state count. Separate correctness
checks are in [verify.py](../verify.py).

The harness is [benchmark.roc](../benchmark.roc); Python is only used for the
independent correctness checks. `/usr/bin/time -p` reports CPU time in hundredths
of a second, while elapsed time comes from Roc’s monotonic nanosecond clock.

The binary is built with `--opt=speed --debug`: LLVM optimization plus symbols
for the separate profile. The five reported runs are **not profiled**.

| Run | Wall seconds | CPU seconds |
| --- | ---: | ---: |
| 1 | 25.195 | 25.110 |
| 2 | 25.239 | 25.190 |
| 3 | 25.409 | 25.360 |
| 4 | 25.877 | 25.840 |
| 5 | 25.507 | 25.470 |

## What limits it?

The median CPU-time / wall-time ratio is **0.998**:
approximately one core is busy throughout. A separate one-second macOS
`sample` run shows the main thread in the dice expectation backups at
[Solver.roc](../Solver.roc) (`complete` / `improve`, called by `boundary`),
with frequent list allocation and reallocation. This is CPU work in the
solver, rather than waiting for I/O or timing a precomputed result.

The profile was collected in a separate full solve before the timed runs.
Its call graph is retained in [benchmark-profile.txt](benchmark-profile.txt).
The machine had normal desktop activity; the one-minute load average was
3.07 before and 2.77 after the timed runs. There is no
comparison against another solver or ruleset here.

## Reproduce

From the repository root, after `mise install`:

```sh
mise exec -- roc benchmark.roc -- --runs 5 --output /var/tmp/yatzy-benchmark.json
# On macOS, also collect a separate, untimed call graph:
mise exec -- roc benchmark.roc -- --runs 5 --output /var/tmp/yatzy-benchmark.json \
  --profile /var/tmp/yatzy-profile.txt
```

[benchmark.json](benchmark.json) contains every sample, machine/compiler
metadata, load averages, and SHA-256 hashes of the exact Roc sources, benchmark harness and
compiler pin measured. Results will vary with hardware and compiler version.
