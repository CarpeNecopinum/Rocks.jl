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
    w <= 0 || h <= 0 || return
    rect = SDL_Rect(round(Int, x), round(Int, y), round(Int, w), round(Int, h))
    SDL_RenderFillRect(renderer, Ref(rect))
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

function draw_background!(fiber, renderer)
    props = fiber.props
    background = background_for(fiber)
    background !== nothing && (set_color(renderer, background); fill_rect(
        renderer, fiber.rect[1], fiber.rect[2], fiber.rect[3], fiber.rect[4]))
    border_color = get(props, :border_color, nothing)
    border_width = float(get(props, :border_width, 0))
    if border_width > 0 && border_color !== nothing
        set_color(renderer, border_color)
        x, y, w, h = fiber.rect
        draw_rect_stroke(renderer, x, y, w, h, border_width)
    end
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
    scolor = SDL_Color(color...)
    for line in lines
        surface = TTF_RenderUTF8_Blended(font, String(line), scolor)
        if surface == C_NULL
            push!(textures, C_NULL)
            push!(linewidths, 0.0)
            continue
        end
        texture = SDL_CreateTextureFromSurface(renderer, surface)
        SDL_FreeSurface(surface)
        w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
        SDL_QueryTexture(texture, C_NULL, C_NULL, w_ref, h_ref)
        push!(textures, texture)
        push!(linewidths, Float64(w_ref[]))
    end
    fiber.host = TextState(content, color, size, fontpath, renderer, textures, linewidths)
    return fiber.host
end

function free_text!(state::TextState)
    renderer = state.renderer
    for texture in state.textures
        texture != C_NULL && SDL_DestroyTexture(texture)
    end
    empty!(state.textures)
    empty!(state.linewidths)
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
        font = load_font(state.fontpath, max(round(Int, state.size), 1))
        lineheight = Float64(TTF_FontHeight(font))
        for (i, texture) in enumerate(state.textures)
            texture == C_NULL && continue
            w = state.linewidths[i]
            dst = SDL_Rect(round(Int, x), round(Int, y + (i-1) * lineheight),
                           round(Int, w), round(Int, lineheight))
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
    if fiber.kind === _BOX || fiber.kind === _PRESSABLE
        draw_background!(fiber, renderer)
    end
    for child in fiber.children
        draw!(child, renderer)
    end
    if fiber.kind === _SPLIT
        draw_split_handle!(fiber, renderer)
    end
    return nothing
end

# The draggable handle of a Split, drawn after its panes.
function draw_split_handle!(fiber, renderer)
    state = fiber.host
    state isa SplitState || return
    hx, hy, hw, hh = state.handle_rect
    set_color(renderer, get(fiber.props, :handle_color, (0.35, 0.35, 0.40)))
    fill_rect(renderer, hx, hy, hw, hh)
    return nothing
end

# The track, filled portion and knob of a Slider.
function draw_slider!(fiber, renderer)
    value = get(fiber.props, :value, nothing)
    value isa Observable || return
    x, y, w, h = fiber.rect
    lo = float(get(fiber.props, :min, 0))
    hi = float(get(fiber.props, :max, 1))
    frac = clamp((value[] - lo) / max(hi - lo, eps()), 0.0, 1.0)
    track_h = 4.0
    knob = 12.0
    accent = get(ACCENTS, Symbol(get(fiber.props, :color, :primary)), ACCENTS[:primary])
    set_color(renderer, (0.28, 0.28, 0.32))
    fill_rect(renderer, x, y + (h - track_h) / 2, w, track_h)
    set_color(renderer, accent)
    fill_rect(renderer, x, y + (h - track_h) / 2, w * frac, track_h)
    fill_rect(renderer, x + (w - knob) * frac, y + (h - knob) / 2, knob, knob)
    return nothing
end

const DEFAULT_WINDOW_BACKGROUND = (0.12, 0.12, 0.14)

"""
    draw_window!(fiber)

Clear the OS window of a window fiber with its background and draw its
children, then present.
"""
function draw_window!(fiber)
    state = fiber.host
    state isa WindowState || return
    renderer = state.renderer
    set_color(renderer, get(fiber.props, :background, DEFAULT_WINDOW_BACKGROUND))
    SDL_RenderClear(renderer)
    for child in fiber.children
        draw!(child, renderer)
    end
    SDL_RenderPresent(renderer)
    return nothing
end
