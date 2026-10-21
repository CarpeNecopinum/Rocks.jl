# Menus, toolbars, status bars and tooltips.

# ---- menu data ------------------------------------------------------------

"""
    Enterprise.MenuItem(; label, on_press, shortcut, checked, enabled, submenu)

One menu entry. `label = "-"` (or [`MenuSeparator`](@ref)) draws a separator.
`checked` may be a `Bool` or a `Bool` `Observable`.
"""
struct MenuItem
    label::String
    on_press::Any
    shortcut::String
    checked::Any
    enabled::Bool
    submenu::Any
end

MenuItem(; label = "", on_press = () -> nothing, shortcut = "",
         checked = nothing, enabled = true, submenu = nothing) =
    MenuItem(string(label), on_press, string(shortcut), checked, enabled, submenu)

MenuSeparator() = MenuItem(label = "-")

"""
    Enterprise.Menu(label; items)

A top-level menu made of [`MenuItem`](@ref)s.
"""
struct Menu
    label::String
    items::Vector{Any}
end

Menu(label; items = Any[]) = Menu(string(label), Any[items...])

normalize_menu(m) = m isa Menu ? m :
    (m isa Tuple || m isa Vector) ? Menu(string(m[1]), Any[m[2]...]) :
    error("a menu must be a Menu or a (label, items) tuple, got: $m")

normalize_item(i) = i isa MenuItem ? i :
    i isa AbstractString ? MenuItem(label = i) :
    (i isa Tuple || i isa Vector) ? MenuItem(label = string(i[1]),
                                             on_press = get(i, 2, () -> nothing)) :
    error("a menu item must be a MenuItem, string or tuple, got: $i")

item_checked(item) = item.checked isa Observable ? Bool(item.checked[]) :
                     Bool(something(item.checked, false))

# A single menu row. `close` runs after the item callback; `width` is the
# dropdown content width.
function menu_item_row(item::MenuItem, t::Theme, close; width = 196)
    if item.label == "-"
        return (@rock Box(;
            width = width, height = 5, padding_x = 6, padding_y = 2,
            direction = :row,
            children = Any[(@rock Box(; width = width - 12, height = 1,
                                      background = t.colors.border))]))
    end
    enabled = item.enabled
    text_color = enabled ? t.colors.text : t.colors.disabled_text
    checked = item_checked(item)
    shortcut = item.shortcut == "" ? nothing :
               (@rock Box(
                   text_element(item.shortcut; color = text_color,
                                size = t.metrics.font_size, font = t.font);
                   position = :absolute, anchor = :top_right, x = 6, y = 3))
    arrow = item.submenu === nothing ? nothing :
            (@rock Box(
                text_element("►"; color = text_color,
                             size = t.metrics.font_size, font = t.font);
                position = :absolute, anchor = :top_right, x = 6, y = 3))
    check = @rock Box(
        checked ? text_element("✓"; color = text_color,
                               size = t.metrics.font_size, font = t.font) : nothing;
        width = 16, height = 18, direction = :row, align = :center,
        justify = :center)
    label = text_element(item.label; color = text_color,
                         size = t.metrics.font_size, font = t.font)
    body = @rock Row(check, label; gap = 2, align = :center)
    return @rock Pressable(
        body, shortcut, arrow;
        on_press = () -> begin
            close()
            enabled && item.on_press isa Function && item.on_press()
        end,
        disabled = !enabled,
        background = checked ? t.colors.hot : nothing,
        hover_background = enabled ? t.colors.hot : nothing,
        pressed_background = enabled ? t.colors.hot_border : nothing,
        width = width, height = 22, padding_x = 4, padding_y = 0,
        direction = :row, align = :center)
end

# Translucent offset rectangles that fake the classic Win7 popup drop shadow.
function popup_shadows(x, y, w, h)
    return Any[
        (@rock Box(; position = :absolute, x = x + 2, y = y + 2,
                   width = w + 1, height = h + 1,
                   background = (0.0, 0.0, 0.0, 0.16))),
        (@rock Box(; position = :absolute, x = x + 3, y = y + 3,
                   width = w + 1, height = h + 1,
                   background = (0.0, 0.0, 0.0, 0.10))),
    ]
end

function menu_dropdown(items, t::Theme, close; x, y, width = 200)
    rows = Any[menu_item_row(normalize_item(i), t, close; width = width - 4)
               for i in items]
    h = 4 + sum((normalize_item(i).label == "-" ? 5 : 22 for i in items), init = 0)
    return Any[popup_shadows(x, y, width, h)...,
               (@rock Box(;
                   position = :absolute, x = x, y = y, width = width, height = h,
                   background = t.colors.document,
                   border_color = t.colors.border, border_width = 1,
                   bevel = :raised, radius = 0, padding = 2,
                   direction = :column, gap = 0, children = rows))]
end

# ---- MenuBar --------------------------------------------------------------

"""
    Enterprise.MenuBar(; menus)

A 22px menu bar. It renders as a transparent full-window overlay so open
dropdowns paint above page content and are not clipped by scroll views.
[`Form`](@ref) positions it automatically through its `menu` prop; when used
directly as a child of a `Window`, pass `position = :absolute, fill = true`.

```julia
@rock Enterprise.MenuBar(menus = [
    Enterprise.Menu("File", items = [
        Enterprise.MenuItem(label = "Open", shortcut = "Ctrl+O"),
        Enterprise.MenuSeparator(),
        Enterprise.MenuItem(label = "Exit"),
    ]),
])
```
"""
function MenuBar(; menus = Any[], position = :absolute, fill = true,
                 x = 0, y = 0)
    t = theme()
    open = @use Observable(0)
    open_idx = open[]
    entries = normalize_menu.(collect(menus))
    widths = [text_width(m.label, t) + 18 for m in entries]
    xs = Float64[]
    cursor = 0.0
    for w in widths
        push!(xs, cursor)
        cursor += w
    end
    close() = (open[] = 0)
    buttons = Any[]
    for (i, m) in enumerate(entries)
        active = open_idx == i
        # Flat until clicked: no hover highlight (it breaks the plastic look
        # of the bar). Only the open menu gets the recessed plastic
        # highlight, like Win7.
        push!(buttons, @rock Pressable(
            text_element(m.label; color = t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            on_press = () -> open[] = active ? 0 : i,
            background = active ? t.gradients.item_hot : nothing,
            hover_background = active ? t.gradients.item_hot : nothing,
            pressed_background = t.gradients.item_hot,
            border_color = active ? t.colors.hot_border : nothing,
            border_width = 1,
            radius = t.metrics.control_radius,
            width = widths[i], height = t.metrics.menu_height,
            padding_x = 8, padding_y = 0,
            direction = :row, align = :center, justify = :center))
    end
    row = @rock Pressable(
        buttons...;
        on_press = close,
        position = :absolute, fill = true, anchor = :top_left,
        background = t.colors.menu,
        border_color = t.colors.border, border_width = 1,
        height = t.metrics.menu_height,
        padding = 0, direction = :row, align = :center)
    dropdown = open_idx >= 1 && open_idx <= length(entries) ?
              menu_dropdown(entries[open_idx].items, t, close;
                            x = xs[open_idx],
                            y = t.metrics.menu_height) : Element[]
    scrim = open_idx == 0 ? nothing :
            (@rock Pressable(;
                position = :absolute, fill = true,
                on_press = close, background = nothing))
    return Element(
        _BOX,
        props_dict(:position => Symbol(position), :x => x, :y => y,
                   :fill => fill, :pointer_events => :none,
                   :direction => :column),
        Any[scrim, row, dropdown...],
    )
end

# ---- ContextMenu ----------------------------------------------------------

"""
    Enterprise.ContextMenu(; open, anchor_x = 0, anchor_y = 0, items,
                           width = 180, position = :absolute, fill = true)

A popup menu anchored within its overlay parent. `open` is an
`Observable{Bool}`; item callbacks close it automatically. Use it with
`position = :absolute, fill = true` (and usually `anchor_x`/`anchor_y`) so it
covers the surrounding page and paints above sibling content.
"""
function ContextMenu(; open, x = 0, y = 0, anchor_x = nothing, anchor_y = nothing,
                     items = Any[], width = 180,
                     position = :absolute, fill = true,
                     pointer_events = :none)
    open isa Observable ||
        error("Enterprise.ContextMenu needs an `Observable{Bool}` as `open`")
    t = theme()
    open = @use open
    open[] || return nothing
    close() = (open[] = false)
    px = anchor_x === nothing ? x : anchor_x
    py = anchor_y === nothing ? y : anchor_y
    parts = menu_dropdown(items, t, close; x = px, y = py, width = width)
    scrim = @rock Pressable(; position = :absolute, fill = true,
                            on_press = close, background = nothing)
    return Element(
        _BOX,
        props_dict(:position => Symbol(position), :x => 0, :y => 0,
                   :fill => fill, :pointer_events => :none,
                   :direction => :column),
        Any[scrim, parts...],
    )
end

# ---- ToolBar / ToolButton -------------------------------------------------

"""
    Enterprise.ToolBar(; children..., grip = true)

A 28px gradient toolbar with an optional grip and separators.
"""
function ToolBar(; children = Any[], grip = true, fill = false)
    t = theme()
    kids = Any[
        grip ? grip_dots(rows = 3, color = t.colors.border_dark) : nothing,
        children...,
    ]
    return Element(
        _BOX,
        props_dict(:direction => :row, :align => :center,
                   :height => t.metrics.toolbar_height,
                   :padding_x => 4, :padding_y => 2, :gap => 2,
                   :background => t.gradients.toolbar,
                   :border_color => t.colors.border,
                   :border_width => 1, :bevel => :raised,
                   :fill => fill),
        kids,
    )
end

"""
    Enterprise.ToolButton(; icon, label, on_press, toggle, disabled, tooltip)

A flat toolbar button that highlights on hover. `toggle` can be a
`Bool` `Observable`; the button shows a pressed/hot background while true.
"""
function ToolButton(; icon = "", label = "", on_press = () -> nothing,
                    toggle = nothing, disabled = false, tooltip = "")
    t = theme()
    on = toggle isa Observable ? Bool(toggle[]) : false
    enabled = !disabled
    kids = Any[
        icon == "" ? nothing : Icon(icon; size = 16,
            color = enabled ? t.colors.text : t.colors.disabled_text,
            font = t.font),
        label == "" ? nothing :
        text_element(label; color = enabled ? t.colors.text : t.colors.disabled_text,
                     size = t.metrics.font_size, font = t.font),
    ]
    # Flat on hover (no highlight; it breaks the plastic look). The recessed
    # plastic highlight only appears while pressed, or while a toggle is on.
    return @rock Pressable(
        kids...;
        on_press = () -> begin
            disabled && return
            toggle isa Observable && (toggle[] = !toggle[])
            on_press()
        end,
        disabled = disabled,
        background = on ? t.gradients.item_hot : nothing,
        hover_background = on ? t.gradients.item_hot : nothing,
        pressed_background = enabled ? t.gradients.item_hot : nothing,
        border_color = enabled && on ? t.colors.hot_border : nothing,
        border_width = 1,
        radius = t.metrics.control_radius,
        padding_x = 5, padding_y = 0,
        height = 24, direction = :row, align = :center, gap = 4)
end

ToolSeparator() = begin
    t = theme()
    @rock Box(; width = 1, height = 18, background = t.colors.border)
end

ToolGrip() = grip_dots(rows = 3)

# ---- StatusBar ------------------------------------------------------------

"""
    Enterprise.StatusPanel(; text, width, spring = false)

One sunken cell of a [`StatusBar`](@ref).
"""
function StatusPanel(; text = "", width = nothing, spring = false)
    t = theme()
    props = props_dict(
        :height => t.metrics.status_height - 4,
        :background => t.colors.status,
        :border_color => t.colors.border,
        :border_width => 1,
        :bevel => :sunken,
        :padding_x => 5, :padding_y => 0,
        :direction => :row, :align => :center,
    )
    width !== nothing && (props[:width] = width)
    return Element(_BOX, props,
                   Any[text_element(text; color = t.colors.status_text,
                                    size = t.metrics.font_size, font = t.font)])
end

"""
    Enterprise.StatusBar(; panels, grip = true)

A 22px gradient status bar with sunken text panels and an optional size grip.
"""
function StatusBar(; panels = Any[], grip = true, fill = false)
    t = theme()
    kids = Any[panels...,
               grip ? grip_dots(rows = 2, color = t.colors.border_dark) : nothing]
    return Element(
        _BOX,
        props_dict(:direction => :row, :align => :center,
                   :height => t.metrics.status_height,
                   :padding_x => 2, :padding_y => 2, :gap => 2,
                   :background => t.gradients.status,
                   :border_color => t.colors.border,
                   :border_width => 1, :bevel => :raised,
                   :fill => fill),
        kids,
    )
end

# ---- ToolTip --------------------------------------------------------------

"""
    Enterprise.ToolTip(; text, children, offset_y)

A wrap-in hover tooltip; the tip is a non-interactive popup drawn just below
the wrapped control (`offset_y` positions it, default below a standard
control).
"""
function ToolTip(; text = "", children = Any[], offset_y = nothing)
    t = theme()
    hover = @use Observable(false)
    child = flat_children(children)
    isempty(child) && return nothing
    oy = something(offset_y, t.metrics.button_height + 1)
    tip = hover[] && text != "" ?
          (@rock Box(
              text_element(text; color = t.colors.text,
                           size = t.metrics.font_size, font = t.font);
              position = :absolute, x = 0, y = oy,
              padding_x = 4, padding_y = 2,
              background = t.colors.tooltip,
              border_color = t.colors.border, border_width = 1,
              pointer_events = :none)) : nothing
    return @rock Box(
        @rock Pressable(
            child...;
            on_hover_in = () -> hover[] = true,
            on_hover_out = () -> hover[] = false,
            background = nothing),
        tip;
        direction = :column, align = :start, overflow = :visible)
end
