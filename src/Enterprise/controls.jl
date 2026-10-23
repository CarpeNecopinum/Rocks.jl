# Basic Windows 7 / Winforms controls.

# ---- Button ---------------------------------------------------------------

"""
    Enterprise.Button(; label, on_press, default = false, disabled = false,
                      icon, width, height, children...)

A raised Win7 push button with a silver vertical gradient, 1px border and
inner bevel. Set `default = true` for the blue default-button border. A leading
[`Icon`](@ref) name is optional.
"""
function Button(; label = "", on_press = () -> nothing, default = false,
                disabled = false, icon = nothing, width = nothing,
                height = nothing, children = Any[])
    t = theme()
    s = button_style(t, disabled; default = default)
    h = something(height, t.metrics.button_height)
    if isempty(children) && icon === nothing
        return Mechanics.Button(; label = label, on_press = on_press,
            disabled = disabled, background = s.background,
            hover_background = s.hover, pressed_background = s.pressed,
            border_color = s.border, border_width = t.metrics.border,
            radius = t.metrics.control_radius, height = h, width = width,
            padding = 12, gap = 4, size = t.metrics.font_size,
            text_color = s.text, font = t.font, bevel = :raised)
    end
    kids = Any[]
    icon === nothing ||
        push!(kids, Icon(icon; size = t.metrics.font_size, color = s.text,
                         font = t.font))
    if isempty(children)
        label == "" ||
            push!(kids, text_element(label; color = s.text,
                                     size = t.metrics.font_size, font = t.font))
    else
        append!(kids, styled_children(children, t, s.text))
    end
    return Mechanics.Button(; children = kids, on_press = on_press,
        disabled = disabled, background = s.background,
        hover_background = s.hover, pressed_background = s.pressed,
        border_color = s.border, border_width = t.metrics.border,
        radius = t.metrics.control_radius, height = h, width = width,
        padding = 12, gap = 4, size = t.metrics.font_size,
        text_color = s.text, font = t.font, bevel = :raised)
end

# ---- labels ---------------------------------------------------------------

"""
    Enterprise.Label(; text, color, size, font, children...)

A plain control label in the active theme's text color.
"""
function Label(; text = "", color = nothing, size = nothing, font = nothing,
               children = Any[])
    t = theme()
    value = isempty(children) ? text : join(string.(flat_children(children)))
    return text_element(value; color = something(color, t.colors.text),
                        size = something(size, t.metrics.font_size),
                        font = font === nothing ? t.font : font)
end

"""
    Enterprise.LinkLabel(; text, on_press, color, children...)

A blue, underlined link-style label.
"""
function LinkLabel(; text = "", on_press = () -> nothing, color = "#0066CC",
                   children = Any[])
    t = theme()
    value = isempty(children) ? text : join(string.(flat_children(children)))
    width = max(text_width(value, t), 1.0)
    link = @rock Pressable(
        @rock Column(
            text_element(value; color = color, size = t.metrics.font_size,
                         font = t.font),
            (@rock Box(; width = width, height = 1, background = color));
            gap = 1, align = :start);
        on_press = on_press,
        background = nothing,
        hover_background = nothing)
    return link
end

# ---- TextBox --------------------------------------------------------------

"""
    Enterprise.TextBox(; text, read_only = false, password = false,
                       placeholder, width, height, disabled, on_submit,
                       on_change)

A sunken white single-line text field with full editing support: a visible
caret, left/right/Home/End cursor movement (Ctrl+arrows jump whole words),
Shift selection, Backspace/Delete, Return submitting and the system clipboard
(Ctrl+A select all, Ctrl+C copy, Ctrl+X cut, Ctrl+V paste). Clicking inside
the field places the caret at the nearest character boundary. `text` is an
`Observable{String}`; `on_change()` fires after every edit.
"""
function TextBox(; text, read_only = false, password = false, placeholder = "",
                  width = 160, height = nothing, disabled = false,
                  on_submit = () -> nothing, on_change = () -> nothing)
    text isa Observable ||
        error("Enterprise.TextBox needs an `Observable` as its `text` prop")
    t = theme()
    text = @use text
    # Cursor and selection positions are character counts. The Observables are
    # tied to this fiber; the `-1` sentinel means "at the end of the current
    # text", so externally set text keeps appending the way the old field did.
    cur = @use Observable(-1)
    anchor = @use Observable(-1)
    focused = has_focus()
    h = something(height, t.metrics.input_height)
    edit = !disabled && !read_only
    # The right-click edit menu (Cut/Copy/Paste/…) anchored at the pointer.
    menu_open = @use Observable(false)
    menu_x = @use Observable(0.0)
    menu_y = @use Observable(0.0)

    # Editing state is re-read inside callbacks so queued events act on the
    # current text and cursor, not on values captured during render.
    state() = begin
        cs = collect(text[])
        n = cur[] < 0 ? length(cs) : clamp(cur[], 0, length(cs))
        m = anchor[] < 0 ? n : clamp(anchor[], 0, length(cs))
        (cs, n, m, min(n, m), max(n, m))
    end
    move!(dest; extend = false) = begin
        dest = clamp(dest, 0, length(collect(text[])))
        if extend
            n = cur[] < 0 ? length(collect(text[])) : cur[]
            anchor[] = anchor[] < 0 ? n : anchor[]
        else
            anchor[] = -1
        end
        cur[] = dest
        return nothing
    end
    word_step!(fwd; extend = false) = begin
        (cs, n, m, lo, hi) = state()
        dest = n
        if fwd
            dest < length(cs) && isspace(cs[dest+1]) && (dest += 1)
            while dest < length(cs) && !isspace(cs[dest+1]); dest += 1; end
        else
            dest > 0 && isspace(cs[dest]) && (dest -= 1)
            while dest > 0 && !isspace(cs[dest]); dest -= 1; end
            # dest is now the separator slot right before the word start —
            # a valid caret in the chars-before-couter semantics.
        end
        move!(dest; extend)
    end
    insert!(s) = begin
        edit || return nothing
        s = replace(s, r"[\r\n]" => "")
        s == "" && return nothing
        (cs, n, m, lo, hi) = state()
        text[] = String([cs[1:lo]; collect(s); cs[hi+1:end]])
        cur[] = lo + length(collect(s))
        anchor[] = -1
        on_change()
        return nothing
    end
    # `forward = true` deletes the character after the caret (the Delete key),
    # otherwise the one before it (Backspace); a selection is deleted as a
    # whole either way.
    delete!(forward = false) = begin
        edit || return nothing
        (cs, n, m, lo, hi) = state()
        if lo < hi
            kept = [cs[1:lo]; cs[hi+1:end]]
        elseif forward
            n < length(cs) || return nothing
            kept = [cs[1:n]; cs[n+2:end]]
        else
            n > 0 || return nothing
            kept = [cs[1:n-1]; cs[n+1:end]]
        end
        text[] = String(kept)
        cur[] = lo < hi ? lo : forward ? n : n - 1
        anchor[] = -1
        on_change()
        return nothing
    end
    select!(n, m) = begin
        total = length(collect(text[]))
        cur[] = clamp(n, 0, total)
        anchor[] = clamp(m, 0, total)
        return nothing
    end
    # With no selection the whole text is copied (the line is the field).
    copy!() = begin
        (cs, n, m, lo, hi) = state()
        clipboard_set_text!(lo < hi ? String(cs[lo+1:hi]) : text[])
        return nothing
    end

    # Losing focus resets the selection: desktop text fields only ever have
    # one selected piece of text, so a blurred field collapses back to its
    # caret (which stays put for the next focus). The right-click menu closes
    # with it.
    useEffect(() -> begin
        !focused && (anchor[] = -1; menu_open[] = false)
        return nothing
    end, (focused,))

    # ---- render ------------------------------------------------------------
    placeholder === nothing && (placeholder = "")
    value = text[]
    chars = collect(value)
    n = cur[] < 0 ? length(chars) : clamp(cur[], 0, length(chars))
    m = anchor[] < 0 ? n : clamp(anchor[], 0, length(chars))
    lo, hi = min(n, m), max(n, m)
    selection = lo < hi
    mask(s) = password ? repeat("●", length(collect(s))) : s
    before = mask(join(chars[1:n]))
    span = mask(join(chars[lo+1:hi]))
    after = mask(join(chars[hi+1:end]))

    piece(str, color) = str == "" ? nothing :
        text_element(str; color = color, size = t.metrics.font_size, font = t.font)
    show_placeholder = value == "" && !focused && placeholder != ""
    content = show_placeholder ?
              Any[text_element(placeholder; color = t.colors.disabled_text,
                               size = t.metrics.font_size, font = t.font)] :
              Any[piece(before, t.colors.text),
                  piece(span, selection ? t.colors.selection_text :
                                          t.colors.text),
                  piece(after, t.colors.text)]
    caret = focused ? (@rock Box(; position = :absolute,
        x = t.metrics.border + 6 + text_width(before, t), y = 3, width = 1,
        height = max(h - 6, 4), background = t.colors.text)) : nothing
    selbg = selection ? (@rock Box(; position = :absolute,
        x = t.metrics.border + 6 + text_width(before, t), y = 3,
        width = max(text_width(span, t), 1.0), height = max(h - 6, 4),
        background = t.colors.selection)) : nothing
    row = @rock Row(content...; gap = 0, align = :center)

    # Right-click edit menu over the field (Cut/[Paste/Delete enabled for
    # editable selections], Copy/Select all otherwise).
    (cs, n, m, lo, hi) = state()
    menu_items = Any[
        MenuItem(label = "Cut", enabled = edit && lo < hi,
                 on_press = () -> (copy!(); delete!())),
        MenuItem(label = "Copy", enabled = lo < hi,
                 on_press = () -> copy!()),
        MenuSeparator(),
        MenuItem(label = "Paste", enabled = edit,
                 on_press = () -> insert!(clipboard_get_text())),
        MenuItem(label = "Delete", enabled = edit && lo < hi,
                 on_press = () -> delete!(true)),
        MenuSeparator(),
        MenuItem(label = "Select all", enabled = length(collect(text[])) > 0,
                 on_press = () -> select!(0, length(collect(text[]))))
    ]

    # ---- mouse -------------------------------------------------------------
    # Event callbacks run after the render, so they resolve placed geometry
    # from this component's fiber instead of the render spec (`row` is an
    # `Element`, whose rect/measured fields only exist on the fiber).
    self = use_fiber()
    field_fiber() = begin
        for c in self.children
            c.kind === _PRESSABLE && return c
        end
        return nothing
    end
    row_fiber() = begin
        f = field_fiber()
        f === nothing && return nothing
        for cc in f.children
            cc.kind === Row && return cc
        end
        return nothing
    end
    row_width() = begin
        rf = row_fiber()
        rf === nothing ? 0.0 : max(get(rf.measured, 1, 0.0), 0.0)
    end

    # Pointer callbacks receive coordinates local to the field area; the
    # caret math and the popup menu both need owner-window coordinates.
    field_offset() = begin
        f = field_fiber()
        f === nothing ? (0.0, 0.0) : (f.rect[1], f.rect[2])
    end

    # Character boundary the pointer lands at, based on the text row geometry.
    caret_at(x) = begin
        rf = row_fiber()
        rf === nothing && return 0
        roww = max(get(rf.measured, 1, 0.0), 0.0)
        x = clamp(x - rf.rect[1], 0.0, roww)
        acc, pos = 0.0, 0
        for (i, c) in enumerate(collect(text[]))
            w = text_width(string(c), t)
            acc + w / 2 <= x || break
            acc += w
            pos = i
        end
        return pos
    end

    ctx = menu_open[] ? ContextMenu(open = menu_open,
                 x = menu_x[], y = menu_y[], width = 150,
                 items = menu_items) : nothing

    return Element(
        _PRESSABLE,
        props_dict(
            :on_text_input => edit ? (s) -> begin
                # Ignore text delivered from Ctrl/Alt/Gui combos; plain typed
                # characters arrive without those modifiers.
                LAST_KEYMODS[] & 0x0F00 == 0x0000 || return nothing
                insert!(s)
            end : (s) -> nothing,
            :on_key => disabled ? (k) -> nothing : (k) -> begin
                if k == "Backspace" && !read_only
                    delete!()
                elseif k == "Delete" && !read_only
                    delete!(true)
                elseif k == "Return"
                    on_submit()
                elseif k == "Escape"
                    unfocus!()
                end
            end,
            :on_key_mods => disabled ? nothing : (k, mods) -> begin
                ctrl = (mods & 0x00C0) != 0     # left/right CTRL
                shift = (mods & 0x0003) != 0    # left/right SHIFT
                if k == "Left" || k == "Right"
                    fwd = k == "Right"
                    ctrl ? word_step!(fwd; extend = shift) :
                           move!(state()[2] + (fwd ? 1 : -1); extend = shift)
                    return :handled
                elseif k == "Home"
                    move!(0; extend = shift)
                    return :handled
                elseif k == "End"
                    move!(length(collect(text[])); extend = shift)
                    return :handled
                elseif ctrl && k in ("a", "A")
                    select!(0, length(collect(text[])))
                    return :handled
                elseif ctrl && k in ("c", "C")
                    copy!()
                    return :handled
                elseif ctrl && k in ("x", "X")
                    copy!()
                    delete!()
                    return :handled
                elseif ctrl && k in ("v", "V")
                    edit && insert!(clipboard_get_text())
                    return :handled
                end
                nothing
            end,
            :on_press_in => disabled ? () -> nothing : (px, py, btn) -> begin
                ox, oy = field_offset()
                wx, wy = px + ox, py + oy
                if btn == 3
                    # Right-click opens the edit menu at the pointer (the
                    # caret and selection stay as they are). The menu opens
                    # as its own borderless OS window, a popup of the owner
                    # window, so it is anchored at the pointer in the owner
                    # window's client area.
                    menu_x[] = wx
                    menu_y[] = wy + 2.0
                    menu_open[] = true
                    return nothing
                end
                # Place the caret at the pressed character boundary; the row
                # rect already covers border and padding.
                pos = caret_at(wx)
                cur[] = anchor[] = pos
                return nothing
            end,
            :on_drag => disabled ? nothing : (px, py) -> begin
                # Hold-and-drag extends the selection from the press point.
                ox, _ = field_offset()
                cur[] = caret_at(px + ox)
                return nothing
            end,
            :on_press => disabled ? () -> nothing : (px, py, btn) -> begin
                btn == 3 && return nothing
                # Left release: the drag selection snaps to the release
                # position; a click without a drag collapses the anchor.
                ox, _ = field_offset()
                cur[] = caret_at(px + ox)
                cur[] == anchor[] && (anchor[] = -1)
                return nothing
            end,
            :disabled => disabled,
            :cursor => :text,
            # The text is clipped to the field, so a long text does not run
            # over the border when the field is squeezed.
            :overflow => :hidden,
            :background => t.colors.input,
            :hover_background => t.colors.input,
            :border_color => focused ? t.colors.focus : t.colors.input_border,
            :border_width => t.metrics.border,
            :bevel => :sunken,
            :bevel_light => t.colors.border_light,
            :bevel_dark => t.colors.border_dark,
            :radius => 2,
            :width => width,
            :height => h,
            :padding_x => 6,
            :padding_y => 0,
            :direction => :row,
            :align => :center,
        ),
        Any[selbg, caret, row, ctx],
    )
end

function clipboard_set_text!(s)
    s == "" && return
    try
        SDL3.SetClipboardText(s)
    catch err
        @warn "Rocks: could not set the clipboard text" err
    end
    return nothing
end

function clipboard_get_text()
    try
        return SDL3.GetClipboardText()
    catch
        return ""
    end
end

# ---- CheckBox / RadioButton ----------------------------------------------

"""
    Enterprise.CheckBox(; checked, label, on_change, disabled, children...)

A 13px sunken checkbox with a black check mark and a label.
"""
function CheckBox(; checked, label = "", on_change = () -> nothing,
                  disabled = false, children = Any[])
    checked isa Observable ||
        error("Enterprise.CheckBox needs an `Observable` as its `checked` prop")
    t = theme()
    checked = @use checked
    color = label_color(t, disabled)
    return Mechanics.Checkbox(; checked = checked, on_change = on_change,
        disabled = disabled, label = label, children = children,
        size = 13, radius = 2, border_width = 1,
        checked_background = t.colors.document,
        unchecked_background = t.colors.document,
        checked_border = t.colors.input_border,
        unchecked_border = t.colors.input_border,
        check_color = color, check_size = 11, label_color = color,
        label_size = t.metrics.font_size,
        font = t.font, marker_bevel = :sunken,
        bevel_light = t.colors.border_light,
        bevel_dark = t.colors.border_dark)
end

"""
    Enterprise.RadioButton(; selected, value, label, on_change, disabled)

A 13px sunken radio button with a themed focus ring and a small center dot.
`selected` is an `Observable{Int}` and `value` is the index this button writes
when clicked.
"""
function RadioButton(; selected, value, label = "", on_change = () -> nothing,
                     disabled = false)
    selected isa Observable ||
        error("Enterprise.RadioButton needs an `Observable` as its `selected` prop")
    t = theme()
    selected = @use selected
    color = label_color(t, disabled)
    return Mechanics.Radio(; selected = selected, value = value,
        on_change = on_change, disabled = disabled, label = label,
        size = 13, border_width = 2, dot_size = 5,
        selected_ring = t.colors.focus, unselected_ring = t.colors.input_border,
        dot_color = t.colors.text, label_color = color,
        label_size = t.metrics.font_size, font = t.font,
        # Bevel highlights are cut as straight strips, which reads as square
        # notches in a circle — a plain ring looks right.
        marker_bevel = :none)
end

# ---- GroupBox / Panel -----------------------------------------------------

"""
    Enterprise.GroupBox(; title, children..., caption_background, padding)

An etched frame with a caption sitting in a notch in the top border.
"""
function GroupBox(; title = "", children = Any[], caption_background = nothing,
                  padding = (8, 10), fill = false, width = nothing,
                  height = nothing)
    t = theme()
    # The caption notch must match the surface the group sits on (Winforms:
    # the caption inherits the parent's BackColor). Pages are document-colored,
    # so that is the default; `caption_background` overrides it for groups on
    # other surfaces.
    bg = something(caption_background, t.colors.document)
    caption = @rock Box(
        text_element(title; color = t.colors.text, size = t.metrics.font_size,
                     font = t.font);
        position = :absolute, x = 8, y = -7,
        padding_x = 3, padding_y = 0,
        background = bg)
    props = props_dict(:direction => :column, :gap => 6, :padding => padding,
                       :border_color => t.colors.border,
                       :border_width => t.metrics.border,
                       :bevel => :etched, :radius => t.metrics.control_radius,
                       :fill => fill)
    width !== nothing && (props[:width] = width)
    height !== nothing && (props[:height] = height)
    # The content is clipped to the frame, so a control that is wider than the
    # group cannot run out of it.  The caption sits in the notch of the top
    # border, outside the frame, so it stays a sibling of the content.
    content = @rock Box(children...;
                        direction = :column, gap = 6, overflow = :hidden)
    return Element(_BOX, props, Any[caption, content])
end

"""
    Enterprise.Panel(; children..., padding, background, border)

A rectangular control/document container. Appearance props default to the
theme's control surface.
"""
function Panel(; children = Any[], padding = 8, background = nothing,
               border_color = nothing, border_width = 0, bevel = :none,
               width = nothing, height = nothing, direction = :column, gap = 4,
               fill = false)
    t = theme()
    props = props_dict(
        :direction => Symbol(direction), :gap => gap, :padding => padding,
        :background => something(background, t.colors.control),
        :border_color => border_color,
        :border_width => border_width,
        :bevel => bevel, :fill => fill,
        # The content stays inside the panel: a text that is wider than the
        # panel (a pane of a split, for example) is clipped instead of
        # running over the border.
        :overflow => :hidden,
    )
    width !== nothing && (props[:width] = width)
    height !== nothing && (props[:height] = height)
    return Element(_BOX, props, children)
end

# ---- ProgressBar ----------------------------------------------------------

"""
    Enterprise.ProgressBar(; value, width = 200, height = 17)

A sunken track with a green gradient fill. `value` is an `Observable` between
0 and 1.
"""
function ProgressBar(; value, width = 200, height = 17)
    value isa Observable ||
        error("Enterprise.ProgressBar needs an `Observable` as its `value` prop")
    t = theme()
    value = @use value
    frac = clamp(Float64(value[]), 0.0, 1.0)
    return Element(
        _BOX,
        props_dict(:width => width, :height => height,
                   :background => t.colors.progress_track,
                   :border_color => t.colors.progress_border,
                   :border_width => 1, :bevel => :sunken,
                   :radius => 2, :direction => :row,
                   # The fill is a share of the bar, so it follows the bar when
                   # the bar is squeezed by a smaller window.
                   :padding => 2),
        Any[
            @rock Box(;
                width = "$(round(frac * 100, digits = 4))%",
                height = "100%",
                radius = 1, background = t.gradients.progress)
        ],
    )
end

# ---- SplitContainer -------------------------------------------------------

"""
    Enterprise.SplitContainer(; children, direction = :horizontal, ratio = 0.5,
                              handle = 6)

A themed wrapper around the framework split container.
"""
function SplitContainer(; children = Any[], direction = :horizontal,
                        ratio = 0.5, handle = 6, width = 400, height = 240)
    t = theme()
    return Element(
        _SPLIT,
        props_dict(:direction => Symbol(direction), :ratio => ratio,
                   :handle => handle, :handle_color => t.colors.border_dark,
                   :handle_bevel => :raised,
                   :bevel_light => t.colors.border_light,
                   :bevel_dark => t.colors.border_dark,
                   # The panes cannot paint outside of the split.
                   :overflow => :hidden,
                   :width => width, :height => height),
        flat_children(children),
    )
end

# ---- Slider ---------------------------------------------------------------

"""
    Enterprise.Slider(; value, min = 0, max = 1, width = 200, ticks = 0)

A Win7 trackbar: a sunken groove, a raised gradient thumb and optional tick
marks. `value` is an `Observable`; dragging writes it.
"""
function Slider(; value, min = 0, max = 1, width = 200, ticks = 0)
    value isa Observable ||
        error("Enterprise.Slider needs an `Observable` as its `value` prop")
    t = theme()
    return Element(
        _SLIDER,
        props_dict(
            :value => value, :min => min, :max => max,
            :width => width,
            # Extra height so the tick marks sit below the knob instead of
            # crossing its bottom edge.
            :height => ticks > 0 ? 30 : 24,
            :track_color => t.colors.progress_track,
            :active_color => t.colors.progress_track,
            :track_height => 4,
            :thumb_size => 11, :thumb_height => 21, :thumb_radius => 2,
            :thumb_gradient => t.gradients.slider_thumb,
            :thumb_border_color => t.colors.border,
            :thumb_border_width => 1,
            :thumb_bevel => :raised,
            :bevel_light => t.colors.border_light,
            :bevel_dark => t.colors.border_dark,
            :ticks => ticks,
            :tick_color => t.colors.border_dark,
            :tick_length => 3,
        ),
        Any[],
    )
end
