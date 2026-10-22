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
    @rock Column(
        @rock Text("Hello, ", name, "!"),  # values are interpolated as text
        children...;
        gap = 8)
end
```

- `@rock` applies to a *call* to the kind: children are the positional
  arguments, props the keyword arguments.
- `nothing`/`false` children are skipped: `cond && @rock Kind(...)` works
  like JSX.
- Components re-run on every re-render; they must return the same hook order.

## Hooks

- `x = @use Observable(0)` — state as an Observable (re-exported by Rocks):
  read/write with `x[]`; setting it triggers a re-render (identical values
  never do). Replaces React-style `useState`.
- `r = @use Ref(0)` — silent mutable ref: mutate `r[]` freely, call
  `request_render()` for a manual redraw. Replaces React-style `useRef`.
- `x = @use someGlobalObservable` / `@use observablePassedInAsProp` —
  subscribe to shared state; unsubscribed automatically on unmount.
- `x = @use SomeContext` — the context receiver: the value provided by the
  nearest `createContext(...).provider` above the component (re-looked-up
  every render; subscribing when the value is an Observable).
- `x = @use map(s -> s.sub, obs)` — derived sub-state; the component only
  re-renders when the mapped value actually changes.
- `useEffect(f, deps = nothing)` — `nothing` = every render, `()` = once on
  mount, `(x,)` = when `x` changes; `f` may return a cleanup function.
- `useMemo(f, deps)` / `useCallback(f, deps)`.
- `useInterval(f, ms)` / `useTimeout(f, ms)` — auto-cleaned on unmount.
- Hooks must be called unconditionally at the top level of a component
  (React rules apply); `@use` expressions are evaluated exactly once, on the
  first render.

## Windows

Windows are components: render `@rock Window(children...; title, width,
height, resizable, background, position, display, x, y, on_key,
on_text_input, on_close)` anywhere in the tree. Positioning: `position` is
`:cascade` (default; centered + cascade offset per open window), `:centered`
(exactly centered), `:manual` (exact `x`/`y`) or `:mouse` (top-left at the
pointer); `display` picks the display for centered modes (`nothing` = the
display the pointer is on); giving `x`/`y` without `position` implies
`:manual`. Multiple windows = multi-window app; `open && @rock Dialog()`
opens a dialog. `quit!()` closes all windows.

## Built-in elements

- `Window` — OS window (also the layout props of Box for its content).
- `Box` — container: `direction` (`:column`/`:row`), `gap`, `padding`
  (number or `(horizontal, vertical)`; `padding_x`/`padding_y` override),
  `align` (cross axis) and `justify` (main axis), both
  `:start`/`:center`/`:end`; `width`, `height`, `background`,
  `border_color`, `border_width`, and `radius` (number or four corner radii
  `(tl, tr, br, bl)`); `position = :absolute` + `x`/`y` to place manually,
  optionally with `anchor` (`:top_left` default, `:center`, `:bottom`,
  `:top_right`, `:bottom_left`, `:bottom_right`). `align`/`justify` remain
  content alignment inside the child. `Row`/`Column` are shortcuts. Set
  `scroll = true` (or `:vertical`/`:horizontal`) to make a Box scrollable.
- `ScrollView` — a clipped, wheel-scrollable Box: `direction = :column`
  (default) or `:row`, `scroll_step` (pixels per notch, default 48), and
  `on_scroll(offset)`. Give it a bounded size (`width`/`height`, or
  `position = :absolute, fill = true`). Absolute children stay pinned.
- `Text` — props `size`, `color`, `font`; `"\\n"` for line breaks.
- `Pressable` — `on_press`, `on_press_in`, `on_press_out`, `on_hover_in`,
  `on_hover_out`, `disabled`; `background`, `hover_background`,
  `pressed_background`.
- `Image` — `src` (path or URL), `width`/`height` scaling.
- `Split` — resizable divider: first two children are panes; `direction`,
  `ratio` (Observable = controlled), `handle`, `width`, `height`.
- `Slider` — `value` (Observable, required), `min`, `max`, `width`,
  `on_change(value)`.

Pre-styled components (widgets.jl): `Button` (variants contained/outlined/
text, colors primary/secondary/success/error/warning/info, sizes),
`Checkbox`, `Toggle` (Observable{Bool} values), `RadioGroup` and
`DropDownMenu` (Observable{Int} selected index over `options::Vector{String}`),
`Tabber` (tabs + one children element per tab), `ProgressBar`
(Observable 0..1). Widgets that index their children flatten them with
`flat_children` first (spaced @rock macrocalls swallow commas into tuples).

Styling is manual (React-Native style): sizes are pixels, colors are tuples
(0-1 floats or 0-255 ints), hex strings or ColorTypes.

## Material Design 3

`Rocks.Material3` provides themed M3 components (Button, FAB, IconButton,
SegmentedButton, Checkbox, Switch, RadioGroup, Slider, Chip, Badge, Snackbar,
Card, Dialog, Divider, List/ListItem, Tooltip, NavigationBar/Rail/Drawer,
Tabs, TopAppBar, TextField, LinearProgress). Theming via `createContext`:

```julia
import Rocks.Material3
const M3 = Rocks.Material3
theme = Observable(M3.light_theme())

function App()
    @rock M3.ThemeContext.provider(
        @rock M3.Button("Hello");
        value = theme)   # Observable{Theme} — theme switches re-render
end
```

- Components read the active theme with `M3.theme()`; `M3.dark_theme()` /
  `M3.light_theme()` are the baseline schemes; the `Theme` struct is
  immutable (updates create new instances).
- Icons are Unicode glyphs from `M3.ICONS` (extend the dict for more).
- `M3.TopAppBar(...; scrolled = obs)` uses `surfaceContainer` instead of
  `surface` when `obs[]` is true. Pair it with a pinned
  `ScrollView` (`position = :absolute, fill = true`) whose `on_scroll` sets
  the flag, and pass the bar `height = 64` so the absolute fill keeps its
  height. Put a 48px spacer at the start of the scroll content to clear the
  bar (`examples/material3.jl`).
- `Rocks.Mechanics` holds the vanilla, appearance-prop-driven controls the M3
  components build on — use them for unstyled but complete behavior.

## Testing apps

Headless (no display needed): set `ENV["SDL_VIDEO_DRIVER"] = "dummy"` before
SDL initializes; render into a fiber tree with `Rocks.create_root` +
`Rocks.perform_render!`, or run the full `render(App)` with a
`useTimeout(quit!, ms)`.

Screenshots: `Rocks.screenshot(window, path)` writes a window's current frame
to a PNG — the pixels come from the renderer's backbuffer, so this works
headlessly too (`SDL_VIDEO_DRIVER=dummy` renders real pixels; no Xvfb needed).
Semi-headless runs: `render(App; frames = N, screenshot = path)` runs `N`
frames and captures the first window before shutting down.
