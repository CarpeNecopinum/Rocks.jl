# M3 selection: checkbox, switch, radio button, slider, chips.

# ---- Checkbox -------------------------------------------------------------

"""
    Material3.Checkbox(; checked, on_change, disabled, label, children...)

A Material 3 checkbox: an 18dp rounded marker (2dp corner radius) with a `✓`
glyph. `checked` is an `Observable{Bool}`; toggling writes it and calls
`on_change()`.
"""
function Checkbox(; checked, on_change = () -> nothing, disabled = false,
                  label = "", children = Any[])
    checked = @use checked # subscribe so toggling re-renders
    t = theme()
    if disabled
        return Mechanics.Checkbox(; checked = checked, on_change = on_change,
            disabled = true, label = label, children = children,
            size = 18, radius = t.shapes.extra_small,
            checked_background = overlay(t.on_surface, 0.12),
            unchecked_background = nothing,
            checked_border = nothing,
            unchecked_border = overlay(t.on_surface, 0.12),
            border_width = 2, check_color = t.surface,
            label_color = overlay(t.on_surface, 0.38))
    end
    return Mechanics.Checkbox(; checked = checked, on_change = on_change,
        disabled = false, label = label, children = children,
        size = 18, radius = t.shapes.extra_small,
        checked_background = t.primary,
        unchecked_background = nothing,
        checked_border = t.primary,
        unchecked_border = t.on_surface_variant,
        border_width = 2, check_color = t.on_primary,
        label_color = t.on_surface)
end

# ---- Switch ---------------------------------------------------------------

"""
    Material3.Switch(; on, on_change, disabled)

A Material 3 switch: a 52×32dp pill track with a thumb that grows from 16 to
24dp and gains a `✓` glyph when on. `on` is an `Observable{Bool}`.
"""
function Switch(; on, on_change = () -> nothing, disabled = false)
    on = @use on # subscribe so toggling re-renders
    t = theme()
    if disabled
        return Mechanics.Switch(; on = on, on_change = on_change, disabled = true,
            on_track = overlay(t.on_surface, 0.12),
            off_track = overlay(t.on_surface, 0.12),
            on_thumb = overlay(t.on_surface, 0.38),
            off_thumb = overlay(t.on_surface, 0.38),
            border_width = 0, track_border_width = 0,
            on_icon = "✓", icon_color = t.surface)
    end
    return Mechanics.Switch(; on = on, on_change = on_change, disabled = false,
        on_track = t.primary, off_track = t.surface_container_highest,
        on_thumb = t.on_primary, off_thumb = t.outline,
        on_thumb_border = t.on_primary, off_thumb_border = t.outline,
        off_track_border = t.outline, track_border_width = 2,
        border_width = 2,
        on_icon = "✓", icon_color = t.primary_container)
end

# ---- RadioGroup -----------------------------------------------------------

"""
    Material3.RadioGroup(; options, selected, on_change, disabled, direction)

A Material 3 radio button group: one 20dp circle per entry of
`options::Vector{String}` (or the options as positional children). `selected`
is an `Observable{Int}` with the 1-based index of the active option.
"""
function RadioGroup(; options = nothing, selected, on_change = () -> nothing,
                    disabled = false, direction = :column, children = Any[])
    selected = @use selected # subscribe so selection changes re-render
    t = theme()
    opts = String[string(o) for o in flat_children(
        options !== nothing ? options : children)]
    isempty(opts) &&
        error("Material3.RadioGroup needs options (positional children or `options`)")
    ring_sel = disabled ? overlay(t.on_surface, 0.38) : t.primary
    ring_unsel = disabled ? overlay(t.on_surface, 0.38) : t.on_surface_variant
    label_color = disabled ? overlay(t.on_surface, 0.38) : t.on_surface
    items = Element[]
    for (i, option) in enumerate(opts)
        push!(items, Mechanics.Radio(; selected = selected, value = i,
            on_change = on_change, disabled = disabled, label = option,
            label_color = label_color, selected_ring = ring_sel,
            unselected_ring = ring_unsel, dot_color = ring_sel,
            size = 20, border_width = 2))
    end
    return Element(
        _BOX,
        props_dict(:direction => Symbol(direction), :gap => 4),
        items,
    )
end

# ---- Slider ---------------------------------------------------------------

"""
    Material3.Slider(; value, min, max, width, stops)

A Material 3 slider: a 16dp rounded track in `surfaceContainerHighest`, the
active portion in `primary`, a 4dp handle gap at the value and stop
indicators at both ends. `value` is an `Observable`; dragging writes it.
"""
function Slider(; value, min = 0, max = 1, width = 260, stops = true)
    t = theme()
    return Element(
        _SLIDER,
        props_dict(
            :value => value, :min => min, :max => max,
            :width => width, :height => 24,
            :track_color => t.surface_container_highest,
            :active_color => t.primary,
            :track_height => 16,
            :thumb_width => 4,
            :rounded => true,
            :stop_color => stops ? t.primary : nothing,
        ),
        Any[],
    )
end

# ---- Chip -----------------------------------------------------------------

"""
    Material3.Chip(; label, kind, selected, on_press, icon, disabled, elevated)

A Material 3 chip. `kind` is `:assist`, `:filter`, `:input` or `:suggestion`.
Filter chips are selectable: `selected` is an `Observable{Bool}` and the chip
gains a `✓` glyph and a `secondaryContainer` background when selected.
"""
function Chip(; label = "", kind = :assist, selected = nothing,
              on_press = () -> nothing, icon = nothing, disabled = false,
              elevated = false, children = Any[])
    k = Symbol(kind)
    k in (:assist, :filter, :input, :suggestion) ||
        error("chip kind must be :assist, :filter, :input or :suggestion")
    is_filter = k === :filter
    if is_filter
        selected isa Observable ||
            error("Material3.Chip(:filter) needs an `Observable{Bool}` as `selected`")
        selected = @use selected # subscribe so selection changes re-render
    end
    t = theme()
    on = is_filter && selected[]
    if disabled
        bg = nothing
        border = k === :input ? nothing : overlay(t.on_surface, 0.12)
        text_color = overlay(t.on_surface, 0.38)
        icon_color = text_color
        hover = nothing
        press = nothing
    elseif on
        bg = t.secondary_container
        border = nothing
        text_color = t.on_secondary_container
        icon_color = t.on_secondary_container
        hover = overlay(t.on_secondary_container, 0.08)
        press = overlay(t.on_secondary_container, 0.12)
    else
        bg = elevated ? t.surface_container_low : nothing
        border = k === :input ? nothing : t.outline_variant
        text_color = t.on_surface
        icon_color = t.primary
        hover = elevated ? overlay(t.on_surface, 0.08) :
                 overlay(t.on_surface_variant, 0.08)
        press = elevated ? overlay(t.on_surface, 0.12) :
                 overlay(t.on_surface_variant, 0.12)
    end
    leading = if is_filter
        on ? (@rock Icon("check"; size = 18, color = icon_color)) :
             (icon === nothing ? nothing :
              (@rock Icon(icon; size = 18, color = icon_color)))
    else
        icon === nothing ? nothing :
        (@rock Icon(icon; size = 18, color = icon_color))
    end
    label_kids = isempty(children) ?
                 Any[label == "" ? nothing :
                     (@rock Text(label; size = t.typescale.label_large,
                                 color = text_color))] :
                 flat_children(children)
    return Mechanics.Chip(; on_press = on_press, selected = selected,
        disabled = disabled, children = label_kids, leading = leading,
        trailing = nothing, height = 32, padding = icon === nothing ? 16 : 8,
        radius = t.shapes.small, background = bg, hover_background = hover,
        pressed_background = press, border_color = border, border_width = 1,
        text_color = text_color, size = t.typescale.label_large)
end
