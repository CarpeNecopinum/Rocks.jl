# The runtime: the main loop that ties events, state updates, rendering and
# timers together, plus the `run` entry point and `quit!`.

const DIRTY = Ref(true)
const RUNNING = Ref(false)

"""
    request_render()

Mark the application dirty so the main loop re-renders and redraws it on the
next frame. Called by state setters; rarely needed manually (e.g. after
mutating a ref).
"""
request_render() = (DIRTY[] = true; nothing)

# ---- targeted re-renders --------------------------------------------------
#
# Changing an Observable re-renders only the fiber(s) that subscribed to it
# (React-style: the component that "uses" the state, plus its subtree) — not
# the whole application. `request_render()` remains the global escape hatch.

const DIRTY_FIBERS = Fiber[]

"Mark a fiber's subtree for a re-render. `nothing` falls back to the global
`request_render()` (used when subscribing outside a component render)."
function mark_dirty!(fiber)
    if fiber === nothing
        request_render()
        return nothing
    end
    fiber.mounted || return nothing
    fiber in DIRTY_FIBERS || push!(DIRTY_FIBERS, fiber)
    return nothing
end

"Whether `fiber` lies inside one of `flushed`' subtrees (or is one of them)."
function _in_subtree_of_any(fiber, flushed)
    for a in flushed
        f = fiber
        while f !== nothing
            f === a && return true
            f = f.parent
        end
    end
    return false
end

"""
    flush_dirty!() -> Nothing

Re-render the subtrees of the fibers whose state changed, until the values
settle. A re-render may dirty further fibers (a body writing another
observable); those are processed in the same pass.
"""
function flush_dirty!()
    flushed = Fiber[]
    while !isempty(DIRTY_FIBERS)
        fiber = popfirst!(DIRTY_FIBERS)
        fiber.mounted || continue
        # An ancestor flushed in this pass already re-rendered this subtree.
        _in_subtree_of_any(fiber, flushed) && continue
        perform_render!(fiber)
        push!(flushed, fiber)
        # Walk up to the window: the redraw follows the re-render.
        f = fiber
        while f !== nothing && !(f.host isa WindowState)
            f = f.parent
        end
        if f !== nothing
            (f.host::WindowState).needs_draw = true
        end
    end
    return nothing
end

"""
    request_redraw() -> Nothing

Mark every live window for a **draw-only** redraw: the `Canvas` draw
callbacks re-issue their primitives, but no component function re-runs.
Used by animated canvases (e.g. marching dashes) where only the pixels
change between frames.
"""
function request_redraw()
    for (_, fiber) in WINDOW_BY_ID
        fiber.host isa WindowState && (fiber.host.needs_draw = true)
    end
    return nothing
end

"""
    quit!()

Close all windows and make [`render`](@ref) return. Use it to implement a quit
button.
"""
function quit!()
    RUNNING[] = false
    request_render()
    return nothing
end

# Create the root fiber for `run`. `kw` is the keyword arguments as a
# NamedTuple.
function create_root(target::Function, kw::NamedTuple)
    props = props_dict(; kw...)
    props[:children] = Any[]
    return Fiber(target, props, nothing)
end

function create_root(target::Element, kw::NamedTuple)
    isempty(kw) || error("render(::Element) does not accept keyword arguments")
    props = Dict{Symbol,Any}(target.props)
    props[:children] = element_children(target)
    return Fiber(target.kind, props, nothing)
end

# Milliseconds to block waiting for the next event: bounded by the time until
# the next due timer (so timers stay accurate) and capped, so the loop keeps
# progressing even if a platform never delivers events.
function event_wait_timeout_ms()
    timeout = 250
    for timer in TIMERS
        timer.active || continue
        delta = Int(timer.due) - Int(time_ns())
        delta <= 0 && return 0
        timeout = min(timeout, Int(ceil(delta / 1e6)))
    end
    return timeout
end

"""
    render(app; kwargs...)

Run the application until all windows are closed (or [`quit!`](@ref) is
called). `app` is either

* a component function, called with `kwargs` as props on every re-render —
  this is the recommended form, since it re-runs on state updates:

  ```julia
  function App()
      ...
  end

  render(App)
  render() do
      @rock Window(@rock Text("Hello"))
  end
  ```

* or an element created with [`@rock`](@ref) (rendered as-is; components
  inside it still re-run on state updates):

  ```julia
  render(@rock Window(@rock Text("Hello")))
  ```

The render loop: block until an event arrives or a timer is due → dispatch
events, fire due timers → if dirty, re-render the tree (component functions
re-run, fibers are reconciled), run pending effects and lay out → redraw the
windows that need it: after a render pass, when the window manager exposed
them (covered, restored), after a resize, or on hover/press styling changes.
An idle application neither redraws nor burns CPU.

Two keyword arguments control the runtime itself instead of being passed as
props: `frames = N` stops the loop after `N` frames (each frame blocks for
up to ~250ms waiting for events), and `screenshot = path` captures the first
window into a PNG file right before the application shuts down. Together
they enable fully headless runs — no window is ever shown, but
[`screenshot`](@ref) still captures real pixels (with
`SDL_VIDEO_DRIVER=dummy`):

```julia
render(App; frames = 3, screenshot = "app.png")
```

Note: like `ReactDOM.render`. `Rocks.run` is available as a qualified alias
if you prefer React's naming (`using Rocks` makes plain `run` ambiguous with
`Base.run`).
"""
function render(app; kwargs...)
    RUNNING[] && error("Rocks.render is already running")
    RUNNING[] = true
    DIRTY[] = true
    init_backend()
    kw = values(kwargs)
    frames = get(kw, :frames, nothing)
    shot = get(kw, :screenshot, nothing)
    kw = Base.structdiff(kw, (frames = nothing, screenshot = nothing))
    root = create_root(app, kw)
    root.mounted = true
    try
        perform_render!(root)
        run_effects!()
        windows = Fiber[]
        frame = 0
        while RUNNING[]
            # Block until the next event or until the next timer is due, so
            # an idle application neither redraws nor burns CPU.
            event = SDL3.WaitEventTimeout(event_wait_timeout_ms())
            if event !== nothing
                dispatch_event!(event)
                for more in SDL3.PollEvents()
                    dispatch_event!(more)
                end
            end
            fire_timers!()
            if DIRTY[] || !isempty(DIRTY_FIBERS) || !isempty(PENDING_EFFECTS)
                global_requested = DIRTY[]
                DIRTY[] = false
                # The global request re-renders the whole tree; a state change
                # re-renders only the subscribing fibers' subtrees.
                global_requested && (perform_render!(root); empty!(DIRTY_FIBERS))
                flush_dirty!()
                run_effects!()
                flush_dirty!()   # effects may write state
                run_effects!()
                flush_dirty!()
                empty!(windows)
                collect_windows!(windows, root)
                for w in windows
                    w.host isa WindowState || create_window!(w)
                    sync_window!(w)
                end
                # Close OS windows whose fibers left the tree this render pass
                # (e.g. a dialog component returned `nothing` after being
                # dismissed).
                for (_, f) in collect(pairs(WINDOW_BY_ID))
                    f in windows || destroy_window!(f)
                end
                for w in windows
                    measure!(w)
                    place!(w, 0.0, 0.0)
                end
                for w in windows
                    w.host isa WindowState && (w.host.needs_draw = true)
                end
            end
            # Resized windows are re-laid out without re-running components.
            for w in windows
                state = w.host
                state isa WindowState || continue
                state.needs_layout || continue
                state.needs_layout = false
                measure!(w)
                place!(w, 0.0, 0.0)
            end
            # Drawing is event-driven: redraw only the windows that need it —
            # after a render pass, when the window manager exposed them
            # (uncovered, restored), after a resize, or on hover/press styling
            # changes.
            for w in windows
                state = w.host
                state isa WindowState || continue
                state.needs_draw || continue
                state.needs_draw = false
                w.hidden || draw_window!(w)
            end
            frame += 1
            frames isa Integer && frame >= frames && (RUNNING[] = false)
        end
        # Semi-headless runs: capture before the windows are torn down.
        shot !== nothing && screenshot(root, String(shot))
    finally
        unmount!(root)
        RUNNING[] = false
        shutdown_backend()
        empty!(TIMERS)
        empty!(PENDING_EFFECTS)
        CURRENT_FIBER[] = nothing
    end
    return nothing
end

# Qualified alias for React nostalgia: `Rocks.run(App)`.
const run = render
