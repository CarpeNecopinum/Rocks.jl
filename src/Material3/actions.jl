# M3 actions: common buttons, FAB, icon buttons, segmented buttons.

# ---- Button ---------------------------------------------------------------

"""
    Material3.Button(; label, variant, on_press, disabled, icon, children...)

A Material 3 common button: a 40dp pill with `labelLarge` text and an optional
leading `icon` (an [`Icon`](@ref) name). `variant` is one of `:filled`,
`:tonal`, `:elevated`, `:outlined`, `:text`. Colors come from the active
theme; disabled buttons use the M3 disabled state (on-surface at 12%/38%).

```julia
@rock Material3.Button("Save"; on_press = save)
@rock Material3.Button("Delete"; variant = :outlined, icon = "close")
```
"""
function Button(; label = "", variant = :filled, on_press = () -> nothing,
                disabled = false, icon = nothing, children = Any[])
    t = theme()
    v = Symbol(variant)
    text_color, bg, hover, press, border, border_w =
        if disabled
            if v in (:text, :outlined)
                (overlay(t.on_surface, 0.38), nothing, nothing, nothing, nothing, 0)
            else
                (overlay(t.on_surface, 0.38), overlay(t.on_surface, 0.12),
                 overlay(t.on_surface, 0.12), overlay(t.on_surface, 0.12), nothing, 0)
            end
        elseif v === :tonal
            (t.on_secondary_container, t.secondary_container,
             overlay(t.on_secondary_container, 0.08),
             overlay(t.on_secondary_container, 0.12), nothing, 0)
        elseif v === :elevated
            (t.primary, t.surface_container_low,
             overlay(t.primary, 0.08), overlay(t.primary, 0.12), nothing, 0)
        elseif v === :outlined
            (t.primary, nothing, overlay(t.primary, 0.08), overlay(t.primary, 0.12),
             t.outline, 1)
        elseif v === :text
            (t.primary, nothing, overlay(t.primary, 0.08), overlay(t.primary, 0.12),
             nothing, 0)
        else # filled
            (t.on_primary, t.primary, overlay(t.on_primary, 0.08),
             overlay(t.on_primary, 0.12), nothing, 0)
        end
    label_kids = isempty(children) ?
                 Any[
                     icon === nothing ? nothing :
                     (@rock Icon(icon; size = 18, color = text_color)),
                     label == "" ? nothing :
                     (@rock Text(label; size = t.typescale.label_large, color = text_color))
                 ] :
                 flat_children(children)
    return Mechanics.Button(; on_press = on_press, disabled = disabled,
        children = label_kids, background = bg, hover_background = hover,
        pressed_background = press, border_color = border, border_width = border_w,
        radius = t.shapes.full, height = 40,
        padding = icon === nothing ? 24 : 16, gap = 8)
end

# ---- FAB ------------------------------------------------------------------

"""
    Material3.FAB(; icon, label, variant, size, on_press, disabled)

A Material 3 floating action button. `size` is `:small` (40dp), `:medium`
(56dp) or `:large` (96dp); giving `label` makes it an extended FAB (a pill).
`variant` picks the color role: `:primary`, `:secondary`, `:tertiary`,
`:surface`.
"""
function FAB(; icon = "add", label = "", variant = :primary, size = :medium,
             on_press = () -> nothing, disabled = false, children = Any[])
    isempty(children) || (icon = string(flat_children(children)[1]))
    t = theme()
    bg, fg = if Symbol(variant) === :secondary
        (t.secondary_container, t.on_secondary_container)
    elseif Symbol(variant) === :tertiary
        (t.tertiary_container, t.on_tertiary_container)
    elseif Symbol(variant) === :surface
        (t.surface_container_high, t.primary)
    else
        (t.primary_container, t.on_primary_container)
    end
    dim = size === :small ? 40 : size === :large ? 96 : 56
    radius = size === :large ? t.shapes.extra_large : t.shapes.large
    icon_color = disabled ? overlay(fg, 0.38) : fg
    kids = Any[
        @rock Icon(icon; size = 24, color = icon_color),
        label == "" ? nothing :
        (@rock Text(label; size = t.typescale.label_large,
                    color = disabled ? icon_color : fg))
    ]
    return Mechanics.Button(; on_press = on_press, disabled = disabled,
        children = kids, background = disabled ? overlay(fg, 0.12) : bg,
        hover_background = overlay(fg, 0.08), pressed_background = overlay(fg, 0.12),
        radius = label == "" ? radius : t.shapes.full, height = dim,
        width = label == "" ? dim : nothing, padding = 16, gap = 12)
end

# ---- IconButton -----------------------------------------------------------

"""
    Material3.IconButton(; icon, variant, on_press, disabled, size)

A Material 3 icon button: a circular pressable with a single glyph. `variant`
is `:standard` (no container), `:filled`, `:tonal` or `:outlined`.
"""
function IconButton(; icon = "", variant = :standard, on_press = () -> nothing,
                    disabled = false, size = 40, children = Any[])
    isempty(children) || (icon = string(flat_children(children)[1]))
    t = theme()
    v = Symbol(variant)
    icon_color, bg, hover, press, border, border_w =
        if disabled
            (overlay(t.on_surface, 0.38), overlay(t.on_surface, 0.12),
             overlay(t.on_surface, 0.12), overlay(t.on_surface, 0.12), nothing, 0)
        elseif v === :filled
            (t.on_primary, t.primary, overlay(t.on_primary, 0.08),
             overlay(t.on_primary, 0.12), nothing, 0)
        elseif v === :tonal
            (t.on_secondary_container, t.secondary_container,
             overlay(t.on_secondary_container, 0.08),
             overlay(t.on_secondary_container, 0.12), nothing, 0)
        elseif v === :outlined
            (t.primary, nothing, overlay(t.primary, 0.08), overlay(t.primary, 0.12),
             t.outline, 1)
        else # standard
            (t.on_surface_variant, nothing, overlay(t.on_surface, 0.08),
             overlay(t.on_surface, 0.12), nothing, 0)
        end
    return Mechanics.Button(; on_press = on_press, disabled = disabled,
        children = Any[@rock Icon(icon; size = 24, color = icon_color)],
        background = bg,
        hover_background = hover, pressed_background = press,
        border_color = border, border_width = border_w,
        radius = t.shapes.full, height = size, width = size, padding = 0)
end

# ---- SegmentedButton ------------------------------------------------------

"""
    Material3.SegmentedButton(; options, selection, multiple, on_change, disabled)

A Material 3 segmented button: one segment per entry of `options::Vector{String}`
(or the options as positional children). `selection` is an `Observable{Int}`
(single select) or `Observable{Vector{Int}}` with `multiple = true`.
"""
function SegmentedButton(; options = nothing, selection, multiple = false,
                         disabled = false, on_change = () -> nothing,
                         children = Any[])
    t = theme()
    return Mechanics.Segmented(; options = options, selection = selection,
        multiple = multiple, disabled = disabled, on_change = on_change,
        height = 40, padding = 16, radius = t.shapes.full,
        segment_radius = t.shapes.full,
        border_color = disabled ? overlay(t.on_surface, 0.12) : t.outline,
        border_width = 1,
        selected_background = t.secondary_container,
        selected_text = disabled ? overlay(t.on_surface, 0.38) :
                         t.on_secondary_container,
        unselected_text = disabled ? overlay(t.on_surface, 0.38) : t.on_surface,
        check_color = t.on_secondary_container,
        children = children)
end
