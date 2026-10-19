---
id: package-dev
name: Developing Rocks.jl Itself
description: How to extend the framework — add host elements, hooks, layout props; test headless
enabled: true
---

Develop the Rocks.jl framework itself. Read `.agents/agents.md` first for
architecture, conventions and gotchas.

## File map

| File | Responsibility |
| --- | --- |
| `src/element.jl` | `Element`, `@rock` macro, host kind singletons |
| `src/hooks.jl` | hook API, `PENDING_EFFECTS`, timers |
| `src/fiber.jl` | `Fiber`, reconciler, unmount, window collection |
| `src/layout.jl` | measure/place passes |
| `src/backend.jl` | SDL2 windows/textures/fonts/colors/drawing |
| `src/events.jl` | event routing, hit testing, pressables |
| `src/runtime.jl` | `render` main loop, `quit!` |
| `src/components.jl` | Row/Column convenience components |
| `src/widgets.jl` | pre-styled components (Button, Checkbox, Toggle, ...) |
| `src/mechanics.jl` | `Mechanics`: vanilla, appearance-prop-driven controls |
| `src/Material3/` | `Material3` submodule: M3-themed components |

## Add a host element

1. Add a singleton in `src/element.jl`: `struct _FooKind <: HostKind end`,
   `const Foo = _FooKind()`, `const _FOO = Foo`, docstring on the constant.
2. Handle it in `measure!`/`place!` (`src/layout.jl`) — natural size and
   child placement.
3. Handle it in `draw!` (`src/backend.jl`) — what it renders.
4. If it participates in pointer events, extend `events.jl`
   (`hit_test`/`find_pressable`/`dispatch_event!`).
5. Add tests in `test/runtests.jl` and an example if user-facing.

## Add a hook

1. Add a state struct and the function in `src/hooks.jl`; reserve the slot
   via `use_hook(mk)`.
2. Effects that must run/cleanup: follow the `EffectHook` pattern; cleanup
   must run in `unmount!` (fiber.jl) and `run_effects!`.
3. Hook state must survive re-renders by call order — test with
   `perform_render!` twice.

## Layout props

Layout is a measure pass (bottom-up natural sizes) and a place pass (top-down
absolute, window-local rects). Shared props live in `layout.jl` helpers
(`flow_children`, `padding_of`, `is_absolute_child`). Windows measure/place
their children into the window rect.

## Testing headless

- `julia --project=. -e 'using Pkg; Pkg.test()'` — all tests run with
  `SDL_VIDEODRIVER=dummy`, no display needed.
- Fiber trees without SDL: `Rocks.create_root(app, NamedTuple())` +
  `Rocks.perform_render!` + `Rocks.run_effects!` — hooks/reconciler are pure.
- Synthetic pointer events: build an `SDL_Event`, `SDL_PushEvent`, then
  `Rocks.dispatch_event!` through the real path (see `push_mouse!` in
  `test/runtests.jl`).
- Pixel tests: `Rocks.screenshot(window, path)` captures a window to PNG
  (works with the dummy driver — the pixels come from the renderer's
  backbuffer, not the windowing system); sample pixels by loading the PNG
  and converting to `SDL_PIXELFORMAT_RGBA32` (see `png_pixel` in
  `test/runtests.jl`).
- Component structure tests: `find_kind(f, kind)` / `collect_kind(f, kind)`
  in `test/runtests.jl` find fibers by kind at any depth (M3 components
  compose 2-3 levels: M3.Button -> Mechanics.Button -> Pressable).
- Rounded shapes: `fill_round_rect` / `ring_round_rect` in `backend.jl`
  (SDL_RenderGeometry; `r = min(w, h)/2` draws circles); `Box`/`Pressable`
  take a `radius` prop.
- Overlays: absolute children take `fill = true` (stretch to the parent),
  corner anchors (`align = :top_right` etc.) and `:center`/`:bottom`; flow
  children fill across the cross axis with `fill = true`.
- Focus: a press focuses the deepest fiber with `:on_key`/`:on_text_input`
  props; keyboard events go to it; `Rocks.has_focus()` tells a component
  whether it holds focus.
- No Xvfb is needed: screenshots render identically under
  `SDL_VIDEODRIVER=dummy` (evaluated: the dummy driver implements window
  framebuffers; `offscreen` behaves the same; x11/Xvfb only adds the real
  X11 code path, not pixels).
- Never let `TTF_Quit` run without clearing `FONT_CACHE` (see
  `shutdown_backend`) — stale font pointers segfault.

## Commands

- Test: `julia --project=. -e 'using Pkg; Pkg.test()'`
- Headless screenshot: `SDL_VIDEODRIVER=dummy julia --project=. examples/screenshot.jl`
- Resolve after deps change: `julia --project=. -e 'using Pkg; Pkg.resolve()'`
- Example: `julia --project=. examples/counter.jl`
