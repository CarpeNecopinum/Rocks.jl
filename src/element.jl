# Elements and the @rock macro.
#
# An `Element` is the immutable description of a piece of UI — the equivalent
# of the object React's `createElement` returns. Its `kind` is either
# * a `HostKind` singleton (`Window`, `Box`, `Label`, `Button`, ...) mapped
#   onto a native GTK widget by the backend, or
# * a plain Julia function (a *component*), called with the props as keyword
#   arguments on every re-render.

"""
Abstract supertype of the built-in (host) element kinds. Host kinds are
mapped onto native GTK widgets by the backend, while component kinds are
Julia functions re-invoked on every render.
"""
abstract type HostKind end

struct _WindowKind <: HostKind end
struct _BoxKind <: HostKind end
struct _LabelKind <: HostKind end
struct _ButtonKind <: HostKind end
struct _PictureKind <: HostKind end
struct _PanedKind <: HostKind end
struct _ScaleKind <: HostKind end
struct _CheckButtonKind <: HostKind end
struct _SwitchKind <: HostKind end
struct _ProgressBarKind <: HostKind end
struct _DropDownKind <: HostKind end
struct _NotebookKind <: HostKind end
struct _EntryKind <: HostKind end

"""
    Window

Host element kind for an OS window (a `GtkWindow`). Windows are components
like everything else: a render tree may contain any number of `Window`
elements, which turns into a multi-window application, and a component may
conditionally render a `Window` to open a dialog.

Props: `title`, `width`, `height`, `resizable`, plus the callback
`on_close()` (return `false` from `on_close` to keep the window open).
"""
const Window = _WindowKind()

"""
    Box

Host element kind for a layout container (a `GtkBox`). Boxes lay their
children out in a column (default) or a row. See [`Row`](@ref)/[`Column`](@ref)
for convenient wrappers.

Props: `direction` (`:column` or `:row`), `gap` (spacing between children,
default 0), `padding` (uniform margin around the children), `width`,
`height`, and `background` (a CSS color string applied via GTK CSS).
"""
const Box = _BoxKind()

"""
    Label

Host element kind for text (a `GtkLabel`). The content is given as the
children of the element and is stringified and concatenated, so values can be
interpolated directly: `@rock Label("Count: ", count)`. Multi-line text is
written with `"\\n"` line breaks; `wrap = true` wraps long lines.

Props: `size` (font size in px via CSS, default 16), `color` (a CSS color
string), `wrap`, `align` (`:start`, `:center` or `:end` for the horizontal
text alignment).
"""
const Label = _LabelKind()

"""
    Button

Host element kind for a push button (a `GtkButton`). The button's label is
given as the children of the element (stringified) or via `label` as a prop.

Props: `on_press` (a no-argument callable, fired on click), `disabled`
(greys the button out and ignores clicks), `label` (a string; the children
win when given).
"""
const Button = _ButtonKind()

"""
    Picture

Host element kind for a graphics file (a `GtkPicture`). `src` is a path or an
URL (fetched with `Downloads` and cached in a temporary directory) to a
PNG/JPG/... file.

Props: `src` (required), `width`/`height` — scale to fit, keeping the aspect
ratio unless both are given.
"""
const Picture = _PictureKind()

"""
    Paned

Host element kind for a resizable split (a `GtkPaned`): the first two
children are the two panes, separated by a draggable divider.

Props: `direction` (`:horizontal` — panes side by side, or `:vertical` —
panes stacked), `ratio` — an `Observable` (controlled: dragging writes it) or
a number (the initial split position, default 0.5), `width`, `height`.
"""
const Paned = _PanedKind()

"""
    Scale

Host element kind for a slider (a `GtkScale`): click or drag to set its
value.

Props: `value` — an `Observable` (required; dragging writes it), `min` and
`max` (default 0 and 1), `width` (default 200), `on_change(value)` fired
while the value changes.
"""
const Scale = _ScaleKind()

"""
    CheckButton

Host element kind for a check button (a `GtkCheckButton`) — a checkbox with
an optional label.

Props: `checked` — an `Observable{Bool}` (two-way), `label`, `on_change()`.
"""
const CheckButton = _CheckButtonKind()

"""
    Switch

Host element kind for a switch (a `GtkSwitch`).

Props: `on` — an `Observable{Bool}` (two-way), `on_change()`.
"""
const Switch = _SwitchKind()

"""
    ProgressBar

Host element kind for a progress bar (a `GtkProgressBar`).

Props: `fraction` — a number or `Observable` between 0 and 1.
"""
const ProgressBar = _ProgressBarKind()

"""
    DropDown

Host element kind for a dropdown (a `GtkDropDown`): a collapsed selection
that expands into a list.

Props: `options` (a vector of strings, or the options as the call's
children), `selected` — an `Observable{Int}` with the 1-based index
(two-way), `on_change()`.
"""
const DropDown = _DropDownKind()

"""
    Notebook

Host element kind for a tabbed container (a `GtkNotebook`): one entry of
`tabs::Vector{String}` per element in `children`; the selected page is shown
and switching tabs is handled by GTK.

Props: `tabs` (required), `selected` — an `Observable{Int}` with the active
page index (two-way).
"""
const Notebook = _NotebookKind()

"""
    Entry

Host element kind for a single-line text entry (a `GtkEntry`).

Props: `text` — an `Observable{String}` (two-way), `placeholder`,
`on_submit()` (fired on Enter), `width`.
"""
const Entry = _EntryKind()

# Internal aliases used throughout the implementation.
const _WINDOW = Window
const _BOX = Box
const _LABEL = Label
const _BUTTON = Button
const _PICTURE = Picture
const _PANED = Paned
const _SCALE = Scale
const _CHECKBUTTON = CheckButton
const _SWITCH = Switch
const _PROGRESSBAR = ProgressBar
const _DROPDOWN = DropDown
const _NOTEBOOK = Notebook
const _ENTRY = Entry

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
# Find an assignment in a *positional* position (not inside a `;` parameter
# block). The Julia parser folds comma-separated items into a tuple, and a
# prop that lost its `;` separator becomes an assignment inside that tuple —
# the parser then rejects the result with a confusing "invalid argument
# destructuring syntax" error. Only `name = value` and `(a, b) = value`
# shapes are reported; assignments to a field (`x[] = v`) are ordinary
# expressions and stay allowed.
function find_positional_assignment(x)
    x isa Expr || return nothing
    x.head === :parameters && return nothing # props live here
    if x.head === :(=)
        lhs = x.args[1]
        if lhs isa Symbol || (lhs isa Expr && lhs.head === :tuple)
            return x
        end
    end
    for a in x.args
        found = find_positional_assignment(a)
        found === nothing || return found
    end
    return nothing
end

macro rock(call)
    if call isa Expr && call.head === :tuple
        # Spaced macros swallow commas: `@rock A(...), B(...)` arrives as the
        # tuple `(A(...), B(...))`. Calls become their own elements; other
        # expressions (macrocalls, conditionals like `open && @rock B()`) are
        # passed through as child expressions. The resulting tuple is
        # flattened into the parent's children.
        for item in call.args
            if item isa Expr && item.head === :kw
                error(
                    "a prop (`$(item.args[1]) = ...`) after a trailing comma was " *
                    "captured by the previous @rock call — put props after the " *
                    "`;` separator instead",
                )
            elseif item isa Expr && item.head === :(=) && item.args[1] isa Symbol
                error(
                    "a prop (`$(item.args[1]) = ...`) after a trailing comma was " *
                    "captured by the previous @rock call — put props after the " *
                    "`;` separator instead",
                )
            end
            # The same mistake one level deeper: the parser folds the items
            # after a comma into a tuple, and a prop that lost its `;`
            # separator turns into an assignment inside that tuple (which the
            # parser then rejects with a confusing "invalid argument
            # destructuring syntax").
            swallowed = find_positional_assignment(item)
            swallowed === nothing && continue
            error(
                "a prop was captured by the previous @rock call — put props " *
                "after the `;` separator instead (offending item: " *
                "`$(swallowed)`)",
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
        push!(v, Element(_LABEL, Dict{Symbol,Any}(), Any[String(e)]))
    elseif e isa Union{Tuple,Vector}
        for sub in e
            push_children!(v, sub)
        end
    elseif e === nothing || e isa Bool
        # skipped
    else
        push!(v, Element(_LABEL, Dict{Symbol,Any}(), Any[string(e)]))
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
