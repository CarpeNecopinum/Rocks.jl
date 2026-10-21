# SDL2 backend: colors, fonts, windows, textures and drawing.
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
const FONT_CACHE = Dict{Tuple{String,Int},Ptr{TTF_Font}}()

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
    load_font(path, size) -> Ptr{TTF_Font}

Open a TTF font (cached by path and size). Returns the SDL font pointer used
by the backend.
"""
function load_font(path::AbstractString, size::Int)
    return get!(FONT_CACHE, (String(path), size)) do
        font = TTF_OpenFont(String(path), size)
        font == C_NULL && error(
            "could not load font \"$path\": $(unsafe_string(SDL_GetError()))",
        )
        font
    end
end

# ---- backend state -------------------------------------------------------

mutable struct WindowState
    ptr::Ptr{SDL_Window}
    renderer::Ptr{SDL_Renderer}
    id::UInt32
    width::Int
    height::Int
    # Drawing is event-driven: a window is redrawn after a render pass, when
    # the window manager exposes it, after a resize, or on hover/press
    # styling changes. `needs_layout` re-lays out the window without
    # re-running components (used after resizes).
    needs_draw::Bool
    needs_layout::Bool
end

mutable struct TextState
    content::String
    color::Tuple{UInt8,UInt8,UInt8,UInt8}
    size::Float64
    fontpath::String
    renderer::Ptr{SDL_Renderer}
    textures::Vector{Ptr{SDL_Texture}}
    linewidths::Vector{Float64}
    lineheights::Vector{Float64}
    advance::Float64 # baseline-to-baseline distance for multi-line text
end

mutable struct PressState
    hovered::Bool
    pressed::Bool
end

mutable struct ImageState
    texture::Ptr{SDL_Texture}
    w::Float64 # natural size of the loaded image
    h::Float64
    src::String
    renderer::Ptr{SDL_Renderer}
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
    rc = SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)
    rc == 0 || error("SDL_Init failed: $(unsafe_string(SDL_GetError()))")
    TTF_Init() == 0 || error("TTF_Init failed: $(unsafe_string(SDL_GetError()))")
    IMG_Init(Cint(IMG_INIT_PNG) | Cint(IMG_INIT_JPG)) # best effort; PNG/JPG cover common formats
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
        font != C_NULL && TTF_CloseFont(font)
    end
    empty!(FONT_CACHE)
    TTF_Quit()
    SDL_Quit()
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
        mx, my = Ref{Cint}(0), Ref{Cint}(0)
        SDL_GetMouseState(mx, my)
        return (Int(mx[]), Int(my[]))
    end

    bx, by, bw, bh = display_bounds(get(props, :display, nothing))
    (bw <= 0 || bh <= 0) && return (SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED)
    cascade = position === :cascade ? 32 * (length(WINDOW_BY_ID) % 8) : 0
    x = bx + max(0, bw - width) ÷ 2 + cascade
    y = by + max(0, bh - height) ÷ 2 + cascade
    return (x, y)
end

# Bounds (x, y, w, h) of a display: `nothing` selects the display the mouse
# pointer is on (falling back to display 0). Returns (0, 0, 0, 0) when the
# display cannot be queried (e.g. headless drivers).
function display_bounds(display)
    if display === nothing
        mx, my = Ref{Cint}(0), Ref{Cint}(0)
        SDL_GetMouseState(mx, my)
        index = SDL_GetPointDisplayIndex(Ref(SDL_Point(mx[], my[])))
        index = index < 0 ? 0 : index
    else
        index = Int(display)
    end
    bounds = Ref(SDL_Rect(0, 0, 0, 0))
    if SDL_GetDisplayBounds(index, bounds) == 0
        return (bounds[].x, bounds[].y, bounds[].w, bounds[].h)
    end
    mode = Ref(SDL_DisplayMode(0, 0, 0, 0, C_NULL))
    if SDL_GetDesktopDisplayMode(index, mode) == 0
        return (0, 0, mode[].w, mode[].h)
    end
    return (0, 0, 0, 0)
end

window_size(fiber) =
    (Int(get(fiber.props, :width, 800)), Int(get(fiber.props, :height, 600)))

function create_window!(fiber)
    title = string(get(fiber.props, :title, "Rocks"))
    width, height = window_size(fiber)
    resizable = Bool(get(fiber.props, :resizable, false))
    flags = UInt32(SDL_WINDOW_SHOWN)
    resizable && (flags |= UInt32(SDL_WINDOW_RESIZABLE))
    xpos, ypos = window_position(fiber)
    ptr = SDL_CreateWindow(title, xpos, ypos, width, height, flags)
    ptr == C_NULL && error("SDL_CreateWindow failed: $(unsafe_string(SDL_GetError()))")
    renderer = SDL_CreateRenderer(
        ptr,
        Cint(-1),
        UInt32(SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC),
    )
    if renderer == C_NULL # fall back to a software renderer
        renderer = SDL_CreateRenderer(ptr, Cint(-1), UInt32(SDL_RENDERER_SOFTWARE))
    end
    renderer == C_NULL && error("SDL_CreateRenderer failed: $(unsafe_string(SDL_GetError()))")
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND)
    state = WindowState(ptr, renderer, SDL_GetWindowID(ptr), width, height, true, false)
    fiber.host = state
    WINDOW_BY_ID[state.id] = fiber
    return state
end

function destroy_window!(fiber)
    fiber.host isa WindowState || return
    state = fiber.host
    delete!(WINDOW_BY_ID, state.id)
    SDL_DestroyRenderer(state.renderer)
    SDL_DestroyWindow(state.ptr)
    fiber.host = nothing
    return nothing
end

# Re-apply window props that the user may have changed between renders.
function sync_window!(fiber)
    fiber.host isa WindowState || return
    state = fiber.host
    title = string(get(fiber.props, :title, "Rocks"))
    resizable = Bool(get(fiber.props, :resizable, false))
    current = unsafe_string(SDL_GetWindowTitle(state.ptr))
    current != title && SDL_SetWindowTitle(state.ptr, title)
    want = resizable ? SDL_TRUE : SDL_FALSE
    (SDL_GetWindowFlags(state.ptr) & UInt32(SDL_WINDOW_RESIZABLE) != 0) != (want != 0) &&
        SDL_SetWindowResizable(state.ptr, want)
    return nothing
end

# ---- drawing helpers -----------------------------------------------------

function set_color(renderer, color)
    r, g, b, a = _to_rgba(color)
    SDL_SetRenderDrawColor(renderer, r, g, b, a)
    return nothing
end

function fill_rect(renderer, x, y, w, h)
    (w <= 0 || h <= 0) && return
    rect = SDL_Rect(round(Int, x), round(Int, y), round(Int, w), round(Int, h))
    SDL_RenderFillRect(renderer, Ref(rect))
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
    pts = Vector{SDL_FPoint}()
    sizehint!(pts, 4 * (n + 1))
    for (cx, cy, a0, cr) in (
        (x + w - r[2], y + r[2], -pi / 2, r[2]),   # top-right: up → right
        (x + w - r[3], y + h - r[3], 0.0, r[3]),   # bottom-right: right → down
        (x + r[4], y + h - r[4], pi / 2, r[4]),    # bottom-left: down → left
        (x + r[1], y + r[1], pi, r[1]),            # top-left: left → up
    )
        for i in 0:n
            a = a0 + (i / n) * (pi / 2)
            push!(pts, SDL_FPoint(cx + cr * cos(a), cy + cr * sin(a)))
        end
    end
    return pts
end

# One SDL_Color per vertex of a geometry batch, scaled by `coverage` (0..1).
geometry_color(color, coverage = 1.0) = begin
    r, g, b, a = _to_rgba(color)
    alpha = round(UInt8, clamp(coverage, 0.0, 1.0) * a)
    SDL_Color(r, g, b, alpha)
end

geometry_vertex(p, color) = SDL_Vertex(p, color, SDL_FPoint(0, 0))

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
        geometry_vertex(SDL_FPoint(x, y), tl),
        geometry_vertex(SDL_FPoint(x + w, y), tr),
        geometry_vertex(SDL_FPoint(x, y + h), bl),
        geometry_vertex(SDL_FPoint(x + w, y + h), br),
    ]
    indices = Cint[0, 1, 2, 2, 1, 3]
    SDL_RenderGeometry(renderer, C_NULL, vertices, length(vertices), indices, length(indices))
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
        (SDL_FPoint(x + w / 2, y), SDL_FPoint(x + w, y + h), SDL_FPoint(x, y + h))
    elseif Symbol(pointing) === :down
        (SDL_FPoint(x, y), SDL_FPoint(x + w, y), SDL_FPoint(x + w / 2, y + h))
    elseif Symbol(pointing) === :left
        (SDL_FPoint(x, y + h / 2), SDL_FPoint(x + w, y), SDL_FPoint(x + w, y + h))
    else
        (SDL_FPoint(x + w, y + h / 2), SDL_FPoint(x, y + h), SDL_FPoint(x, y))
    end
    vertices = [geometry_vertex(p, c) for p in points]
    indices = Cint[0, 1, 2]
    SDL_RenderGeometry(renderer, C_NULL, vertices, length(vertices), indices, length(indices))
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
    vertices = Vector{SDL_Vertex}(undef, 2m + 1)
    vertices[1] = geometry_vertex(
        SDL_FPoint(x + w / 2, y + h / 2), c)
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
    SDL_RenderGeometry(renderer, C_NULL, vertices, length(vertices), indices, length(indices))
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
    vertices = Vector{SDL_Vertex}(undef, 2m + 1)
    vertices[1] = geometry_vertex(
        SDL_FPoint(x + w / 2, y + h / 2), color_at(x + w / 2, y + h / 2))
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
    SDL_RenderGeometry(renderer, C_NULL, vertices, length(vertices), indices, length(indices))
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
    vertices = Vector{SDL_Vertex}(undef, 4m)
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
    SDL_RenderGeometry(renderer, C_NULL, vertices, length(vertices), indices, length(indices))
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
    textures = Ptr{SDL_Texture}[]
    linewidths = Float64[]
    lineheights = Float64[]
    scolor = SDL_Color(color...)
    for line in lines
        surface = TTF_RenderUTF8_Blended(font, String(line), scolor)
        if surface == C_NULL
            push!(textures, C_NULL)
            push!(linewidths, 0.0)
            push!(lineheights, 0.0)
            continue
        end
        texture = SDL_CreateTextureFromSurface(renderer, surface)
        SDL_FreeSurface(surface)
        w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
        SDL_QueryTexture(texture, C_NULL, C_NULL, w_ref, h_ref)
        push!(textures, texture)
        push!(linewidths, Float64(w_ref[]))
        push!(lineheights, Float64(h_ref[]))
    end
    advance = max(Float64(TTF_FontLineSkip(font)), maximum(lineheights; init = 0.0))
    fiber.host = TextState(content, color, size, fontpath, renderer, textures,
                           linewidths, lineheights, advance)
    return fiber.host
end

function free_text!(state::TextState)
    renderer = state.renderer
    for texture in state.textures
        texture != C_NULL && SDL_DestroyTexture(texture)
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
const IMAGE_SURFACES = Dict{String,Ptr{SDL_Surface}}()

# Resolve an `Image` `src` prop: local paths pass through; URLs are fetched
# with `Downloads` into a per-session cache directory. Returns `nothing` when
# the source cannot be resolved.
function resolve_image_src(src)
    isempty(src) && return nothing
    if startswith(src, "http://") || startswith(src, "https://")
        if IMAGE_CACHE_DIR[] === nothing
            IMAGE_CACHE_DIR[] = mkpath(joinpath(tempdir(), "rocks-images"))
        end
        name = string(hash(src), ".", lowercase(splitext(src)[2]))
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

# Loaded surface for an image source (cached). Returns C_NULL when the image
# cannot be loaded.
function image_surface(src::String)
    return get!(IMAGE_SURFACES, src) do
        path = resolve_image_src(src)
        path === nothing && return C_NULL
        surface = IMG_Load(path)
        surface == C_NULL && @warn "Rocks: could not load image" src path
        return surface
    end
end

function free_image!(state::ImageState)
    state.texture != C_NULL && SDL_DestroyTexture(state.texture)
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
        texture = SDL_CreateTextureFromSurface(renderer, surface)
        if texture == C_NULL
            @warn "Rocks: could not create texture for image" src
        else
            w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
            SDL_QueryTexture(texture, C_NULL, C_NULL, w_ref, h_ref)
            w, h = Float64(w_ref[]), Float64(h_ref[])
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
    dst = SDL_Rect(round(Int, x), round(Int, y), round(Int, w), round(Int, h))
    SDL_RenderCopy(renderer, state.texture, C_NULL, Ref(dst))
    return nothing
end

# ---- the draw pass -------------------------------------------------------

# Intersect an SDL clip rectangle with the previous one.
function clip_rect(a::SDL_Rect, b::SDL_Rect)
    x1, y1 = max(a.x, b.x), max(a.y, b.y)
    x2 = min(a.x + a.w, b.x + b.w)
    y2 = min(a.y + a.h, b.y + b.h)
    return SDL_Rect(x1, y1, max(x2 - x1, 0), max(y2 - y1, 0))
end

# Draw a scroll container's children clipped to its viewport (and to any
# outer clip, so nested scroll views compose correctly).
function draw_scrolled!(fiber, renderer)
    previous = Ref(SDL_Rect(0, 0, 0, 0))
    had_clip = SDL_RenderIsClipEnabled(renderer) != SDL_FALSE
    had_clip && SDL_RenderGetClipRect(renderer, previous)
    x, y, w, h = fiber.rect
    clip = SDL_Rect(round(Int, x), round(Int, y), round(Int, w), round(Int, h))
    had_clip && (clip = clip_rect(previous[], clip))
    if clip.w <= 0 || clip.h <= 0
        return nothing
    end
    SDL_RenderSetClipRect(renderer, Ref(clip))
    try
        for child in fiber.children
            draw!(child, renderer)
        end
    finally
        had_clip ? SDL_RenderSetClipRect(renderer, previous) :
                   SDL_RenderSetClipRect(renderer, C_NULL)
    end
    draw_scrollbar!(fiber, renderer)
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
            dst = SDL_Rect(round(Int, x), round(Int, y + (i-1) * state.advance),
                           round(Int, w), round(Int, h))
            SDL_RenderCopy(renderer, texture, C_NULL, Ref(dst))
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
    if fiber.kind === _BOX || fiber.kind === _PRESSABLE ||
       fiber.kind === _SCROLLVIEW
        draw_background!(fiber, renderer)
    end
    if is_scrollable(fiber)
        draw_scrolled!(fiber, renderer)
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
    SDL_RenderClear(renderer)
    for child in fiber.children
        draw!(child, renderer)
    end
    present && SDL_RenderPresent(renderer)
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
    w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
    SDL_GetWindowSize(state.ptr, w_ref, h_ref)
    w, h = max(Int(w_ref[]), 1), max(Int(h_ref[]), 1)
    # Redraw without presenting so the backbuffer holds the current frame,
    # read it, then present the redrawn frame.
    draw_window!(fiber, false)
    surface = SDL_CreateRGBSurfaceWithFormat(
        UInt32(0), Cint(w), Cint(h), Cint(32), UInt32(SDL_PIXELFORMAT_RGBA32),
    )
    surface == C_NULL &&
        error("SDL_CreateRGBSurfaceWithFormat failed: $(unsafe_string(SDL_GetError()))")
    s = unsafe_load(surface)
    rect = SDL_Rect(Cint(0), Cint(0), Cint(w), Cint(h))
    rc = SDL_RenderReadPixels(
        state.renderer, Ref(rect), UInt32(SDL_PIXELFORMAT_RGBA32), s.pixels, s.pitch,
    )
    ok = Cint(0)
    if rc == 0
        ok = IMG_SavePNG(surface, String(path))
    end
    SDL_FreeSurface(surface)
    SDL_RenderPresent(state.renderer)
    rc != 0 && error("SDL_RenderReadPixels failed: $(unsafe_string(SDL_GetError()))")
    ok != 0 && error("IMG_SavePNG failed: $(unsafe_string(SDL_GetError()))")
    return path
end
