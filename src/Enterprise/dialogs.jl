# Modal dialogs and the application form scaffold.

"""
    Enterprise.MessageBox(; open, title, message, icon = :info, buttons = :ok,
                          result, on_result, width = 380, height = nothing,
                          position = :cascade, display = nothing)

A modal Win7-style message box that opens as its **own OS window** (with a
native title bar and close button) instead of drawing over its parent.
`open` is an `Observable{Bool}`; the window closes when a button is pressed,
through the OS close button (which resolves like the Cancel choice), or when
`open` flips back to `false`. `position` / `display` pass straight to the
window placement modes (`:cascade`, `:centered`, `:manual`, `:mouse`).
"""
function MessageBox(; open, title = "", message = "", icon = :info,
                    buttons = :ok, result = nothing,
                    on_result = (r) -> nothing, width = 380,
                    height = nothing, position = :cascade,
                    display = nothing)
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
    # The OS title bar's X resolves like Winforms: Cancel if offered,
    # otherwise No, otherwise the first choice.
    syms = [s[2] for s in specs]
    close_sym = :cancel in syms ? :cancel : (:no in syms ? :no : syms[1])
    icon_glyph = get(ICONS, string(icon), string(icon))
    badge_bg = icon === :warning ? "#E8A33D" :
               icon === :error ? "#D0452F" : "#3B7FC4"
    badge_glyph = icon === :warning ? "#12100A" : "#FFFFFF"
    badge = @rock Box(
        text_element(icon_glyph; color = badge_glyph,
                     size = t.metrics.font_size + 7, font = t.font);
        width = 27, height = 27, radius = 13.5, background = badge_bg,
        direction = :row, align = :center, justify = :center)
    content = @rock Row(
        badge,
        (@rock Box(
            text_element(message; color = t.colors.text,
                         size = t.metrics.font_size, font = t.font);
            width = width - 77, direction = :column, align = :start));
        gap = 14, align = :start)
    footer = @rock Box(
        btns...;
        direction = :row, gap = 8, align = :center, justify = :end)
    # Size the window from the message's line count.
    nlines = count(isequal('\n'), message) + 1
    line_h = t.metrics.font_size + 8
    body_h = max(nlines * line_h, 27.0)
    h = height === nothing ?
        18.0 + body_h + 14.0 + t.metrics.button_height + 18.0 : float(height)
    dialog = @rock Box(
        content, footer;
        direction = :column, gap = 12, padding = 18,
        background = t.colors.control, fill = true)
    return Element(
        _WINDOW,
        props_dict(:title => title, :width => width, :height => h,
                   :background => t.colors.control, :padding => 1,
                   :direction => :column, :position => Symbol(position),
                   :display => display, :resizable => false,
                   :on_close => () -> finish(close_sym)),
        Any[dialog],
    )
end

"""
    Enterprise.Form(; menu, toolbar, status, children, title = "",
                    width = 900, height = 600, resizable = true, padding = 12,
                    on_scroll)

A complete application window scaffold: optional menu bar, toolbar, scrolling
client area and status bar on the theme's control background. The bars are
pinned; only the client area scrolls. The menu and toolbar stretch with the
window and the status bar stays anchored to the bottom edge, so the frame
tracks window resizes.
"""
function Form(; menu = nothing, toolbar = nothing, status = nothing,
              children = Any[], overlay = nothing, title = "", width = 900,
              height = 600, resizable = true, padding = 12,
              on_scroll = nothing)
    t = theme()
    # The form is a column flow: the bars auto-size to their contents
    # (+padding) unless a fixed size is set, and the scroll view grows
    # (`flex = 1`) to fill the remaining space.
    toolbar !== nothing && toolbar isa Element &&
        (toolbar.props[:fill] = true)
    status !== nothing && status isa Element &&
        (status.props[:fill] = true)
    # The menu joins the column flow (the MenuBar defaults to :absolute for
    # standalone use — override it, or the flow layout excludes it and the
    # scroll view overlaps the bar).
    menu !== nothing && menu isa Element && begin
        (menu.props[:fill] = true)
        (menu.props[:position] = :relative)
    end
    # Overlay dialogs (context menus) paint above everything as an absolute
    # child; window-based dialogs (MessageBox) mount untouched as an extra
    # window and receive their own wrap so they stay out of the window's own
    # flow layout.
    if overlay isa Element && overlay.kind === ContextMenu
        overlay.props[:position] = :absolute
        overlay.props[:fill] = true
        overlay.props[:pointer_events] = :none
    end
    toolbar_wrap = toolbar === nothing ? nothing :
        Element(_BOX, props_dict(:fill => true, :direction => :column),
                Any[toolbar])
    status_wrap = status === nothing ? nothing :
        Element(_BOX, props_dict(:fill => true, :direction => :column),
                Any[status])
    scroll = Element(
        _SCROLLVIEW,
        props_dict(:fill => true, :flex => 1,
                   :background => t.colors.window,
                   :padding => padding, :gap => 8,
                   :direction => :column, :align => :start,
                   :scrollbar => true,
                   :scrollbar_width => t.metrics.scrollbar,
                   :scrollbar_track => t.colors.scrollbar_track,
                   :scrollbar_thumb => t.gradients.scrollbar_thumb,
                   :scrollbar_border => t.colors.scrollbar_border,
                   :scrollbar_arrow_background => t.gradients.scrollbar_button,
                   :scrollbar_arrow_color => t.colors.text,
                   :scrollbar_radius => 2,
                   :on_scroll => something(on_scroll, _ -> nothing)),
        flat_children(children),
    )
    # A window-based overlay (MessageBox) mounts inside a transparent
    # absolute wrapper so it stays out of the form's own flow layout.
    overlay_child = overlay
    if overlay isa Element && overlay.kind === MessageBox
        overlay_child = Element(_BOX,
                                props_dict(:position => :absolute),
                                Any[overlay])
    end
    return Element(
        _WINDOW,
        props_dict(:title => title, :width => width, :height => height,
                   :resizable => resizable, :background => t.colors.window,
                   :padding => 0, :direction => :column),
        Any[menu, toolbar_wrap, scroll, status_wrap, overlay_child],
    )
end
