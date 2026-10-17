---
kind: agents
---

# Rocks.jl — Project Guidelines

Rocks.jl is a React(Native)-style GUI framework in Julia built on SDL2
(SimpleDirectMediaLayer.jl). Components are plain Julia functions; the
`@rock` macro plays the role of React's `createElement` (children as
positional varargs, props as keyword arguments); hooks track component
lifecycle; Windows are components too, so multi-window apps and dialogs are
just conditional rendering. Styling is left to the user — Rocks provides the
primitives: `Window`, `Box`, `Text`, `Pressable`.

## Architecture

```
src/
├── Rocks.jl       # module, exports, includes
├── element.jl     # Element type, @rock macro, host kind singletons
├── hooks.jl       # useState/useEffect/useRef/useMemo/..., timers
├── fiber.jl       # Fiber struct + reconciler (headless-testable)
├── layout.jl      # measure/place passes (headless-testable)
├── backend.jl     # SDL2 backend: windows, textures, fonts, colors, drawing
├── events.jl      # SDL event routing, hit testing, press/hover tracking
├── runtime.jl     # main loop, render entry point, quit!
└── components.jl  # Row/Column convenience components
```

Render cycle: SDL events → setState marks the app dirty → re-render the tree
(component functions re-run, fibers reconciled in place) → run pending
effects → measure/place layout — then draw every window every frame.
Rendering and drawing are decoupled: components only re-run when the app is
dirty, while the current visual state is presented every frame so window
damage (occlusion, off-screen movement) redraws immediately.

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
- Macro kwargs arrive wrapped in `Expr(:parameters, ...)` as the *first*
  positional argument of `@rock` — the macro splits them in element.jl.
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
