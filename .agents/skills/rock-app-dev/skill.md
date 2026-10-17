---
id: rock-app-dev
name: Writing Apps with Rocks.jl
description: Patterns for building GUI applications with the Rocks.jl framework (components, hooks, windows, styling)
enabled: true
---

Write Rocks.jl applications following these patterns. Rocks is a
React(Native)-style GUI framework: components are plain Julia functions, no
JSX-like language. See `.agents/agents.md` for architecture background.

## Setup

```julia
using Rocks
import Rocks: Text   # Rocks.Text clashes with Base.Text
```

The entry point is `render(App)` (not `run` — that clashes with `Base.run`).

## Components

Components are functions taking props as keyword arguments, returning an
element created with `@rock`:

```julia
function Greeting(; name, children = Any[])
    @rock(Column,
        @rock(Text, "Hello, ", name, "!"),  # values are interpolated as text
        children...;
        gap = 8)
end
```

- Children are positional varargs of `@rock`, props are keyword arguments.
- `nothing`/`false` children are skipped: `cond && @rock(...)` works like JSX.
- Components re-run on every re-render; they must return the same hook order.

## Hooks

- `count, set_count = useState(0)` — setter takes a value or `c -> c + 1`.
- `useEffect(f, deps = nothing)` — `nothing` = every render, `()` = once on
  mount, `(x,)` = when `x` changes; `f` may return a cleanup function.
- `useRef(v)` — mutable `.current`, survives re-renders silently.
- `useMemo(f, deps)` / `useCallback(f, deps)`.
- `useInterval(f, ms)` / `useTimeout(f, ms)` — auto-cleaned on unmount.
- Hooks must be called unconditionally at the top level of a component
  (React rules apply).

## Windows

Windows are components: render `@rock(Window, children...; title, width,
height, resizable, background, on_key, on_text_input, on_close)` anywhere in
the tree. Multiple windows = multi-window app; `open && @rock(Dialog)` opens
a dialog. `quit!()` closes all windows.

## Built-in elements

- `Window` — OS window (also the layout props of Box for its content).
- `Box` — container: `direction` (`:column`/`:row`), `gap`, `padding`,
  `align` (`:start`/`:center`/`:end`), `width`, `height`, `background`,
  `border_color`, `border_width`; `position = :absolute` + `x`/`y` to place
  manually. `Row`/`Column` are shortcuts.
- `Text` — props `size`, `color`, `font`; `"\\n"` for line breaks.
- `Pressable` — `on_press`, `on_press_in`, `on_press_out`, `on_hover_in`,
  `on_hover_out`, `disabled`; `background`, `hover_background`,
  `pressed_background`.

Styling is manual (React-Native style): sizes are pixels, colors are tuples
(0-1 floats or 0-255 ints), hex strings or ColorTypes.

## Testing apps

Headless (no display needed): set `ENV["SDL_VIDEODRIVER"] = "dummy"` before
SDL initializes; render into a fiber tree with `Rocks.create_root` +
`Rocks.perform_render!`, or run the full `render(App)` with a
`useTimeout(quit!, ms)`.
