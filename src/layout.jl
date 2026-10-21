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

"Children that participate in flow layout (absolute ones are skipped)."
flow_children(fiber) = (c for c in fiber.children if !is_absolute_child(c))

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
        pw0 = get(fiber.props, :width, nothing)
        ph0 = get(fiber.props, :height, nothing)
        pw0 !== nothing && (w = float(pw0))
        ph0 !== nothing && (h = float(ph0))
    end
    for child in fiber.children
        is_absolute_child(child) || continue
        if get(child.props, :fill, false)
            # Fill children measure their subtree, then stretch to the
            # parent's current size (windows use the real OS size). An
            # explicit width/height still wins, which lets an absolute
            # full-width app bar keep its 64px height.
            measure!(child)
            fw = get(child.props, :width, nothing)
            fh = get(child.props, :height, nothing)
            child.measured = (fw === nothing ? w : float(fw),
                              fh === nothing ? h : float(fh))
        else
            measure!(child)
        end
    end
    # Same guard as above: an explicitly sized window is sized by its real
    # (possibly user-resized) OS size, not by its creation props.
    if !is_window(fiber)
        pw = get(fiber.props, :width, nothing)
        ph = get(fiber.props, :height, nothing)
        pw !== nothing && (w = float(pw))
        ph !== nothing && (h = float(ph))
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
    for child in kids
        get(child.props, :fill, false) && continue
        cw, ch = measure!(child)
        main += dir === :column ? ch : cw
        cross = max(cross, dir === :column ? cw : ch)
    end
    for child in kids
        get(child.props, :fill, false) || continue
        cw, ch = measure!(child)
        if dir === :column
            child.measured = (cross, ch)
            main += ch
        else
            child.measured = (cw, cross)
            main += cw
        end
    end
    main += gap * max(length(kids) - 1, 0)
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
        w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
        TTF_SizeUTF8(font, String(line), w_ref, h_ref)
        push!(widths, Float64(w_ref[]))
        push!(heights, Float64(h_ref[]))
    end
    # Some glyphs (descenders, symbols) render one pixel taller than
    # TTF_FontHeight. Advance by the taller of the line skip and the tallest
    # line so textures are never squashed into a shorter destination rect.
    advance = max(Float64(TTF_FontLineSkip(font)), maximum(heights; init = 0.0))
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
        # Component fibers lay their output out like a gap-less column. A
        # `fill` child stretches to the component's (possibly constrained)
        # width, so a component that returns a host box can fill the space its
        # parent allocated (e.g. a pinned TopAppBar component).
        cy = y
        for child in flow_children(fiber)
            if get(child.props, :fill, false)
                if Symbol(get(child.props, :position, :relative)) === _ABSOLUTE
                    fw = get(child.props, :width, nothing)
                    fh = get(child.props, :height, nothing)
                    child.measured = (fw === nothing ? w : float(fw),
                                      fh === nothing ? h : float(fh))
                else
                    child.measured = (w, child.measured[2])
                end
            end
            place!(child, x, cy)
            cy += child.measured[2]
        end
        place_absolute_children!(fiber, x, y, w, h)
    end
    return
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

# Natural image size scaled to the `width`/`height` props. The image loads
# (and is cached) at measure time, so the size is known before the first draw.
function measure_image(fiber)
    src = string(get(fiber.props, :src, ""))
    surface = image_surface(src)
    surface == C_NULL && return (0.0, 0.0)
    dims = unsafe_load(surface)
    nw, nh = Float64(dims.w), Float64(dims.h)
    w = get(fiber.props, :width, nothing)
    h = get(fiber.props, :height, nothing)
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
    if dir === :column
        main = sum(child -> child.measured[2], kids; init = 0.0) +
               gap * max(length(kids) - 1, 0)
        cy = cy0 + (justify === :center ? (content_h - main) / 2 :
                    justify === :end ? content_h - main : 0.0)
        stretch = Bool(get(fiber.props, :stretch_children, false))
        for child in kids
            # `fill` stretches across the parent's content box even when the
            # parent's size was fixed/filled after measurement (e.g. a
            # ScrollView content column matching the viewport width).
            # `stretch_children` does the same for every child without an
            # explicit width, which lets a page host stretch a component whose
            # own output wants to fill (e.g. a tab page).
            if get(child.props, :fill, false) ||
               (stretch && get(child.props, :width, nothing) === nothing)
                child.measured = (content_w, child.measured[2])
            end
            cw = child.measured[1]
            cxx = align === :center ? cx0 + (content_w - cw) / 2 :
                  align === :end ? cx0 + content_w - cw : cx0
            place!(child, cxx, cy)
            cy += child.measured[2] + gap
        end
    else
        main = sum(child -> child.measured[1], kids; init = 0.0) +
               gap * max(length(kids) - 1, 0)
        cx = cx0 + (justify === :center ? (content_w - main) / 2 :
                    justify === :end ? content_w - main : 0.0)
        for child in kids
            if get(child.props, :fill, false)
                child.measured = (child.measured[1], content_h)
            end
            ch = child.measured[2]
            cyy = align === :center ? cy0 + (content_h - ch) / 2 :
                  align === :end ? cy0 + content_h - ch : cy0
            place!(child, cx, cyy)
            cx += child.measured[1] + gap
        end
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
            fw = get(child.props, :width, nothing)
            fh = get(child.props, :height, nothing)
            bottom = get(child.props, :bottom, nothing)
            # A fill child stretches to the parent box; with a `bottom` inset
            # (and no explicit height) it instead spans from its `y` offset
            # down to the parent's bottom edge minus the inset, so overlays
            # like a status bar keep their room when the window resizes.
            fh === nothing && bottom !== nothing &&
                (fh = max(h - dy - float(bottom), 0.0))
            child.measured = (fw === nothing ? w : float(fw),
                              fh === nothing ? h : float(fh))
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
