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

struct _WindowKind <: HostKind end
struct _BoxKind <: HostKind end
struct _TextKind <: HostKind end
struct _PressableKind <: HostKind end

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

Props: `background`, `border_color`, `border_width`, `direction` (`:column`
or `:row`), `gap`, `padding`, `align` (`:start`, `:center` or `:end` along
the cross axis), `width`, `height`, and `position = :absolute` with `x`/`y`
to place a child manually instead of flowing it.
"""
const Box = _BoxKind()

"""
    Text

Host element kind for text. The content is given as the children of the
element and is stringified and concatenated, so values can be interpolated
directly: `@rock(Text, "Count: ", count)`. Multi-line text is written with
`"\\n"` line breaks.

Props: `size` (font size in px, default 16), `color`, `font` (path to a TTF
font; defaults to the auto-discovered system font, see
[`set_default_font!`](@ref)).
"""
const Text = _TextKind()

"""
    Pressable

Host element kind for pressable areas (React-Native style). A `Pressable`
lays out and draws like a [`Box`](@ref) but also participates in pointer
event dispatch.

Props: `on_press`, `on_press_in`, `on_press_out`, `on_hover_in`,
`on_hover_out` (all no-argument callables), `disabled`, and the styling props
`background`, `hover_background`, `pressed_background`, `border_color`,
`border_width` plus the layout props of [`Box`](@ref).
"""
const Pressable = _PressableKind()

# Internal aliases used throughout the implementation.
const _WINDOW = Window
const _BOX = Box
const _TEXT = Text
const _PRESSABLE = Pressable

is_host(kind) = kind isa HostKind

"""
    Element(kind, props, children)

An immutable element description created by the [`@rock`](@ref) macro. Not
usually constructed directly.
"""
struct Element
    kind::Any
    props::Dict{Symbol,Any}
    children::Vector{Any}
end

props_dict(; kwargs...) = Dict{Symbol,Any}(kwargs)

"""
    @rock(kind, children...; props...)

Create an element. This is Rocks' equivalent of React's `createElement`
(normally hidden behind JSX): `kind` is either a host element kind
([`Window`](@ref), [`Box`](@ref), [`Text`](@ref), [`Pressable`](@ref)) or a
component function, children are passed as positional varargs, and props as
keyword arguments.

```julia
@rock(Box,
    @rock(Text, "Hello, ", name),
    @rock(Pressable, @rock(Text, "Press me"); on_press = () -> println("hi"));
    direction = :row, padding = 8)
```

Children may also be written after the semicolon, intermixed with props —
which makes trailing conditional rendering read naturally:

```julia
@rock(Window,
    @rock(Text, "Main window");
    title = "Main", width = 340,
    open && @rock(SecondWindow))
```

Strings, numbers and other values used as children are stringified and
concatenated (they become text). `nothing` and `false` children are skipped,
which makes conditional rendering (`cond && @rock(...)`) work like in JSX.
"""
macro rock(args...)
    prop_kw = Any[]
    pos = Any[]
    trailing = Any[] # non-assignment expressions after `;` are children too
    for a in args
        if a isa Expr && a.head === :parameters
            # `@rock(kind, children...; props...)` — the post-`;` expressions
            # arrive wrapped in an Expr(:parameters, ...) as the first
            # argument. `name = value` items and `splats...` are props;
            # everything else (e.g. `open && @rock(SecondWindow)`) is a child.
            for kw in a.args
                if kw isa Expr && (kw.head === :kw || (kw.head === :(=) && kw.args[1] isa Symbol) ||
                                   kw.head === :...)
                    push!(prop_kw, kw)
                else
                    push!(trailing, kw)
                end
            end
        elseif a isa Expr && a.head === :kw
            push!(prop_kw, a)
        elseif a isa Expr && a.head === :(=) && a.args[1] isa Symbol
            # Spaced form: `@rock kind x = 1`
            push!(prop_kw, Expr(:kw, a.args[1], a.args[2]))
        else
            push!(pos, a)
        end
    end
    isempty(pos) && error("@rock needs a kind: a host element kind (Window, Box, Text, Pressable) or a component function")
    kind = popfirst!(pos)
    children = [esc(c) for c in [pos..., trailing...]]
    # Direct props become keyword arguments of props_dict; splats go into the
    # keyword slot too, so both NamedTuples and Pair iterators splat as props.
    prop_args = Any[Expr(:kw, kw.args[1], esc(kw.args[2])) for kw in prop_kw if !(kw isa Expr && kw.head === :...)]
    prop_splats = Any[Expr(:..., esc(kw.args[1])) for kw in prop_kw if kw isa Expr && kw.head === :...]
    call = Expr(:call, :props_dict)
    # In a call AST the keyword-parameters expression comes before the args.
    isempty(prop_splats) || push!(call.args, Expr(:parameters, prop_splats...))
    append!(call.args, prop_args)
    return quote
        Element($(esc(kind)), $call, Any[$(children...)])
    end
end

# Normalize a component's return value into a flat Vector{Any} of elements.
function to_elements(out)
    v = Any[]
    _collect_elements!(v, out)
    return v
end

function _collect_elements!(v, ::Nothing)
    return v
end

function _collect_elements!(v, ::Bool)
    return v # `cond && @rock(...)` idioms produce `false`; skip
end

function _collect_elements!(v, s::AbstractString)
    push!(v, Element(_TEXT, Dict{Symbol,Any}(), Any[String(s)]))
    return v
end

function _collect_elements!(v, e::Element)
    push!(v, e)
    return v
end

function _collect_elements!(v, xs::Union{Tuple,Vector})
    for x in xs
        _collect_elements!(v, x)
    end
    return v
end
