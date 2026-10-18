---
kind: agents
---

# Rocks.jl — Project Guidelines

Rocks.jl is a React(Native)-style GUI framework in Julia built on SDL2
(SimpleDirectMediaLayer.jl). Components are plain Julia functions; the
`@rock` macro plays the role of React's `createElement` — it applies to a
*call* to the kind (`@rock Text("hi")`), children as positional arguments,
props as keyword arguments; state is created with the `@use` macro as a
`Ref` or `Observable` (Observables.jl) — setting an Observable re-renders,
`@use` also subscribes to shared/global observables and derived `map`
sub-states; other hooks (useEffect, useMemo, useInterval, ...) track
component lifecycle; Windows are components too, so multi-window apps and
dialogs are just conditional rendering. Styling is left to the user — Rocks
provides the primitives: `Window`, `Box`, `Text`, `Pressable`.

## Architecture

```
src/
├── Rocks.jl       # module, exports, includes
├── element.jl     # Element type, @rock macro, host kind singletons
├── hooks.jl       # @use (Ref/Observable state), useEffect/useMemo/..., timers
├── fiber.jl       # Fiber struct + reconciler (headless-testable)
├── layout.jl      # measure/place passes (headless-testable)
├── backend.jl     # SDL2 backend: windows, textures, fonts, colors, drawing
├── events.jl      # SDL event routing, hit testing, press/hover tracking
├── runtime.jl     # main loop, render entry point, quit!
└── components.jl  # Row/Column convenience components
```

Render cycle: SDL events / Observable sets → mark the app dirty → re-render
the tree
(component functions re-run, fibers reconciled in place) → run pending
effects → measure/place layout → mark all windows for drawing. Drawing is
event-driven, not a timer loop: windows carry `needs_draw`/`needs_layout`
flags (WindowState) set by a dirty render pass, `SDL_WINDOWEVENT_EXPOSED`,
`SDL_WINDOWEVENT_RESIZED`/`SIZE_CHANGED` (re-layout only, no component
re-run), and hover/press styling changes (`mark_window_draw!`, redraw only).
The main loop blocks on `SDL_WaitEventTimeout` bounded by the next due
timer — an idle application draws nothing.

## Build & Test

- Tests (headless, uses `SDL_VIDEODRIVER=dummy`):
  `julia --project=. -e 'using Pkg; Pkg.test()'`
- Run an example (needs a display):
  `julia --project=. examples/counter.jl`
- After dependency changes: `julia --project=. -e 'using Pkg; Pkg.resolve()'`

## Conventions

- 4-space indent; docstring every exported API surface.
- Host elements are exported singleton constants (`Window`, `Box`, `Text`,
  `Pressable`) — never functions. Components are functions.
- Hook names start with `use`; hook state structs live in hooks.jl; only
  hooks touch `CURRENT_FIBER`.
- Keep SDL calls out of element.jl/hooks.jl/fiber.jl/layout.jl — those must
  stay headless-testable. SDL belongs in backend.jl/events.jl/runtime.jl.
- Components receive their children via the `children` keyword argument
  (only passed when non-empty) and return an `Element`, a tuple/vector of
  elements, `nothing`, or a string.
- Layout props shared by Box-like hosts: `direction`, `gap`, `padding`,
  `align`, `width`, `height`, `position`/`x`/`y`.
- Colors: accept tuples (all-int → 0-255, any-float → 0-1), hex strings, or
  ColorTypes — normalize through `_to_rgba`.

## Gotchas

- `Text` clashes with `Base.Text` and `run` with `Base.run` when `using
  Rocks`: users should `import Rocks: Text` (examples show the pattern);
  the entry point is named `render` for this reason, `Rocks.run` is a
  qualified alias.
- `@rock` applies to a *call*: the macro receives `Expr(:call, kind, ...)`
  whose args start with the `Expr(:parameters, ...)` kwargs block (when
  present). Only `name = value` items and `splats...` are props; any other
  expression (e.g. `open && @rock SecondWindow()`) is a positional child.
  Spaced macros swallow commas: `@rock A(...), B(...)` inside a call arrives
  as ONE macrocall with a tuple argument — the macro expands each tuple item
  and `Element`'s constructor flattens tuple children.
- Text fibers hold raw content children (no child fibers); string children
  of non-Text hosts become Text elements during reconciliation.
- Effect cleanup must run on unmount; timers/effects are tied to fibers and
  cleaned in `unmount!`.
- Cached TTF fonts are invalidated by `TTF_Quit` — `shutdown_backend`
  closes and clears `FONT_CACHE`, otherwise the next render segfaults.

## Checklist before committing

- `Pkg.test()` passes (66 tests, headless).
- New host element: singleton in element.jl + measure/draw dispatch + docs.
- New hook: hooks.jl with mount/update/unmount semantics + tests.
- New layout prop: layout.jl (measure + place) and document on `Box`.
