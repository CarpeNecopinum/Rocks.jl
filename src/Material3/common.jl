# Shared helpers: icons, state layers.

# Material Symbols are not available, so icons are Unicode glyphs rendered as
# `Text`. Extend the dict to add more (the values must be covered by the
# active font — DejaVu Sans covers the defaults).
const ICONS = Dict{String,String}(
    "check" => "✓",
    "close" => "✕",
    "menu" => "☰",
    "more" => "⋯",
    "arrow_back" => "←",
    "arrow_forward" => "→",
    "add" => "+",
    "remove" => "−",
    "home" => "⌂",
    "settings" => "⚙",
    "favorite" => "♥",
    "star" => "★",
    "person" => "☺",
    "mail" => "✉",
    "info" => "ⓘ",
    "warning" => "⚠",
)

"""
    Material3.Icon(name; size = 24, color)

A `Text` element rendering the Unicode glyph registered for `name` in
[`ICONS`](@ref) (unknown names render literally). The name is the call's
positional child.
"""
function Icon(; name = "", size = 24, color = nothing, children = Any[])
    isempty(children) || (name = string(flat_children(children)[1]))
    glyph = get(ICONS, name, name)
    return color === nothing ? (@rock Text(glyph; size = size)) :
           (@rock Text(glyph; size = size, color = color))
end

"""
    Material3.overlay(color, opacity) -> (r, g, b, a)

A Material 3 state layer: `color` at `opacity` (0..1). Components pass it as
`hover_background` / `pressed_background`; the backend blends it over
whatever is behind, so it also works on transparent containers.
"""
overlay(color, opacity) = begin
    r, g, b, a = _to_rgba(color)
    return (r, g, b, UInt8(round(clamp(opacity, 0.0, 1.0) * 255)))
end
