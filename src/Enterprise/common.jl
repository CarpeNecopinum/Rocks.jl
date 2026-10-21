# Shared helpers for the Enterprise controls: icons, themed text, geometry.

# A compact Win7-ish glyph set. Values must be covered by the active font;
# DejaVu Sans covers the defaults.
const ICONS = Dict{String,String}(
    "check" => "✓",
    "close" => "✕",
    "menu" => "☰",
    "more" => "⋯",
    "arrow_back" => "←",
    "arrow_forward" => "→",
    "arrow_up" => "↑",
    "arrow_down" => "↓",
    "add" => "+",
    "remove" => "−",
    "home" => "⌂",
    "settings" => "⚙",
    "folder" => "▣",
    "file" => "▤",
    "save" => "▣",
    "open" => "▤",
    "cut" => "✂",
    "copy" => "⧉",
    "paste" => "▥",
    "undo" => "↶",
    "redo" => "↷",
    "search" => "⌕",
    "help" => "?",
    "info" => "i",
    "warning" => "!",
    "error" => "×",
    "person" => "☺",
    "computer" => "▥",
    "drive" => "▰",
    "printer" => "▧",
    "network" => "☍",
    "refresh" => "⟳",
    "play" => "▶",
    "stop" => "■",
    "separator" => "│",
)

"""
    Enterprise.Icon(name; size = 12, color, children...)

A `Text` element for a glyph in [`ICONS`](@ref). An unknown name renders
literally.
"""
function Icon(; name = "", size = 12, color = nothing, font = nothing,
              children = Any[])
    isempty(children) || (name = string(flat_children(children)[1]))
    glyph = get(ICONS, name, name)
    el = @rock Text(glyph; size = size)
    color !== nothing && (el.props[:color] = color)
    font !== nothing && (el.props[:font] = string(font))
    return el
end

Icon(name::AbstractString; kwargs...) = Icon(; name = name, kwargs...)

function text_element(content; color = nothing, size = 12, font = nothing)
    el = @rock Text(string(content); size = size)
    color !== nothing && (el.props[:color] = color)
    font !== nothing && (el.props[:font] = string(font))
    return el
end

# Wrap raw children in themed Text while letting element children pass through.
function styled_children(kids, t, color = t.colors.text)
    out = Any[]
    for k in flat_children(kids)
        if k isa Element
            push!(out, k)
        elseif k === nothing || k isa Bool
            continue
        else
            push!(out, text_element(k; color = color, size = t.metrics.font_size,
                                    font = t.font))
        end
    end
    return out
end

function text_width(s, t::Theme; size = t.metrics.font_size)
    path = t.font === nothing ? default_font() : t.font
    font = load_font(path, max(round(Int, size), 1))
    w = Ref{Cint}(0)
    h = Ref{Cint}(0)
    TTF_SizeUTF8(font, String(s), w, h)
    return Float64(w[])
end

# A 1px separator used by menus, toolbars and status bars.
function separator(; vertical = false, color = nothing, length = 16)
    t = theme()
    c = something(color, t.colors.border)
    return vertical ?
        (@rock Box(; width = 1, height = length, background = c)) :
        (@rock Box(; width = length, height = 1, background = c))
end

# Text color helper for disabled vs enabled controls.
label_color(t, disabled) = disabled ? t.colors.disabled_text : t.colors.text

function button_style(t, disabled; default = false)
    if disabled
        return (background = t.colors.disabled_bg,
                hover = t.colors.disabled_bg,
                pressed = t.colors.disabled_bg,
                border = t.colors.border,
                text = t.colors.disabled_text)
    elseif default
        return (background = t.gradients.button_default,
                hover = t.gradients.button_default_hover,
                pressed = t.gradients.button_default_pressed,
                border = t.colors.default_border,
                text = t.colors.button_text)
    else
        return (background = t.gradients.button,
                hover = t.gradients.button_hover,
                pressed = t.gradients.button_pressed,
                border = t.colors.border,
                text = t.colors.button_text)
    end
end

# A simple dot pattern used for toolbar/status grips.
function grip_dots(; rows = 3, color = nothing)
    t = theme()
    c = something(color, t.colors.border_dark)
    cols = [(@rock Box(; width = 2, height = 2, background = c)) for _ in 1:2]
    lines = [(@rock Row(cols...; gap = 2, align = :center)) for _ in 1:rows]
    return @rock Column(lines...; gap = 2, align = :center)
end
