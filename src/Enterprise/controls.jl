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
                       placeholder, width, height, on_submit, disabled)

A sunken white single-line text field with a caret, Backspace/Return handling
and optional password masking.
"""
function TextBox(; text, read_only = false, password = false, placeholder = "",
                 width = 160, height = nothing, on_submit = () -> nothing,
                 disabled = false)
    text isa Observable ||
        error("Enterprise.TextBox needs an `Observable` as its `text` prop")
    t = theme()
    text = @use text
    focused = has_focus()
    h = something(height, t.metrics.input_height)
    value = text[]
    display = password ? repeat("●", length(value)) : value
    content = value == "" && !focused && placeholder != "" ?
              text_element(placeholder; color = t.colors.disabled_text,
                           size = t.metrics.font_size, font = t.font) :
              text_element(display; color = t.colors.text,
                           size = t.metrics.font_size, font = t.font)
    caret = focused && !read_only ? (@rock Box(;
        width = 1, height = max(h - 6, 4),
        background = t.colors.text)) : nothing
    field = @rock Row(content, caret; gap = 1, align = :center)
    return Element(
        _PRESSABLE,
        props_dict(
            :on_text_input => (disabled || read_only) ? (s) -> nothing :
                (s) -> (text[] = text[] * s),
            :on_key => disabled ? (k) -> nothing : (k) -> begin
                if k == "Backspace" && !read_only
                    isempty(text[]) || (text[] = chop(text[]))
                elseif k == "Return"
                    on_submit()
                elseif k == "Escape"
                    unfocus!()
                end
            end,
            :disabled => disabled,
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
        Any[field],
    )
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
        font = t.font, marker_bevel = :sunken,
        bevel_light = t.colors.border_light,
        bevel_dark = t.colors.border_dark)
end

"""
    Enterprise.RadioButton(; selected, value, label, on_change, disabled)

A 13px sunken radio button. `selected` is an `Observable{Int}` and `value` is
the index this button writes when clicked.
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
        size = 13, border_width = 1,
        selected_ring = t.colors.focus, unselected_ring = t.colors.input_border,
        dot_color = t.colors.text, label_color = color, font = t.font,
        marker_bevel = :sunken, bevel_light = t.colors.border_light,
        bevel_dark = t.colors.border_dark)
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
    bg = something(caption_background, t.colors.control)
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
    return Element(_BOX, props, Any[caption, children...])
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
    inner_w = max(width - 4, 0)
    return Element(
        _BOX,
        props_dict(:width => width, :height => height,
                   :background => t.colors.progress_track,
                   :border_color => t.colors.progress_border,
                   :border_width => 1, :bevel => :sunken,
                   :radius => 2, :direction => :row),
        Any[
            @rock Box(;
                position = :absolute, x = 2, y = 2,
                width = inner_w * frac, height = max(height - 4, 1),
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
                   :handle => handle, :handle_color => t.colors.border,
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
            :width => width, :height => 24,
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
