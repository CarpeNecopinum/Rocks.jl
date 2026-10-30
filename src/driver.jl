# Synthetic input and tree inspection for headless tests and diagnostics.
#
# Everything here drives the *real* pipeline: the `push_*` helpers build SDL
# events (window-local coordinates, exactly as SDL delivers them) that enter
# `dispatch_event!` as if the pending event loop had delivered them, with no
# code path shortcuts. On top of that, tree queries let tests and probes
# address rendered elements (`find_kind`, `find_by_key`, `find_by_label`),
# and `click!` presses one — so interaction tests can go "click through the
# UI" instead of hand-walking fiber trees and computing pixels.
#
# Coordinate note: `fiber.rect` values are laid out **window-absolutely**
# (`place!` positions children at parent coordinates + padding), so a
# fiber's own rect already encodes its position inside the owning window;
# a click needs no coordinate translation along the ancestor chain.

"Build an SDL event by storing the typed payload into the event union."
function push_event!(::Type{P}, type::Integer, payload::P) where {P}
    event = SDL3.SDL_Event(type = type)
    GC.@preserve event begin
        unsafe_store!(Ptr{P}(pointer_from_objref(event)), payload)
    end
    @assert SDL3.PushEvent(event)
    return event
end

"The window fiber that owns `fiber` (the fiber itself if it is a window)."
function window_of(fiber)
    window = fiber
    while !is_window(window)
        window = window.parent
    end
    return window
end

function push_mouse!(fiber, type, x, y; button = 1, clicks = 1)
    window = window_of(fiber)
    push_event!(SDL3.SDL_MouseButtonEvent, type,
                SDL3.SDL_MouseButtonEvent(
                    Int32(type), UInt32(0), UInt64(0),
                    UInt32(window.host.id), UInt32(0),
                    UInt8(button), true, UInt8(clicks), UInt8(0),
                    Float32(x), Float32(y),
                ))
    return nothing
end

function push_motion!(fiber, x, y)
    window = window_of(fiber)
    push_event!(SDL3.SDL_MouseMotionEvent, SDL3.SDL_EVENT_MOUSE_MOTION,
                SDL3.SDL_MouseMotionEvent(
                    Int32(SDL3.SDL_EVENT_MOUSE_MOTION), UInt32(0), UInt64(0),
                    UInt32(window.host.id), UInt32(0),
                    UInt32(0x0001), # left button held
                    Float32(x), Float32(y), Float32(0), Float32(0),
                ))
    return nothing
end

function push_wheel!(fiber, x, y; dx = 0, dy = -1)
    window = window_of(fiber)
    # Wheel events have no coordinates; real gestures follow mouse motion.
    LAST_POINTER[window.host.id] = (Float64(x), Float64(y))
    push_event!(SDL3.SDL_MouseWheelEvent, SDL3.SDL_EVENT_MOUSE_WHEEL,
                SDL3.SDL_MouseWheelEvent(
                    Int32(SDL3.SDL_EVENT_MOUSE_WHEEL), UInt32(0), UInt64(0),
                    UInt32(window.host.id), UInt32(0),
                    Float32(dx), Float32(dy), Int32(0),
                    Float32(0), Float32(0), Int32(dx), Int32(dy),
                ))
    return nothing
end

function push_window_event!(fiber, wev; data1 = 0, data2 = 0)
    push_event!(SDL3.SDL_WindowEvent, wev,
                SDL3.SDL_WindowEvent(
                    Int32(wev), UInt32(0), UInt64(0),
                    UInt32(fiber.host.id), Int32(data1), Int32(data2),
                ))
    return nothing
end

"A key event (down or up) carrying `key` and the SDL modifier bits."
function push_key!(fiber, key; type = SDL3.SDL_EVENT_KEY_DOWN, mod = UInt16(0))
    push_event!(SDL3.SDL_KeyboardEvent, type,
                SDL3.SDL_KeyboardEvent(
                    Int32(type), UInt32(0), UInt64(0),
                    UInt32(fiber.host.id), UInt32(0), Int32(0),
                    UInt32(key), mod, UInt16(0),
                    type == SDL3.SDL_EVENT_KEY_DOWN, false,
                ))
    return nothing
end

"Pump the SDL event queue into `dispatch_event!` (headless driving)."
drain_events!() = begin
    for ev in SDL3.PollEvents()
        dispatch_event!(ev)
    end
end

# ---- tree addressing ------------------------------------------------------

"Fiber walk: `fiber` itself and all descendants, depth-first."
function fibers(fiber)
    out = Fiber[]
    sizehint!(out, 64)
    stack = [fiber]
    while !isempty(stack)
        f = pop!(stack)
        push!(out, f)
        for c in Iterators.reverse(f.children)
            push!(stack, c)
        end
    end
    return out
end

"The first fiber (depth-first) matching the predicate, or `nothing`."
function find_fiber(pred, fiber)
    pred(fiber) && return fiber
    for c in fiber.children
        found = find_fiber(pred, c)
        found !== nothing && return found
    end
    return nothing
end

"All fibers matching the predicate, depth-first order."
function find_fibers(pred, fiber)
    return filter(pred, fibers(fiber))
end

"The first fiber whose `kind` is exactly `kind` (e.g. `Rocks._BoxKind`, your
own component function), or `nothing`."
find_kind(fiber, kind) = find_fiber(f -> f.kind === kind, fiber)

# All fibers whose `kind` is exactly `kind`, depth-first order.
collect_kind(fiber, kind) = find_fibers(f -> f.kind === kind, fiber)

"The first fiber with the given `key` (a reconciliation key), or `nothing`."
find_by_key(fiber, key) = find_fiber(f -> f.key == key, fiber)

"""
    find_by_label(fiber, text; exact = true)

The first `Text` fiber whose content matches `text` (substring match unless
`exact`), or `nothing`. Content is read with the same rules the renderer
uses (`text_content`), so labels of buttons, menu items and headings are
addressed by the text they actually render.
"""
function find_by_label(fiber, text::AbstractString; exact = true)
    matches(s) = exact ? s == text : occursin(text, s)
    return find_fiber(fiber) do f
        is_text(f) || return false
        return try
            matches(text_content(f))
        catch
            false
        end
    end
end

# All `Text` fibers matching, depth-first order (`find_by_label` plural).
function collect_by_label(fiber, text::AbstractString; exact = true)
    matches(s) = exact ? s == text : occursin(text, s)
    return find_fibers(fiber) do f
        is_text(f) || return false
        return try
            matches(text_content(f))
        catch
            false
        end
    end
end

"The center of `fiber` in window-local coordinates (what mouse events carry)."
fiber_center(fiber) = (
    round(Int, fiber.rect[1] + fiber.rect[3] / 2),
    round(Int, fiber.rect[2] + fiber.rect[4] / 2),
)

# Historic shorter name for `fiber_center`.
const center_of = fiber_center

"""
    click!(fiber; clicks = 1, button = 1, at = nothing)

Synthesize a full press-and-release on `fiber` at its center (or at a point
`at = (x, y)` inside the fiber, in the fiber's own rect space), through the
real event pipeline. `clicks >= 2` produces a double click (`clicks` is the
consecutive-click count SDL reports on both the down and up event). The
caller drives the queue: in `with_tree`-style tests call `drain_events!`
afterwards; inside `render(...)` the runtime loop picks the events up on
its own.

Returns `(x, y)`, the window-local point the click landed at.
"""
function click!(fiber; clicks = 1, button = 1, at = nothing)
    if at === nothing
        x, y = fiber_center(fiber)
    else
        # `at` is the point in fiber-rect space; rects are window-absolute.
        x = round(Int, fiber.rect[1] + at[1])
        y = round(Int, fiber.rect[2] + at[2])
    end
    push_mouse!(fiber, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, x, y;
                button = button, clicks = clicks)
    push_mouse!(fiber, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, x, y;
                button = button, clicks = clicks)
    return (x, y)
end

# ---- driving a rendered tree outside the runtime loop ----------------------

"""
    with_tree(f, app; kwargs...)

Render `app` (a component function) into a fiber tree with the dummy
backend, run mount effects, call `f(root)`, and tear everything down
afterwards. Tests and probes then address the tree with `sync_windows!`,
the `find_*` queries and `click!`.
"""
function with_tree(f, app; kwargs...)
    RUNNING[] = true
    DIRTY[] = true
    init_backend()
    root = create_root(app, values(kwargs))
    root.mounted = true
    perform_render!(root)
    run_effects!()
    try
        f(root)
    finally
        RUNNING[] = false
        unmount!(root)
        shutdown_backend()
    end
end

"""
    sync_windows!(root) -> Vector{Fiber}

Create OS windows for all window fibers of `root` and measure/place them —
the work one dirty frame of the runtime loop does, available outside the
loop for tests and probes. Also closes OS windows whose fibers left the
tree (`destroy_window!`), mirroring the loop.
"""
function sync_windows!(root)
    windows = collect_windows!(Fiber[], root)
    for w in windows
        w.host isa WindowState || create_window!(w)
        sync_window!(w)
        measure!(w)
        place!(w, 0.0, 0.0)
    end
    # Mirror the runtime loop: close OS windows whose fibers left the tree.
    for (_, f) in collect(pairs(WINDOW_BY_ID))
        f in windows || destroy_window!(f)
    end
    return windows
end
