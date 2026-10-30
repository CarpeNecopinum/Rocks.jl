# Shared helpers for the Enterprise controls: icons, themed text, geometry.

# A compact Win7-ish unicode glyph set — the built-in icons of the Enterprise
# design. Rocks stays font-agnostic: apps that want a real icon font (Material
# Design Icons, …) load the file themselves and pair each `Icon` with a
# [`Font`](@ref) that supplies the font path (and size, weight, variant).
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
    "select" => "↖",
    "rectangle" => "▭",
    "delete" => "⌫",
    "play" => "▶",
    "stop" => "■",
    "separator" => "│",
)

"""
    Enterprise.Icon(name; size = 12, color, font, children...)

A `Text` element for a glyph in [`ICONS`](@ref); an unknown name renders its
text literally. `name` may be a glyph char already (e.g. an MDI codepoint)
when a `font` is supplied — typically by a wrapping [`Font`](@ref). The
semantic name (or glyph) rides along as an `icon` prop so tests and probes
can address rendered icons by name (`get(f.props, :icon, nothing)`).
"""
function Icon(; name = "", size = 12, color = nothing, font = nothing,
              children = Any[])
    isempty(children) || (name = string(flat_children(children)[1]))
    glyph = get(ICONS, name, name)
    el = @rock Text(glyph; size = size)
    font !== nothing && (el.props[:font] = string(font))
    el.props[:icon] = name
    color !== nothing && (el.props[:color] = color)
    return el
end

Icon(name; kwargs...) = Icon(; name = name, kwargs...)

# The font properties a component function may declare as keywords; `Font`
# passes them through only to components that accept them, so undeclared
# keywords never reach a component call.
const FONT_KW = (:font, :size, :font_weight, :font_variant)

"""
    Enterprise.Font(; font = nothing, weight = nothing, variant = nothing,
                    size = nothing, children...)

Applies font properties to the text rendered by `children` — every `Text`
element in the subtree gets `font` (a path to a TTF/OTF file), `size` (font
size in px) and the descriptive `weight`/`variant` (e.g. `"bold"`,
`"italic"`). Host containers are walked recursively; component elements
receive only the font properties they declare as keywords, so a component
that renders text (e.g. [`Icon`](@ref)) picks them up.

SDL_ttf renders one face per file, so `weight`/`variant` select the file the
application passes as `font`; the values ride along as `font_weight`/
`font_variant` props on `Text` fibers.

An icon-bearing button is therefore a button whose child is a `Font`:

    @rock Pressable(
        @rock Font(font = mdi_font, size = 20, weight = "medium";
                   @rock Icon(0xf05c6; size = 20, color = ...));
        on_press = ...)
"""
function Font(; font = nothing, weight = nothing, variant = nothing, size = nothing,
              children = Any[])
    out = Any[]
    for c in flat_children(children)
        if c isa Element
            apply_font_to_element!(c; font = font, weight = weight,
                                   variant = variant, size = size)
            push!(out, c)
        elseif c === nothing || c isa Bool
            continue
        else
            push!(out, @rock Text(string(c); font = font, size = size))
        end
    end
    return out
end

# Set font properties on one element and recurse into its element descendants.
# Host elements get the props directly; component elements only get the ones
# they declare as keywords (undeclared keywords would fail the component call).
function apply_font_to_element!(el; font = nothing, weight = nothing,
                                variant = nothing, size = nothing)
    if el.kind === Text
        font !== nothing && (el.props[:font] = font)
        size !== nothing && (el.props[:size] = size)
        weight !== nothing && (el.props[:font_weight] = weight)
        variant !== nothing && (el.props[:font_variant] = variant)
    else
        if el.kind isa Function
            for kw in FONT_KW
                val = kw === :font ? font : kw === :size ? size :
                      kw === :font_weight ? weight : variant
                if val !== nothing && kw in kwprops(el.kind)
                    el.props[kw] = val
                end
            end
        else
            font !== nothing && (el.props[:font] = font)
            size !== nothing && (el.props[:size] = size)
            weight !== nothing && (el.props[:font_weight] = weight)
            variant !== nothing && (el.props[:font_variant] = variant)
        end
        for c in el.children
            c isa Element && apply_font_to_element!(c; font = font,
                                                    weight = weight,
                                                    variant = variant,
                                                    size = size)
        end
    end
    return el
end

# Keyword names a component function explicitly declares, pooled over its
# methods. The `kwargs...` catch-all marker is ignored: a wrapper that accepts
# and forwards arbitrary keywords (e.g. `Icon(name; kwargs...)`) still only
# accepts what its target method declares.
function kwprops(kind::Function)
    names = Symbol[]
    for m in methods(kind)
        for kw in Base.kwarg_decl(m)
            kw === Symbol("kwargs...") || push!(names, kw)
        end
    end
    return names
end

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
    w, _ = SDL3.TTF_GetStringSize(font, String(s))
    return Float64(w)
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

# The borderless OS-window popup that hosts a menu: content = a bevel box of
# item rows sized to the window so nothing clips, `:menu_open` carries the
# open observable that `close_open_menus!` flips when the user clicks or
# presses Escape elsewhere.
#
# `x`/`y` are the offset of the popup inside the owner window's client area:
# the popup is created as a child popup of that window, so it lines up with
# the control that opened it on every platform.
function menu_popup(items, t, close; x, y, width, height, open)
    rows = Any[menu_item_row(normalize_item(i), t, close; width = width - 4)
               for i in items]
    box = @rock Box(rows...;
        width = width, height = height,
        background = t.colors.document,
        border_color = t.colors.border, border_width = 1,
        bevel = :raised, radius = 0, padding = 2,
        direction = :column, gap = 0)
    return @rock Window(box;
        position = :manual, x = round(Int,x), y = round(Int,y),
        width = width, height = height,
        popup = true, menu_open = open)
end

# Height of a popup menu holding `items` (separator rows are 5px, entries 22px).
menu_popup_height(items) =
    4 + sum((normalize_item(i).label == "-" ? 5 : 22 for i in items), init = 0)
