# The benchmark: a complex scene and a back-to-back draw run with per-frame
# timing — the baseline harness for renderer work (a transition to SDL GPU
# must not regress the average frame time).

using BenchmarkTools

using ..Rocks: Fiber, WindowState, collect_windows!, create_window!,
               sync_window!, measure!, place!, draw_window!, init_backend,
               shutdown_backend, RUNNING, DIRTY, GPU_MODE, gpu_init,
               gpu_shutdown

"""
    benchmark_scene() -> Element

A complex benchmark scene: a grid of representative widgets — rounded boxes
with borders, bevels and gradients, labels, and a canvas of batched lines —
exercising every draw path (rounded-rect geometry with AA fringes, text
textures, gradient geometry, canvas batches).
"""
function benchmark_scene()
    rows = Any[]
    for r in 1:14
        cells = Any[]
        for c in 1:10
            label = "r$r c$c"
            if c == 10
                # A gradient rounded box: the heaviest fill path.
                push!(cells, @rock Box(;
                    background = LinearGradient("#7ea6d8", "#20304a"),
                    radius = 8, width = 92, height = 28))
            elseif c == 9
                # A bordered bevelled control with a label.
                push!(cells, @rock Box(
                    @rock Text(label; size = 12);
                    background = "#d8e2ee",
                    border_color = "#5a6a7a", border_width = 1,
                    bevel = :raised, radius = 4,
                    padding = 2, align = :center,
                    width = 92, height = 28))
            else
                # A rounded, bordered box with a label.
                push!(cells, @rock Box(
                    @rock Text(label; size = 12);
                    background = (0.16 + 0.03c, 0.3, 0.52),
                    border_color = (0.9, 0.9, 0.95), border_width = 1,
                    radius = 6, padding = 2, align = :center,
                    width = 92, height = 28))
            end
        end
        push!(rows, @rock Row(cells...; gap = 4, padding = 2))
    end
    lines = Tuple{Float64,Float64,Float64,Float64}[]
    for i in 1:120
        x = 20.0 + i * 8.0
        push!(lines, (x, 20.0, x + 60.0, 380.0))
    end
    canvas = @rock Canvas(;
        draw = (ctx) -> begin
            ctx.clear((0.97, 0.97, 0.97))
            ctx.lines(:bench;
                      deps = (:bench,),
                      build = () -> ((x1, y1, x2, y2, (0.2, 0.4, 0.7), 1.0)
                                     for (x1, y1, x2, y2) in lines))
        end,
        background = (0.97, 0.97, 0.97), fill = true)
    return @rock Window(
        @rock Column(
            @rock Row(canvas; fill = true, height = 400),
            @rock Column(rows...; gap = 4);
            gap = 4);
        title = "benchmark", width = 1180, height = 800)
end

"Draw every window of `windows` back-to-back `frames` times — one benchmark
sample."
function draw_frames(windows, frames)
    for _ in 1:frames
        for w in windows
            draw_window!(w)
        end
    end
    return nothing
end

"""
    benchmark(app = benchmark_scene; frames = 300, samples = 5,
              seconds = 30.0, width = 1180, height = 800, gpu = false)
        -> NamedTuple

Draw `app`'s windows back-to-back with
[BenchmarkTools](https://juliaci.github.io/BenchmarkTools.jl/stable/): each
**sample** draws `frames` frames; `run` tunes and executes `samples`
samples within `seconds`, tracking the allocations. The per-frame
statistics come from the sample times, and `memory`/`allocs` report the
allocations of one back-to-back run — a draw pass that allocates per frame
is a regression signal. The layout runs once up front; the benchmark
measures the **draw pass** (clear, geometry, textures, present), which is
the cost a renderer transition must not regress.

`gpu = true` benchmarks the SDL GPU path (`render(...; gpu = true)`); it
needs a Vulkan-capable environment with a display (the GPU swapchain needs a
window system) and falls back to the SDL renderer with a warning otherwise.
"""
function benchmark(app = benchmark_scene; frames = 300, samples = 5,
                   seconds = 30.0, width = 1180, height = 800, gpu = false)
    RUNNING[] && error("Rocks.benchmark is already running")
    RUNNING[] = true
    DIRTY[] = false
    init_backend()
    GPU_MODE[] = gpu
    if gpu
        try
            gpu_init()
        catch err
            @warn "Rocks: SDL GPU unavailable — benchmarking the SDL renderer" exception = err
            GPU_MODE[] = false
        end
    end
    root = create_root(app, (;))
    root.mounted = true
    try
        perform_render!(root)
        run_effects!()
        flush_dirty!()
        run_effects!()
        windows = Fiber[]
        collect_windows!(windows, root)
        for w in windows
            w.host isa WindowState || create_window!(w)
            sync_window!(w)
        end
        for w in windows
            measure!(w)
            place!(w, 0.0, 0.0)
        end
        # Each sample draws `frames` frames back-to-back; BenchmarkTools
        # warms up, tunes and executes the samples, tracking allocations.
        trial = BenchmarkTools.run(
            @benchmarkable draw_frames($windows, $frames);
            gcsample = true, samples = samples, seconds = seconds)
        # Per-frame milliseconds per sample (sample time is in ns).
        per_frame = sort(trial.times) ./ (frames * 1e6)
        pick(p) = per_frame[clamp(ceil(Int, p * length(per_frame)),
                                  1, length(per_frame))]
        best = minimum(trial).time / 1e6     # the best back-to-back run, ms
        return (samples = length(per_frame),
                frames = frames,
                total_ms = best,
                avg_ms = mean(trial).time / 1e6 / frames,
                min_ms = minimum(trial).time / 1e6 / frames,
                p50_ms = pick(0.5),
                p95_ms = pick(0.95),
                max_ms = maximum(trial).time / 1e6 / frames,
                fps = frames * 1e3 / best,
                memory = memory(trial),
                allocs = allocs(trial))
    finally
        unmount!(root)
        RUNNING[] = false
        GPU_MODE[] && gpu_shutdown()
        GPU_MODE[] = false
        shutdown_backend()
    end
end

"Run `benchmark` and print a one-line summary."
function benchmark_and_print(args...; kwargs...)
    r = benchmark(args...; kwargs...)
    println("samples=$(r.samples)  frames=$(r.frames)  " *
            "avg=$(round(r.avg_ms, digits = 2)) ms  " *
            "p50=$(round(r.p50_ms, digits = 2)) ms  " *
            "p95=$(round(r.p95_ms, digits = 2)) ms  " *
            "max=$(round(r.max_ms, digits = 2)) ms  " *
            "fps=$(round(r.fps, digits = 1))  " *
            "mem=$(r.memory ÷ 1024) KiB/run  allocs=$(r.allocs)/run")
    return r
end