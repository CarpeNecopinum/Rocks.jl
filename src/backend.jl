# SDL3 backend: colors, fonts, windows, textures and drawing.
#
# All SDL calls live in this file (plus events.jl/runtime.jl), keeping the
# reconciler and layout logic headless-testable.

using Downloads

# ---- colors --------------------------------------------------------------

# Normalize a user color into (r, g, b, a) bytes.
# Accepted: tuples/vectors of 3-4 numbers (all-integer → 0-255 scale, any
# float → 0-1 scale), hex strings "#rgb"/"#rrggbb"/"#rrggbbaa", and
# ColorTypes colors.
_to_rgba(c) = (UInt8(255), UInt8(255), UInt8(255), UInt8(255))

function _to_rgba(c::Colorant)
    rgba = RGBA{Float64}(c)
    return (
        UInt8(round(clamp(rgba.r, 0.0, 1.0) * 255)),
        UInt8(round(clamp(rgba.g, 0.0, 1.0) * 255)),
        UInt8(round(clamp(rgba.b, 0.0, 1.0) * 255)),
        UInt8(round(clamp(rgba.alpha, 0.0, 1.0) * 255)),
    )
end

function _to_rgba(c::Union{Tuple,Vector})
    length(c) in 3:4 || error("colors need 3 or 4 components, got: $c")
    if all(x -> x isa Integer, c)
        vals = ntuple(i -> UInt8(clamp(Int(c[i]), 0, 255)), length(c))
    else
        vals = ntuple(i -> UInt8(round(clamp(Float64(c[i]), 0.0, 1.0) * 255)), length(c))
    end
    alpha = length(vals) == 4 ? vals[4] : UInt8(255)
    return (vals[1], vals[2], vals[3], alpha)
end

function _to_rgba(c::AbstractString)
    s = startswith(c, "#") ? c[2:end] : c
    n = length(s)
    n in (3, 6, 8) || error("hex colors need 3, 6 or 8 digits, got: \"$c\"")
    if n == 3
        vals = ntuple(i -> UInt8(tryparse(Int, string(s[i], s[i]); base = 16)), 3)
        return (vals[1], vals[2], vals[3], UInt8(255))
    end
    rgb = (UInt8(tryparse(Int, s[1:2]; base = 16)), UInt8(tryparse(Int, s[3:4]; base = 16)),
           UInt8(tryparse(Int, s[5:6]; base = 16)))
    n == 6 && return (rgb..., UInt8(255))
    return (rgb..., UInt8(tryparse(Int, s[7:8]; base = 16)))
end

# ---- fonts ---------------------------------------------------------------

const DEFAULT_FONT = Ref{Union{Nothing,String}}(nothing)
const FONT_CACHE = Dict{Tuple{String,Int},SDL3.TTF_Font}()

const FONT_SEARCH_PATHS = [
    # honored first
    get(ENV, "ROCKS_FONT", ""),
    # linux
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
    "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
    # macOS
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
    # windows
    "C:\\Windows\\Fonts\\arial.ttf",
    "C:\\Windows\\Fonts\\segoeui.ttf",
]

"""
    set_default_font!(path)

Set the TTF font file used by [`Text`](@ref) elements that do not carry an
explicit `font` prop. By default a font is auto-discovered from common system
locations (or the `ROCKS_FONT` environment variable).
"""
function set_default_font!(path::AbstractString)
    isfile(path) || error("font file does not exist: $path")
    DEFAULT_FONT[] = String(path)
    return nothing
end

function default_font()
    DEFAULT_FONT[] !== nothing && return DEFAULT_FONT[]
    for path in FONT_SEARCH_PATHS
        isempty(path) && continue
        isfile(path) && return (DEFAULT_FONT[] = path)
    end
    error(
        "no default font found — set one with Rocks.set_default_font!(path), " *
        "the ROCKS_FONT environment variable, or the `font` prop on Text elements",
    )
end

"""
    load_font(path, size) -> SDL3.TTF_Font

Open a TTF font (cached by path and size). Returns the SDL font pointer used
by the backend.
"""
function load_font(path::AbstractString, size::Int)
    return get!(FONT_CACHE, (String(path), size)) do
        font = try
            SDL3.TTF_OpenFont(String(path), Float64(size))
        catch err
            error("could not load font \"$path\": $(sprint(showerror, err))")
        end
        font
    end
end

# ---- backend state -------------------------------------------------------

mutable struct WindowState
    ptr::SDL3.Window
    renderer::SDL3.Renderer
    id::UInt32
    width::Int
    height::Int
    # Drawing is event-driven: a window is redrawn after a render pass, when
    # the window manager exposes it, after a resize, or on hover/press
    # styling changes. `needs_layout` re-lays out the window without
    # re-running components (used after resizes).
    needs_draw::Bool
    needs_layout::Bool
    # The clip rectangle currently set on the renderer (SDL3 has no
    # "is the clip enabled" query, so the backend keeps track of it).
    clip::Union{Nothing,SDL3.Rect}
end

mutable struct TextState
    content::String
    color::Tuple{UInt8,UInt8,UInt8,UInt8}
    size::Float64
    fontpath::String
    renderer::SDL3.Renderer
    textures::Vector{SDL3.Texture}
    linewidths::Vector{Float64}
    lineheights::Vector{Float64}
    advance::Float64 # baseline-to-baseline distance for multi-line text
end

mutable struct PressState
    hovered::Bool
    pressed::Bool
end

mutable struct ImageState
    texture::SDL3.Texture
    w::Float64 # natural size of the loaded image
    h::Float64
    src::String
    renderer::SDL3.Renderer
end

mutable struct SplitState
    ratio::Float64 # internal split position when `ratio` is not an Observable
    seeded::Bool
    handle_rect::Tuple{Float64,Float64,Float64,Float64}
    drag_start_ratio::Float64
    drag_start_pos::Float64
end

mutable struct SliderState
    handle_rect::Tuple{Float64,Float64,Float64,Float64}
end

# SDL init / shutdown ------------------------------------------------------

const BACKEND_INITIALIZED = Ref(false)

function init_backend()
    BACKEND_INITIALIZED[] && return
    try
        SDL3.Init(SDL3.SDL_INIT_VIDEO | SDL3.SDL_INIT_EVENTS)
    catch err
        error("SDL3 could not be initialised: $(sprint(showerror, err))")
    end
    try
        SDL3.TTF_Init()
    catch err
        error("SDL3_ttf could not be initialised: $(sprint(showerror, err))")
    end
    BACKEND_INITIALIZED[] = true
    return nothing
end

function shutdown_backend()
    BACKEND_INITIALIZED[] || return
    for fiber in collect(values(WINDOW_BY_ID))
        destroy_window!(fiber)
    end
    empty!(WINDOW_BY_ID)
    empty!(ACTIVE_PRESS)
    empty!(HOVERED)
    # Cached font pointers are invalidated by TTF_Quit — close and forget them.
    for font in values(FONT_CACHE)
        font != C_NULL && SDL3.TTF_CloseFont(font)
    end
    empty!(FONT_CACHE)
    # The same holds for cached image surfaces: they belong to the SDL
    # instance that is about to go away.
    for surface in values(IMAGE_SURFACES)
        surface != C_NULL && SDL3.DestroySurface(surface)
    end
    empty!(IMAGE_SURFACES)
    SDL3.TTF_Quit()
    SDL3.Quit()
    # SDL_QuitMouse destroyed the cached system cursors: forget the dangling
    # pointers so the next session re-creates them (SDL 3.4's SDL_SetCursor
    # validates the cursor against the current mouse and rejects stale ones
    # with "Cursor not associated with the current mouse").
    HAND_CURSOR[] = C_NULL
    ARROW_CURSOR[] = C_NULL
    TEXT_CURSOR[] = C_NULL
    GRAB_CURSOR[] = C_NULL
    GRABBING_CURSOR[] = C_NULL
    CURSORS_UNAVAILABLE[] = false
    # Pending re-renders belong to the (unmounted) fibers of the session that
    # just ended.
    empty!(DIRTY_FIBERS)
    BACKEND_INITIALIZED[] = false
    return nothing
end

# ---- windows -------------------------------------------------------------

# Compute a reasonable position for a new window according to its
# positioning props:
#
# * `position = :cascade` (default) — centered on the chosen display with a
#   cascade offset per already-open window, so multiple windows don't stack
#   exactly on top of each other.
# * `position = :centered` — exactly centered on the chosen display.
# * `position = :manual` — exact `x`/`y`.
# * `position = :mouse` — top-left corner at the current pointer position.
#
# `display` selects the display for the centered modes (`nothing`, the
# default, means the display the pointer is on). Giving `x`/`y` without a
# `position` implies `:manual`.
function window_position(fiber)
    props = fiber.props
    position = if haskey(props, :position)
        Symbol(props[:position])
    elseif haskey(props, :x) || haskey(props, :y)
        :manual
    else
        :cascade
    end
    width, height = window_size(fiber)

    if position === :manual
        return (Int(get(props, :x, 0)), Int(get(props, :y, 0)))
    elseif position === :mouse
        _, mx, my = SDL3.GetGlobalMouseState()
        return (round(Int, mx), round(Int, my))
    end

    bx, by, bw, bh = display_bounds(get(props, :display, nothing))
    (bw <= 0 || bh <= 0) && return (0, 0)
    cascade = position === :cascade ? 32 * (length(WINDOW_BY_ID) % 8) : 0
    x = bx + max(0, bw - width) ÷ 2 + cascade
    y = by + max(0, bh - height) ÷ 2 + cascade
    return (x, y)
end

# Bounds (x, y, w, h) of a display: `nothing` selects the display the mouse
# pointer is on (falling back to display 0). Returns (0, 0, 0, 0) when the
# display cannot be queried (e.g. headless drivers).
#
# `display` is a display *index* (0 = the first display); SDL3 identifies
# displays by an id, so the index is translated here.
function display_bounds(display)
    if display === nothing
        _, mx, my = SDL3.GetGlobalMouseState()
        id = SDL3.GetDisplayForPoint(SDL3.Point(round(Int, mx), round(Int, my)))
    else
        displays = SDL3.GetDisplays()
        index = Int(display)
        (index < 0 || index >= length(displays)) && return (0, 0, 0, 0)
        id = displays[index + 1]
    end
    bounds = try
        SDL3.GetDisplayBounds(id)
    catch
        return (0, 0, 0, 0)
    end
    (bounds.w > 0 && bounds.h > 0) && return (bounds.x, bounds.y, bounds.w, bounds.h)
    try
        mode = SDL3.GetDesktopDisplayMode(id)
        return (0, 0, mode.w, mode.h)
    catch
        return (0, 0, 0, 0)
    end
end

"True when the window is meant to size itself from its laid-out content."
is_fit_window(fiber) = Bool(get(fiber.props, :fit_content, false))

"""
    fit_window_size(fiber) -> (w, h)

The natural content size of a window: its children in the window's flow
direction, plus the window's `padding` and `gap` props. `fill` children
measure naturally here — they never see a host to stretch into — so the
result is the size at which the layout is exactly full. The `width`/`height`
props are not consulted; `window_size` uses them as per-axis overrides.
"""
function fit_window_size(fiber)
    dir = Symbol(get(fiber.props, :direction, :column))
    gap = float(get(fiber.props, :gap, 0))
    pad = float(get(fiber.props, :padding, 0))
    main = 2pad
    cross = 0.0
    for (i, child) in enumerate(collect(flow_children(fiber)))
        cw, ch = measure!(child)
        # Swap so `dw` is the main-axis size and `dh` the cross-axis size.
        dw, dh = dir === :column ? (ch, cw) : (cw, ch)
        i > 1 && (main += gap)
        main += dw
        cross = max(cross, dh)
    end
    return cross + 2pad, main
end

window_size(fiber) = begin
    fw, fh = is_fit_window(fiber) ? fit_window_size(fiber) :
             (float(get(fiber.props, :width, 800)), float(get(fiber.props, :height, 600)))
    (round(Int, get(fiber.props, :width, fw)), round(Int, get(fiber.props, :height, fh)))
end

# The screen origin of a window's client area: the window position plus its
# decorations (title bar and frame), which are not part of the client area.
# Headless drivers do not report decorations, so they contribute nothing.
function client_origin(fiber)
    fiber.host isa WindowState || return (0, 0)
    x, y = SDL3.GetWindowPosition(fiber.host.ptr)
    top, left = try
        t, l, _, _ = SDL3.GetWindowBordersSize(fiber.host.ptr)
        (Int(t), Int(l))
    catch
        (0, 0)
    end
    return (Int(x) + left, Int(y) + top)
end

# The window a popup belongs to: its nearest ancestor window.
function owner_window(fiber)
    f = fiber.parent
    while f !== nothing
        is_window(f) && return f
        f = f.parent
    end
    return nothing
end

function create_window!(fiber)
    title = string(get(fiber.props, :title, "Rocks"))
    width, height = window_size(fiber)
    resizable = Bool(get(fiber.props, :resizable, false))
    popup = Bool(get(fiber.props, :popup, false))
    flags = UInt64(0)
    resizable && (flags |= SDL3.SDL_WINDOW_RESIZABLE)
    if popup
        # Popup menus: borderless, transient, always above the parent —
        # the window content draws its own bevel border. A plain borderless
        # window is used instead of SDL's `SDL_WINDOW_POPUP_MENU`: the
        # renderer of an override-redirect popup aborts the process with an
        # X BadValue on some X servers (X_GLXCreateContext), and the menu's
        # dismissal is handled in-app (`close_open_menus!`) anyway.
        flags |= SDL3.SDL_WINDOW_BORDERLESS | SDL3.SDL_WINDOW_ALWAYS_ON_TOP
    end
    xpos, ypos = window_position(fiber)
    ptr = if popup
        # A popup is positioned relative to its owner window, so it lines up
        # with the control that opened it on every platform (window positions
        # and their decorations differ between them).
        owner = owner_window(fiber)
        if owner === nothing
            error("a popup window needs an owner window")
        end
        w = try
            SDL3.CreateWindow(title, width, height, flags)
        catch err
            error("SDL3 could not create the window: $(sprint(showerror, err))")
        end
        ox, oy = client_origin(owner)
        SDL3.SetWindowPosition(w, ox + xpos, oy + ypos)
        w
    else
        w = try
            SDL3.CreateWindow(title, width, height, flags)
        catch err
            error("SDL3 could not create the window: $(sprint(showerror, err))")
        end
        SDL3.SetWindowPosition(w, xpos, ypos)
        w
    end
    renderer = try
        SDL3.CreateRenderer(ptr, "")
    catch err
        error("SDL3 could not create a renderer: $(sprint(showerror, err))")
    end
    SDL3.SetRenderDrawBlendMode(renderer, SDL3.SDL_BLENDMODE_BLEND)
    state = WindowState(ptr, renderer, SDL3.GetWindowID(ptr), width, height,
                        true, false, nothing)
    fiber.host = state
    WINDOW_BY_ID[state.id] = fiber
    # Menu popups must paint above their owner window.
    popup && SDL3.RaiseWindow(ptr)
    return state
end

function destroy_window!(fiber)
    fiber.host isa WindowState || return
    state = fiber.host
    delete!(WINDOW_BY_ID, state.id)
    SDL3.DestroyRenderer(state.renderer)
    SDL3.DestroyWindow(state.ptr)
    fiber.host = nothing
    return nothing
end

# Re-apply window props that the user may have changed between renders.
function sync_window!(fiber)
    fiber.host isa WindowState || return
    state = fiber.host
    # Popup windows have no title bar and SDL3 rejects both a title change
    # and a resize on them.
    if Bool(get(fiber.props, :popup, false))
        return nothing
    end
    title = string(get(fiber.props, :title, "Rocks"))
    resizable = Bool(get(fiber.props, :resizable, false))
    current = SDL3.GetWindowTitle(state.ptr)
    current != title && SDL3.SetWindowTitle(state.ptr, title)
    want = SDL3.HasWindowFlag(state.ptr, SDL3.SDL_WINDOW_RESIZABLE)
    want != resizable && SDL3.SetWindowResizable(state.ptr, resizable)
    return nothing
end

# ---- drawing helpers -----------------------------------------------------

function set_color(renderer, color)
    r, g, b, a = _to_rgba(color)
    SDL3.SetRenderDrawColor(renderer, r, g, b, a)
    return nothing
end

function fill_rect(renderer, x, y, w, h)
    (w <= 0 || h <= 0) && return
    SDL3.RenderFillRect(renderer,
                        SDL3.FRect(round(Int, x), round(Int, y),
                                   round(Int, w), round(Int, h)))
    return nothing
end

# ---- rounded-rect geometry (SDL_RenderGeometry) ---------------------------

# SDL_RenderGeometry rasterizes triangles without multisampling, so curved
# edges are aliased. Shapes are drawn with a one-pixel fringe whose vertex
# alpha ramps from 1 just inside the boundary to 0 just outside it: this
# approximates pixel coverage and antialiases fills and outlines.
const AA_HALF_WIDTH = 0.5

# Segments per 90° corner, chosen so the polygon stays within a fraction of a
# pixel of the true arc even for large radii.
round_rect_segments(r) =
    r <= 0 ? 1 : clamp(ceil(Int, 2.5 * sqrt(r)), 6, 64)

# Radii of the four corners, clockwise from the top left. A scalar radius
# applies to every corner; a 4-tuple `(top_left, top_right, bottom_right,
# bottom_left)` allows partially rounded shapes (e.g. segmented buttons).
function corner_radii(r, w, h)
    maxr = min(w, h) / 2
    vals = r isa Tuple || r isa AbstractVector ? r : (r, r, r, r)
    length(vals) == 4 ||
        error("radius must be a number or 4 corner radii, got: $r")
    return ntuple(i -> clamp(float(vals[i]), 0.0, maxr), 4)
end

has_radius(r) = r isa Tuple || r isa AbstractVector ?
                any(x -> float(x) > 0, r) : float(r) > 0

# Shrink corner radii by `d` (for an inset fill inside a border).
inset_radius(r, d) = r isa Tuple || r isa AbstractVector ?
    ntuple(i -> max(float(r[i]) - d, 0.0), 4) :
    max(float(r) - d, 0.0)

# Boundary points of a rounded rectangle, clockwise in screen space, with `n`
# segments per corner. With `r = min(w, h) / 2` this traces a circle.
function round_rect_points(x, y, w, h, r, n)
    return round_rect_points(x, y, w, h, (r, r, r, r), n)
end

function round_rect_points(x, y, w, h, r::NTuple{4,<:Real}, n)
    pts = Vector{SDL3.SDL_FPoint}()
    sizehint!(pts, 4 * (n + 1))
    for (cx, cy, a0, cr) in (
        (x + w - r[2], y + r[2], -pi / 2, r[2]),   # top-right: up → right
        (x + w - r[3], y + h - r[3], 0.0, r[3]),   # bottom-right: right → down
        (x + r[4], y + h - r[4], pi / 2, r[4]),    # bottom-left: down → left
        (x + r[1], y + r[1], pi, r[1]),            # top-left: left → up
    )
        for i in 0:n
            a = a0 + (i / n) * (pi / 2)
            push!(pts, SDL3.SDL_FPoint(cx + cr * cos(a), cy + cr * sin(a)))
        end
    end
    return pts
end

# One vertex colour per vertex of a geometry batch, scaled by `coverage`
# (0..1). SDL3 geometry uses floating point colours.
function geometry_color(color, coverage = 1.0)
    r, g, b, a = _to_rgba(color)
    alpha = clamp(coverage, 0.0, 1.0) * (a / 255)
    SDL3.SDL_FColor(r / 255, g / 255, b / 255, alpha)
end

geometry_vertex(p, color) = SDL3.SDL_Vertex(p, color, SDL3.SDL_FPoint(0, 0))

# ---- gradients -----------------------------------------------------------

# Interpolate a two-stop gradient at `t` (0 = top/left, 1 = bottom/right).
function gradient_color(g::LinearGradient, t)
    t = clamp(Float64(t), 0.0, 1.0)
    a = _to_rgba(g.top)
    b = _to_rgba(g.bottom)
    lerp(x, y) = round(UInt8, clamp(Float64(x) + (Float64(y) - Float64(x)) * t,
                                   0.0, 255.0))
    return (lerp(a[1], b[1]), lerp(a[2], b[2]),
            lerp(a[3], b[3]), lerp(a[4], b[4]))
end

gradient_fraction(g::LinearGradient, x, y, rx, ry, rw, rh) =
    g.direction === :horizontal ?
    (rw <= 0 ? 0.0 : (x - rx) / rw) :
    (rh <= 0 ? 0.0 : (y - ry) / rh)

# A rectangle filled with a two-stop gradient. Axis-aligned rectangles do not
# need the rounded-shape fringe, so a single quad is enough.
function fill_gradient_rect(renderer, x, y, w, h, g::LinearGradient)
    (w <= 0 || h <= 0) && return
    c0 = geometry_color(gradient_color(g, 0.0))
    c1 = geometry_color(gradient_color(g, 1.0))
    tl, tr, bl, br = if g.direction === :horizontal
        (c0, c1, c0, c1)
    else
        (c0, c0, c1, c1)
    end
    vertices = [
        geometry_vertex(SDL3.SDL_FPoint(x, y), tl),
        geometry_vertex(SDL3.SDL_FPoint(x + w, y), tr),
        geometry_vertex(SDL3.SDL_FPoint(x, y + h), bl),
        geometry_vertex(SDL3.SDL_FPoint(x + w, y + h), br),
    ]
    indices = Cint[0, 1, 2, 2, 1, 3]
    SDL3.RenderGeometry(renderer, vertices, indices)
    return nothing
end

# Append the triangles of a band between two equal-length rims. The first
# rim (`a`) is at the inside of the band and carries the shape color; the
# second (`b`) is at the outside and fades to transparent.
function push_rim_band!(indices, m, a0, b0)
    for i in 1:m
        j = i % m + 1
        ai, aj = Cint(a0 + i - 1), Cint(a0 + j - 1)
        bi, bj = Cint(b0 + i - 1), Cint(b0 + j - 1)
        push!(indices, ai, bi, aj)
        push!(indices, aj, bi, bj)
    end
    return indices
end

"Fill a small triangle (a scrollbar arrow glyph) with `color`. `pointing` is
`:up`, `:down`, `:left` or `:right`."
function fill_triangle!(renderer, x, y, w, h, color; pointing = :up)
    (w <= 0 || h <= 0) && return
    c = geometry_color(color)
    points = if Symbol(pointing) === :up
        (SDL3.SDL_FPoint(x + w / 2, y), SDL3.SDL_FPoint(x + w, y + h), SDL3.SDL_FPoint(x, y + h))
    elseif Symbol(pointing) === :down
        (SDL3.SDL_FPoint(x, y), SDL3.SDL_FPoint(x + w, y), SDL3.SDL_FPoint(x + w / 2, y + h))
    elseif Symbol(pointing) === :left
        (SDL3.SDL_FPoint(x, y + h / 2), SDL3.SDL_FPoint(x + w, y), SDL3.SDL_FPoint(x + w, y + h))
    else
        (SDL3.SDL_FPoint(x + w, y + h / 2), SDL3.SDL_FPoint(x, y + h), SDL3.SDL_FPoint(x, y))
    end
    vertices = [geometry_vertex(p, c) for p in points]
    indices = Cint[0, 1, 2]
    SDL3.RenderGeometry(renderer, vertices, indices)
    return nothing
end

"""
    fill_round_rect(renderer, x, y, w, h, r, color)

Fill an antialiased rounded rectangle with `color` using
`SDL_RenderGeometry`. With `r = min(w, h) / 2` this fills a circle.
Degenerate (`r <= 0`) falls back to `fill_rect` (axis-aligned rectangles do
not need antialiasing).
"""
function fill_round_rect(renderer, x, y, w, h, r, color)
    (w <= 0 || h <= 0) && return
    radii = corner_radii(r, w, h)
    maximum(radii) <= 0 &&
        return (set_color(renderer, color); fill_rect(renderer, x, y, w, h))
    t = min(AA_HALF_WIDTH, w / 2, h / 2)
    n = round_rect_segments(maximum(radii) + t)
    inner = round_rect_points(
        x + t, y + t, max(w - 2t, 0.0), max(h - 2t, 0.0),
        ntuple(i -> max(radii[i] - t, 0.0), 4), n)
    outer = round_rect_points(
        x - t, y - t, w + 2t, h + 2t, ntuple(i -> radii[i] + t, 4), n)
    m = length(inner)
    c = geometry_color(color)
    c0 = geometry_color(color, 0.0)
    vertices = Vector{SDL3.SDL_Vertex}(undef, 2m + 1)
    vertices[1] = geometry_vertex(
        SDL3.SDL_FPoint(x + w / 2, y + h / 2), c)
    for i in 1:m
        vertices[i + 1] = geometry_vertex(inner[i], c)
        vertices[m + i + 1] = geometry_vertex(outer[i], c0)
    end
    indices = Cint[]
    sizehint!(indices, 9m)
    for i in 1:m
        j = i % m + 1
        # solid interior fan, then the antialiasing fringe
        push!(indices, Cint(0), Cint(i), Cint(j))
    end
    push_rim_band!(indices, m, 1, m + 1)
    SDL3.RenderGeometry(renderer, vertices, indices)
    return nothing
end

# Rounded-rectangle fill with a two-stop gradient. The mesh mirrors
# `fill_round_rect`, but each vertex takes the gradient color at its position
# and keeps the same 1px alpha fringe.
function fill_round_rect_gradient(renderer, x, y, w, h, r, g::LinearGradient)
    (w <= 0 || h <= 0) && return
    radii = corner_radii(r, w, h)
    maximum(radii) <= 0 &&
        return fill_gradient_rect(renderer, x, y, w, h, g)
    t = min(AA_HALF_WIDTH, w / 2, h / 2)
    n = round_rect_segments(maximum(radii) + t)
    inner = round_rect_points(
        x + t, y + t, max(w - 2t, 0.0), max(h - 2t, 0.0),
        ntuple(i -> max(radii[i] - t, 0.0), 4), n)
    outer = round_rect_points(
        x - t, y - t, w + 2t, h + 2t, ntuple(i -> radii[i] + t, 4), n)
    m = length(inner)
    color_at(px, py, coverage = 1.0) = geometry_color(
        gradient_color(g, gradient_fraction(g, px, py, x, y, w, h)),
        coverage)
    vertices = Vector{SDL3.SDL_Vertex}(undef, 2m + 1)
    vertices[1] = geometry_vertex(
        SDL3.SDL_FPoint(x + w / 2, y + h / 2), color_at(x + w / 2, y + h / 2))
    for i in 1:m
        vertices[i + 1] = geometry_vertex(inner[i], color_at(inner[i].x, inner[i].y))
        vertices[m + i + 1] = geometry_vertex(outer[i], color_at(outer[i].x, outer[i].y, 0.0))
    end
    indices = Cint[]
    sizehint!(indices, 9m)
    for i in 1:m
        j = i % m + 1
        push!(indices, Cint(0), Cint(i), Cint(j))
    end
    push_rim_band!(indices, m, 1, m + 1)
    SDL3.RenderGeometry(renderer, vertices, indices)
    return nothing
end

# Fill the ring between two rounded rectangles (a rounded border). Both the
# outer and the inner (hole) edges are antialiased.
function ring_round_rect(renderer, x, y, w, h, r, bw, color)
    (w <= 0 || h <= 0 || bw <= 0) && return
    radii = corner_radii(r, w, h)
    bw = min(bw, w / 2, h / 2)
    bw <= 0 && return
    t = min(AA_HALF_WIDTH, bw / 2, w / 2, h / 2)
    n = round_rect_segments(maximum(radii) + t)
    iw, ih = max(w - 2bw, 0.0), max(h - 2bw, 0.0)
    ir = ntuple(i -> max(radii[i] - bw, 0.0), 4)
    outer_in = round_rect_points(
        x + t, y + t, max(w - 2t, 0.0), max(h - 2t, 0.0),
        ntuple(i -> max(radii[i] - t, 0.0), 4), n)
    outer_out = round_rect_points(
        x - t, y - t, w + 2t, h + 2t, ntuple(i -> radii[i] + t, 4), n)
    inner_out = round_rect_points(
        x + bw - t, y + bw - t, iw + 2t, ih + 2t,
        ntuple(i -> ir[i] + t, 4), n)
    inner_in = round_rect_points(
        x + bw + t, y + bw + t, max(iw - 2t, 0.0), max(ih - 2t, 0.0),
        ntuple(i -> max(ir[i] - t, 0.0), 4), n)
    m = length(outer_in)
    c = geometry_color(color)
    c0 = geometry_color(color, 0.0)
    vertices = Vector{SDL3.SDL_Vertex}(undef, 4m)
    for i in 1:m
        vertices[i] = geometry_vertex(outer_in[i], c)
        vertices[m + i] = geometry_vertex(outer_out[i], c0)
        vertices[2m + i] = geometry_vertex(inner_out[i], c)
        vertices[3m + i] = geometry_vertex(inner_in[i], c0)
    end
    indices = Cint[]
    sizehint!(indices, 18m)
    push_rim_band!(indices, m, 0, m)      # outer edge fringe
    push_rim_band!(indices, m, 0, 2m)     # solid border
    push_rim_band!(indices, m, 2m, 3m)    # inner (hole) edge fringe
    SDL3.RenderGeometry(renderer, vertices, indices)
    return nothing
end

function draw_rect_stroke(renderer, x, y, w, h, border_width)
    bw = min(border_width, w / 2, h / 2)
    fill_rect(renderer, x, y, w, bw)           # top
    fill_rect(renderer, x, y + h - bw, w, bw)  # bottom
    fill_rect(renderer, x, y, bw, h)           # left
    fill_rect(renderer, x + w - bw, y, bw, h)  # right
    return nothing
end

function fill_shape(renderer, x, y, w, h, radius, color)
    if color isa LinearGradient
        has_radius(radius) ? fill_round_rect_gradient(renderer, x, y, w, h, radius, color) :
        fill_gradient_rect(renderer, x, y, w, h, color)
    elseif has_radius(radius)
        fill_round_rect(renderer, x, y, w, h, radius, color)
    else
        set_color(renderer, color)
        fill_rect(renderer, x, y, w, h)
    end
    return nothing
end

# Draw the highlight/shadow edges of raised, sunken or etched controls inside
# the outer border. This is a 1px bevel, matching the compact Win7 metrics.
function draw_bevel!(fiber, renderer)
    props = fiber.props
    bevel = Symbol(get(props, :bevel, :none))
    bevel === :none && return nothing
    x, y, w, h = fiber.rect
    border = float(get(props, :border_width, 0))
    inset = border
    x += inset; y += inset; w -= 2inset; h -= 2inset
    (w <= 0 || h <= 0) && return nothing
    light = get(props, :bevel_light, (1.0, 1.0, 1.0, 0.75))
    dark = get(props, :bevel_dark, (0.0, 0.0, 0.0, 0.35))
    top_color, left_color, bottom_color, right_color =
        bevel === :raised ? (light, light, dark, dark) :
        bevel === :sunken ? (dark, dark, light, light) :
        (dark, dark, light, light)
    set_color(renderer, top_color)
    fill_rect(renderer, x, y, w, 1)
    set_color(renderer, left_color)
    fill_rect(renderer, x, y, 1, h)
    set_color(renderer, bottom_color)
    fill_rect(renderer, x, y + h - 1, w, 1)
    set_color(renderer, right_color)
    fill_rect(renderer, x + w - 1, y, 1, h)
    if bevel === :etched
        set_color(renderer, light)
        fill_rect(renderer, x + 1, y + 1, max(w - 2, 0.0), 1)
        fill_rect(renderer, x + 1, y + 1, 1, max(h - 2, 0.0))
    end
    return nothing
end

function draw_background!(fiber, renderer)
    props = fiber.props
    background = background_for(fiber)
    radius = get(props, :radius, 0)
    border_color = get(props, :border_color, nothing)
    border_width = float(get(props, :border_width, 0))
    x, y, w, h = fiber.rect
    if has_radius(radius)
        # Rounded shape: fill and border are drawn as geometry so outlined
        # containers (no background) keep their interior transparent. When
        # there is both a border and a background, paint the whole shape in
        # the border color and lay the background on top: overlapping two
        # separate antialiased shapes at the shared inner edge would let the
        # window background show through the seam.
        if background !== nothing && border_width > 0 && border_color !== nothing
            fill_round_rect(renderer, x, y, w, h, radius, border_color)
            fill_shape(
                renderer, x + border_width, y + border_width,
                max(w - 2border_width, 0.0), max(h - 2border_width, 0.0),
                inset_radius(radius, border_width), background)
        elseif background !== nothing
            fill_shape(renderer, x, y, w, h, radius, background)
        elseif border_width > 0 && border_color !== nothing
            ring_round_rect(renderer, x, y, w, h, radius, border_width, border_color)
        end
        draw_bevel!(fiber, renderer)
        return nothing
    end
    background !== nothing && fill_shape(renderer, x, y, w, h, radius, background)
    if border_width > 0 && border_color !== nothing
        set_color(renderer, border_color)
        draw_rect_stroke(renderer, x, y, w, h, border_width)
    end
    draw_bevel!(fiber, renderer)
    return nothing
end

# The background a box-like fiber draws with, taking pressable state into
# account.
function background_for(fiber)
    props = fiber.props
    if fiber.kind === _PRESSABLE && fiber.host isa PressState
        pressed = fiber.host.pressed
        hovered = fiber.host.hovered
        if pressed && haskey(props, :pressed_background)
            return get(props, :pressed_background, nothing)
        elseif hovered && haskey(props, :hover_background)
            return get(props, :hover_background, nothing)
        end
    end
    return get(props, :background, nothing)
end

# ---- text ----------------------------------------------------------------

# Build the text content from the element's children: values are stringified
# and concatenated (like JSX text children), element children are ignored.
function text_content(fiber)
    content = get(fiber.props, :content, nothing)
    content !== nothing && return string(content)
    parts = String[]
    for child in fiber.props[:children]
        (child isa Element || child === nothing || child isa Bool) && continue
        push!(parts, string(child))
    end
    return join(parts, "")
end

function text_props(fiber)
    props = fiber.props
    size = float(get(props, :size, 16))
    color = _to_rgba(get(props, :color, (1.0, 1.0, 1.0)))
    fontpath = haskey(props, :font) ? string(props[:font]) : default_font()
    return size, color, fontpath
end

# (Re)create the cached textures of a text fiber if its props changed.
function ensure_text!(fiber, renderer)
    content = text_content(fiber)
    size, color, fontpath = text_props(fiber)
    state = fiber.host
    if state isa TextState &&
       state.content == content && state.color == color && state.size == size &&
       state.fontpath == fontpath && state.renderer == renderer
        return state
    end
    state === nothing || free_text!(state)
    font = load_font(fontpath, max(round(Int, size), 1))
    lines = split(content, '\n'; keepempty = true)
    textures = SDL3.Texture[]
    linewidths = Float64[]
    lineheights = Float64[]
    scolor = SDL3.SDL_Color(color...)
    for line in lines
        # SDL3_ttf refuses to render an empty string ("Text has zero
        # width"), so empty lines simply have no texture.
        if isempty(line)
            push!(textures, C_NULL)
            push!(linewidths, 0.0)
            push!(lineheights, 0.0)
            continue
        end
        surface = try
            SDL3.TTF_RenderText_Blended(font, String(line), scolor)
        catch err
            @warn "Rocks: could not render text" line exception = err
            nothing
        end
        if surface === nothing || surface == C_NULL
            push!(textures, C_NULL)
            push!(linewidths, 0.0)
            push!(lineheights, 0.0)
            continue
        end
        texture = SDL3.CreateTextureFromSurface(renderer, surface)
        SDL3.DestroySurface(surface)
        tw, th = SDL3.GetTextureSize(texture)
        push!(textures, texture)
        push!(linewidths, Float64(tw))
        push!(lineheights, Float64(th))
    end
    advance = max(Float64(SDL3.TTF_GetFontLineSkip(font)),
                  maximum(lineheights; init = 0.0))
    fiber.host = TextState(content, color, size, fontpath, renderer, textures,
                           linewidths, lineheights, advance)
    return fiber.host
end

function free_text!(state::TextState)
    for texture in state.textures
        texture != C_NULL && SDL3.DestroyTexture(texture)
    end
    empty!(state.textures)
    empty!(state.linewidths)
    empty!(state.lineheights)
    state.renderer = C_NULL
    return nothing
end

# ---- images --------------------------------------------------------------

const IMAGE_CACHE_DIR = Ref{Union{Nothing,String}}(nothing)

# Cached loaded surfaces, keyed by resolved source path. Surfaces are
# renderer-independent and kept for the session so measuring and drawing an
# image read the file only once.
const IMAGE_SURFACES = Dict{String,SDL3.Surface}()

# Resolve an `Image` `src` prop: local paths pass through; URLs are fetched
# with `Downloads` into a per-session cache directory. Returns `nothing` when
# the source cannot be resolved.
function resolve_image_src(src)
    isempty(src) && return nothing
    if startswith(src, "http://") || startswith(src, "https://")
        if IMAGE_CACHE_DIR[] === nothing
            IMAGE_CACHE_DIR[] = mkpath(joinpath(tempdir(), "rocks-images"))
        end
        # A fixed seed: Julia salts the default string hash per process, so
        # the cache file would get a new name on every run and never hit.
        name = string(hash(src, UInt(0)), ".", lowercase(splitext(src)[2]))
        path = joinpath(IMAGE_CACHE_DIR[], name)
        isfile(path) && return path
        try
            Downloads.download(src, path)
        catch err
            @warn "Rocks: could not download image" src exception = err
            return nothing
        end
        return path
    end
    return isfile(src) ? src : nothing
end

# The natural pixel size of an image file, read from its header. SDL3 keeps
# the surface opaque and offers no query for its size, so the header is read
# directly: PNG stores the size in the IHDR chunk, BMP in the DIB header.
function image_file_size(path::AbstractString)
    try
        open(path, "r") do io
            header = read(io, 32)
            length(header) >= 26 || return (0.0, 0.0)
            be32(b, i) = (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) |
                         (UInt32(b[i+2]) << 8) | UInt32(b[i+3])
            le32(b, i) = UInt32(b[i]) | (UInt32(b[i+1]) << 8) |
                         (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
            if header[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
                return (Float64(be32(header, 17)), Float64(be32(header, 21)))
            elseif header[1:2] == UInt8[0x42, 0x4d] # "BM"
                return (Float64(abs(Int32(le32(header, 19)))),
                        Float64(abs(Int32(le32(header, 23)))))
            end
            return (0.0, 0.0)
        end
    catch
        return (0.0, 0.0)
    end
end

# Loaded surface for an image source (cached). Returns C_NULL when the image
# cannot be loaded.
function image_surface(src::String)
    return get!(IMAGE_SURFACES, src) do
        path = resolve_image_src(src)
        path === nothing && return C_NULL
        surface = C_NULL
        for loader in (SDL3.LoadPNG, SDL3.LoadBMP)
            surface = try
                loader(path)
            catch
                C_NULL
            end
            surface != C_NULL && break
        end
        surface == C_NULL && @warn "Rocks: could not load image" src path
        return surface
    end
end

function free_image!(state::ImageState)
    state.texture != C_NULL && SDL3.DestroyTexture(state.texture)
    state.texture = C_NULL
    state.renderer = C_NULL
    return nothing
end

# (Re)create the texture of an Image fiber if its `src` changed.
function ensure_image!(fiber, renderer)
    src = string(get(fiber.props, :src, ""))
    state = fiber.host
    if state isa ImageState && state.src == src && state.renderer == renderer
        return state
    end
    state === nothing || free_image!(state)
    texture, w, h = C_NULL, 0.0, 0.0
    surface = image_surface(src)
    if surface != C_NULL
        texture = SDL3.CreateTextureFromSurface(renderer, surface)
        if texture == C_NULL
            @warn "Rocks: could not create texture for image" src
        else
            tw, th = SDL3.GetTextureSize(texture)
            w, h = Float64(tw), Float64(th)
        end
    end
    fiber.host = ImageState(texture, w, h, src, renderer)
    return fiber.host
end

function draw_image!(fiber, renderer)
    state = ensure_image!(fiber, renderer)
    x, y, w, h = fiber.rect
    if state.texture == C_NULL
        # placeholder while missing/failed
        set_color(renderer, (0.20, 0.20, 0.24))
        fill_rect(renderer, x, y, w, h)
        return
    end
    dst = SDL3.FRect(round(Int, x), round(Int, y), round(Int, w), round(Int, h))
    SDL3.RenderTexture(renderer, state.texture, nothing, dst)
    return nothing
end

# ---- canvas --------------------------------------------------------------

"""
    Rocks.CanvasContext

The immediate-mode drawing surface passed to a [`Canvas`](@ref) element's
`draw` callback. Helpers draw in **canvas-local** coordinates: `(0, 0)` is the
top-left of the canvas and the y axis points down, matching the SDL/draw
axis that the rest of Rocks uses (`fiber.rect` is `(x, y, w, h)` in the
window's client area). `ctx.rect` returns that window-space rect, so a caller
can convert local ⇄ window coordinates.

All color arguments accept the same forms as everywhere else in Rocks
(tuples/vectors of 3–4 numbers on the 0–1 or 0–255 scale, hex strings
`"#rgb"`/`"#rrggbb"`/`"#rrggbbaa"`, or `ColorTypes` colors). No state persists
between frames: `draw` re-issues every primitive each redraw, so the canvas is
recomputed from scratch like the rest of the tree.

    ctx.clear([color])                 fill the whole canvas with `color` (or transparent)
    ctx.set_color(color)               set the stroke/fill colour for later calls
    ctx.rect(x, y, w, h; color, fill)  stroked or filled rectangle (canvas-local)
    ctx.line(x1, y1, x2, y2; color, width)   single line segment
    ctx.polyline(pts; color, width, closed)  polyline; pts = iterable of (x, y);
                                             closed loops back to pts[1]
    ctx.polygon(pts; color)            filled polygon (ear-clip free: triangle fan)
    ctx.points(pts; color, size)       filled square dots
    ctx.text(str, x, y; size, color, font)  TTF text, top-left at (x, y)
    ctx.texture(tex, x, y; w, h)       blit a caller-supplied `SDL3.Texture`
"""
# ---- canvas --------------------------------------------------------------

"""
    Rocks.CanvasContext

The immediate-mode drawing surface passed to a [`Canvas`](@ref) element's
`draw` callback. Helpers are stored as callable fields and draw in
**canvas-local** coordinates: `(0, 0)` is the top-left of the canvas and the
y axis points down, matching the SDL/draw axis that the rest of Rocks uses.
`ctx.rect` is `(x, y, w, h)` of the canvas in the window's client area, so a
caller can convert local ⇄ window coordinates.

All color arguments accept the same forms as everywhere else in Rocks
(tuples/vectors of 3–4 numbers on the 0–1 or 0–255 scale, hex strings
`"#rgb"`/`"#rrggbb"`/`"#rrggbbaa"`, or `ColorTypes` colors). No state persists
between frames: `draw` re-issues every primitive each redraw, so the canvas is
recomputed from scratch like the rest of the tree.

    ctx.clear([color])                     fill the whole canvas with `color` (or transparent)
    ctx.line(x1,y1, x2,y2; color, width)   single line segment (width>1 → filled quad)
    ctx.polyline(pts; color, width, closed)  polyline; pts = iterable of (x, y);
                                             closed loops back to pts[1]
    ctx.polygon(pts; color)                filled polygon (triangle fan; convex / fan-decomposed)
    ctx.points(pts; color, size)           filled square dots
    ctx.text(str, x, y; size, color, font) TTF text, top-left at (x, y)
    ctx.texture(tex, x, y; w, h)           blit a caller-supplied SDL3.Texture
"""
struct CanvasContext
    renderer::SDL3.Renderer
    rect::NTuple{4,Float64}
    clear::Function
    line::Function
    polyline::Function
    polygon::Function
    points::Function
    text::Function
    texture::Function
end

# Fill a convex quad with a solid colour. The colour is baked into the
# vertices via `geometry_color`, because `RenderGeometry` ignores
# `SetRenderDrawColor`.
function _canvas_fill_quad(renderer, pts, color)
    c = geometry_color(color)
    verts = SDL3.SDL_Vertex[
        SDL3.SDL_Vertex(SDL3.SDL_FPoint(Float32(p[1]), Float32(p[2])), c,
                        SDL3.SDL_FPoint(0, 0)) for p in pts]
    # The vertices arrive in ring order (p1, p2, p3, p4). Triangles must share
    # the p1-p3 diagonal; reusing the indices (0,1,2,2,1,3) of the gradient
    # helper (whose vertex order is TL,TR,BL,BR) would split along the wrong
    # diagonal and leave part of the quad unpainted.
    SDL3.RenderGeometry(renderer, verts, Cint[0, 1, 2, 0, 2, 3])
    return nothing
end

# Build a CanvasContext for one draw pass, closing over the renderer and the
# canvas origin so all coordinates are canvas-local.
function make_canvas(renderer, x0, y0, w, h)
    function canvas_line(x1, y1, x2, y2; color = nothing, width = 1.0)
        color !== nothing && set_color(renderer, color)
        if width <= 1.0
            SDL3.RenderLine(renderer, x0 + x1, y0 + y1, x0 + x2, y0 + y2)
        else
            dx, dy = x2 - x1, y2 - y1
            len = hypot(dx, dy)
            if len > 0
                nx, ny = -dy / len * width / 2, dx / len * width / 2
                pts = [(x0 + x1 + nx, y0 + y1 + ny), (x0 + x1 - nx, y0 + y1 - ny),
                       (x0 + x2 - nx, y0 + y2 - ny), (x0 + x2 + nx, y0 + y2 + ny)]
                _canvas_fill_quad(renderer, pts, something(color, (0, 0, 0)))
            end
        end
        return nothing
    end
    function canvas_clear(color = nothing)
        (w <= 0 || h <= 0) && return
        if color === nothing
            SDL3.SetRenderDrawBlendMode(renderer, SDL3.SDL_BLENDMODE_BLEND)
            SDL3.SetRenderDrawColor(renderer, 0, 0, 0, 0)
        else
            set_color(renderer, color)
        end
        SDL3.RenderFillRect(renderer,
                            SDL3.FRect(round(Int, x0), round(Int, y0),
                                       round(Int, w), round(Int, h)))
        return nothing
    end
    function canvas_polyline(pts; color = nothing, width = 1.0, closed = false)
        prev = nothing
        first = nothing
        for p in pts
            px, py = Float64(p[1]), Float64(p[2])
            if first === nothing
                first = (px, py)
            elseif prev !== nothing
                canvas_line(prev[1], prev[2], px, py; color = color, width = width)
            end
            prev = (px, py)
        end
        # A closed loop draws the segment back to the first point — shapes
        # from a laser document are closed by definition (PolyLine(closed)).
        if closed && first !== nothing && prev !== nothing &&
           (first[1] != prev[1] || first[2] != prev[2])
            canvas_line(prev[1], prev[2], first[1], first[2];
                        color = color, width = width)
        end
        return nothing
    end
    function canvas_polygon(pts; color = nothing)
        color === nothing && return
        c = geometry_color(color)
        verts = SDL3.SDL_Vertex[
            SDL3.SDL_Vertex(SDL3.SDL_FPoint(Float32(x0 + p[1]), Float32(y0 + p[2])), c,
                            SDL3.SDL_FPoint(0, 0)) for p in pts]
        n = length(verts)
        n < 3 && return
        idx = Cint[]
        for i in 2:n-1
            push!(idx, 0, Cint(i - 1), Cint(i))
        end
        SDL3.RenderGeometry(renderer, verts, idx)
        return nothing
    end
    function canvas_points(pts; color = nothing, size = 3.0)
        color !== nothing && set_color(renderer, color)
        r = size / 2
        for p in pts
            SDL3.RenderFillRect(renderer,
                SDL3.FRect(round(Int, x0 + p[1] - r), round(Int, y0 + p[2] - r),
                           round(Int, size), round(Int, size)))
        end
        return nothing
    end
    function canvas_text(str, x, y; size = 16.0, color = nothing, font = nothing)
        str == "" && return
        path = font === nothing ? default_font() : font
        path === nothing && return
        f = load_font(path, max(round(Int, size), 1))
        f == C_NULL && return
        (r, g, b, a) = color === nothing ? (UInt8(0), UInt8(0), UInt8(0), UInt8(255)) :
                        _to_rgba(color)
        surface = try
            SDL3.TTF_RenderText_Blended(f, String(str), SDL3.SDL_Color(r, g, b, a))
        catch err
            @warn "Rocks: canvas text failed" str exception = err
            C_NULL
        end
        surface == C_NULL && return
        texture = SDL3.CreateTextureFromSurface(renderer, surface)
        SDL3.DestroySurface(surface)
        texture == C_NULL && return
        tw, th = SDL3.GetTextureSize(texture)
        SDL3.RenderTexture(renderer, texture, nothing,
                           SDL3.FRect(round(Int, x0 + x), round(Int, y0 + y),
                                      round(Int, tw), round(Int, th)))
        SDL3.DestroyTexture(texture)
        return nothing
    end
    function canvas_texture(tex, x, y; w = nothing, h = nothing)
        if w === nothing || h === nothing
            tw, th = SDL3.GetTextureSize(tex)
            w === nothing && (w = tw)
            h === nothing && (h = th)
        end
        SDL3.RenderTexture(renderer, tex, nothing,
                           SDL3.FRect(round(Int, x0 + x), round(Int, y0 + y),
                                      round(Int, w), round(Int, h)))
        return nothing
    end
    return CanvasContext(renderer, (x0, y0, w, h), canvas_clear, canvas_line,
                         canvas_polyline, canvas_polygon, canvas_points,
                         canvas_text, canvas_texture)
end

# Draw a Canvas fiber: its background (like a Box), then the user `draw`
# callback and any children, all clipped to the canvas content box (honouring
# any outer clip) so content never runs out of the canvas.
function draw_canvas!(fiber, renderer)
    draw_background!(fiber, renderer)
    drawcb = get(fiber.props, :draw, nothing)
    dcb = drawcb isa Function ? drawcb : nothing
    previous = get(RENDER_CLIP, renderer, nothing)
    x, y, w, h = fiber.rect
    px, py = padding_of(fiber)
    clip = SDL3.Rect(round(Int, x + px), round(Int, y + py),
                     round(Int, max(w - 2px, 0)), round(Int, max(h - 2py, 0)))
    previous === nothing || (clip = clip_rect(previous, clip))
    if clip.w <= 0 || clip.h <= 0
        return nothing
    end
    SDL3.SetRenderClipRect(renderer, clip)
    RENDER_CLIP[renderer] = clip
    try
        if dcb !== nothing
            ctx = make_canvas(renderer, x + px, y + py, clip.w, clip.h)
            dcb(ctx)
        end
        for child in fiber.children
            draw!(child, renderer)
        end
    finally
        if previous === nothing
            SDL3.SetRenderClipRect(renderer, nothing)
            delete!(RENDER_CLIP, renderer)
        else
            SDL3.SetRenderClipRect(renderer, previous)
            RENDER_CLIP[renderer] = previous
        end
    end
    return nothing
end


# ---- the draw pass -------------------------------------------------------

# Intersect an SDL clip rectangle with the previous one.
function clip_rect(a::SDL3.Rect, b::SDL3.Rect)
    x1, y1 = max(a.x, b.x), max(a.y, b.y)
    x2 = min(a.x + a.w, b.x + b.w)
    y2 = min(a.y + a.h, b.y + b.h)
    return SDL3.Rect(x1, y1, max(x2 - x1, 0), max(y2 - y1, 0))
end

# SDL3 has no "is a clip set" query, so the backend keeps track of the clip
# rectangle that is currently applied to a renderer.
const RENDER_CLIP = Dict{SDL3.Renderer,SDL3.Rect}()

# Draw a scroll container's children clipped to its viewport (and to any
# outer clip, so nested scroll views compose correctly).
function draw_scrolled!(fiber, renderer)
    previous = get(RENDER_CLIP, renderer, nothing)
    x, y, w, h = fiber.rect
    clip = SDL3.Rect(round(Int, x), round(Int, y), round(Int, w), round(Int, h))
    previous === nothing || (clip = clip_rect(previous, clip))
    if clip.w <= 0 || clip.h <= 0
        return nothing
    end
    SDL3.SetRenderClipRect(renderer, clip)
    RENDER_CLIP[renderer] = clip
    try
        for child in fiber.children
            draw!(child, renderer)
        end
    finally
        if previous === nothing
            SDL3.SetRenderClipRect(renderer, nothing)
            delete!(RENDER_CLIP, renderer)
        else
            SDL3.SetRenderClipRect(renderer, previous)
            RENDER_CLIP[renderer] = previous
        end
    end
    draw_scrollbar!(fiber, renderer)
    return nothing
end

# Draw the children of a fiber with a clip rectangle applied: they are
# clipped to the content box of the fiber, so nothing can be drawn outside of
# it.  The previous clip is restored afterwards, so nested clips compose.
function draw_clipped!(fiber, renderer)
    previous = get(RENDER_CLIP, renderer, nothing)
    x, y, w, h = fiber.rect
    px, py = padding_of(fiber)
    clip = SDL3.Rect(round(Int, x + px), round(Int, y + py),
                     round(Int, max(w - 2px, 0)), round(Int, max(h - 2py, 0)))
    previous === nothing || (clip = clip_rect(previous, clip))
    if clip.w <= 0 || clip.h <= 0
        return nothing
    end
    SDL3.SetRenderClipRect(renderer, clip)
    RENDER_CLIP[renderer] = clip
    try
        for child in fiber.children
            draw!(child, renderer)
        end
    finally
        if previous === nothing
            SDL3.SetRenderClipRect(renderer, nothing)
            delete!(RENDER_CLIP, renderer)
        else
            SDL3.SetRenderClipRect(renderer, previous)
            RENDER_CLIP[renderer] = previous
        end
    end
    return nothing
end

# Optional scrollbar of a scroll container, drawn after (and outside) the
# clipped content so the thumb stays crisp at the viewport edge.
function draw_scrollbar!(fiber, renderer)
    scrollbar_direction(fiber) === nothing && return nothing
    state = fiber.host
    state isa ScrollState || return nothing
    tx, ty, tw, th = state.track_rect
    (tw <= 0 || th <= 0) && return nothing
    track = get(fiber.props, :scrollbar_track, (0.86, 0.86, 0.86))
    set_color(renderer, track)
    fill_rect(renderer, tx, ty, tw, th)
    set_color(renderer, get(fiber.props, :scrollbar_border, (0.65, 0.65, 0.65)))
    fill_rect(renderer, tx, ty, 1, th)
    fill_rect(renderer, tx, ty, tw, 1)
    # The arrow buttons at both ends (Win7 style) sit on top of the track.
    dir = scrollbar_direction(fiber)
    arrow_bg = get(fiber.props, :scrollbar_arrow_background,
                   LinearGradient("#FBFBFB", "#E8E8E8"))
    arrow_color = get(fiber.props, :scrollbar_arrow_color, (0.25, 0.25, 0.25))
    for (rect, pointing) in
        ((state.arrow_a_rect,
          dir === :horizontal ? :left : :up),
         (state.arrow_b_rect,
          dir === :horizontal ? :right : :down))
        ax, ay, aw, ah = rect
        (aw <= 0 || ah <= 0) && continue
        fill_shape(renderer, ax, ay, aw, ah, 2, arrow_bg)
        set_color(renderer, get(fiber.props, :scrollbar_border, (0.65, 0.65, 0.65)))
        draw_rect_stroke(renderer, ax, ay, aw, ah, 1)
        gw, gh = min(5.0, aw - 4.0), min(3.0, ah - 4.0)
        fill_triangle!(renderer, ax + (aw - gw) / 2, ay + (ah - gh) / 2,
                       gw, gh, arrow_color; pointing)
    end
    hx, hy, hw, hh = state.thumb_rect
    (hw <= 0 || hh <= 0) && return nothing
    thumb = get(fiber.props, :scrollbar_thumb, "#C9C9C9")
    fill_shape(renderer, hx, hy, hw, hh, get(fiber.props, :scrollbar_radius, 2), thumb)
    set_color(renderer, get(fiber.props, :scrollbar_border, (0.65, 0.65, 0.65)))
    draw_rect_stroke(renderer, hx, hy, hw, hh, 1)
    return nothing
end

"""
    draw!(fiber, renderer)

Draw a fiber's subtree into `renderer`. The renderer must belong to the OS
window the fiber was laid out for.
"""
function draw!(fiber, renderer)
    is_window(fiber) && return # windows are drawn by their own draw pass
    if is_text(fiber)
        state = ensure_text!(fiber, renderer)
        x, y = fiber.rect[1], fiber.rect[2]
        for (i, texture) in enumerate(state.textures)
            texture == C_NULL && continue
            w, h = state.linewidths[i], state.lineheights[i]
            (w <= 0 || h <= 0) && continue
            dst = SDL3.FRect(round(Int, x), round(Int, y + (i-1) * state.advance),
                             round(Int, w), round(Int, h))
            SDL3.RenderTexture(renderer, texture, nothing, dst)
        end
        return
    end
    if fiber.kind === _IMAGE
        draw_image!(fiber, renderer)
        return
    end
    if fiber.kind === _SLIDER
        draw_slider!(fiber, renderer)
        return
    end
    if fiber.kind === _CANVAS
        draw_canvas!(fiber, renderer)
        return
    end
    if fiber.kind === _BOX || fiber.kind === _PRESSABLE ||
       fiber.kind === _SCROLLVIEW
        draw_background!(fiber, renderer)
    end
    if is_scrollable(fiber)
        draw_scrolled!(fiber, renderer)
    elseif overflow_hidden(fiber)
        # `overflow = :hidden` keeps the children inside the box: a control
        # cannot draw outside of the space it was given.
        draw_clipped!(fiber, renderer)
    else
        for child in fiber.children
            draw!(child, renderer)
        end
    end
    if fiber.kind === _SPLIT
        draw_split_handle!(fiber, renderer)
    end
    return nothing
end

# The draggable handle of a Split, drawn after its panes. Besides a flat
# `handle_color`, `handle_bevel = :raised` (or `:sunken`) draws a Winforms
# style grip: dark edge lines on both sides of a light core, oriented across
# the split direction.
function draw_split_handle!(fiber, renderer)
    state = fiber.host
    state isa SplitState || return
    hx, hy, hw, hh = state.handle_rect
    props = fiber.props
    bevel = Symbol(get(props, :handle_bevel, :none))
    if bevel in (:raised, :sunken) && hw > 2 && hh > 2
        light = get(props, :bevel_light, (1.0, 1.0, 1.0, 0.75))
        dark = get(props, :bevel_dark, (0.0, 0.0, 0.0, 0.35))
        first = bevel === :raised ? (dark, light) : (light, dark)
        edge_first, edge_second = first[1], first[2]
        horizontal = Symbol(get(props, :direction, :horizontal)) == :horizontal
        if horizontal
            set_color(renderer, edge_first)
            fill_rect(renderer, hx, hy, 1, hh)
            fill_rect(renderer, hx + hw - 1, hy, 1, hh)
            set_color(renderer, edge_second)
            fill_rect(renderer, hx + 1, hy, 1, hh)
            fill_rect(renderer, hx + hw - 2, hy, 1, hh)
            fill_rect(renderer, hx + 2, hy, max(hw - 4, 0.0), hh)
        else
            set_color(renderer, edge_first)
            fill_rect(renderer, hx, hy, hw, 1)
            fill_rect(renderer, hx, hy + hh - 1, hw, 1)
            set_color(renderer, edge_second)
            fill_rect(renderer, hx, hy + 1, hw, 1)
            fill_rect(renderer, hx, hy + hh - 2, hw, 1)
            fill_rect(renderer, hx, hy + 2, hw, max(hh - 4, 0.0))
        end
    else
        set_color(renderer, get(props, :handle_color, (0.35, 0.35, 0.40)))
        fill_rect(renderer, hx, hy, hw, hh)
    end
    return nothing
end

# The track, filled portion and knob of a Slider. The appearance is
# prop-driven so styled variants (e.g. Rocks.Material3) can theme it:
#
# * `track_color` / `active_color` — inactive and active track colors.
# * `track_height` — the track thickness (the fiber rect may be taller).
# * `thumb_width > 0` — a gap of this width is cut into the track at the
#   value position (Material 3 style) instead of a round knob.
# * `handle_width` / `handle_height` / `handle_color` — a vertical handle
#   drawn in the gap (Material 3 expressive slider style).
# * `rounded` — rounded track ends.
# * `stop_color` — dots drawn at both ends of the track.
function draw_slider!(fiber, renderer)
    value = get(fiber.props, :value, nothing)
    value isa Observable || return
    x, y, w, h = fiber.rect
    lo = float(get(fiber.props, :min, 0))
    hi = float(get(fiber.props, :max, 1))
    frac = clamp((value[] - lo) / max(hi - lo, eps()), 0.0, 1.0)
    props = fiber.props
    track_h = float(get(props, :track_height, 4))
    accent = get(ACCENTS, Symbol(get(props, :color, :primary)), ACCENTS[:primary])
    track_color = get(props, :track_color, (0.28, 0.28, 0.32))
    active_color = get(props, :active_color, accent)
    rounded = get(props, :rounded, false)
    thumb_w = float(get(props, :thumb_width, 0))
    stop_color = get(props, :stop_color, nothing)
    handle_w = float(get(props, :handle_width, 0))
    handle_h = float(get(props, :handle_height, h))
    handle_color = get(props, :handle_color, active_color)
    ty = y + (h - track_h) / 2
    draw_track = (cx, cw, c) ->
        fill_shape(renderer, cx, ty, cw, track_h, rounded ? track_h / 2 : 0, c)
    if thumb_w > 0
        # Material 3 style: a gap in the track around the handle at the value.
        gap = min(thumb_w, w)
        center = x + w * frac
        active_end = max(center - gap / 2, x)
        inactive_start = min(center + gap / 2, x + w)
        draw_track(x, max(active_end - x, 0.0), active_color)
        draw_track(inactive_start, max(x + w - inactive_start, 0.0), track_color)
        if handle_w > 0
            hx = center - handle_w / 2
            hy = y + (h - handle_h) / 2
            fill_round_rect(renderer, hx, hy, handle_w, handle_h, handle_w / 2, handle_color)
        end
    else
        draw_track(x, w, track_color)
        active_color != track_color && draw_track(x, w * frac, active_color)
        # Classical/Win7 thumb: a raised rectangular grip, optionally with a
        # gradient and a border. Material 3 uses the `thumb_width > 0` branch
        # above and keeps its existing look.
        knob_w = float(get(props, :thumb_size, 12))
        knob_h = float(get(props, :thumb_height, knob_w))
        knob_r = float(get(props, :thumb_radius, knob_w / 2))
        kx = x + (w - knob_w) * frac
        ky = y + (h - knob_h) / 2
        thumb = get(props, :thumb_gradient,
                    get(props, :thumb_color, active_color))
        fill_shape(renderer, kx, ky, knob_w, knob_h, knob_r, thumb)
        tbw = float(get(props, :thumb_border_width, 0))
        tbc = get(props, :thumb_border_color, nothing)
        if tbw > 0 && tbc !== nothing
            knob_r > 0 ?
                ring_round_rect(renderer, kx, ky, knob_w, knob_h, knob_r, tbw, tbc) :
                (set_color(renderer, tbc);
                 draw_rect_stroke(renderer, kx, ky, knob_w, knob_h, tbw))
        end
        if get(props, :thumb_bevel, false) === true ||
           Symbol(get(props, :thumb_bevel, :none)) !== :none
            light = get(props, :bevel_light, (1.0, 1.0, 1.0, 0.8))
            dark = get(props, :bevel_dark, (0.0, 0.0, 0.0, 0.35))
            set_color(renderer, light)
            fill_rect(renderer, kx + 1, ky + 1, max(knob_w - 2, 0.0), 1)
            fill_rect(renderer, kx + 1, ky + 1, 1, max(knob_h - 2, 0.0))
            set_color(renderer, dark)
            fill_rect(renderer, kx + 1, ky + knob_h - 2, max(knob_w - 2, 0.0), 1)
            fill_rect(renderer, kx + knob_w - 2, ky + 1, 1, max(knob_h - 2, 0.0))
        end
    end
    if stop_color !== nothing
        dot = 2.0
        fill_round_rect(renderer, x - dot / 2, ty + track_h / 2 - dot / 2, dot, dot, dot / 2, stop_color)
        fill_round_rect(renderer, x + w - dot / 2, ty + track_h / 2 - dot / 2, dot, dot, dot / 2, stop_color)
    end
    ticks = Int(get(props, :ticks, 0))
    if ticks > 0
        tick_color = get(props, :tick_color, (0.45, 0.45, 0.45))
        tick_len = float(get(props, :tick_length, 3))
        set_color(renderer, tick_color)
        # Ticks sit where the knob's center lands for the respective value:
        # the knob center travels across `w - knob_w` pixels, not the full
        # width, so the first and last tick match the end knobs exactly.
        knob_w = thumb_w > 0 ? 0.0 : float(get(props, :thumb_size, 12))
        span = max(w - knob_w, 1.0)
        for i in 0:ticks
            tx = x + knob_w / 2 + span * (i / ticks)
            fill_rect(renderer, tx, y + h - tick_len, 1, tick_len)
        end
    end
    return nothing
end

const DEFAULT_WINDOW_BACKGROUND = (0.12, 0.12, 0.14)

"""
    draw_window!(fiber, present = true)

Clear the OS window of a window fiber with its background and draw its
children, then present. [`screenshot`](@ref) draws with `present = false` to
read the backbuffer before presenting.
"""
function draw_window!(fiber, present::Bool = true)
    state = fiber.host
    state isa WindowState || return
    renderer = state.renderer
    set_color(renderer, get(fiber.props, :background, DEFAULT_WINDOW_BACKGROUND))
    SDL3.RenderClear(renderer)
    for child in fiber.children
        draw!(child, renderer)
    end
    present && SDL3.RenderPresent(renderer)
    return nothing
end

# The first fiber in a subtree with a live OS window.
function find_window_fiber(fiber)
    is_window(fiber) && fiber.host isa WindowState && return fiber
    for child in fiber.children
        found = find_window_fiber(child)
        found !== nothing && return found
    end
    return nothing
end

"""
    screenshot(window, path) -> path

Capture the current frame of a window into a PNG file at `path` and return
`path`. `window` is the root fiber of a rendered tree (the first window found
in the tree is captured) or a window fiber. The window is redrawn before the
capture, so the file reflects the current tree and state; the screen keeps
showing the redrawn frame afterwards.

Works in normal windows and headlessly (SDL's dummy driver writes real
pixels with a software renderer), which makes pixel-verified screenshot
tests possible without any display:

```julia
root = render(App; frames = 3, screenshot = "app.png")  # capture and quit
```

For trees with several windows, pass the specific window fiber to capture a
different one.
"""
function screenshot(window, path::AbstractString)
    window isa Fiber ||
        error("screenshot expects a rendered window or root fiber, got: $(typeof(window))")
    fiber = find_window_fiber(window)
    fiber === nothing &&
        error("no rendered window found in the given fiber tree")
    state = fiber.host
    w, h = SDL3.GetWindowSize(state.ptr)
    w, h = max(Int(w), 1), max(Int(h), 1)
    # Redraw without presenting so the backbuffer holds the current frame,
    # read it, then present the redrawn frame.
    draw_window!(fiber, false)
    surface = try
        SDL3.RenderReadPixels(state.renderer,
                              SDL3.Rect(Cint(0), Cint(0), Cint(w), Cint(h)))
    catch err
        error("could not read the framebuffer: $(sprint(showerror, err))")
    end
    try
        SDL3.SavePNG(surface, String(path))
    catch err
        error("could not write the screenshot: $(sprint(showerror, err))")
    finally
        SDL3.DestroySurface(surface)
    end
    SDL3.RenderPresent(state.renderer)
    return path
end
