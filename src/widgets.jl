# Pre-styled components, built on top of the primitives (Pressable, Box,
# Text, @use/@rock). These are plain Julia functions like every component.

# Material-UI-inspired accent palette.
const ACCENTS = Dict{Symbol,Tuple{Float64,Float64,Float64}}(
    :primary   => (0.18, 0.50, 0.96),
    :secondary => (0.60, 0.35, 0.94),
    :success   => (0.19, 0.65, 0.35),
    :error     => (0.84, 0.22, 0.22),
    :warning   => (0.95, 0.62, 0.14),
    :info      => (0.04, 0.65, 0.71),
)

_shade(c::Tuple{Float64,Float64,Float64}, f::Real) =
    (clamp(c[1] * f, 0.0, 1.0), clamp(c[2] * f, 0.0, 1.0), clamp(c[3] * f, 0.0, 1.0))

"""
    Button(; label = "", variant = :contained, color = :primary,
           size = :medium, on_press = () -> nothing, disabled = false,
           children = Any[])

Pre-styled button with Material-UI-inspired variants. `variant` is
`:contained` (filled), `:outlined` or `:text`; `color` one of `:primary`,
`:secondary`, `:success`, `:error`, `:warning`, `:info`; `size` one of
`:small`, `:medium`, `:large`. The label is either the `label` prop or the
call's children.

```julia
@rock Button("Save"; on_press = save, variant = :contained, color = :primary)
@rock Button("Delete"; color = :error, variant = :outlined)
```
"""
function Button(; label = "", variant = :contained, color = :primary,
                size = :medium, on_press = () -> nothing, disabled = false,
                children = Any[])
    accent = get(ACCENTS, Symbol(color), ACCENTS[:primary])
    pad, fsize = size === :small ? (6, 12) :
                 size === :large ? (14, 18) : (10, 15)
    kids = isempty(children) ?
           Any[label === "" ? nothing : @rock Text(label; size = fsize)] :
           children
    bg, hbg, pbg, textc, border, bw =
        if disabled
            ((0.32, 0.32, 0.36), (0.32, 0.32, 0.36), (0.32, 0.32, 0.36),
             (0.55, 0.55, 0.58), nothing, 0)
        elseif Symbol(variant) === :outlined
            (nothing, _shade(accent, 0.12), _shade(accent, 0.22), accent, accent, 1)
        elseif Symbol(variant) === :text
            (nothing, _shade(accent, 0.12), _shade(accent, 0.22), accent, nothing, 0)
        else # contained
            (accent, _shade(accent, 1.15), _shade(accent, 0.82), (1.0, 1.0, 1.0),
             nothing, 0)
        end
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => disabled ? () -> nothing : on_press,
            :background => bg,
            :hover_background => hbg,
            :pressed_background => pbg,
            :border_color => border,
            :border_width => bw,
            :disabled => disabled,
            :padding => pad,
            :align => :center,
        ),
        Any[@rock Row(kids...; gap = 6, align = :center)],
    )
end

"""
    Checkbox(; value, label = "", on_change = () -> nothing, disabled = false)

Checkbox with a check mark. `value` is an `Observable{Bool}` (required);
toggling writes it and calls `on_change()`.

```julia
@rock Checkbox("Show grid"; value = show_grid)
```
"""
function Checkbox(; value, label = "", on_change = () -> nothing,
                  disabled = false, size = 16, children = Any[])
    value isa Observable ||
        error("Checkbox needs an `Observable` as its `value` prop")
    accent = ACCENTS[:primary]
    boxbg = value[] ? accent : (0.28, 0.28, 0.32)
    checkcolor = value[] ? (1.0, 1.0, 1.0) : (0.0, 0.0, 0.0, 0.0)
    # the label is either the `label` prop or the call's children
    label_part = isempty(children) ?
                 (label === "" ? nothing :
                  @rock Text(label; color = (0.90, 0.90, 0.92))) :
                 @rock Row(flat_children(children)...; gap = 4, align = :center)
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => () -> begin
                value[] = !value[]
                on_change()
            end,
            :disabled => disabled,
            :align => :center,
        ),
        Any[@rock Row(
            @rock Box(
                @rock Text("✓"; color = checkcolor, size = size - 4);
                width = size, height = size,
                background = boxbg,
                direction = :row, align = :center),
            label_part;
            gap = 8, align = :center)],
    )
end

"""
    Toggle(; value, on_change = () -> nothing, disabled = false)

Switch with a sliding knob. `value` is an `Observable{Bool}` (required);
toggling writes it and calls `on_change()`.

```julia
@rock Toggle(; value = dark_mode)
```
"""
function Toggle(; value, on_change = () -> nothing, disabled = false)
    value isa Observable ||
        error("Toggle needs an `Observable` as its `value` prop")
    accent = ACCENTS[:primary]
    on = value[]
    track_w, track_h, knob = 40, 20, 16
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => () -> begin
                value[] = !value[]
                on_change()
            end,
            :disabled => disabled,
        ),
        Any[@rock Box(
            @rock Box(;
                position = :absolute,
                x = on ? track_w - knob - 2 : 2, y = 2,
                width = knob, height = knob,
                background = on ? (1.0, 1.0, 1.0) : (0.78, 0.78, 0.82));
            width = track_w, height = track_h,
            background = on ? accent : (0.45, 0.45, 0.50))],
    )
end

"""
    RadioGroup(; options, selected, on_change = () -> nothing,
               direction = :column, disabled = false)

Group of radio indicators, one per entry of `options::Vector{String}` (or
the options given as positional children). `selected` is an `Observable{Int}`
holding the 1-based index of the active option; clicking an indicator writes
it and calls `on_change()`.

```julia
@rock RadioGroup(["Small", "Medium", "Large"]; selected = size)
```
"""
function RadioGroup(; selected, on_change = () -> nothing,
                    direction = :column, disabled = false, options = nothing,
                    children = Any[])
    selected isa Observable ||
        error("RadioGroup needs an `Observable` as its `selected` prop")
    # the options are either the `options` prop or the call's children
    opts = String[string(o) for o in flat_children(options !== nothing ? options : children)]
    isempty(opts) && error("RadioGroup needs options (positional children or the `options` prop)")
    accent = ACCENTS[:primary]
    items = Any[
        @rock Pressable(
            @rock Row(
                @rock Box(;
                    width = 14, height = 14,
                    background = selected[] == i ? accent : nothing,
                    border_color = selected[] == i ? accent : (0.55, 0.55, 0.58),
                    border_width = 1),
                @rock Text(option; color = selected[] == i ? (1.0, 1.0, 1.0) : (0.75, 0.75, 0.78));
                gap = 8, align = :center);
            on_press = () -> (selected[] = i; on_change()),
            disabled = disabled,
            align = :center)
        for (i, option) in enumerate(opts)
    ]
    return Element(
        _BOX,
        props_dict(:direction => Symbol(direction), :gap => 6),
        items,
    )
end

"""
    DropDownMenu(; options, selected, on_change = () -> nothing,
                 width = 160, disabled = false)

Dropdown menu: a toggle showing the selected entry of `options::Vector{String}`
(or the options given as positional children), expanding into a list when
clicked. `selected` is an `Observable{Int}` holding the 1-based index; picking
an entry writes it, closes the menu and calls `on_change()`.

```julia
@rock DropDownMenu(["Sans", "Serif", "Mono"]; selected = font)
```
"""
function DropDownMenu(; selected, on_change = () -> nothing,
                      width = 160, disabled = false, options = nothing,
                      children = Any[])
    selected isa Observable ||
        error("DropDownMenu needs an `Observable` as its `selected` prop")
    # the options are either the `options` prop or the call's children
    opts = String[string(o) for o in flat_children(options !== nothing ? options : children)]
    isempty(opts) && error("DropDownMenu needs options (positional children or the `options` prop)")
    open = @use Observable(false)
    accent = ACCENTS[:primary]
    sel = clamp(selected[], 1, max(length(opts), 1))
    entries = Any[
        @rock Pressable(
            @rock Text(option; size = 14,
                       color = i == sel ? (1.0, 1.0, 1.0) : (0.80, 0.80, 0.85));
            on_press = () -> (selected[] = i; open[] = false; on_change()),
            background = i == sel ? _shade(accent, 0.25) : nothing,
            hover_background = _shade(accent, 0.15),
            width = width, padding = 8)
        for (i, option) in enumerate(opts)
    ]
    return Element(
        _BOX,
        props_dict(:direction => :column, :gap => 2),
        Any[
            (@rock Pressable(
                @rock Row(
                    @rock Text(length(opts) >= sel ? opts[sel] : "";
                               size = 14),
                    @rock Text(open[] ? "▲" : "▼"; size = 10,
                               color = (0.60, 0.60, 0.65));
                    gap = 8, align = :center);
                on_press = () -> open[] = !open[],
                disabled = disabled,
                background = (0.25, 0.25, 0.29),
                hover_background = (0.30, 0.30, 0.34),
                border_color = (0.40, 0.40, 0.45),
                border_width = 1,
                width = width, padding = 8, align = :center)),
            open[] && (@rock Box(;
                width = width,
                background = (0.20, 0.20, 0.24),
                border_color = (0.40, 0.40, 0.45),
                border_width = 1,
                children = entries)),
        ],
    )
end

"""
    Tabber(; tabs, selected, children = Any[], on_change = () -> nothing)

Tab bar with one entry of `tabs::Vector{String}` per element in `children`
(passed as the `children` keyword).
`selected` is an `Observable{Int}` with the active tab index (1-based);
clicking a tab writes it and calls `on_change()`. Only the selected child is
rendered, so per-tab component state resets when switching tabs.

```julia
@rock Tabber(["Settings", "About"]; selected = tab, children = [...])
```
"""
function Tabber(; tabs, selected, children = Any[], on_change = () -> nothing)
    selected isa Observable ||
        error("Tabber needs an `Observable` as its `selected` prop")
    kids = flat_children(children)
    accent = ACCENTS[:primary]
    tabbar = Any[
        @rock Pressable(
            @rock Text(tab; color = selected[] == i ? (1.0, 1.0, 1.0) : (0.65, 0.65, 0.68));
            on_press = () -> (selected[] = i; on_change()),
            background = selected[] == i ? _shade(accent, 0.18) : nothing,
            padding = 10, align = :center)
        for (i, tab) in enumerate(tabs)
    ]
    content = length(kids) >= selected[] && selected[] >= 1 ?
              kids[selected[]] : nothing
    return Element(
        _BOX,
        props_dict(:direction => :column, :gap => 8),
        Any[@rock Row(tabbar...; gap = 2), content],
    )
end

"""
    ProgressBar(; value, width = 200, height = 8, color = :primary)

Progress bar. `value` is an `Observable` holding the progress between 0 and
1; the filled portion of the bar tracks it and re-renders on change.

```julia
@rock ProgressBar(; value = progress)
```
"""
function ProgressBar(; value, width = 200, height = 8, color = :primary)
    value isa Observable ||
        error("ProgressBar needs an `Observable` as its `value` prop")
    accent = get(ACCENTS, Symbol(color), ACCENTS[:primary])
    frac = clamp(value[], 0.0, 1.0)
    return Element(
        _BOX,
        props_dict(:width => width, :height => height, :background => (0.25, 0.25, 0.29)),
        Any[@rock Box(;
            position = :absolute, x = 0, y = 0,
            width = round(Int, width * frac), height = height,
            background = accent)],
    )
end
