# Layout — a measure pass followed by a place pass.
#
# Measurement computes the natural size of each fiber bottom-up (text is
# measured with the font, boxes stack their children with gap/padding).
# Placement then assigns absolute, window-local rects top-down, honoring
# `direction`, `gap`, `padding`, `align` and fixed `width`/`height` props.
#
# This file is pure logic (except for font metrics) and headless-testable.

const _ABSOLUTE = :absolute

padding_of(fiber) = float(get(fiber.props, :padding, 0))

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
    for child in fiber.children
        is_absolute_child(child) || continue
        if get(child.props, :fill, false)
            # fill children measure their subtree, then stretch to the
            # parent's current size (windows use the real OS size)
            measure!(child)
            child.measured = (w, h)
        else
            measure!(child)
        end
    end
    pw = get(fiber.props, :width, nothing)
    ph = get(fiber.props, :height, nothing)
    pw !== nothing && (w = float(pw))
    ph !== nothing && (h = float(ph))
    fiber.measured = (w, h)
    return fiber.measured
end

function measure_box(fiber)
    p = padding_of(fiber)
    dir = Symbol(get(fiber.props, :direction, :column))
    gap = float(get(fiber.props, :gap, 0))
    kids = collect(flow_children(fiber))
    main, cross = 2p, 0.0
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
    return dir === :column ? (cross + 2p, main) : (main, cross + 2p)
end

function measure_text(fiber)
    content = text_content(fiber)
    isempty(content) && return (0.0, 0.0)
    size, _, fontpath = text_props(fiber)
    font = load_font(fontpath, max(round(Int, size), 1))
    lines = split(content, '\n'; keepempty = true)
    lineheight = Float64(TTF_FontHeight(font))
    w = 0.0
    for line in lines
        w_ref, _ = Ref{Cint}(0), Ref{Cint}(0)
        TTF_SizeUTF8(font, String(line), w_ref, Ref{Cint}(0))
        w = max(w, Float64(w_ref[]))
    end
    return (w, lineheight * length(lines))
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
        place_flow!(fiber, dir, gap, p, align, x, y, w, h)
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
        place_flow!(fiber, dir, gap, p, align, x, y, w, h)
    else
        # Component fibers lay their output out like a gap-less column.
        cy = y
        for child in flow_children(fiber)
            place!(child, x, cy)
            cy += child.measured[2]
        end
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

function place_flow!(fiber, dir, gap, p, align, x, y, w, h)
    cx0, cy0 = x + p, y + p
    content_w, content_h = max(w - 2p, 0.0), max(h - 2p, 0.0)
    if dir === :column
        cy = cy0
        for child in flow_children(fiber)
            cw = child.measured[1]
            cxx = align === :center ? cx0 + (content_w - cw) / 2 :
                  align === :end ? cx0 + content_w - cw : cx0
            place!(child, cxx, cy)
            cy += child.measured[2] + gap
        end
    else
        cx = cx0
        for child in flow_children(fiber)
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
    for child in fiber.children
        is_absolute_child(child) || continue
        cw, ch = child.measured
        calign = Symbol(get(child.props, :align, :top_left))
        dx = float(get(child.props, :x, 0))
        dy = float(get(child.props, :y, 0))
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
