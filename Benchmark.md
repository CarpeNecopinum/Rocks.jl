# Benchmark

The baseline harness for renderer work: a complex scene drawn back-to-back
with [BenchmarkTools](https://juliaci.github.io/BenchmarkTools.jl/stable/),
timing the **draw pass** (clear, geometry, textures, present) — the cost a
renderer transition must not regress.

## Running it

```julia
using Rocks
benchmark_and_print(; frames = 300)          # the default scene
# or with a custom app and sampling:
r = benchmark(MyApp; frames = 300, samples = 5, seconds = 30.0)
```

Each **sample** draws `frames` frames back-to-back; BenchmarkTools tunes and
executes `samples` samples within `seconds`, tracking the allocations. The
layout runs once up front — the benchmark measures drawing only, not the
event loop or component re-renders.

## The scene

`benchmark_scene()` is a 1180×800 window exercising every draw path:

- a 14 × 10 grid (140 widgets) of rounded, bordered boxes with labels,
- 14 bordered **bevelled** controls,
- 14 **gradient** rounded boxes (the heaviest fill path),
- a canvas of **120 batched anti-aliased lines**.

## Baseline — SDL software renderer

| run | avg ms/frame | p50 | p95 | fps | memory per run | allocs per run |
|-----|--------------|------|------|------|----------------|----------------|
| 1   | 25.86        | 24.70 | 31.17 | 41.7 | 544 MiB | 8 916 300 |
| 2   | 25.28        | 25.23 | 25.51 | 39.8 | 544 MiB | 8 916 300 |
| 3   | 24.90        | 24.85 | 25.05 | 40.3 | 544 MiB | 8 916 300 |

Per frame: **~25 ms (≈40 fps)**, ≈1.86 MiB and ≈29 700 allocations — the
allocations are the AA-fringe rounded-rect geometry (vertex/index vectors
built per draw), the clearest target for a renderer transition.

Environment: SDL software renderer (dummy video driver), Julia 1.13.1,
Intel Core i7-7700K @ 4.20 GHz.

## The regression gate

A transition of the rendering backend (e.g. to SDL GPU) must keep the
average frame time and the per-run allocations at or below this baseline on
the same machine — re-run `benchmark_and_print(; frames = 300)` after the
change and compare against this table.
