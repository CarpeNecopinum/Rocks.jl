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

## SDL GPU renderer

| run | avg ms/frame | p50 | p95 | fps | memory per run | allocs per run |
|-----|--------------|------|------|------|----------------|----------------|
| 1   | 4.93         | 4.91 | 4.99 | 204.2 | 657 MiB | 11 881 200 |
| 2   | 4.91         | 4.93 | 4.99 | 208.2 | 642 MiB | 11 662 800 |

Per frame: **~4.9 ms (≈208 fps)** — **5.3× faster than the baseline**. The
frame uploads the staged vertices/indices once per copy pass and replays the
recorded commands inside one render pass, so the per-draw cost is recording
only. Memory and allocations are ≈18%/≈31% above the baseline: the GPU path
records a command tuple and stages vertices per draw where the SDL renderer
fills rects and textures without any geometry. A future optimization is a
persistent staging arena that reuses the transfer buffer across frames and
drops the per-draw recording allocations.

Pixel verification: the same probe scene rendered headlessly through
`SDL_VIDEO_DRIVER=dummy` (SDL renderer) and with `render(...; gpu = true)`
(x11, NVIDIA GTX 1080, Vulkan) is **99.1% pixel-identical**; the remaining
differences are AA-fringe rounding at shape edges and glyph-edge AA (the GPU
samples the text textures bilinearly where the software rasterizer
computes coverage).

Environment: Vulkan (NVIDIA GTX 1080), x11, Julia 1.13.1, Intel Core
i7-7700K @ 4.20 GHz.

## The regression gate

A transition of the rendering backend (e.g. to SDL GPU) must keep the
average frame time at or below the baseline on the same machine — re-run
`benchmark_and_print(; frames = 300)` (or `; gpu = true` for the GPU path)
after the change and compare against this table. The allocation column is
informational for backend transitions: the GPU path records per-draw
staging that the software renderer does not need, so its allocation count
sits above the baseline while the frame time is far below it.

The SDL GPU transition (`render(...; gpu = true)`) is implemented behind
this gate: `src/gpu.jl` records the draw primitives into a per-frame
transfer buffer, uploads once per frame and replays the recorded commands
inside a render pass on the swapchain. It requires a Vulkan-capable
environment with a display (the GPU swapchain needs a window system — the
dummy video driver falls back to the SDL renderer path above); the shaders
ship as SPIR-V in `assets/shaders/`. Screenshots work in GPU mode too: the
next drawn frame is copied out of the swapchain into a PNG (see
`GPU_CAPTURE` in gpu.jl).
