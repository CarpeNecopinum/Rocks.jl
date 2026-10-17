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
      @rock(Window, @rock(Text, "Hello"))
  end
  ```

* or an element created with [`@rock`](@ref) (rendered as-is; components
  inside it still re-run on state updates):

  ```julia
  render(@rock(Window, @rock(Text, "Hello")))
  ```

The render loop: poll and dispatch SDL events → fire due timers → if dirty,
re-render the tree (component functions re-run, fibers are reconciled), run
pending effects and lay out — then draw every window every frame. Drawing is
decoupled from rendering, so window damage (occlusion, off-screen movement)
is redrawn immediately without waiting for a state update.

Note: like `ReactDOM.render`. `Rocks.run` is available as a qualified alias
if you prefer React's naming (`using Rocks` makes plain `run` ambiguous with
`Base.run`).
"""
function render(app; kwargs...)
    RUNNING[] && error("Rocks.render is already running")
    RUNNING[] = true
    DIRTY[] = true
    init_backend()
    root = create_root(app, values(kwargs))
    root.mounted = true
    try
        perform_render!(root)
        run_effects!()
        event = Ref{SDL_Event}()
        windows = Fiber[]
        while RUNNING[]
            if SDL_WaitEventTimeout(event, 16) == 1
                dispatch_event!(event[])
                while SDL_PollEvent(event) == 1
                    dispatch_event!(event[])
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
                for w in windows
                    measure!(w)
                    place!(w, 0.0, 0.0)
                end
            end
            # Drawing is decoupled from rendering: every frame is presented,
            # so damage from window occlusion or off-screen movement is
            # redrawn immediately, not just on the next state update.
            for w in windows
                w.hidden || draw_window!(w)
            end
        end
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
