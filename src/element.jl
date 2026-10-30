# Elements and the @rock macro.
#
# An `Element` is the immutable description of a piece of UI — the equivalent
# of the object React's `createElement` returns. Its `kind` is either
# * a `HostKind` singleton (`Window`, `Box`, `Text`, `Pressable`) rendered by
#   the SDL backend, or
# * a plain Julia function (a *component*), called with the props as keyword
#   arguments on every re-render.

"""
Abstract supertype of the built-in (host) element kinds. Host kinds are
rendered directly by the SDL backend, while component kinds are Julia
functions re-invoked on every render.
"""
abstract type HostKind end

"""
    LinearGradient(top, bottom; direction = :vertical)

A two-stop linear gradient fill accepted anywhere a `background`,
`hover_background`, `pressed_background` or slider track color is accepted.
`direction` is `:vertical` (top to bottom, the default) or `:horizontal`
(left to right). The colors use the same forms as solid colors.
"""
struct LinearGradient
    top::Any
    bottom::Any
    direction::Symbol
    function LinearGradient(top, bottom; direction = :vertical)
        d = Symbol(direction)
        d in (:vertical, :horizontal) ||
            error("LinearGradient direction must be :vertical or :horizontal, got: $direction")
        return new(top, bottom, d)
    end
end

struct _WindowKind <: HostKind end
struct _BoxKind <: HostKind end
struct _ScrollViewKind <: HostKind end
struct _TextKind <: HostKind end
struct _MouseAreaKind <: HostKind end
struct _ImageKind <: HostKind end
struct _SplitKind <: HostKind end
struct _SliderKind <: HostKind end
struct _CanvasKind <: HostKind end

"""
    Window

Host element kind for an OS window. Windows are components like everything
else: a render tree may contain any number of `Window` elements, which turns
into a multi-window application, and a component may conditionally render a
`Window` to open a dialog.

Props: `title`, `width`, `height`, `resizable`, `background`, plus the
positioning props `position`, `display`, `x` and `y`:

* `position = :cascade` (default) — centered on the chosen display with a
  cascade offset per already-open window, so multiple windows don't stack
  exactly on top of each other.
* `position = :centered` — exactly centered on the chosen display.
* `position = :manual` — top-left corner at exactly `x`/`y`.
* `position = :mouse` — top-left corner at the current pointer position.

`display` selects the display index for the centered modes (`nothing`, the
default, means the display the pointer is currently on). Giving `x`/`y`
without a `position` implies `:manual`.

The layout props shared with [`Box`](@ref) (`padding`, `gap`, `direction`,
`align`) control how the window's children are laid out, and the callbacks
`on_key(key)`, `on_text_input(text)` and `on_close()` (return `false` from
`on_close` to keep the window open) are also supported.
"""
const Window = _WindowKind()

"""
    Box

Host element kind for a rectangular layout container. Boxes draw an optional
background/border and lay their children out in a column (default) or a row.
See [`Row`](@ref)/[`Column`](@ref) for convenient wrappers.

Props: `background`, `border_color`, `border_width`, `radius`, `direction`
(`:column` or `:row`), `gap`, `padding`, `align` (`:start`, `:center` or
`:end` along the cross axis), `justify` (the same values along the main
axis), `width`, `height`, and `position = :absolute` with `x`/`y` to place a
child manually instead of flowing it. Absolute children use `anchor`
(`:top_left` by default, or `:center`, `:bottom`, `:top_right`,
`:bottom_left`, `:bottom_right`) to pick the pinned corner/edge; `align`
remains content alignment inside the child.

`scroll = true` (or `:vertical` / `:horizontal`) turns the Box into a scroll
container: its flow content is clipped to the Box and the mouse wheel scrolls
the nearest scroll container under the pointer. `scroll_step` sets the pixels
per wheel notch (default 48) and `on_scroll(offset)` fires when the offset
changes. See [`ScrollView`](@ref) for a named wrapper.
"""
const Box = _BoxKind()

"""
    ScrollView

Host element kind for a scrollable container. It lays out and draws like a
[`Box`](@ref) but clips its flow content to its viewport and lets the mouse
wheel scroll it. `direction = :column` (default) scrolls vertically;
`direction = :row` scrolls horizontally. `scroll_step` sets the pixels per
wheel notch (default 48), and `on_scroll(offset)` is called with the new pixel
offset whenever it changes.

A ScrollView must have a bounded size to be useful: pass `width`/`height`, or
`position = :absolute` with `fill = true` to fill its parent. Absolute
children are pinned to the viewport rather than scrolling with the content.
Use a spacer box at the start of the content (or padding) to keep the first
items clear of a fixed header.

```julia
@rock ScrollView(
    @rock Column(
        @rock Box(; height = 48),  # clear the 64px app bar (+ gaps)
        cards...;
        gap = 16, fill = true);
    position = :absolute, fill = true, padding = 16,
    on_scroll = offset -> scrolled[] = offset > 0)
```
"""
const ScrollView = _ScrollViewKind()

"""
    Text

Host element kind for text. The content is given as the children of the
element and is stringified and concatenated, so values can be interpolated
directly: `@rock Text("Count: ", count)`. Multi-line text is written with
`"\\n"` line breaks.

Props: `size` (font size in px, default 16), `color`, `font` (path to a TTF
font; defaults to the auto-discovered system font, see
[`set_default_font!`](@ref)).
"""
const Text = _TextKind()

"""
    MouseArea

Host element kind for mouse interaction — the single primitive every
interactive control is composed from. A `MouseArea` lays out like a neutral
[`Box`](@ref): it renders its children and contributes no styling of its own
— no background, border or padding unless you explicitly pass styling props,
so wrapping content in `MouseArea(...)` adding nothing visually; it only
makes the subtree interactive. One layout special case: a single child with
`fill = true` (the [`Canvas`](@ref) workspace pattern) is stretched over the
**whole** area, which is what makes canvas draw coordinates and the
callbacks' area-local coordinates coincide.

Props:

* Mouse callbacks — all coordinates are **area-local** (0,0 = area top-left;
  a single `fill = true` child shares one coordinate space with its own draw
  area, e.g. a wrapped canvas):
  * `on_down(x, y, button)` — a button was pressed in the area (left is
    button 1). While the button is held, the area captures the pointer: it
    keeps receiving motion even outside its bounds (drag tracking) until the
    matching release.
  * `on_up(x, y, button)` — the pressed button was released (fires on the
    area the press started in, whether or not the pointer is still inside).
  * `on_click(x, y, button)` — the press was released inside the area.
  * `on_move(x, y)` — the pointer moved over the area while not pressed, and
    moves during a press capture (a pan/drag surface uses this).
  * `on_enter` / `on_leave` — the pointer entered/left the area (no
    arguments).
  * `on_wheel(dx, dy, x, y)` — raw wheel deltas; takes precedence over any
    scrollable ancestor, so a wrapped [`Canvas`](@ref) can zoom inside a
    `ScrollView`.
* `disabled = false` — suppresses all mouse callbacks when true.
* `cursor` — visible pointer shape while hovered: `:grab` (open hand, closed
  while pressed — a pan surface), `:text` (I-beam, what `TextBox` uses),
  `:pan` (the plain arrow while hovered — no hover cursor change — and the
  closed grabbing hand while a non-left button is held, the workspace's
  middle-drag), `:crosshair` (a creation-tool drag), or the default pointing
  hand.
* Legacy aliases kept for the existing [`Pressable`](@ref) API —
  `on_press_in` (≈ `on_down`), `on_press` (≈ `on_click`), `on_press_out`,
  `on_drag(x, y)` (called with area-local coordinates while the pointer is
  held), `on_hover_in`/`on_hover_out` (≈ `on_enter`/`on_leave`).
* Opt-in styling props of [`Box`](@ref) — `background`, `hover_background`,
  `pressed_background`, `border_color`/`border_width`, `bevel`, `radius`,
  `padding`, `direction`, `gap`, `align`, `overflow`, `flex`, `width`,
  `height`, … Pre-styled controls like `Button` set these so the area doubles
  as the visible chip; a bare `MouseArea` stays invisible.

`Pressable` is a legacy synonym of `MouseArea` (the old React-Native-flavored
name); prefer `MouseArea` in new code.

```julia
# A canvas workspace that pans and zooms:
@rock MouseArea(
    @rock Canvas(draw = draw_scene, background = (0.97, 0.97, 0.97), fill = true);
    on_down = (x, y, b) -> (start = (x, y)),
    on_move = (x, y) -> pan_view!(x, y),
    on_wheel = (dx, dy, x, y) -> zoom_at!(x, y, dy),
    cursor = :grab)
```
"""
const MouseArea = _MouseAreaKind()

"Deprecated synonym for [`MouseArea`](@ref)."
const Pressable = MouseArea

"""
    Canvas

Host element kind for an arbitrary, immediately-drawn 2D region — the escape
hatch for content that cannot be expressed as Box/Text/Image (e.g. an
interactive vector canvas). It lays out and clips like a [`Box`](@ref) (drawing
its `background`/`border`/`radius`), then calls its user-supplied `draw`
callback before its children.

Props:

* `draw = canvas -> nothing` — called during the draw pass with a
  [`Rocks.CanvasContext`](@ref) whose helpers draw in **canvas-local**
  coordinates (0,0 = the canvas top-left, y-down, matching the SDL/draw
  axis). `canvas.rect` gives `(x, y, w, h)` in window coordinates.
* Plus the layout/styling props of [`Box`](@ref): `background`,
  `border_color`/`border_width`, `radius`, `width`, `height`, `direction`,
  `gap`, `padding`, `align`, `overflow`, `position = :absolute`, `flex`, …

The canvas is a pure drawing surface: it takes no part in pointer event
dispatch. Make it interactive by wrapping it in a [`MouseArea`](@ref) — as
the area's single `fill = true` child, the canvas and the area coincide
exactly, so the callbacks' **area-local** coordinates match the canvas's
**canvas-local** draw coordinates (a pan/zoom handler reuses the same
transform as the `draw` callback):

The canvas composites naturally with sibling panels, respects parent
clipping, and needs no texture round-trip — a pan/zoom drag re-issues vector
primitives per frame. For full-resolution offscreen work (a raster Preview,
exports, thumbnails), render to a bitmap with a drawing library (e.g. Luxor)
and feed it to the [`Image`](@ref) element instead.

```julia
# A pan/zoom workspace: a closed shape drawn onto the canvas each frame, its
# world→screen transform driven by state that the MouseArea's callbacks update.
function Workspace()
    zoom = @use Observable(1.0)               # view state (renders again)
    pan = @use Observable((40.0, 210.0))      # world → screen offset, px
    start = @use Ref((0.0, 0.0))              # silent hook state (useRef)
    dragging = @use Ref(false)
    shape = [(0, 0), (60, 0), (60, 40), (0, 40)]          # world units, y-up
    local_pt(p) = (p[1]*zoom[] + pan[][1], pan[][2] - p[2]*zoom[])  # y-down
    @rock MouseArea(                          # supplies pan/zoom/cursor
        @rock Canvas(                         # the pure drawing surface
            draw = ctx -> begin
                ctx.clear((0.98, 0.98, 0.98))
                ctx.polyline(local_pt.(shape); color = (0.8, 0.1, 0.1),
                             closed = true)
            end,
            background = nothing);            # children draw on top
        on_down = (x, y, _) -> begin
            start[] = (pan[][1] - x, pan[][2] - y)
            dragging[] = true
        end,
        on_move = (x, y) -> begin
            dragging[] && (pan[] = (start[][1] + x, start[][2] + y))
            nothing
        end,
        on_up = (_, _, _) -> (dragging[] = false),
        cursor = :grab)
end
```
"""
const Canvas = _CanvasKind()

"""
    Image

Host element kind for a graphics file. `src` is a path or an URL (fetched
with `Downloads` and cached in a temporary directory) to a PNG or BMP file,
the formats SDL3 loads natively.

Props: `src` (required), `width`/`height` — scale to `width` (keeping the
aspect ratio) when only one is given, stretch when both are given, natural
size when neither.
"""
const Image = _ImageKind()

"""
    Split

Host element kind for a resizable split: the first two children are the two
panes, separated by a draggable handle that resizes them. Useful as a window
divider.

Props: `direction` (`:horizontal` — panes side by side, or `:vertical` —
panes stacked), `ratio` — an `Observable` (controlled: dragging writes it) or
a number (the initial split position, default 0.5), `handle` (handle
thickness in px, default 6), `handle_color`, `width`, `height`. The panes are
laid out to fill their side of the split exactly, so give them backgrounds to
see them.
"""
const Split = _SplitKind()

"""
    Slider

Host element kind for a slider: click or drag anywhere on it to set its
value.

Props: `value` — an `Observable` (required; dragging writes it), `min` and
`max` (default 0 and 1), `width` (default 200), `height` (default 24), and an
`on_change(value)` callback fired while the value changes.
"""
const Slider = _SliderKind()

# Internal aliases used throughout the implementation.
const _WINDOW = Window
const _BOX = Box
const _SCROLLVIEW = ScrollView
const _TEXT = Text
const _PRESSABLE = Pressable          # legacy alias (=== MouseArea)
const _MOUSEAREA = MouseArea
const _IMAGE = Image
const _SPLIT = Split
const _SLIDER = Slider
const _CANVAS = Canvas

is_host(kind) = kind isa HostKind

# Flatten tuple/vector children (nested `@rock` calls in one invocation
# arrive as tuples, because spaced macros swallow commas) so an Element's
# children are always a flat list.
function _flatten_children!(v, c)
    if c isa Union{Tuple,Vector}
        for sub in c
            _flatten_children!(v, sub)
        end
    else
        push!(v, c)
    end
    return v
end

"""
    Element(kind, props, children)

An immutable element description created by the [`@rock`](@ref) macro. Not
usually constructed directly.
"""
struct Element
    kind::Any
    props::Dict{Symbol,Any}
    children::Vector{Any}
    function Element(kind, props, children)
        v = Any[]
        for c in children
            _flatten_children!(v, c)
        end
        new(kind, props, v)
    end
end

props_dict(args...; kwargs...) = begin
    dict = Dict{Symbol,Any}()
    for a in args
        a isa Pair ||
            error("expected `name = value` or splatted pairs after the semicolon in @rock, got: $a")
        dict[Symbol(a.first)] = a.second
    end
    for (k, v) in kwargs
        dict[Symbol(k)] = v
    end
    dict
end

"""
    FLEX_PROPS

The props that size a component inside its parent.  They belong to the
component itself — the box around it lays it out with them — so they are not
passed on to the component function: every component can be sized by the flexbox
model without having to declare the props.
"""
const FLEX_PROPS = (:flex, :flex_grow, :flex_shrink, :flex_basis, :align_self,
                    :margin, :min_width, :max_width, :min_height, :max_height)

"""
    @rock Kind(children...; props...)
    @rock Kind()

Create an element by applying `@rock` to a call to the kind: children are
the positional arguments of the call, props the keyword arguments. `kind`
is either a host element kind ([`Window`](@ref), [`Box`](@ref),
[`Text`](@ref), [`Pressable`](@ref)) or a component function.

```julia
@rock Window(
    @rock Text("Hello, ", name),
    @rock Pressable(
        @rock Text("Press me");
        on_press = () -> println("hi"));
    direction = :row, padding = 8)
```

Children may also be written after the semicolon, intermixed with props —
which makes trailing conditional rendering read naturally:

```julia
@rock Window(
    @rock Text("Main window");
    title = "Main", width = 340,
    open && @rock SecondWindow())
```

Strings, numbers and other values used as children are stringified and
concatenated (they become text). `nothing` and `false` children are skipped,
which makes conditional rendering (`cond && @rock Kind(...)`) work like in
JSX.
"""
macro rock(call)
    if call isa Expr && call.head === :tuple
        # Spaced macros swallow commas: `@rock A(...), B(...)` arrives as the
        # tuple `(A(...), B(...))`. Calls become their own elements; other
        # expressions (macrocalls, conditionals like `open && @rock B()`) are
        # passed through as child expressions. The resulting tuple is
        # flattened into the parent's children.
        for item in call.args
            item isa Expr && item.head === :kw && error(
                "a prop (`$(item.args[1]) = ...`) after a trailing comma was " *
                "captured by the previous @rock call — put props after the " *
                "`;` separator instead",
            )
        end
        items = Any[
            item isa Expr && item.head === :call ?
            Expr(:macrocall, Symbol("@rock"), __source__, item) : item
            for item in call.args
        ]
        return Expr(:tuple, esc.(items)...)
    end
    if !(call isa Expr && call.head === :call)
        # `@rock Kind` — an element with no children and no props
        return quote
            Element($(esc(call)), props_dict(), Any[])
        end
    end
    kind = call.args[1]
    prop_kw = Any[]
    pos = Any[]       # positional children (before the semicolon)
    trailing = Any[]  # non-assignment expressions after the semicolon
    # Visit the call's arguments, flattening nested `;` parameter groups
    # (`f(a; k = v; k2 = w)` parses as nested `parameters` blocks). Items
    # inside a parameters block come after the semicolon, so they are
    # trailing children; top-level items are positional.
    function visit_arg(a, where)
        if a isa Expr && a.head === :parameters
            for kw in a.args
                visit_arg(kw, :trailing)
            end
        elseif a isa Expr && a.head === :kw
            push!(prop_kw, a)
        elseif a isa Expr && a.head === :...
            # splats inside a `;` group are props; positional splats are
            # children
            push!(where === :trailing ? prop_kw : pos, a)
        elseif a isa Expr && a.head === :(=) && a.args[1] isa Symbol
            push!(prop_kw, Expr(:kw, a.args[1], a.args[2]))
        else
            push!(where === :trailing ? trailing : pos, a)
        end
    end
    for a in call.args[2:end]
        visit_arg(a, :pos)
    end
    children = [esc(c) for c in [pos..., trailing...]]
    # Direct props become keyword arguments of props_dict; splats go into the
    # keyword slot too, so both NamedTuples and Pair iterators splat as props.
    prop_args = Any[Expr(:kw, kw.args[1], esc(kw.args[2])) for kw in prop_kw if !(kw isa Expr && kw.head === :...)]
    prop_splats = Any[Expr(:..., esc(kw.args[1])) for kw in prop_kw if kw isa Expr && kw.head === :...]
    props_call = Expr(:call, :props_dict)
    isempty(prop_splats) || push!(props_call.args, Expr(:parameters, prop_splats...))
    append!(props_call.args, prop_args)
    return quote
        Element($(esc(kind)), $props_call, Any[$(children...)])
    end
end

# Migration guard for the old `@rock(Kind, children...; props...)` syntax.
macro rock(kind, args...)
    return error(
        "the @rock macro applies to a call: write " *
        "`@rock Kind(children...; props...)` instead of " *
        "`@rock(Kind, children...; props...)`",
    )
end

# Normalize a component's return value (or a list of raw children) into
# elements: strings/values become text, `nothing`/`false` are skipped
# (conditional rendering idioms), tuples/vectors of elements are flattened.
function push_children!(v, e)
    if e isa Element
        push!(v, e)
    elseif e isa AbstractString
        push!(v, Element(_TEXT, Dict{Symbol,Any}(), Any[String(e)]))
    elseif e isa Union{Tuple,Vector}
        for sub in e
            push_children!(v, sub)
        end
    elseif e === nothing || e isa Bool
        # skipped
    else
        push!(v, Element(_TEXT, Dict{Symbol,Any}(), Any[string(e)]))
    end
    return v
end

function to_elements(out)
    return push_children!(Any[], out)
end

# Flatten tuple/vector children (spaced @rock macrocalls swallow commas, so
# arrays of elements arrive as nested tuples). Single elements and `nothing`
# are accepted too.
function flat_children(children)
    children isa Element && return Any[children]
    children === nothing && return Any[]
    out = Any[]
    for c in children
        if c isa Union{Tuple,Vector}
            append!(out, flat_children(c))
        else
            push!(out, c)
        end
    end
    return out
end
