# M3 containment: cards, dialog, divider, lists, tooltip.

# ---- Card -----------------------------------------------------------------

"""
    Material3.Card(children...; variant, padding)

A Material 3 card: a 12dp-rounded container. `variant` is `:elevated`
(`surfaceContainerLow`), `:filled` (`surfaceContainerHighest`) or `:outlined`
(`surface` with an `outlineVariant` border).
"""
function Card(; variant = :elevated, padding = 16, children = Any[])
    t = theme()
    v = Symbol(variant)
    bg, border, border_w =
        v === :filled ? (t.surface_container_highest, nothing, 0) :
        v === :outlined ? (t.surface, t.outline_variant, 1) :
        (t.surface_container_low, nothing, 0)
    return Element(
        _BOX,
        props_dict(
            :direction => :column, :padding => padding,
            :radius => t.shapes.medium, :background => bg,
            :border_color => border, :border_width => border_w,
        ),
        flat_children(children),
    )
end

# ---- Dialog ---------------------------------------------------------------

"""
    Material3.Dialog(children...; open, icon, title, actions)

A Material 3 basic dialog: a scrim covering the parent window with a centered
`surfaceContainerHigh` card (28dp radius). `open` is an `Observable{Bool}`;
when false nothing is rendered. `title` and `icon` head the dialog, `actions`
holds the action buttons.

```julia
@rock Material3.Dialog(
    @rock Material3.Text("Delete this item?");
    open = confirm, actions = (@rock Material3.Button("Cancel"),))
```
"""
function Dialog(; open, icon = nothing, title = "", actions = nothing,
                children = Any[])
    open isa Observable ||
        error("Material3.Dialog needs an `Observable{Bool}` as its `open` prop")
    open = @use open # subscribe so opening/closing re-renders
    open[] || return nothing
    t = theme()
    head = Any[
        icon === nothing ? nothing :
        (@rock Box(
            @rock Icon(icon; size = 24, color = t.secondary);
            width = 24, height = 24, direction = :row, align = :center,
            justify = :center)),
        title == "" ? nothing :
        (@rock Text(title; size = t.typescale.headline_small, color = t.on_surface)),
    ]
    action_row = actions === nothing ? nothing :
                 (@rock Row(flat_children(actions)...; gap = 8, align = :end))
    card = @rock Box(
        head...,
        flat_children(children)...,
        action_row;
        position = :absolute, align = :center,
        direction = :column, gap = 16, padding = 24,
        radius = t.shapes.extra_large, background = t.surface_container_high,
        width = 320)
    return @rock Box(
        card;
        position = :absolute, align = :center,
        fill = true, background = t.scrim,
        direction = :row)
end

# ---- Divider --------------------------------------------------------------

"""
    Material3.Divider(; thickness, width)

A Material 3 divider: a 1dp `outlineVariant` line. By default it stretches
across its parent (flow `fill`); pass `width` for a fixed width.
"""
function Divider(; thickness = 1, width = nothing)
    t = theme()
    props = props_dict(:height => thickness, :fill => true,
                       :background => t.outline_variant, :direction => :row)
    width !== nothing && (props[:fill] = false; props[:width] = width)
    return Element(_BOX, props, Any[])
end

# ---- ListItem / List ------------------------------------------------------

"""
    Material3.ListItem(headline; supporting, leading, trailing, on_press)

A Material 3 list item: a 56dp row (72dp with `supporting` text) with optional
`leading`/`trailing` elements, a hover state layer and a divider below.
"""
function ListItem(; headline = "", supporting = nothing, leading = nothing,
                  trailing = nothing, on_press = () -> nothing, children = Any[])
    isempty(children) || (headline = string(flat_children(children)[1]))
    t = theme()
    height = supporting === nothing ? 56 : 72
    head = @rock Text(headline; size = t.typescale.body_large, color = t.on_surface)
    support = supporting === nothing ? nothing :
              (@rock Text(supporting; size = t.typescale.body_medium,
                          color = t.on_surface_variant))
    leading_kid = leading isa AbstractString ?
                  (@rock Icon(leading; size = 24, color = t.on_surface_variant)) :
                  leading
    text_col = @rock Box(
        head, support;
        direction = :column, gap = 2, padding = 0)
    return @rock Column(
        @rock Pressable(
            @rock Row(
                leading_kid,
                text_col,
                trailing;
                gap = 16, align = :center);
            on_press = on_press, padding_x = 16, padding_y = 0, height = height,
            hover_background = overlay(t.on_surface, 0.08), align = :center),
        Divider();
        gap = 0)
end

"""
    Material3.List(items...; gap)

A Material 3 list container: a column of [`ListItem`](@ref)s (or any
elements) with no gap.
"""
function List(; gap = 0, children = Any[])
    return @rock Column(children...; gap = gap)
end

# ---- Tooltip --------------------------------------------------------------

"""
    Material3.Tooltip(content, tip; x, y)

A Material 3 plain tooltip: an `inverseSurface` bubble with `inverseOnSurface`
text shown above `content` while hovered. The wrapper is absolutely positioned
at `x`/`y` inside its parent.
"""
function Tooltip(; content, tip, x = 0, y = 0)
    t = theme()
    open = @use Observable(false)
    bubble = open[] ? (@rock Box(
        @rock Text(tip; size = t.typescale.label_large,
                   color = t.inverse_on_surface);
        padding = 8, radius = t.shapes.extra_small,
        background = t.inverse_surface,
        direction = :row, align = :center)) : nothing
    return @rock Box(
        bubble,
        (@rock Pressable(
            content;
            on_hover_in = () -> open[] = true,
            on_hover_out = () -> open[] = false,
            padding = 0));
        position = :absolute, x = x, y = y,
        direction = :column, align = :center, gap = 4)
end
