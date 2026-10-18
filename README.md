# Rocks.jl

A React(Native)-style GUI framework for Julia, built on SDL2 (via
[SimpleDirectMediaLayer.jl](https://github.com/JuliaMultimedia/SimpleDirectMediaLayer.jl)).

Components are plain Julia functions — there is no separate component
language and no JSX-like sublanguage. The [`@rock`](@ref) macro plays the
role of React's (usually hidden) `createElement` call: children are passed
as positional varargs, props as keyword arguments. Hook functions track the
lifecycle of a component between renders. Windows are components like
everything else, which makes multi-window applications and dialogs just
conditional rendering.

```julia
using Rocks
import Rocks: Text # disambiguate Rocks.Text from Base.Text

function Counter()
    count = @use Observable(0)
    @rock Window(
        @rock Text("Count: ", count; size = 32),
        @rock Pressable(
            @rock Text("Increment");
            on_press = () -> set_count(c -> c + 1),
            background = (0.20, 0.45, 0.95),
            padding = 12, align = :center);
        title = "Counter", width = 380, height = 180,
        padding = 24, gap = 20)
end

render(Counter)
```

## Installation

```julia
pkg> add SimpleDirectMediaLayer   # SDL2 bindings (dependency of Rocks)
pkg> dev /path/to/Rocks.jl        # Rocks is currently not registered
```

On Linux you may need `ALSA_CONFIG_PATH=/usr/share/alsa/alsa.conf` in your
environment (see [Yggdrasil#1432](https://github.com/JuliaPackaging/Yggdrasil/issues/1432)).

## Concepts

### Components are functions

A component is any Julia function that accepts its props as keyword
arguments and returns an element (or a tuple/vector of elements, `nothing`,
or a string which becomes text):

```julia
function Greeting(; name, children = Any[])
    @rock Column(
        @rock Text("Hello, ", name, "!"),
        children...;
        gap = 8)
end

@rock Greeting(; name = "World")
```

Components re-run on every re-render of their subtree. `children` is passed
as a keyword argument (only when non-empty), so child-less components do not
need to declare it.

### Elements and the @rock macro

`@rock Kind(children...; props...)` creates an element — `@rock` applies to
a *call* to the kind, children are the positional arguments, props the
keyword arguments:

```julia
@rock Box(
    @rock Text("Hello, ", name),                    # values are interpolated as text
    @rock Pressable(@rock Text("Press me"); on_press = () -> println("hi"));
    direction = :row, padding = 8)                  # props as keyword arguments
```

`kind` is either one of the built-in host elements (`Window`, `Box`, `Text`,
`Pressable`) or a component function. Strings, numbers and other values used
as children are stringified and concatenated (they become text), and
`nothing`/`false` children are skipped — so `cond && @rock Kind(...)`
conditional rendering works like in JSX. Children may also be written after
the semicolon, intermixed with props:

```julia
@rock Window(
    @rock Text("Main window");
    title = "Main", width = 340,
    open && @rock SecondWindow())
```

### Hooks

Hooks may only be called from component functions, and the number and order
of hook calls must be the same on every render (top level only — no
conditional hooks), exactly like React.

| Hook | Purpose |
| --- | --- |
| `@use expr` | State. `expr` creates a `Ref` or an `Observable` on the first render and is returned on every render. Setting an `Observable` re-renders; `Ref`s are silent. `@use SomeContext` is the context receiver. |
| `useEffect(f, deps = nothing)` | Side effects after render. `nothing` = every render, `()` = once on mount, `(x,)` = when `x` changes. Return a cleanup function from `f`. |
| `useMemo(f, deps)` / `useCallback(f, deps)` | Memoization. |
| `useInterval(f, ms)` / `useTimeout(f, ms)` | Timers, cleaned up automatically on unmount. |

State is a `Ref` or an `Observable` created with `@use` — read and write it
with `obs[]`:

```julia
function Counter()
    count = @use Observable(0)
    @rock Window(
        @rock Text("Count: ", count[]),
        @rock Pressable(
            @rock Text("Increment");
            on_press = () -> count[] += 1);
        title = "Counter")
end
```

Because the observable itself is returned, state can be shared and derived
without extra libraries: `@use someGlobalObservable` subscribes to a global
observable, `@use observablePassedInAsProp` to one owned by a parent, and
`@use map(x -> x.sub, obs)` derives a sub-state whose changes alone trigger
a re-render (setting an observable to an identical value never re-renders).
`@use Ref(0)` replaces React-style `useRef` — mutate `ref[]` silently and
call `request_render()` when a redraw is needed.

### Context

`createContext(default)` creates a context with a `provider` component and a
value that components read with `@use` — the nearest provider above a
component in the fiber tree wins, the `default` otherwise:

```julia
const Theme = createContext((dark = false,))

function Toolbar()
    theme = @use Theme                       # the receiver
    @rock Text("dark mode: ", theme[].dark)
end

function App()
    theme = @use Observable((dark = true,))
    @rock Theme.provider(                    # the provider
        @rock Toolbar();
        value = theme)
end
```

Provide an `Observable` as the `value` so consumers re-render when it changes
(identical values never re-render). Plain values work too — consumers then
update whenever their subtree re-renders.

### Windows are components

A render tree may contain any number of `Window` elements — each becomes a
real SDL window. Multi-window apps and dialogs are just conditional
rendering:

```julia
function App()
    open = @use Observable(false)
    @rock Window(
        @rock Pressable(@rock Text("Open dialog"); on_press = () -> open[] = true);
        title = "Main", width = 400, height = 300,
        open[] && @rock Dialog())
end

function Dialog()
    @rock Window(@rock Text("I am a dialog"); title = "Dialog", width = 300, height = 150)
end
```

Window props: `title`, `width`, `height`, `resizable`, `background`, plus
the positioning props — `position` (`:cascade` default: centered on the
chosen display with a cascade offset per open window; `:centered`: exactly
centered; `:manual`: exact `x`/`y`; `:mouse`: top-left at the pointer),
`display` (display index for the centered modes; default: the display the
pointer is on) and `x`/`y` (giving them without `position` implies
`:manual`) — plus layout props and the callbacks `on_key(key)`,
`on_text_input(text)` and `on_close()`. Returning `false` from `on_close`
keeps the window open; without `on_close`, clicking the X hides the window
(or quits if it is the last visible one). `quit!()` closes all windows and
makes `render` return.

### Built-in elements

Akin to React Native, styling is left to the user. Rocks provides primitives:

* **`Window`** — an OS window.
* **`Box`** — a rectangular container with an optional `background`,
  `border_color`/`border_width`, that lays out its children in a `:column`
  (default) or `:row` `direction` with `gap`, `padding` and cross-axis
  `align` (`:start`, `:center`, `:end`). Fixed `width`/`height` override the
  natural size; `position = :absolute` with `x`/`y` places a child manually.
  `Row`/`Column` are convenience components for directional boxes.
* **`Text`** — stringified children rendered with a TTF font. Props: `size`,
  `color`, `font`. Multi-line text uses `"\\n"`; the default font is
  auto-discovered (or set with `Rocks.set_default_font!(path)`, the
  `ROCKS_FONT` environment variable, or the `font` prop).
* **`Pressable`** — lays out and draws like a `Box`, but participates in
  pointer events. Props: `on_press`, `on_press_in`, `on_press_out`,
  `on_hover_in`, `on_hover_out`, `disabled`, and `background`,
  `hover_background`, `pressed_background` for state-dependent styling.
* **`Image`** — a graphics file (PNG/JPG/BMP/... via SDL2_image). `src` is a
  path or an URL (fetched with `Downloads` and cached); `width`/`height`
  scale it (keeping the aspect ratio when only one is given).
* **`Split`** — a resizable divider: the first two children are panes
  separated by a draggable handle. Props: `direction` (`:horizontal`/
  `:vertical`), `ratio` (an `Observable` — controlled by dragging — or a
  number for the initial position), `handle` (thickness), `handle_color`,
  `width`, `height`.
* **`Slider`** — click or drag to set a value. Props: `value` (an
  `Observable`, required), `min`, `max`, `width`, `height`, `color`,
  `on_change(value)`.

Plus pre-styled components (Material-UI-inspired, built on the primitives):

* **`Button`** — `variant` (`:contained`, `:outlined`, `:text`), `color`
  (`:primary`, `:secondary`, `:success`, `:error`, `:warning`, `:info`),
  `size` (`:small`, `:medium`, `:large`), `label`/children, `on_press`,
  `disabled`.
* **`Checkbox`** / **`Toggle`** — boolean controls bound to an
  `Observable{Bool}` `value`; optional `label` (Checkbox) and `on_change`.
* **`RadioGroup`** — `options::Vector{String}` and an `Observable{Int}`
  `selected` index.
* **`DropDownMenu`** — expanding dropdown with `options` and an
  `Observable{Int}` `selected`.
* **`Tabber`** — tab bar + content: `tabs::Vector{String}`, an
  `Observable{Int}` `selected`, and one `children` element per tab.
* **`ProgressBar`** — an `Observable` `value` between 0 and 1.

```julia
function Settings()
    dark = @use Observable(false)
    size = @use Observable(2)
    @rock Window(
        @rock Column(
            @rock Toggle(; value = dark),
            @rock Checkbox("Show grid"; value = show_grid),
            @rock RadioGroup(["Small", "Medium", "Large"]; selected = size),
            @rock Button("Apply"; on_press = apply, variant = :contained);
            gap = 12, padding = 20);
        title = "Settings", width = 320, height = 280)
end
```

Colors are tuples of 3–4 numbers (all-integer → 0–255, any-float → 0–1),
hex strings (`"#f00"`, `"#00ff00"`, `"#rrggbbaa"`) or ColorTypes colors.

## Rendering model

State updates mark the application dirty; the main loop then re-renders the
tree (component functions re-run, the reconciler updates persistent fibers
in place), runs pending effects and lays out each window. Drawing is
event-driven, not tied to a timer: windows are redrawn after a render pass,
when the window manager exposes them (uncovered, restored), after they are
resized, and on hover/press styling changes (redraw only, components do not
re-run). Pointer styling changes redraw just the affected window; hover/press
callbacks that update state go through the full dirty path. With no timers
or events the main loop blocks, so an idle application neither redraws nor
burns CPU.

Pointer events are dispatched to the deepest fiber under the pointer,
bubbling up to the nearest `Pressable` ancestor, like DOM event targets.

## Examples

See [`examples/`](examples/): `counter.jl`, `clock.jl`, `multiwindow.jl`,
`dialog.jl`, `widgets.jl` (a tour of the pre-styled widgets) and `image.jl`
(the `Image` element with a generated gradient BMP).

```shell
julia --project examples/counter.jl
julia --project examples/widgets.jl
```

Examples are includable: `include("examples/widgets.jl")` defines their
components without rendering (the `render` call is guarded by
`abspath(PROGRAM_FILE) == @__FILE__`).

## Testing

The test suite runs headless (SDL's dummy video driver), so it works without
a display:

```shell
julia --project -e 'using Pkg; Pkg.test()'
```

## Roadmap

* Keyed list reconciliation (full reordering support; `key` currently guards
  index slots only)
* Text wrapping, text input fields, scrolling
* Fractional layout: flexbox-style growing/shrinking (`flex` props)
* Custom drawing (canvas escape hatch), images
* Window-level `on_focus`/`on_resize` callbacks

## License

MIT — see [LICENSE](LICENSE).
