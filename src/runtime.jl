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
            if DIRTY[]
                DIRTY[] = false
                # Rendering (component functions, reconciliation, effects,
                # layout) only happens when the application is dirty.
                perform_render!(root)
                run_effects!()
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
