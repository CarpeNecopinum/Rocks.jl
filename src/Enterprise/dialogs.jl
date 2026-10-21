# Modal dialogs and the application form scaffold.

"""
    Enterprise.MessageBox(; open, title, message, icon = :info, buttons = :ok,
                          result, on_result)

A modal Win7-style message box. `open` is an `Observable{Bool}`. The chosen
button symbol is written to `result` (an optional `Observable{Symbol}`) and
passed to `on_result`. `buttons` is `:ok`, `:okcancel`, `:yesno` or
`:yesnocancel`.
"""
function MessageBox(; open, title = "", message = "", icon = :info,
                    buttons = :ok, result = nothing,
                    on_result = (r) -> nothing, position = :absolute,
                    fill = true, pointer_events = :none)
    open isa Observable ||
        error("Enterprise.MessageBox needs an `Observable{Bool}` as `open`")
    t = theme()
    open = @use open
    internal = @use Observable(:none)
    result_obs = result isa Observable ? result : internal
    open[] || return nothing
    finish(sym) = begin
        result_obs[] = sym
        open[] = false
        on_result(sym)
    end
    specs = buttons === :okcancel ? [("OK", :ok, true), ("Cancel", :cancel, false)] :
            buttons === :yesno ? [("Yes", :yes, true), ("No", :no, false)] :
            buttons === :yesnocancel ? [("Yes", :yes, true), ("No", :no, false),
                                       ("Cancel", :cancel, false)] :
            [("OK", :ok, true)]
    btns = Any[
        @rock Button(spec[1]; default = spec[3],
                     on_press = () -> finish(spec[2]))
        for spec in specs
    ]
    icon_glyph = get(ICONS, string(icon), string(icon))
    heading = @rock Row(
        text_element(icon_glyph; color = t.colors.text,
                     size = t.metrics.font_size + 6, font = t.font),
        text_element(title; color = t.colors.text,
                     size = t.metrics.font_size + 1, font = t.font);
        gap = 10, align = :center)
    dialog = @rock Box(
        heading,
        (@rock Box(
            text_element(message; color = t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            width = 348, direction = :column, align = :start)),
        (@rock Box(
            btns...;
            direction = :row, gap = 6, align = :center, justify = :end,
            fill = true));
        width = 380, background = t.colors.control,
        border_color = t.colors.border, border_width = 1,
        bevel = :raised, radius = 4, padding = 16,
        direction = :column, gap = 14)
    return Element(
        _BOX,
        props_dict(:position => Symbol(position), :x => 0, :y => 0,
                   :fill => fill,
                   :background => (0.0, 0.0, 0.0, 0.35),
                   :direction => :column, :align => :center, :justify => :center),
        Any[dialog],
    )
end

"""
    Enterprise.Form(; menu, toolbar, status, children, title = "",
                    width = 900, height = 600, resizable = false, padding = 12,
                    on_scroll)

A complete application window scaffold: optional menu bar, toolbar, scrolling
client area and status bar on the theme's control background. The bars are
pinned; only the client area scrolls.
"""
function Form(; menu = nothing, toolbar = nothing, status = nothing,
              children = Any[], overlay = nothing, title = "", width = 900,
              height = 600, resizable = false, padding = 12,
              on_scroll = nothing)
    t = theme()
    menu_h = menu === nothing ? 0 : t.metrics.menu_height
    toolbar_h = toolbar === nothing ? 0 : t.metrics.toolbar_height
    status_h = status === nothing ? 0 : t.metrics.status_height
    content_y = menu_h + toolbar_h
    content_h = max(height - content_y - status_h, 0)
    # Bars are component elements; fill lets their host box stretch to the
    # window width inside the absolute wrapper.
    toolbar !== nothing && toolbar isa Element &&
        (toolbar.props[:fill] = true)
    status !== nothing && status isa Element &&
        (status.props[:fill] = true)
    if menu isa Element && menu.kind === MenuBar
        menu.props[:position] = :absolute
        menu.props[:fill] = true
        menu.props[:x] = 0
        menu.props[:y] = 0
    end
    if overlay isa Element && (overlay.kind === MessageBox ||
                               overlay.kind === ContextMenu)
        overlay.props[:position] = :absolute
        overlay.props[:fill] = true
        overlay.props[:pointer_events] = :none
    end
    toolbar_wrap = toolbar === nothing ? nothing :
        Element(_BOX, props_dict(:position => :absolute, :x => 0, :y => menu_h,
                                 :width => width, :height => toolbar_h,
                                 :direction => :column), Any[toolbar])
    status_wrap = status === nothing ? nothing :
        Element(_BOX, props_dict(:position => :absolute, :x => 0,
                                 :y => height - status_h, :width => width,
                                 :height => status_h, :direction => :column),
                Any[status])
    scroll = Element(
        _SCROLLVIEW,
        props_dict(:position => :absolute, :x => 0, :y => content_y,
                   :width => width, :height => content_h,
                   :background => t.colors.window,
                   :padding => padding, :gap => 8,
                   :direction => :column, :align => :start,
                   :scrollbar => true,
                   :scrollbar_width => t.metrics.scrollbar,
                   :scrollbar_track => t.colors.scrollbar_track,
                   :scrollbar_thumb => t.gradients.scrollbar_thumb,
                   :scrollbar_border => t.colors.scrollbar_border,
                   :scrollbar_radius => 2,
                   :on_scroll => something(on_scroll, _ -> nothing)),
        flat_children(children),
    )
    return Element(
        _WINDOW,
        props_dict(:title => title, :width => width, :height => height,
                   :resizable => resizable, :background => t.colors.window,
                   :padding => 0, :direction => :column),
        Any[toolbar_wrap, scroll, status_wrap, menu, overlay],
    )
end
