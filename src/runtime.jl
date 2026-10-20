# The runtime: the entry point that ties reconciliation, GTK widgets, timers
# and the GLib main loop together, plus `quit!`.
#
# With GTK, the GLib main loop owns the event delivery: Rocks' state changes
# mark the tree dirty, an idle callback re-renders and re-syncs the widgets,
# and Rocks' timers (useInterval/useTimeout) are fired from a low-frequency
# GLib timeout tick. Bounded `frames` runs (tests) skip the loop and pump the
# GLib main context directly.

const DIRTY = Ref(true)
const RUNNING = Ref(false)
const DONE = Condition()
const RENDER_QUEUED = Ref(false)
const ROOT_FIBER = Ref{Any}(nothing) # Union{Nothing,Fiber}
const TICK_ID = Ref{Int}(-1)

"""
    request_render()

Mark the application dirty so the main loop re-renders the tree on the next
idle pass. Called by state setters; rarely needed manually (e.g. after
mutating a ref).
"""
function request_render()
    DIRTY[] = true
    if !RENDER_QUEUED[] && RUNNING[] && Gtk4.GLib.is_loop_running()
        RENDER_QUEUED[] = true
        Gtk4.g_idle_add() do
            RENDER_QUEUED[] = false
            process_dirty!()
            return false
        end
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
    notify(DONE)
    return nothing
end

# One render pass: fire due timers, then re-render and re-sync the widgets
# when the tree is dirty. Runs on the GLib loop task in interactive mode and
# on the caller's task in bounded frames mode.
function process_dirty!()
    fire_timers!()
    DIRTY[] || return
    DIRTY[] = false
    root = ROOT_FIBER[]
    root === nothing && return
    perform_render!(root)
    run_effects!()
    sync_backend!(root)
    return nothing
end

# A repeating tick that fires Rocks' timers while the GLib loop idles.
function install_tick!()
    TICK_ID[] >= 0 && return
    TICK_ID[] = Gtk4.g_timeout_add(function ()
        fire_timers!()
        return true # repeat
    end, 16)
    return nothing
end

function uninstall_tick!()
    TICK_ID[] >= 0 || return
    Gtk4.GLib.g_source_remove(TICK_ID[])
    TICK_ID[] = -1
    return nothing
end

"""
    pump(n = 1)

Process pending GLib events `n` times without blocking. Used by bounded
`frames` runs to realize, map and lay out windows (and to drive tests) with
the main loop not running.
"""
function pump(n::Integer = 1)
    for _ in 1:n
        ccall((:g_main_context_iteration, Gtk4.GLib.libglib), Cint,
              (Ptr{Cvoid}, Cint), C_NULL, 0)
    end
    return nothing
end

# Create the root fiber for `render`. `kw` is the keyword arguments as a
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

Run the application until all its windows are closed (or [`quit!`](@ref) is
called). `app` is either

* a component function, called with the remaining `kwargs` as props on every
  re-render — the recommended form, since it re-runs on state updates:

  ```julia
  function App()
      ...
  end

  render(App)
  render() do
      @rock Window(@rock Label("Hello"))
  end
  ```

* or an element created with [`@rock`](@ref) (rendered as-is; components
  inside it still re-run on state updates):

  ```julia
  render(@rock Window(@rock Label("Hello")))
  ```

The GLib main loop delivers input events and repaints; Rocks re-renders the
fiber tree (component functions re-run, fibers are reconciled, props are
re-applied to the widgets) whenever application state changes. Idle
applications neither re-render nor burn CPU.

Two keyword arguments control the runtime itself instead of being passed as
props: `frames = N` runs the loop for `N` bounded, synchronous iterations
(realizing and laying out windows through the GLib main context, without the
background loop task) and then returns — and `screenshot = path` captures the
first window into a PNG right before the application shuts down. Together
they are how tests run against a real display:

```julia
render(App; frames = 3, screenshot = "app.png")
```

Note: like `ReactDOM.render`, `Rocks.run` is available as a qualified alias
if you prefer React's naming (`using Rocks` makes plain `run` ambiguous with
`Base.run`).
"""
function render(app; kwargs...)
    RUNNING[] && error("Rocks.render is already running")
    RUNNING[] = true
    DIRTY[] = true
    RENDER_QUEUED[] = false
    init_backend()
    kw = values(kwargs)
    frames = get(kw, :frames, nothing)
    shot = get(kw, :screenshot, nothing)
    kw = Base.structdiff(kw, (frames = nothing, screenshot = nothing))
    root = create_root(app, kw)
    ROOT_FIBER[] = root
    root.mounted = true
    started_loop = false
    try
        perform_render!(root)
        run_effects!()
        sync_backend!(root)
        if frames isa Integer
            # Bounded, synchronous runs: realize, map and lay out the windows
            # by pumping the GLib main context, then dispatch and render.
            wait_windows_mapped!(root)
            for _ in 1:frames
                RUNNING[] || break
                pump(10)
                process_dirty!()
            end
        else
            install_tick!()
            Gtk4.GLib.start_main_loop(true)
            started_loop = true
            while RUNNING[]
                wait(DONE)
            end
        end
        # Capture before the windows are torn down.
        shot !== nothing && screenshot(root, String(shot))
    finally
        started_loop && Gtk4.GLib.stop_main_loop(true)
        uninstall_tick!()
        unmount!(root)
        RUNNING[] = false
        ROOT_FIBER[] = nothing
        RENDER_QUEUED[] = false
        empty!(TIMERS)
        empty!(PENDING_EFFECTS)
        CURRENT_FIBER[] = nothing
    end
    return nothing
end

# Qualified alias for React nostalgia: `Rocks.run(App)`.
const run = render
