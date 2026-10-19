# Vanilla mechanics: the behavior of interactive controls — state, callbacks,
# focus and hit behavior — with appearance fully prop-driven and minimal,
# unstyled defaults (flat colors, sharp corners).
#
# Rocks.Material3 builds Material Design 3 themed controls on top of these by
# passing theme-derived colors, shapes and type into them. All state is
# controlled through `Observable`s (the same pattern as the plain widgets).

module Mechanics

using ..Rocks: @rock, @use, Observable, Element, props_dict, _PRESSABLE, _BOX,
    flat_children, Row, Column, Box, Text, Pressable, has_focus, unfocus!

# Wrap raw string/value children in `Text` elements with the control's colors;
# element children pass through, `nothing`/`Bool`s are skipped.
function styled_children(kids, color, size)
    out = Any[]
    for k in flat_children(kids)
        if k isa Element
            push!(out, k)
        elseif k === nothing || k isa Bool
            continue
        else
            push!(out, @rock Text(string(k); color = color, size = size))
        end
    end
    return out
end

# ---- Button ---------------------------------------------------------------

"""
    Mechanics.Button(; on_press, disabled, label, children...;
                     background, hover_background, pressed_background,
                     border_color, border_width, radius, height, padding,
                     gap, size, text_color)

The mechanics of a push button: a pressable container with a label row.
All appearance is prop-driven; the label is the call's children (already
styled `Text`/icon elements) or the `label` string prop. A disabled button
ignores presses and freezes its visuals.
"""
function Button(; on_press = () -> nothing, disabled = false, label = "",
                children = Any[], background = nothing,
                hover_background = nothing, pressed_background = nothing,
                border_color = nothing, border_width = 0, radius = 0,
                height = 40, width = nothing, padding = 16, gap = 8, size = 14,
                text_color = (0.0, 0.0, 0.0))
    label_kids = isempty(children) ?
                 Any[label == "" ? nothing :
                     @rock Text(label; color = text_color, size = size)] :
                 styled_children(children, text_color, size)
    props = props_dict(
        :on_press => disabled ? () -> nothing : on_press,
        :disabled => disabled,
        :background => background,
        :hover_background => disabled ? background : hover_background,
        :pressed_background => disabled ? background : pressed_background,
        :border_color => border_color,
        :border_width => border_width,
        :radius => radius,
        :height => height,
        :padding => padding,
        :direction => :row,
        :align => :center,
        :gap => gap,
    )
    width !== nothing && (props[:width] = width)
    return Element(_PRESSABLE, props, label_kids)
end

# ---- Checkbox -------------------------------------------------------------

"""
    Mechanics.Checkbox(; checked, on_change, disabled, label, children...;
                       size, radius, checked_background, unchecked_background,
                       checked_border, unchecked_border, border_width,
                       check_color, check_size, label_color)

The mechanics of a checkbox: a pressable marker that toggles an
`Observable{Bool}` and calls `on_change()`. All colors are prop-driven per
state; the marker is a rounded square with a `✓` glyph.
"""
function Checkbox(; checked, on_change = () -> nothing, disabled = false,
                  label = "", children = Any[], size = 18, radius = 2,
                  checked_background = nothing, unchecked_background = nothing,
                  checked_border = nothing, unchecked_border = nothing,
                  border_width = 2, check_color = nothing, check_size = 14,
                  label_color = nothing)
    checked isa Observable ||
        error("Mechanics.Checkbox needs an `Observable` as its `checked` prop")
    on = checked[]
    label_kid = isempty(children) ?
                (label == "" ? nothing :
                 @rock Text(label; color = label_color)) :
                @rock Row(flat_children(children)...; gap = 8, align = :center)
    check = on && check_color !== nothing ? check_color : (0, 0, 0, 0)
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => () -> begin
                checked[] = !checked[]
                on_change()
            end,
            :disabled => disabled,
            :direction => :row,
            :align => :center,
            :gap => 8,
        ),
        Any[
            @rock Box(
                @rock Text("✓"; color = check, size = check_size);
                width = size, height = size,
                radius = radius,
                background = on ? checked_background : unchecked_background,
                border_color = on ? checked_border : unchecked_border,
                border_width = border_width,
                direction = :row, align = :center),
            label_kid
        ],
    )
end

# ---- Switch ---------------------------------------------------------------

"""
    Mechanics.Switch(; on, on_change, disabled;
                     track_w, track_h, on_track, off_track,
                     on_thumb, off_thumb, on_thumb_border, off_thumb_border,
                     border_width, thumb_on_size, thumb_off_size,
                     on_icon, off_icon, icon_color, icon_size)

The mechanics of a switch: a pressable track with a thumb that slides when an
`Observable{Bool}` toggles. Geometry and colors are prop-driven; `on_icon` /
`off_icon` are optional glyphs drawn inside the thumb.
"""
function Switch(; on, on_change = () -> nothing, disabled = false,
                track_w = 52, track_h = 32, on_track = nothing,
                off_track = nothing, on_thumb = nothing, off_thumb = nothing,
                on_thumb_border = nothing, off_thumb_border = nothing,
                on_track_border = nothing, off_track_border = nothing,
                track_border_width = 2, border_width = 2,
                thumb_on_size = 24, thumb_off_size = 16,
                on_icon = "", off_icon = "", icon_color = nothing,
                icon_size = 14)
    on isa Observable ||
        error("Mechanics.Switch needs an `Observable` as its `on` prop")
    is_on = on[]
    thumb_size = is_on ? thumb_on_size : thumb_off_size
    icon = is_on ? on_icon : off_icon
    thumb_kid = icon == "" ? nothing :
                (@rock Text(icon; color = icon_color, size = icon_size))
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => () -> begin
                on[] = !on[]
                on_change()
            end,
            :disabled => disabled,
            :direction => :row,
            :align => :center,
        ),
        Any[@rock Box(
            @rock Box(
                thumb_kid;
                position = :absolute, align = :center,
                width = thumb_size, height = thumb_size,
                radius = thumb_size / 2,
                background = is_on ? on_thumb : off_thumb,
                border_color = is_on ? on_thumb_border : off_thumb_border,
                border_width = border_width);
            width = track_w, height = track_h,
            radius = track_h / 2,
            background = is_on ? on_track : off_track,
            border_color = is_on ? on_track_border : off_track_border,
            border_width = is_on ?
                           (on_track_border === nothing ? 0 : track_border_width) :
                           (off_track_border === nothing ? 0 : track_border_width),
            direction = :row, align = :center)],
    )
end

# ---- Radio ----------------------------------------------------------------

"""
    Mechanics.Radio(; selected, value, on_change, disabled, label, children...;
                    size, border_width, selected_ring, unselected_ring,
                    dot_color, label_color)

The mechanics of a radio indicator: a pressable circle that sets
`selected` (an `Observable{Int}`) to `value` and calls `on_change()`.
"""
function Radio(; selected, value, on_change = () -> nothing, disabled = false,
               label = "", children = Any[], size = 20, border_width = 2,
               selected_ring = nothing, unselected_ring = nothing,
               dot_color = nothing, label_color = nothing)
    selected isa Observable ||
        error("Mechanics.Radio needs an `Observable` as its `selected` prop")
    is_selected = selected[] == value
    label_kid = isempty(children) ?
                (label == "" ? nothing :
                 @rock Text(label; color = label_color)) :
                @rock Row(flat_children(children)...; gap = 8, align = :center)
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => () -> begin
                selected[] = value
                on_change()
            end,
            :disabled => disabled,
            :direction => :row,
            :align => :center,
            :gap => 8,
        ),
        Any[
            @rock Box(
                (is_selected ? (@rock Box(;
                    width = size - 2border_width, height = size - 2border_width,
                    radius = (size - 2border_width) / 2,
                    background = dot_color)) : nothing);
                width = size, height = size,
                radius = size / 2,
                border_color = is_selected ? selected_ring : unselected_ring,
                border_width = border_width,
                direction = :row, align = :center),
            label_kid
        ],
    )
end

# ---- Chip -----------------------------------------------------------------

"""
    Mechanics.Chip(; on_press, selected, disabled, label, children...;
                   leading, trailing, height, padding, gap, radius,
                   background, hover_background, pressed_background,
                   border_color, border_width, text_color, size)

The mechanics of a chip: a pressable pill; when `selected` is an
`Observable{Bool}`, clicking toggles it (filter chips), otherwise the chip is
a plain pressable (assist/input/suggestion chips).
"""
function Chip(; on_press = () -> nothing, selected = nothing, disabled = false,
              label = "", children = Any[], leading = nothing, trailing = nothing,
              height = 32, padding = 16, gap = 8, radius = 8,
              background = nothing, hover_background = nothing,
              pressed_background = nothing, border_color = nothing,
              border_width = 1, text_color = nothing, size = 14)
    label_kids = isempty(children) ?
                 Any[label == "" ? nothing :
                     @rock Text(label; color = text_color, size = size)] :
                 styled_children(children, text_color, size)
    toggle = selected isa Observable
    return Element(
        _PRESSABLE,
        props_dict(
            :on_press => toggle ? () -> begin
                selected[] = !selected[]
                on_press()
            end : (disabled ? () -> nothing : on_press),
            :disabled => disabled,
            :background => background,
            :hover_background => disabled ? background : hover_background,
            :pressed_background => disabled ? background : pressed_background,
            :border_color => border_color,
            :border_width => border_width,
            :radius => radius,
            :height => height,
            :padding => padding,
            :direction => :row,
            :align => :center,
            :gap => gap,
        ),
        Any[leading, label_kids..., trailing],
    )
end

# ---- Segmented ------------------------------------------------------------

"""
    Mechanics.Segmented(; options, selection, multiple, disabled, on_change;
                        height, padding, gap, radius, border_color,
                        border_width, selected_background, selected_text,
                        unselected_text, size, check_color, check_size)

The mechanics of a segmented button: one pressable segment per entry of
`options::Vector{String}`. `selection` is an `Observable{Int}` (single
select) or `Observable{Vector{Int}}` (`multiple = true`).
"""
function Segmented(; selection, multiple = false, disabled = false,
                   on_change = () -> nothing, height = 40, padding = 12,
                   gap = 2, radius = 20, segment_radius = radius,
                   border_color = nothing, border_width = 1,
                   selected_background = nothing,
                   selected_text = nothing, unselected_text = nothing,
                   size = 14, check_color = nothing, check_size = 14,
                   options = nothing, children = Any[])
    selection isa Observable ||
        error("Mechanics.Segmented needs an `Observable` as its `selection` prop")
    opts = String[string(o) for o in flat_children(
        options !== nothing ? options : children)]
    isempty(opts) &&
        error("Mechanics.Segmented needs options (positional children or `options`)")
    is_selected(i) = multiple ? i in selection[] : selection[] == i
    segments = Element[]
    for (i, option) in enumerate(opts)
        on = is_selected(i)
        segment = Element(
            _PRESSABLE,
            props_dict(
                :on_press => () -> begin
                    if multiple
                        set = collect(Int, selection[])
                        if i in set
                            filter!(!=(i), set)
                        else
                            push!(set, i)
                        end
                        selection[] = sort(set)
                    else
                        selection[] = i
                    end
                    on_change()
                end,
                :disabled => disabled,
                :background => on ? selected_background : nothing,
                :hover_background => disabled ? nothing : selected_background,
                :pressed_background => disabled ? nothing : selected_background,
                :radius => segment_radius,
                :height => height,
                :padding => padding,
                :direction => :row,
                :align => :center,
                :gap => 8,
            ),
            Any[
                on && check_color !== nothing ?
                (@rock Text("✓"; color = check_color, size = check_size)) : nothing,
                @rock Text(option; color = on ? selected_text : unselected_text,
                           size = size)
            ],
        )
        push!(segments, segment)
        i < length(opts) && push!(segments, Element(
            _BOX,
            props_dict(:width => border_width, :height => height, :background => border_color),
            Any[],
        ))
    end
    return Element(
        _BOX,
        props_dict(
            :direction => :row, :align => :center,
            :border_color => border_color, :border_width => border_width,
            :radius => radius,
        ),
        segments,
    )
end

# ---- TextField ------------------------------------------------------------

"""
    Mechanics.TextField(; text, on_submit, disabled, label, placeholder;
                        width, height, padding, radius, background,
                        hover_background, border_color, focused_border_color,
                        border_width, text_color, placeholder_color,
                        caret_color, caret_width, label_color, size)

The mechanics of a single-line text field: a focusable field that appends
typed characters to `text` (an `Observable{String}`), deletes on Backspace,
submits on Return and releases focus on Escape. The caret is shown at the end
of the text while the field holds keyboard focus.
"""
function TextField(; text, on_submit = () -> nothing, disabled = false,
                   label = "", placeholder = "", width = 240, height = 48,
                   padding = 16, radius = 4, background = nothing,
                   hover_background = nothing, border_color = nothing,
                   focused_border_color = nothing, border_width = 1,
                   text_color = nothing, placeholder_color = nothing,
                   caret_color = nothing, caret_width = 2, label_color = nothing,
                   size = 16)
    text isa Observable ||
        error("Mechanics.TextField needs an `Observable` as its `text` prop")
    focused = has_focus()
    value = text[]
    content = value == "" && !focused && placeholder != "" ?
              (@rock Text(placeholder; color = placeholder_color, size = size)) :
              (@rock Text(value; color = text_color, size = size))
    caret = focused ? (@rock Box(;
        width = caret_width, height = height - 2padding,
        background = caret_color)) : nothing
    line = @rock Row(content, caret; gap = 2, align = :center)
    field_kid = label == "" ? line :
                (@rock Column(
                    (@rock Text(label; color = label_color, size = 12)),
                    line;
                    gap = 2))
    return Element(
        _PRESSABLE,
        props_dict(
            :on_text_input => disabled ? (s) -> nothing :
                (s) -> (text[] = text[] * s),
            :on_key => disabled ? (k) -> nothing : (k) -> begin
                if k == "Backspace"
                    isempty(text[]) || (text[] = text[][1:end-1])
                elseif k == "Return"
                    on_submit()
                elseif k == "Escape"
                    unfocus!()
                end
            end,
            :disabled => disabled,
            :background => background,
            :hover_background => hover_background,
            :border_color => focused && focused_border_color !== nothing ?
                             focused_border_color : border_color,
            :border_width => border_width,
            :radius => radius,
            :width => width,
            :height => height,
            :padding => padding,
            :direction => :row,
            :align => :center,
        ),
        Any[field_kid],
    )
end

# ---- Progress -------------------------------------------------------------

"""
    Mechanics.Progress(; value, width, height; track_color, active_color,
                       radius, stop_color)

The mechanics of a linear progress bar: a track with a filled portion
tracking `value` (an `Observable` between 0 and 1). Non-interactive.
"""
function Progress(; value, width = 240, height = 4, track_color = nothing,
                  active_color = nothing, radius = 0, stop_color = nothing)
    value isa Observable ||
        error("Mechanics.Progress needs an `Observable` as its `value` prop")
    v = clamp(value[], 0.0, 1.0)
    return Element(
        _BOX,
        props_dict(:width => width, :height => height, :background => track_color,
                   :radius => radius, :direction => :row),
        Any[
            @rock Box(;
                position = :absolute, x = 0, y = 0,
                width = width * v, height = height,
                radius = radius, background = active_color),
            stop_color === nothing ? nothing :
            (@rock Box(;
                position = :absolute, x = width - height, y = 0,
                width = height, height = height,
                radius = height / 2, background = stop_color))
        ],
    )
end

end # module Mechanics
