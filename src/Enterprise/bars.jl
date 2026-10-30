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

# ---- MenuBar --------------------------------------------------------------

"""
    Enterprise.MenuBar(; menus)

A 22px menu bar. Open dropdown menus open as their own borderless OS windows
pinned under their title, so they are never clipped by the owner window and
always paint above its content. [`Form`](@ref) positions it automatically
through its `menu` prop; when used directly as a child of a `Window`, pass
`position = :absolute, fill = true`.

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
    self = use_fiber()
    open = @use Observable(0)
    menu_x = @use Observable(0.0)
    menu_y = @use Observable(0.0)
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
    # The laid-out rect of the i-th menu title button, in the coordinates of
    # the owner window's client area. The dropdown is anchored to it, so it
    # opens right below its title on every platform.
    title_rect(i) = begin
        for child in self.children
            child.kind === _PRESSABLE || continue
            kids = child.children
            i <= length(kids) || continue
            return kids[i].rect
        end
        return nothing
    end
    buttons = Any[]
    for (i, m) in enumerate(entries)
        active = open_idx == i
        # Flat until clicked: no hover highlight (it breaks the plastic look
        # of the bar). Only the open menu gets the recessed plastic
        # highlight, like Win7. The dropdown opens as its own borderless OS
        # window, anchored to the title below it.
        push!(buttons, @rock Pressable(
            text_element(m.label; color = t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            on_press = () -> begin
                if !active
                    rect = title_rect(i)
                    if rect === nothing
                        menu_x[] = xs[i]
                        menu_y[] = t.metrics.menu_height
                    else
                        menu_x[] = rect[1]
                        menu_y[] = rect[2] + rect[4]
                    end
                end
                open[] = active ? 0 : i
            end,
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
    # The dropdown is a separate borderless OS window, so it is never clipped
    # by the owner window and always paints above its content.
    dropdown = open_idx >= 1 && open_idx <= length(entries) ?
              menu_popup(entries[open_idx].items, t, close;
                         x = menu_x[], y = menu_y[],
                         width = 200,
                         height = menu_popup_height(entries[open_idx].items),
                         open = open) : nothing
    return Element(
        _BOX,
        props_dict(:position => Symbol(position), :x => x, :y => y,
                   :fill => fill, :pointer_events => :none,
                   # The bar's row is absolutely positioned inside (so the
                   # dropdown anchors to this box) — the box therefore needs
                   # its fixed height; the auto-size sees no flow children.
                   :height => t.metrics.menu_height,
                   :direction => :column),
        Any[row, dropdown],
    )
end

# ---- ContextMenu ----------------------------------------------------------

"""
    Enterprise.ContextMenu(; open, x = nothing, y = nothing, items = Any[], width = 180)

A popup menu that opens as its own borderless OS window — a child popup of
the window it is rendered in — so it is never clipped by the edges of that
window and always paints above every other window's content. `x`/`y` are
the offset of the menu inside the owner window's client area; omitted (or
`nothing`) they defer to the window's *last pointer position* — the opening
click — so a right-click context menu anchors at the pointer with no extra
state. `open` is an `Observable{Bool}`; item callbacks close it
automatically. Clicking elsewhere or pressing Escape dismisses it.

```julia
@rock E.ContextMenu(open = open, x = 100, y = 120,
                    items = [E.MenuItem(label = "Rename")])
```
"""
function ContextMenu(; open, x = nothing, y = nothing, items = Any[], width = 180)
    open isa Observable ||
        error("Enterprise.ContextMenu needs an `Observable{Bool}` as `open`")
    t = theme()
    open = @use open
    open[] || return nothing
    close() = (open[] = false)
    # Default `x`/`y`: the pointer position of the owning window at the
    # moment of the opening click (what a right-click context menu wants).
    # The click that flips `open` was already dispatched — `LAST_POINTER`
    # holds its window coordinates — so the menu anchors at the pointer
    # without the caller tracking window-space mouse positions. The +2 nudge
    # keeps the cursor hot pixel off the first menu row.
    if x === nothing || y === nothing
        wid = nothing
        f = CURRENT_FIBER[]
        while f !== nothing
            f.host isa WindowState || (f = f.parent; continue)
            wid = f.host.id
            break
        end
        (mx, my) = wid === nothing ? (0.0, 0.0) :
                   get(LAST_POINTER, wid, (0.0, 0.0))
        x === nothing && (x = mx + 2)
        y === nothing && (y = my + 2)
    end
    return menu_popup(items, t, close; x = x, y = y, width = width,
                      height = menu_popup_height(items), open = open)
end

# ---- ToolBar / ToolButton -------------------------------------------------

"""
    Enterprise.ToolBar(; children..., grip = true)

A 28px gradient toolbar with an optional grip and separators.
"""
function ToolBar(; children = Any[], grip = true, fill = false, height = nothing)
    t = theme()
    kids = Any[
        grip ? grip_dots(rows = 3, color = t.colors.border_dark) : nothing,
        children...,
    ]
    props = props_dict(:direction => :row, :align => :center,
                       :padding_x => 4, :padding_y => 2, :gap => 2,
                       :background => t.gradients.toolbar,
                       :border_color => t.colors.border,
                       :border_width => 1, :bevel => :raised,
                       :fill => fill)
    # A Box auto-sizes to its contents unless a fixed size is set: the
    # toolbar's height defaults to the content so taller tool rows (a 9-dot
    # grid, labelled spinners) are never clipped.
    height === nothing || (props[:height] = height)
    return Element(_BOX, props, kids)
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
