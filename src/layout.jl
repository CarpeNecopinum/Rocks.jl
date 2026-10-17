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
        is_absolute_child(child) && measure!(child)
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
    main, cross = 2p, 0.0
    count = 0
    for child in flow_children(fiber)
        cw, ch = measure!(child)
        main += dir === :column ? ch : cw
        cross = max(cross, dir === :column ? cw : ch)
        count += 1
    end
    main += gap * max(count - 1, 0)
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
    # Absolutely positioned children are placed manually relative to the
    # parent's top-left corner.
    for child in fiber.children
        is_absolute_child(child) || continue
        place!(child, x + float(get(child.props, :x, 0)), y + float(get(child.props, :y, 0)))
    end
    return nothing
end
