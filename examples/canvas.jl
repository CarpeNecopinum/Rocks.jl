# Rocks.Canvas — the 2D escape hatch, demonstrated as an app fragment.
#
#   julia --project examples/canvas.jl
#   SDL_VIDEO_DRIVER=dummy ROCKS_SCREENSHOT=out.png julia --project examples/canvas.jl
#
# Two columns: the interactive vector workspace on the left (a grid, a closed
# rectangle outline with a hatched fill region and a filled triangle, all drawn
# straight into the SDL renderer — no texture round-trip) and a control panel on
# the right with buttons and labels. Drag to pan (grab-hand cursor), wheel to
# zoom at the pointer.
#
# State placement: the view state (zoom, pan) lives as Observables owned by the
# app component — the nearest common ancestor of everything that reads or
# writes it (the canvas callbacks and the control panel) — created with `@use`
# and seeded from keyword arguments, so a test can vary it without reaching
# into module state (`render(App; initial_zoom = 40, ...)`, see below). Module
# scope only holds constants (scene geometry, layout constants). Auxiliary
# state that renders nothing (the drag gate, the pan-at-drag-start store) is
# silent `@use Ref(...)` state: hook-stable identity, no re-renders on writes.
# The app subscribes to the view observables via `@use`, which is what makes the
# panel's labels update live while dragging/zooming (a plain `zoom[]` read in a
# component body does NOT subscribe anything); the draw callbacks read the same
# observables lazily at draw time.
#
# The layout doubles as a *containment test*: nothing the `draw` callback emits
# may leak outside the canvas's box. The grid spans far beyond the viewport in
# all directions, and panning/zooming moves content arbitrarily across the
# boundary; if Rocks' clip stack ever leaks, the right column gets painted
# over. (A dedicated set of 40-px-overshoot stroke stressors was pixel-verified
# and then removed for visual clarity.)

using Rocks
import Rocks: Canvas, MouseArea, Text   # Text: disambiguate from Base.Text

# Canvas-region constants of this window (window 720×520, right column 220).
const CANVAS_W = 500.0
const CANVAS_H = 520.0
const CENTER   = (CANVAS_W / 2, CANVAS_H / 2)

world_to_local(p, zoom, panx, pany) =
    (p[1] * zoom + panx, -p[2] * zoom + pany)
# world (laser, y-up, mm) → canvas-local screen (y-down, px):
#     local = world * zoom + pan  (x),   local = pan - world * zoom  (y)

# A square, some hatched fill lines and a triangle, in "mm" world coordinates.
const rect  = [(0.0, 0.0), (60.0, 0.0), (60.0, 40.0), (0.0, 40.0)]
const hatch = [((0.0, y), (60.0, y)) for y in range(5.0, 35.0, step = 5.0)]
const tri   = [(70.0, 0.0), (95.0, 12.0), (78.0, 34.0)]
const grid  = vcat([((x, -1000.0), (x, 1000.0)) for x in range(-1000.0, 1000.0, step = 10.0)],
                   [((-1000.0, y), (1000.0, y)) for y in range(-1000.0, 1000.0, step = 10.0)])

# `zoom`/`panx`/`pany` arrive as the current draw-frame values, resolved by the
# caller from the app's view observables.
function draw_workspace(ctx, zoom, panx, pany)
    x0, y0, w, h = ctx.rect
    ctx.clear((0.97, 0.97, 0.97))

    # a grid much larger than the viewport: the clip must cut it on all sides
    for (a, b) in grid
        ctx.line(world_to_local(a, zoom, panx, pany)...,
                 world_to_local(b, zoom, panx, pany)...;
                 color = (0.87, 0.87, 0.87))
    end
    for (a, b) in hatch
        ctx.line(world_to_local(a, zoom, panx, pany)...,
                 world_to_local(b, zoom, panx, pany)...;
                 color = (0.72, 0.82, 0.95))
    end
    ctx.polyline(world_to_local.(rect, zoom, panx, pany);
                 color = (0.82, 0.12, 0.12), width = 2, closed = true)
    ctx.polygon(world_to_local.(tri, zoom, panx, pany);
                color = (0.16, 0.55, 0.90))

    ctx.text("drag to pan, wheel to zoom (×$(round(zoom; digits = 2)))",
             8, 4; size = 12, color = (0.35, 0.35, 0.35))
    return nothing
end

function App(; initial_zoom = 4.0, initial_panx = 40.0, initial_pany = 210.0)
    # `@use Ref(...)` is silent hook state (React-style `useRef`): the Ref is
    # created once per component instance (the hook keeps it across
    # re-renders, so callbacks that re-runs recreate still share it) and
    # mutating it NEVER re-renders.
    panx0 = @use Ref(0.0)
    pany0 = @use Ref(0.0)
    # `dragging` gates `on_move`, which also fires for plain hover motion
    dragging = @use Ref(false)

    # The view state: owned by the app (nearest common ancestor of the canvas
    # callbacks and the panel), seeded from the keyword arguments. `@use` also
    # subscribes the app to these observables — without that subscription the
    # labels below only refresh when something else re-runs the component
    # (e.g. the next click), because drag/zoom events only mark the window for
    # *redraw*, never for re-render.
    zoom = @use Observable(initial_zoom)
    panx = @use Observable(initial_panx)
    pany = @use Observable(initial_pany)

    # view helpers close over this instance's observables — no module state
    function zoom_at(x, y, factor)
        wzx = (x - panx[]) / zoom[]
        wzy = (pany[] - y) / zoom[]
        zoom[] = clamp(zoom[] * factor, 0.05, 200.0)
        panx[] = x - wzx * zoom[]
        pany[] = y + wzy * zoom[]
        return nothing
    end
    reset_view() = begin
        zoom[] = initial_zoom
        panx[] = initial_panx
        pany[] = initial_pany
    end
    # "Focus Rectangle": put the 60×40 mm rectangle centered, zoom 8.
    focus_rectangle() = begin
        zoom[] = 8.0
        panx[] = CENTER[1] - 30.0 * 8.0
        pany[] = CENTER[2] + 20.0 * 8.0
    end

    @rock Window(
        @rock Row(
            # The canvas is a pure drawing surface; the MouseArea wrapper
            # makes it interactive. With a single child the two coincide
            # exactly, so the area-local callback coordinates equal the
            # canvas-local draw coordinates. `on_move` also fires on plain
            # hover, so the pan gate is an explicit dragging flag.
            @rock MouseArea(
                @rock Canvas(
                    draw = (ctx) -> draw_workspace(ctx, zoom[], panx[], pany[]),
                    background = (0.95, 0.95, 0.95));
                on_down = (x, y, _) -> begin
                    panx0[] = panx[] - x
                    pany0[] = pany[] - y
                    dragging[] = true
                end,
                on_move = (x, y) -> begin
                    dragging[] || return nothing
                    panx[] = panx0[] + x
                    pany[] = pany0[] + y
                end,
                on_up = (_, _, _) -> (dragging[] = false),
                on_wheel = (dx, dy, x, y) -> zoom_at(x, y, 1.15^dy),
                cursor = :grab,
                flex = 1, fill = true),
            @rock Column(
                @rock Box(
                    @rock Text("View"; size = 15, color = (0.15, 0.15, 0.18)),
                    @rock Button("Reset Zoom";
                                 on_press = reset_view,
                                 variant = :outlined, color = :secondary),
                    @rock Button("Focus Rectangle";
                                 on_press = focus_rectangle),
                    @rock Row(
                        @rock Button("−"; on_press = () -> zoom_at(CENTER..., 0.8),
                                     size = :small),
                        @rock Button("+"; on_press = () -> zoom_at(CENTER..., 1.25),
                                     size = :small);
                        gap = 8),
                    @rock Text("zoom = $(round(zoom[]; digits = 2))×"; size = 12,
                               color = (0.12, 0.12, 0.14)),
                    @rock Text("pan   = ($(round(panx[]; digits = 1)), $(round(pany[]; digits = 1))) px";
                               size = 12, color = (0.12, 0.12, 0.14)),
                    @rock Text("origin = ($(round(-panx[] / zoom[]; digits = 1)), $(round(pany[] / zoom[]; digits = 1))) mm";
                               size = 12, color = (0.45, 0.45, 0.45)),
                    @rock Text("""world mm, y-up ↷ screen y-down
local = world·z + pan""";
                               size = 11, color = (0.55, 0.55, 0.55));
                    gap = 10, padding = 12, direction = :column);
                width = 220, fill = true,
                background = (0.92, 0.92, 0.94));
            gap = 1;
            position = :absolute, fill = true);
        title = "Canvas", width = 720, height = 520)
end

if abspath(PROGRAM_FILE) == @__FILE__
    if haskey(ENV, "ROCKS_SCREENSHOT")
        # Keyword arguments seed the app's state, e.g. for headless tests —
        #   ROCKS_CANVAS_ARGS="40,100,3000" → zoom 40, pan (100, 3000)
        if haskey(ENV, "ROCKS_CANVAS_ARGS")
            z, x, y = parse.(Float64, split(ENV["ROCKS_CANVAS_ARGS"], ","))
            render(App; initial_zoom = z, initial_panx = x, initial_pany = y,
                   frames = 2, screenshot = ENV["ROCKS_SCREENSHOT"])
        else
            render(App; frames = 2, screenshot = ENV["ROCKS_SCREENSHOT"])
        end
    else
        render(App)
    end
end
