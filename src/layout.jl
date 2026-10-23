# Layout — a measure pass followed by a place pass.
#
# Measurement computes the natural size of each fiber bottom-up (text is
# measured with the font, boxes stack their children with gap/padding).
# Placement then assigns absolute, window-local rects top-down, honoring
# `direction`, `gap`, `padding`, `align` and fixed `width`/`height` props.
#
# This file is pure logic (except for font metrics) and headless-testable.

const _ABSOLUTE = :absolute

"""
Scroll position of a scrollable [`Box`](@ref). `offset` is measured in pixels
from the start of the content; `max_offset` is recomputed on every layout
from the content and viewport extents.
"""
mutable struct ScrollState
    offset::Float64
    max_offset::Float64
    content_extent::Float64
    viewport_extent::Float64
    track_rect::Tuple{Float64,Float64,Float64,Float64}
    thumb_rect::Tuple{Float64,Float64,Float64,Float64}
    # Rects of the arrow buttons at the start (up/left) and stop (down/right)
    # ends of the scrollbar; empty when the scrollbar is invisible.
    arrow_a_rect::Tuple{Float64,Float64,Float64,Float64}
    arrow_b_rect::Tuple{Float64,Float64,Float64,Float64}
    drag_start_offset::Float64
    drag_start_pos::Float64
end

ScrollState(offset, max_offset, content_extent, viewport_extent) =
    ScrollState(offset, max_offset, content_extent, viewport_extent,
                (0.0, 0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 0.0),
                (0.0, 0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 0.0), 0.0, 0.0)

# `scrollbar = true` / `:vertical` / `:horizontal` adds a compact visible
# scrollbar. It is opt-in so plain scroll views keep their old pixel output.
function scrollbar_direction(fiber)
    s = get(fiber.props, :scrollbar, false)
    (s === false || s === nothing) && return nothing
    s === true && return :vertical
    d = Symbol(s)
    d in (:vertical, :horizontal) && return d
    return nothing
end

# A ScrollView always scrolls (its `direction` selects the axis); a Box
# becomes scrollable when `scroll = true` (vertical) or `:vertical` /
# `:horizontal` is given explicitly.
function scroll_direction(fiber)
    if fiber.kind === _SCROLLVIEW
        s = get(fiber.props, :scroll, nothing)
        (s === :horizontal || s === :row) && return :horizontal
        s === :vertical && return :vertical
        return Symbol(get(fiber.props, :direction, :column)) === :row ?
               :horizontal : :vertical
    end
    fiber.kind === _BOX || return nothing
    s = get(fiber.props, :scroll, false)
    (s === false || s === nothing) && return nothing
    s === true && return :vertical
    d = Symbol(s)
    (d === :vertical || d === :horizontal) && return d
    return nothing
end

is_scrollable(fiber) = scroll_direction(fiber) !== nothing

function scroll_state!(fiber)
    state = fiber.host
    state isa ScrollState && return state
    state = ScrollState(0.0, 0.0, 0.0, 0.0)
    fiber.host = state
    return state
end

# Padding is `(horizontal, vertical)`. `padding` may be a scalar (both axes)
# or a 2-tuple; `padding_x`/`padding_y` override either axis.
function padding_of(fiber)
    p = get(fiber.props, :padding, 0)
    px, py = p isa Tuple && length(p) == 2 ?
             (float(p[1]), float(p[2])) : (float(p), float(p))
    px = float(get(fiber.props, :padding_x, px))
    py = float(get(fiber.props, :padding_y, py))
    return (px, py)
end

is_absolute_child(fiber) = Symbol(get(fiber.props, :position, :relative)) === _ABSOLUTE

"""
    overflow_hidden(fiber) -> Bool

Whether the children of a fiber are clipped to its content box.  Set
`overflow = :hidden` on a box to keep its content inside it: a text field
whose text is wider than the field then clips the text instead of letting it
run over the border.
"""
overflow_hidden(fiber) = Symbol(get(fiber.props, :overflow, :visible)) === :hidden

"Children that participate in flow layout (absolute ones are skipped)."
flow_children(fiber) = (c for c in fiber.children if !is_absolute_child(c))

# ---- flexbox ---------------------------------------------------------------
#
# The layout follows the React Native model: a container has a main axis
# (the one its children flow along) and a cross axis, children have a flex
# basis and may grow or shrink into the free space of the container, and
# the container distributes the children along the main axis with `justify`
# and across the cross axis with `align`.

"The main-axis size of a (width, height) pair."
main_size(dir, size) = dir === :row ? size[1] : size[2]

"The cross-axis size of a (width, height) pair."
cross_size(dir, size) = dir === :row ? size[2] : size[1]

"""
    resolve_length(value, base)

Resolve a length prop: a number, a percentage of `base` (`"50%"`), or
`nothing` when the prop is absent or not a length.
"""
function resolve_length(value, base)
    value === nothing && return nothing
    if value isa AbstractString
        s = strip(value)
        endswith(s, "%") || return nothing
        pct = tryparse(Float64, s[1:end-1])
        pct === nothing && return nothing
        return pct / 100 * base
    end
    value isa Number || return nothing
    return float(value)
end

"""
    margin_of(fiber) -> (horizontal, vertical)

The outer margin of a child: a scalar or a `(horizontal, vertical)` pair.
"""
function margin_of(fiber)
    m = get(fiber.props, :margin, 0)
    m isa Tuple && length(m) == 2 && return (float(m[1]), float(m[2]))
    return (float(m), float(m))
end

"""
    flex_factor(fiber) -> (grow, shrink, basis)

The flex properties of a child.  `flex` is the React Native shorthand:
`flex = 1` means "grow 1, shrink 1, basis 0", so the child takes the free
space of its parent.  `flex_grow`, `flex_shrink` and `flex_basis` set the
parts individually.
"""
function flex_factor(fiber)
    props = fiber.props
    grow = float(get(props, :flex_grow, 0))
    shrink = float(get(props, :flex_shrink, 0))
    basis = get(props, :flex_basis, nothing)
    f = get(props, :flex, nothing)
    if f !== nothing
        grow = float(f)
        shrink = 1.0
        basis === nothing && (basis = 0.0)
    end
    return (grow = grow, shrink = shrink, basis = basis)
end

"""
    main_bounds(fiber, dir, inner) -> (min, max)

The minimum and maximum length of a child along the container's main axis.
"""
function main_bounds(fiber, dir, inner)
    props = fiber.props
    lo = resolve_length(get(props, dir === :row ? :min_width : :min_height, nothing),
                        inner)
    hi = resolve_length(get(props, dir === :row ? :max_width : :max_height, nothing),
                        inner)
    return (lo, hi)
end

"""
    cross_bounds(fiber, dir, inner) -> (min, max)

The minimum and maximum length of a child along the container's cross axis.
"""
function cross_bounds(fiber, dir, inner)
    props = fiber.props
    lo = resolve_length(get(props, dir === :row ? :min_height : :min_width, nothing),
                        inner)
    hi = resolve_length(get(props, dir === :row ? :max_height : :max_width, nothing),
                        inner)
    return (lo, hi)
end

"""
    justify_mode(value)

Normalize a `justify` prop (the main axis) to one of `:start`, `:end`,
`:center`, `:between`, `:around` or `:evenly`.  The React Native spellings
(`flex-start`, `space-between`, ...) are accepted as well.
"""
function justify_mode(value)
    v = Symbol(value)
    v === :flex_start && return :start
    v === :flex_end && return :end
    v === :space_between && return :between
    v === :space_around && return :around
    v === :space_evenly && return :evenly
    return v in (:start, :end, :center, :between, :around, :evenly) ? v : :start
end

"""
    align_mode(value)

Normalize an `align` prop (the cross axis) to one of `:start`, `:end`,
`:center` or `:stretch`.  The React Native spelling `flex-start` is accepted
as well.
"""
function align_mode(value)
    v = Symbol(value)
    v === :flex_start && return :start
    v === :flex_end && return :end
    return v in (:start, :end, :center, :stretch) ? v : :start
end

"The cross-axis alignment of a child: its own `align_self` wins over the
container's `align`."
function child_align(child, align)
    own = get(child.props, :align_self, nothing)
    own === nothing && return align
    return align_mode(own)
end

"""
    flex_wrap(fiber) -> :nowrap | :wrap

Whether the children of a container wrap onto several lines.  `wrap-reverse`
is treated like `wrap` (the lines are stacked from the start).
"""
function flex_wrap(fiber)
    v = Symbol(get(fiber.props, :flex_wrap, :nowrap))
    v in (:wrap, :wrap_reverse) && return :wrap
    return :nowrap
end

"""
    flex_base(child, dir, measured)

The main-axis size a child contributes to the natural size of its parent:
its flex basis when it has one, its measured size otherwise.
"""
function flex_base(child, dir, measured)
    fl = flex_factor(child)
    fl.basis === nothing && return measured
    b = resolve_length(fl.basis, measured)
    return b === nothing ? measured : b
end

"""
    flex_lines(bases, margins, gap, inner_main)

Group the children into flex lines: a child that does not fit into the
current line starts a new one.  Returns the indices of the children per
line.
"""
function flex_lines(bases, margins, gap, inner_main)
    lines = Vector{Vector{Int}}()
    current = Int[]
    used = 0.0
    for i in eachindex(bases)
        b = bases[i] + margins[i]
        if !isempty(current) && used + gap + b > inner_main
            push!(lines, current)
            current = [i]
            used = b
        else
            isempty(current) || (used += gap)
            push!(current, i)
            used += b
        end
    end
    isempty(current) || push!(lines, current)
    return lines
end

"""
    fixed_length(fiber, prop) -> Union{Float64, Nothing}

The `width`/`height` prop of a fiber when it is a fixed number.  A
percentage (`"50%"`) is resolved in the place pass, against the size of the
parent, and therefore has no value here.
"""
function fixed_length(fiber, prop)
    v = get(fiber.props, prop, nothing)
    v isa Number || return nothing
    return float(v)
end

"""
    measure!(fiber) -> (width, height)

Compute the measured size of a fiber bottom-up. Fixed `width`/`height` props
override the natural size.
"""
function measure!(fiber)
    if is_window(fiber)
        # Windows size themselves from props, or from their real (possibly
        # user-resized) OS size once created. Their children are measured for
        # placement.
        if fiber.host isa WindowState
            w, h = float(fiber.host.width), float(fiber.host.height)
        else
            w = float(get(fiber.props, :width, 800))
            h = float(get(fiber.props, :height, 600))
        end
        for child in flow_children(fiber)
            measure!(child)
        end
    elseif is_text(fiber)
        w, h = measure_text(fiber)
    elseif fiber.kind === _IMAGE
        w, h = measure_image(fiber)
    elseif fiber.kind === _SPLIT
        w = float(get(fiber.props, :width, 400))
        h = float(get(fiber.props, :height, 300))
        seed_split_ratio!(fiber)
        for child in flow_children(fiber)
            measure!(child)
        end
    elseif fiber.kind === _SLIDER
        value = get(fiber.props, :value, nothing)
        value isa Observable ||
            error("Slider needs an `Observable` as its `value` prop")
        w = float(get(fiber.props, :width, 200))
        h = float(get(fiber.props, :height, 24))
    elseif is_host(fiber.kind)
        w, h = measure_box(fiber)
    else
        # Component fibers stack their output like a gap-less column.
        main, cross = 0.0, 0.0
        for child in flow_children(fiber)
            cw, ch = measure!(child)
            main += ch
            cross = max(cross, cw)
        end
        w, h = cross, main
    end
    # Box-like hosts with an explicit width/height must apply those bounds
    # before measuring absolute `fill` children, so a full-size absolute child
    # of a fixed-size container gets the container's final size.
    if !is_window(fiber)
        pw0 = fixed_length(fiber, :width)
        ph0 = fixed_length(fiber, :height)
        pw0 !== nothing && (w = pw0)
        ph0 !== nothing && (h = ph0)
    end
    for child in fiber.children
        is_absolute_child(child) || continue
        if get(child.props, :fill, false)
            # Fill children measure their subtree, then stretch to the
            # parent's current size (windows use the real OS size). An
            # explicit width/height still wins, which lets an absolute
            # full-width app bar keep its 64px height.
            measure!(child)
            fw = fixed_length(child, :width)
            fh = fixed_length(child, :height)
            child.measured = (fw === nothing ? w : fw,
                              fh === nothing ? h : fh)
        else
            measure!(child)
        end
    end
    # Same guard as above: an explicitly sized window is sized by its real
    # (possibly user-resized) OS size, not by its creation props.
    if !is_window(fiber)
        pw = fixed_length(fiber, :width)
        ph = fixed_length(fiber, :height)
        pw !== nothing && (w = pw)
        ph !== nothing && (h = ph)
    end
    fiber.measured = (w, h)
    return fiber.measured
end

function measure_box(fiber)
    px, py = padding_of(fiber)
    dir = Symbol(get(fiber.props, :direction, :column))
    gap = float(get(fiber.props, :gap, 0))
    kids = collect(flow_children(fiber))
    main, cross = dir === :column ? 2py : 2px, 0.0
    # Regular children first: they determine the cross size that `fill`
    # children stretch across.
    bases = Float64[]
    margins = Float64[]
    for child in kids
        get(child.props, :fill, false) && continue
        cw, ch = measure!(child)
        base = flex_base(child, dir, dir === :column ? ch : cw)
        push!(bases, base)
        push!(margins, dir === :column ? margin_of(child)[2] : margin_of(child)[1])
        main += base
        cross = max(cross, dir === :column ? cw : ch)
    end
    for child in kids
        get(child.props, :fill, false) || continue
        cw, ch = measure!(child)
        base = flex_base(child, dir, dir === :column ? ch : cw)
        push!(bases, base)
        push!(margins, dir === :column ? margin_of(child)[2] : margin_of(child)[1])
        if dir === :column
            child.measured = (cross, ch)
            main += base
        else
            child.measured = (cw, cross)
            main += base
        end
    end
    main += gap * max(length(kids) - 1, 0)
    # Wrapped children form lines: the container is then as tall (or wide) as
    # the lines together.  Only a container with a definite main size can
    # break its lines.
    if flex_wrap(fiber) === :wrap && !isempty(kids)
        fixed = get(fiber.props, dir === :row ? :width : :height, nothing)
        fixed === nothing || begin
            inner = float(fixed) - (dir === :column ? 2py : 2px)
            lines = flex_lines(bases, margins, gap, inner)
            if length(lines) > 1
                line_cross = 0.0
                for line in lines
                    lc = 0.0
                    for i in line
                        child = kids[i]
                        cw, ch = child.measured
                        lc = max(lc, dir === :column ? cw : ch)
                    end
                    line_cross += lc
                end
                line_cross += gap * (length(lines) - 1)
                cross = max(cross, line_cross)
                main = float(fixed)
            end
        end
    end
    return dir === :column ? (cross + 2px, main) : (main, cross + 2py)
end

function measure_text(fiber)
    content = text_content(fiber)
    isempty(content) && return (0.0, 0.0)
    size, _, fontpath = text_props(fiber)
    font = load_font(fontpath, max(round(Int, size), 1))
    lines = split(content, '\n'; keepempty = true)
    widths, heights = Float64[], Float64[]
    for line in lines
        w, h = SDL3.TTF_GetStringSize(font, String(line))
        push!(widths, Float64(w))
        push!(heights, Float64(h))
    end
    # Some glyphs (descenders, symbols) render one pixel taller than the font
    # height. Advance by the taller of the line skip and the tallest line so
    # textures are never squashed into a shorter destination rect.
    advance = max(Float64(SDL3.TTF_GetFontLineSkip(font)),
                  maximum(heights; init = 0.0))
    h = advance * (length(lines) - 1) + heights[end]
    return (maximum(widths; init = 0.0), h)
end

"""
    place!(fiber, x, y)

Assign the absolute, window-local rect of `fiber` from its measured size and
lay out its children according to `direction`, `gap`, `padding`, `align` and
absolute-positioning props.
"""
function place!(fiber, x, y)
    w, h = fiber.measured
    fiber.rect = (x, y, w, h)
    if is_window(fiber)
        dir = Symbol(get(fiber.props, :direction, :column))
        gap = float(get(fiber.props, :gap, 0))
        p = padding_of(fiber)
        align = Symbol(get(fiber.props, :align, :start))
        justify = Symbol(get(fiber.props, :justify, :start))
        place_flow!(fiber, dir, gap, p, align, justify, x, y, w, h)
        return
    end
    if is_text(fiber)
        return # text draws at its rect origin
    end
    if fiber.kind === _SPLIT
        place_split!(fiber, x, y)
        return
    end
    if fiber.kind === _SLIDER
        place_slider!(fiber, x, y)
        return
    end
    if fiber.kind === _MOUSEAREA
        place_mouse_area!(fiber, x, y, w, h)
        return
    end
    if is_host(fiber.kind)
        dir = Symbol(get(fiber.props, :direction, :column))
        gap = float(get(fiber.props, :gap, 0))
        p = padding_of(fiber)
        align = Symbol(get(fiber.props, :align, :start))
        justify = Symbol(get(fiber.props, :justify, :start))
        if is_scrollable(fiber)
            place_scroll!(fiber, dir, gap, p, align, justify, x, y, w, h)
        else
            place_flow!(fiber, dir, gap, p, align, justify, x, y, w, h)
        end
    else
        # Component fibers lay their output out like a gap-less column, with
        # the same flex rules as a box.  The element a component returns takes
        # the size the parent gave the component, so a component that is
        # sized by flexbox (or stretched across the cross axis) fills the
        # space it was given.
        dir = Symbol(get(fiber.props, :direction, :column))
        gap = float(get(fiber.props, :gap, 0))
        p = padding_of(fiber)
        align = Symbol(get(fiber.props, :align, :start))
        justify = Symbol(get(fiber.props, :justify, :start))
        for child in flow_children(fiber)
            if get(child.props, :fill, false) ||
               Symbol(get(child.props, :position, :relative)) === _ABSOLUTE
                fw = fixed_length(child, :width)
                fh = fixed_length(child, :height)
                child.measured = (fw === nothing ? w : fw,
                                  fh === nothing ? h : fh)
            else
                child.measured = (w, h)
            end
        end
        place_flow!(fiber, dir, gap, p, align, justify, x, y, w, h)
    end
    return
end

# MouseArea layout: a single flow child fills the area (its content box)
# exactly, so wrapping content in a MouseArea is visually a no-op. Explicit
# child width/height still wins. With several children the area behaves like
# a plain Box (flex flow); absolute children keep their overlay placement.
function place_mouse_area!(fiber, x, y, w, h)
    kids = collect(flow_children(fiber))
    px, py = padding_of(fiber)
    if length(kids) == 1
        child = kids[1]
        fw = fixed_length(child, :width)
        fh = fixed_length(child, :height)
        child.measured = (something(fw, w - 2px), something(fh, h - 2py))
        place!(child, x + px, y + py)
    else
        dir = Symbol(get(fiber.props, :direction, :column))
        gap = float(get(fiber.props, :gap, 0))
        align = Symbol(get(fiber.props, :align, :start))
        justify = Symbol(get(fiber.props, :justify, :start))
        place_flow!(fiber, dir, gap, (px, py), align, justify, x, y, w, h)
    end
    place_absolute_children!(fiber, x, y, w, h)
    return nothing
end

# Lay out the two panes of a Split and record the handle rect for hit
# testing. Panes fill their side of the split exactly.
function place_split!(fiber, x, y)
    W, H = fiber.measured
    t = float(get(fiber.props, :handle, 6))
    dir = Symbol(get(fiber.props, :direction, :horizontal))
    ratio = split_ratio(fiber)
    if dir === :vertical
        pane1_h = (H - t) * ratio
        pane1 = (x, y, W, pane1_h)
        handle = (x, y + pane1_h, W, t)
        pane2 = (x, y + pane1_h + t, W, max(H - t - pane1_h, 0.0))
    else
        pane1_w = (W - t) * ratio
        pane1 = (x, y, pane1_w, H)
        handle = (x + pane1_w, y, t, H)
        pane2 = (x + pane1_w + t, y, max(W - t - pane1_w, 0.0), H)
    end
    panes = collect(flow_children(fiber))
    if length(panes) >= 1
        panes[1].measured = (pane1[3], pane1[4])
        place!(panes[1], pane1[1], pane1[2])
    end
    if length(panes) >= 2
        panes[2].measured = (pane2[3], pane2[4])
        place!(panes[2], pane2[1], pane2[2])
    end
    fiber.host isa SplitState && (fiber.host.handle_rect = handle)
    return nothing
end

function place_slider!(fiber, x, y)
    fiber.host isa SliderState &&
        (fiber.host.handle_rect = (x, y, fiber.measured[1], fiber.measured[2]))
    return nothing
end

# The current split position: an `Observable` `ratio` prop is controlled
# (read and written by dragging), a number seeds the internal position.
function split_ratio(fiber)
    r = get(fiber.props, :ratio, nothing)
    r isa Observable && return clamp(r[], 0.05, 0.95)
    fiber.host isa SplitState && return clamp(fiber.host.ratio, 0.05, 0.95)
    return 0.5
end

function set_split_ratio!(fiber, r)
    r = clamp(r, 0.05, 0.95)
    prop = get(fiber.props, :ratio, nothing)
    if prop isa Observable
        prop[] = r
    elseif fiber.host isa SplitState
        fiber.host.ratio = r
    end
    return nothing
end

# Seed the internal split position from a numeric `ratio` prop, once.
function seed_split_ratio!(fiber)
    fiber.host isa SplitState || return
    fiber.host.seeded && return
    r = get(fiber.props, :ratio, nothing)
    r isa Real && !isa(r, Observable) && (fiber.host.ratio = clamp(Float64(r), 0.05, 0.95))
    fiber.host.seeded = true
    return nothing
end

# Natural image size scaled to the `width`/`height` props. The image size is
# read from the file header (SDL3 has no public query for the size of a
# surface), so it is known before the first draw.
function measure_image(fiber)
    src = string(get(fiber.props, :src, ""))
    path = resolve_image_src(src)
    path === nothing && return (0.0, 0.0)
    nw, nh = image_file_size(path)
    (nw <= 0 || nh <= 0) && return (0.0, 0.0)
    w = fixed_length(fiber, :width)
    h = fixed_length(fiber, :height)
    if w !== nothing && h !== nothing
        return (float(w), float(h))
    elseif w !== nothing && nw > 0
        return (float(w), nh * float(w) / nw)
    elseif h !== nothing && nh > 0
        return (nw * float(h) / nh, float(h))
    end
    return (nw, nh)
end

# Scrollable boxes lay their flow content out like a normal Box, then shift
# it opposite the scroll offset. The offset is stored on the fiber and clamped
# whenever the content or viewport size changes. Absolute children stay
# pinned to the viewport.
function place_scroll!(fiber, dir, gap, p, align, justify, x, y, w, h)
    state = scroll_state!(fiber)
    px, py = p
    kids = collect(flow_children(fiber))
    main = sum(child -> dir === :column ? child.measured[2] : child.measured[1],
               kids; init = 0.0) + gap * max(length(kids) - 1, 0)
    extent = main + 2 * (dir === :column ? py : px)
    viewport = dir === :column ? h : w
    state.content_extent = extent
    state.viewport_extent = viewport
    state.max_offset = max(extent - viewport, 0.0)
    state.offset = clamp(state.offset, 0.0, state.max_offset)
    state.track_rect = (0.0, 0.0, 0.0, 0.0)
    state.thumb_rect = (0.0, 0.0, 0.0, 0.0)
    state.arrow_a_rect = (0.0, 0.0, 0.0, 0.0)
    state.arrow_b_rect = (0.0, 0.0, 0.0, 0.0)
    sb = scrollbar_direction(fiber)
    sbw = float(get(fiber.props, :scrollbar_width, 17))
    if sb !== nothing && sb === :vertical && state.max_offset > 0
        # Win7-style scrollbar: an arrow button at each end; the thumb travels
        # between them.
        arrow = sbw
        travel = max(h - 2arrow, 0.0)
        thumb_h = max(24.0, h * state.viewport_extent / max(state.content_extent, 1.0))
        thumb_h = min(thumb_h, max(travel, 24.0))
        thumb_y = travel > 24.0 ?
                  y + arrow + (travel - thumb_h) * (state.offset / state.max_offset) :
                  y + arrow
        state.track_rect = (x + w - sbw, y + arrow, sbw, travel)
        # The thumb spans the full scrollbar width like the arrow buttons (the
        # 1px stroke paints over the track edges, matching the Win7 look).
        state.thumb_rect = (x + w - sbw, thumb_y, sbw, thumb_h)
        state.arrow_a_rect = (x + w - sbw, y, sbw, arrow)
        state.arrow_b_rect = (x + w - sbw, y + h - arrow, sbw, arrow)
    elseif sb !== nothing && sb === :horizontal && state.max_offset > 0
        arrow = sbw
        travel = max(w - 2arrow, 0.0)
        thumb_w = max(24.0, w * state.viewport_extent / max(state.content_extent, 1.0))
        thumb_w = min(thumb_w, max(travel, 24.0))
        thumb_x = travel > 24.0 ?
                  x + arrow + (travel - thumb_w) * (state.offset / state.max_offset) :
                  x + arrow
        state.track_rect = (x + arrow, y + h - sbw, travel, sbw)
        state.thumb_rect = (thumb_x, y + h - sbw, thumb_w, sbw)
        state.arrow_a_rect = (x, y + h - sbw, arrow, sbw)
        state.arrow_b_rect = (x + w - arrow, y + h - sbw, arrow, sbw)
    end
    offset_x = dir === :horizontal ? state.offset : 0.0
    offset_y = dir === :column ? state.offset : 0.0
    place_flow!(fiber, dir, gap, p, align, justify, x, y, w, h;
                offset_x = offset_x, offset_y = offset_y)
    return nothing
end

function place_flow!(fiber, dir, gap, p, align, justify, x, y, w, h;
                     offset_x = 0.0, offset_y = 0.0)
    px, py = p
    cx0, cy0 = x + px - offset_x, y + py - offset_y
    content_w, content_h = max(w - 2px, 0.0), max(h - 2py, 0.0)
    kids = collect(flow_children(fiber))
    inner_main = dir === :column ? content_h : content_w
    inner_cross = dir === :column ? content_w : content_h
    align = align_mode(align)
    justify = justify_mode(justify)
    stretch = Bool(get(fiber.props, :stretch_children, false))

    # Base sizes, margins and flex factors of every child.
    bases = Float64[]
    margins = Float64[]
    grows = Float64[]
    shrinks = Float64[]
    bounds = Vector{Tuple{Union{Nothing,Float64},Union{Nothing,Float64}}}()
    for child in kids
        fl = flex_factor(child)
        cm, xm = margin_of(child)
        main_margin = dir === :column ? xm : cm
        # The child's own main-axis size: an explicit width/height wins over
        # the measured size, a percentage resolves against the container.
        explicit_main = resolve_length(
            get(child.props, dir === :row ? :width : :height, nothing), inner_main)
        fallback = explicit_main === nothing ? main_size(dir, child.measured) :
                   explicit_main
        base = fl.basis === nothing ? fallback :
               something(resolve_length(fl.basis, inner_main), fallback)
        lo, hi = main_bounds(child, dir, inner_main)
        lo !== nothing && (base = max(base, lo))
        hi !== nothing && (base = min(base, hi))
        push!(bases, base)
        push!(margins, main_margin)
        push!(grows, fl.grow)
        push!(shrinks, fl.shrink)
        push!(bounds, (lo, hi))
    end

    # Children that wrap form lines; every line then gets the free space of
    # the container on its own.
    lines = flex_wrap(fiber) === :wrap && !isempty(kids) ?
            flex_lines(bases, margins, gap, inner_main) : [collect(1:length(kids))]

    # Distribute the free space of every line along the main axis: children
    # with a grow factor share the surplus, children that do not fit share
    # the deficit weighted by their shrink factor and their base size.
    finals = copy(bases)
    for line in lines
        used = sum(i -> bases[i] + margins[i], line; init = 0.0) +
               gap * max(length(line) - 1, 0)
        free = inner_main - used
        if free > 0
            total = sum(i -> grows[i], line; init = 0.0)
            if total > 0
                for i in line
                    finals[i] = bases[i] + free * grows[i] / total
                end
            end
        elseif free < 0
            weights = [shrinks[i] * bases[i] for i in line]
            total = sum(weights; init = 0.0)
            if total > 0
                for (k, i) in enumerate(line)
                    finals[i] = bases[i] + free * weights[k] / total
                end
            end
        end
        # The flexed size is clamped to the child's own bounds.  A child that
        # hits its bound leaves space over, which the others get: the line is
        # distributed again with the sizes that were actually taken.
        clamped = Set{Int}()
        for i in line
            lo, hi = bounds[i]
            if lo !== nothing
                finals[i] < lo && push!(clamped, i)
                finals[i] = max(finals[i], lo)
            end
            if hi !== nothing
                finals[i] > hi && push!(clamped, i)
                finals[i] = min(finals[i], hi)
            end
        end
        if !isempty(clamped)
            used = sum(i -> finals[i] + margins[i], line; init = 0.0) +
                   gap * max(length(line) - 1, 0)
            free = inner_main - used
            room = [i for i in line if grows[i] > 0 && !(i in clamped)]
            total = sum(i -> grows[i], room; init = 0.0)
            if free > 0 && total > 0
                for i in room
                    finals[i] += free * grows[i] / total
                end
                for i in line
                    lo, hi = bounds[i]
                    lo !== nothing && (finals[i] = max(finals[i], lo))
                    hi !== nothing && (finals[i] = min(finals[i], hi))
                end
            end
        end
    end

    # Cross-axis sizes: an explicit width/height wins, `fill` and
    # `align = :stretch` stretch the child across the content box.
    crosses = Float64[]
    for child in kids
        cw, ch = child.measured
        explicit = resolve_length(
            get(child.props, dir === :column ? :width : :height, nothing),
            inner_cross)
        cross = explicit === nothing ? cross_size(dir, (cw, ch)) : explicit
        if explicit === nothing &&
           (get(child.props, :fill, false) ||
            (stretch && get(child.props, dir === :column ? :width : :height,
                            nothing) === nothing) ||
            child_align(child, align) === :stretch)
            cross = inner_cross
        end
        lo, hi = cross_bounds(child, dir, inner_cross)
        lo !== nothing && (cross = max(cross, lo))
        hi !== nothing && (cross = min(cross, hi))
        # A child never sticks out of its window sideways: the width is
        # clipped to the content box, so shrinking a window shrinks the
        # controls in it instead of letting them fall out.  (The height is
        # left alone: content that is taller than its box scrolls.)
        dir === :column && (cross = min(cross, inner_cross))
        push!(crosses, cross)
    end

    # Place the lines (cross axis) and the children (main axis).
    line_cross = 0.0
    for line in lines
        lc = 0.0
        for i in line
            lc = max(lc, crosses[i])
        end
        used = sum(i -> finals[i] + margins[i], line; init = 0.0) +
               gap * max(length(line) - 1, 0)
        leftover = inner_main - used
        offset = 0.0
        between = 0.0
        if justify === :center
            offset = leftover / 2
        elseif justify === :end
            offset = leftover
        elseif justify === :between && length(line) > 1
            between = leftover / (length(line) - 1)
        elseif justify === :around
            between = leftover / length(line)
            offset = between / 2
        elseif justify === :evenly
            between = leftover / (length(line) + 1)
            offset = between
        end
        cursor = offset
        for i in line
            child = kids[i]
            main_i = finals[i]
            cross_i = crosses[i]
            # The child's own size on both axes.
            if dir === :column
                child.measured = (cross_i, main_i)
            else
                child.measured = (main_i, cross_i)
            end
            cm, xm = margin_of(child)
            cross_offset = child_align(child, align) === :center ?
                           (inner_cross - cross_i) / 2 :
                           child_align(child, align) === :end ?
                           inner_cross - cross_i : 0.0
            if dir === :column
                place!(child, cx0 + cross_offset + cm,
                       cy0 + line_cross + xm + cursor)
            else
                place!(child, cx0 + cm + cursor,
                       cy0 + line_cross + cross_offset + xm)
            end
            cursor += main_i + margins[i] + gap + between
        end
        line_cross += lc + gap
    end
    # Absolutely positioned children are placed relative to the parent's
    # top-left corner, honoring overlay anchors (`align` prop): `:top_left`
    # (default), `:top_right`, `:bottom_left`, `:bottom_right` place the child
    # at that corner of the parent with `x`/`y` as inward offsets (negative
    # values push it outward past the edge), `:center` centers it in the
    # parent and `:bottom` bottom-anchors it centered horizontally.
    place_absolute_children!(fiber, x, y, w, h)
    return nothing
end

function place_absolute_children!(fiber, x, y, w, h)
    for child in fiber.children
        is_absolute_child(child) || continue
        dx = float(get(child.props, :x, 0))
        dy = float(get(child.props, :y, 0))
        if get(child.props, :fill, false)
            # A percentage resolves against the parent box.
            fw = resolve_length(get(child.props, :width, nothing), w)
            fh = resolve_length(get(child.props, :height, nothing), h)
            bottom = get(child.props, :bottom, nothing)
            # A fill child stretches to the parent box; with a `bottom` inset
            # (and no explicit height) it instead spans from its `y` offset
            # down to the parent's bottom edge minus the inset, so overlays
            # like a status bar keep their room when the window resizes.
            fh === nothing && bottom !== nothing &&
                (fh = max(h - dy - float(bottom), 0.0))
            child.measured = (fw === nothing ? w : fw,
                              fh === nothing ? h : fh)
        end
        cw, ch = child.measured
        calign = Symbol(get(child.props, :anchor,
                            get(child.props, :align, :top_left)))
        if calign === :center
            place!(child, x + (w - cw) / 2, y + (h - ch) / 2)
        elseif calign === :bottom
            place!(child, x + (w - cw) / 2, y + h - ch - dy)
        elseif calign === :top_right
            place!(child, x + (w - cw) - dx, y + dy)
        elseif calign === :bottom_left
            place!(child, x + dx, y + (h - ch) - dy)
        elseif calign === :bottom_right
            place!(child, x + (w - cw) - dx, y + (h - ch) - dy)
        else
            place!(child, x + dx, y + dy)
        end
    end
    return nothing
end
