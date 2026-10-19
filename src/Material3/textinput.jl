# M3 text input: text field.

"""
    Material3.TextField(; text, label, placeholder, variant, on_submit,
                        helper, disabled, width)

A Material 3 text field. `variant` is `:filled` (a `surfaceContainerHighest`
field with the label inside) or `:outlined` (a transparent field with an
`outline` border that turns `primary` while focused). `text` is an
`Observable{String}` — typing appends to it, Backspace deletes, Return calls
`on_submit()`, Escape releases focus.

```julia
name = @use Observable("")
@rock Material3.TextField(text = name, label = "Name", placeholder = "Ada")
```
"""
function TextField(; text, label = "", placeholder = "", variant = :filled,
                   on_submit = () -> nothing, helper = nothing, disabled = false,
                   width = 280)
    text = @use text # subscribe so typing re-renders
    t = theme()
    v = Symbol(variant)
    v in (:filled, :outlined) ||
        error("text field variant must be :filled or :outlined")
    focused_border = disabled ? overlay(t.on_surface, 0.12) : t.primary
    if v === :outlined
        field = Mechanics.TextField(; text = text, on_submit = on_submit,
            disabled = disabled, label = label, placeholder = placeholder,
            width = width, height = 48, padding = 16, radius = t.shapes.extra_small,
            background = nothing,
            border_color = disabled ? overlay(t.on_surface, 0.12) : t.outline_variant,
            focused_border_color = focused_border, border_width = 1,
            text_color = t.on_surface, placeholder_color = t.on_surface_variant,
            caret_color = t.primary, label_color = t.on_surface_variant,
            size = t.typescale.body_large)
    else # filled
        field = Mechanics.TextField(; text = text, on_submit = on_submit,
            disabled = disabled, label = label, placeholder = placeholder,
            width = width, height = 48, padding = 16, radius = t.shapes.extra_small,
            background = t.surface_container_highest,
            border_color = nothing,
            focused_border_color = focused_border, border_width = 1,
            text_color = t.on_surface, placeholder_color = t.on_surface_variant,
            caret_color = t.primary, label_color = t.on_surface_variant,
            size = t.typescale.body_large)
    end
    helper_kid = helper === nothing ? nothing :
                 (@rock Text(helper; size = t.typescale.body_small,
                             color = t.on_surface_variant))
    return @rock Column(
        field,
        helper_kid;
        gap = 4)
end
