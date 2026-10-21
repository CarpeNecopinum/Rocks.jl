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
| `use_fiber()` | The fiber of the component currently being rendered — event callbacks and effects can use it to look up placed geometry (rects, measured sizes) of their output. |
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
  `border_color`/`border_width` and `radius` (a number, or four corner radii
  `(top_left, top_right, bottom_right, bottom_left)` for partially rounded
  shapes), that lays out its children in a `:column` (default) or `:row`
  `direction` with `gap`, `padding` and cross-axis `align` (`:start`,
  `:center`, `:end`) plus main-axis `justify` (same values). `padding` is a
  number or `(horizontal, vertical)`; `padding_x`/`padding_y` override either
  axis. Fixed `width`/`height` override the natural size;
  `position = :absolute` with `x`/`y` places a child manually, using `anchor`
  (`:top_left` default, `:center`, `:bottom`, `:top_right`, `:bottom_left`,
  `:bottom_right`) as the pinned point. `Row`/`Column` are convenience
  components for directional boxes. `scroll = true` (or `:vertical` /
  `:horizontal`) turns a Box into a clipped scroll container; use
  **`ScrollView`** (below) for a named wrapper.

  `background` (and the `hover_background`/`pressed_background` props of
  `Pressable`) also accepts
  `LinearGradient(top, bottom; direction = :vertical)`. `bevel` draws a
  Win7-style edge — `:raised`, `:sunken`, `:etched` or `:none` — with
  `bevel_light`/`bevel_dark` override colors. `overflow = :visible` lets
  positioned children paint (and receive pointer events) outside the parent's
  rect. `pointer_events = :none` makes a transparent overlay pass clicks
  through to the content below while keeping its children hittable. These
  primitives are used by `Rocks.Enterprise` and are available to custom
  components too.
* **`ScrollView`** — lays out like a `Box`, but clips its flow content to the
  viewport and scrolls it with the mouse wheel. `direction = :column` scrolls
  vertically (default), `:row` horizontally; `scroll_step` sets pixels per
  notch (default 48) and `on_scroll(offset)` reports the new offset. Give it a
  bounded size (`width`/`height`, or `position = :absolute, fill = true`).
  Absolute children stay pinned to the viewport. Set `scrollbar = true` to
  show a draggable scrollbar (`scrollbar_width`, `scrollbar_track`,
  `scrollbar_thumb`, `scrollbar_border`, `scrollbar_radius`); clicking the
  track pages the viewport. Scrollbars are opt-in so ordinary scroll views
  look unchanged.
* **`Text`** — stringified children rendered with a TTF font. Props: `size`,
  `color`, `font`. Multi-line text uses `"\\n"`; the default font is
  auto-discovered (or set with `Rocks.set_default_font!(path)`, the
  `ROCKS_FONT` environment variable, or the `font` prop).
* **`Pressable`** — lays out and draws like a `Box`, but participates in
  pointer events. Props: `on_press`, `on_press_in`, `on_press_out`,
  `on_hover_in`, `on_hover_out`, `disabled`, and `background`,
  `hover_background`, `pressed_background` for state-dependent styling.
  `cursor` picks the pointer shape while hovered — `:hand` (the default
  pressable) or `:text`, which shows the I-beam over editable text.
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

Plus pre-styled components (Material-UI-inspired, built on the primitives;
see also the separate Windows 7 / Winforms set, `Rocks.Enterprise`, below):

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

## Material Design 3

`Rocks.Material3` is a submodule implementing much of the
[Material Design 3](https://m3.material.io/components) specification on top of
the primitives: buttons, FABs, icon buttons, segmented buttons, checkbox,
switch, radio group, slider, chips (assist/filter/input/suggestion), badge,
snackbar, cards, dialog, divider, list, tooltip, navigation bar/rail/drawer,
tabs, top app bar, text fields and a linear progress indicator.

Theming is provided through `createContext`: a non-mutable `Theme` (M3 color
roles as hex strings, the type scale, the shape scale) supplied by
`ThemeContext.provider`. Provide an `Observable{Theme}` to make theme switches
re-render every component:

```julia
using Rocks
import Rocks.Material3
const M3 = Rocks.Material3

theme = Observable(M3.light_theme())

function App()
    @rock M3.ThemeContext.provider(
        @rock M3.Button("Hello"; on_press = () -> println("hi"));
        value = theme)
end

render(App)
```

`M3.dark_theme()` / `M3.light_theme()` are the baseline schemes. Components
read the active theme with `M3.theme()`. Icons are Unicode glyphs from the
`M3.ICONS` dict (extend it with your own).

A small top app bar stays pinned over a scrollable page and changes from
`surface` to `surfaceContainer` once content scrolls behind it, following the
M3 on-scroll fill guidance:

```julia
function Page()
    scrolled = @use Observable(false)
    @rock Window(
        @rock ScrollView(
            @rock Column(
                @rock Box(; height = 48),  # clear the pinned 64px bar
                @rock M3.Card(@rock Text("Content"));
                gap = 16, fill = true);
            position = :absolute, fill = true, padding = 16,
            on_scroll = offset -> scrolled[] = offset > 0),
        @rock M3.TopAppBar("Title"; scrolled = scrolled, height = 64,
            position = :absolute, fill = true);
        title = "Page", width = 480, height = 640)
end
```

See `examples/material3.jl` for a full tour with a live light/dark switch:

```shell
julia --project examples/material3.jl
SDL_VIDEODRIVER=dummy julia --project examples/material3.jl   # headless
```

## Windows 7 / Winforms components

`Rocks.Enterprise` is a second, deliberately old-school component set: raised
gradient buttons, sunken inputs, etched group boxes, menus, toolbars, status
bars, tabs, list/grid views and more, all built on the same primitives and
`Mechanics` as the Material 3 components.

```julia
using Rocks
import Rocks.Enterprise
const E = Rocks.Enterprise

theme = Observable(E.light_theme())
name = Observable("Ada Lovelace")
enabled = Observable(true)

function App()
    @rock E.ThemeContext.provider(
        @rock E.Form(
            @rock E.Column(
                @rock E.GroupBox(
                    @rock E.TextBox(text = name),
                    @rock E.CheckBox(checked = enabled, label = "Enabled");
                    title = "General", fill = true),
                @rock E.Button("Apply"; default = true);
                gap = 12, fill = true);
            menu = (@rock E.MenuBar(menus = [
                E.Menu("File", items = [
                    E.MenuItem(label = "Exit", on_press = Rocks.quit!),
                ]),
            ])),
            title = "Utility", width = 640, height = 420);
        value = theme)
end

render(App)
```

`Enterprise` provides `Button`, `LinkLabel`, `TextBox`, `CheckBox`,
`RadioButton`, `GroupBox`, `Panel`, `ProgressBar`, `Slider`, `SplitContainer`,
`TabControl`, `ListView`, `GridView`, `ComboBox`, `MenuBar`, `ContextMenu`,
`ToolBar`, `StatusBar`, `ToolTip`, `MessageBox` and `Form`. `Form` is the
application scaffold: it pins the optional menu/toolbar/status bars and
scrolls only the client area. `E.light_theme()` is the Aero-inspired default;
`E.classic_theme()` and `E.high_contrast_theme()` are alternatives. Supply an
`Observable{Theme}` to switch themes live.

Menus open as **separate borderless OS popup windows** pinned at their anchor
in screen coordinates, so a menu is never clipped by the edges of its owner
window and always paints above every other window's content (including
dialogues). Clicking anywhere outside the menu (or pressing Escape) closes it,
and that first click is swallowed as the dismiss gesture. Menu titles and
toolbar buttons stay flat under the pointer — the
recessed plastic highlight appears only while an item is pressed or its menu
is open. `MessageBox` opens as its **own OS window** (native title bar and
close button — the close button resolves like the Cancel choice, so no scrim
is drawn over the parent window). `Form` wires the menu window in
automatically through its `menu` prop; a standalone
`ContextMenu` or `MenuBar` should be
given `position = :absolute, fill = true`. A `ComboBox` popup is painted by
the combo itself, so leave vertical room below it (or place it after
potentially overlapping siblings). `GridView` accepts `fill = true` to stretch
its last column across the grid width, and `ToolTip` accepts `offset_y` to
move the tip relative to the wrapped control.

The desktop details are there too: `Form` windows are resizable and drag
re-layout the page live, with the scrolled client ending above the status
bar (which stays anchored to the bottom edge on any window size); scrollbars
carry Win7-style arrow buttons at both ends (styled with
`scrollbar_arrow_background` / `scrollbar_arrow_color`, clicking a page steps
the viewport ~15%), over a darker recessed track with a flat thumb exactly as
wide as the buttons; tab pages melt into their selected
tab through a seam patch so no border line cuts through; `Slider` ticks mark
the thumb travel exactly (the end ticks sit where the knob's center can
reach); check/radio labels follow the theme's font size; and `TextBox` is a
real editing field — caret and visible selection, Shift+arrows/Home/End,
Ctrl+A/C/X/V against the SDL clipboard, Ctrl+←/→ word jumps and insert mode
with the Return/Escape keys wired to focus handling. The mouse works too:
clicking places the caret, holding a button and dragging extends the
selection, and right-click opens an edit menu (Cut, Copy, Paste, Delete,
Select all, disabled to match the current state). Losing focus collapses
the selection and closes that menu, since only one selected piece of text
exists at a time.

See `examples/enterprise.jl` for a full tour — menu bar, toolbar, tabs,
group boxes, text fields, combo box, check/radio buttons, progress/slider,
list and grid views, split panes, tooltip, context menu, status bar and a
message box:

```shell
julia --project examples/enterprise.jl
SDL_VIDEODRIVER=dummy julia --project examples/enterprise.jl   # headless
```

## Examples

See [`examples/`](examples/): `counter.jl`, `clock.jl`, `multiwindow.jl`,
`dialog.jl`, `widgets.jl` (a tour of the pre-styled widgets),
`material3.jl` (the Material 3 component tour with a live light/dark switch),
`enterprise.jl` (the Windows 7 / Winforms showcase), `image.jl`
(the `Image` element with a generated gradient BMP) and `screenshot.jl`
(bounded-frame rendering with a captured PNG).

```shell
julia --project examples/counter.jl
julia --project examples/widgets.jl
```

Examples are includable: `include("examples/widgets.jl")` defines their
components without rendering (the `render` call is guarded by
`abspath(PROGRAM_FILE) == @__FILE__`).

## Screenshots and headless runs

`screenshot(window, path)` captures a window's current frame into a PNG file.
`window` is the root fiber of a rendered tree (the first window found is
captured) or a window fiber; the window is redrawn first, so the file
reflects the current tree. The pixels come from the renderer's backbuffer,
not the windowing system — so this works in normal windows *and* headlessly
with `SDL_VIDEODRIVER=dummy`, whose software renderer writes real pixels:

```julia
root = render(App; frames = 3, screenshot = "app.png")  # bounded + captured
```

`render` takes two runtime keyword arguments that are *not* passed to the
component as props: `frames = N` stops the loop after `N` frames (each frame
waits up to ~250ms for events) and `screenshot = path` captures the first
window right before the application shuts down. Together they enable fully
headless runs — no window is ever shown, but the capture still contains real
pixels:

```shell
SDL_VIDEODRIVER=dummy julia --project examples/screenshot.jl
```

The test suite uses this to pixel-verify captured screenshots without any
display (see `png_pixel` in `test/runtests.jl`).

## Testing

The test suite runs headless (SDL's dummy video driver), so it works without
a display — layout, events, screenshots and down-to-the-pixel render
verification all run against the dummy driver's software renderer:

```shell
julia --project -e 'using Pkg; Pkg.test()'
```

## Roadmap

* Keyed list reconciliation (full reordering support; `key` currently guards
  index slots only)
* Text wrapping, text input fields
* Keyboard scrollbar paging and fractional layout (flexbox-style
  growing/shrinking `flex` props)
* Custom drawing (canvas escape hatch), images
* Window-level `on_focus`/`on_resize` callbacks

## License

MIT — see [LICENSE](LICENSE).
