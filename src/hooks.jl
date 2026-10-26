# Hooks — the lifecycle API of components.
#
# Hooks may only be called from component functions during a render. State is
# stored per fiber (component instance) in call order, exactly like React
# stores hooks in a linked list per fiber. This means the number and order of
# hook calls must be the same on every render of a component (top level only,
# no conditional hooks).

"Fiber currently being rendered (see fiber.jl). Hooks read/write this."
const CURRENT_FIBER = Ref{Any}(nothing) # Union{Nothing,Fiber}

"Effects waiting to run after the current render has been committed."
const PENDING_EFFECTS = Any[] # Vector{Tuple{Fiber,EffectHook,Function}}

current_fiber() = CURRENT_FIBER[]

"""
    use_fiber() -> Fiber

The fiber of the component currently being rendered. Event callbacks and
effects close over it to look up placed geometry (rects, measured sizes) of
their output at event time, when the render spec is long gone.
"""
function use_fiber()
    fiber = CURRENT_FIBER[]
    fiber === nothing && error("use_fiber may only be called during a render")
    return fiber
end

# Reserve the next hook slot for the current fiber. Returns (hook, created).
function use_hook(mk)
    fiber = CURRENT_FIBER[]
    fiber === nothing && error(
        "Hook called outside of a component render. " *
        "Hooks must be called from component functions.",
    )
    fiber.hook_index += 1
    i = fiber.hook_index
    if i <= length(fiber.hooks)
        return fiber.hooks[i], false
    end
    hook = mk()
    push!(fiber.hooks, hook)
    return hook, true
end

# Compare effect/memo dependencies.
deps_equal(a, b) = a == b

mutable struct UseHook
    value::Any         # what the expression evaluated to (Ref/Observable/Context)
    subscription::Any  # current ObserverFunction, or nothing
    subscribed_to::Any # the Observable the subscription is on
    last::Any          # last seen observable value, for change deduplication
    is_context::Bool   # context hooks re-look-up their value on every render
end

# Subscribe a @use hook to an Observable; re-subscribes when the target
# changes (contexts can switch providers between renders).
function subscribe_observable!(hook, value)
    hook.subscribed_to === value && return
    hook.subscription !== nothing && off(hook.subscription)
    hook.subscribed_to = value
    hook.last = value[]
    fiber = CURRENT_FIBER[]
    hook.subscription = on(value) do new
        new === hook.last && return # identical values do not re-render
        hook.last = new
        mark_dirty!(fiber)
    end
    return nothing
end

"""
    @use expr

Evaluate `expr` on the first render of the component and return the result on
that and every subsequent render. `expr` must create a `Ref` or an
`Observable` (from Observables.jl, re-exported by Rocks).

If the result is an `Observable`, the component re-renders whenever the
observable is set — this replaces React-style `useState`:

```julia
function Counter()
    count = @use Observable(0)
    @rock Window(
        @rock Text("Count: ", count[]),
        @rock Pressable(
            @rock Text("Increment");
            on_press = () -> count[] += 1);
        title = "Counter")
end
```

`Ref`s are silent, replacing React-style `useRef`: mutating `ref[]` does not
re-render (call [`request_render`](@ref) to redraw manually).

Because the observable itself is returned, state can also be shared and
derived without extra libraries:

* `@use someGlobalObservable` — subscribe to a global observable.
* `@use observablePassedInAsProp` — subscribe to an observable owned by a
  parent component.
* `@use map(x -> x.sub, obs)` — derive a sub-state; the component only
  re-renders when the mapped value actually changes.
* `@use SomeContext` — the context receiver: the value provided by the
  nearest [`createContext`](@ref) provider above the component.

Like all hooks, `@use` must be called unconditionally at the top level of a
component (React rules apply). The expression is evaluated exactly once, on
the first render — later prop changes do not re-create the Ref/Observable.
"""
macro use(expr)
    return quote
        hook, _ = use_hook(() -> begin
            value = $(esc(expr))
            is_context = value isa Context
            h = UseHook(value, nothing, nothing, nothing, is_context)
            !is_context && value isa Observable && subscribe_observable!(h, value)
            h
        end)
        if hook.is_context
            # context: re-look-up the nearest provider value on every render
            fiber = CURRENT_FIBER[]
            value = fiber === nothing ? hook.value.default :
                    lookup_context(fiber, hook.value)
            value isa Observable && subscribe_observable!(hook, value)
            value
        else
            hook.value
        end
    end
end

mutable struct EffectHook
    deps::Any
    cleanup::Any
    run_pending::Bool
end

"""
    useEffect(f, deps = nothing)

Effect hook. `f` runs after the component's render has been committed. The
semantics of `deps` match React:

* `nothing` (default): `f` runs after *every* render.
* An empty collection `()` / `[]`: `f` runs once, when the component mounts.
* A non-empty collection: `f` re-runs whenever any entry differs (`==`)
  from the previous render's deps. Deps must not be mutated in place.

`f` may return a cleanup function, which runs before the next effect
execution and when the component unmounts.

```julia
useEffect(() -> println("mounted"), ())        # once on mount
useEffect(() -> println("count is ", count))   # every render
useEffect(() -> println("count changed"), (count,))
```
"""
function useEffect(f::Function, deps = nothing)
    hook, created = use_hook(() -> EffectHook(nothing, nothing, false))
    if created
        hook.deps = deps
        hook.run_pending = true
    else
        # `nothing` deps run on every render; a differing collection re-runs;
        # an equal collection (e.g. `()`) runs once on mount.
        if deps === nothing || hook.deps === nothing || !deps_equal(hook.deps, deps)
            hook.run_pending = true
        end
        hook.deps = deps
    end
    hook.run_pending && push!(PENDING_EFFECTS, (CURRENT_FIBER[], hook, f))
    return nothing
end

# Run all pending effects (after a render has been committed). Effects may
# request renders, but renders are deferred to the main loop, so effects
# cannot cascade synchronously.
function run_effects!()
    while !isempty(PENDING_EFFECTS)
        items = copy(PENDING_EFFECTS)
        empty!(PENDING_EFFECTS)
        for (fiber, hook, f) in items
            fiber.mounted || continue
            if hook.cleanup isa Function
                try
                    hook.cleanup()
                catch err
                    @warn "Rocks: effect cleanup failed" exception = (err, catch_backtrace())
                end
            end
            res = try
                f()
            catch err
                @warn "Rocks: effect failed" exception = (err, catch_backtrace())
                nothing
            end
            hook.cleanup = res isa Function ? res : nothing
            hook.run_pending = false
        end
    end
end

mutable struct MemoHook
    value::Any
    deps::Any
end

"""
    useMemo(f, deps)

Memoization hook. Calls `f()` only when `deps` differ (`==`) from the
previous render's deps and returns the cached value otherwise.
"""
function useMemo(f::Function, deps)
    hook, created = use_hook(() -> MemoHook(nothing, nothing))
    if created || hook.deps === nothing || !deps_equal(hook.deps, deps)
        hook.value = f()
        hook.deps = deps
    end
    return hook.value
end

"""
    useCallback(f, deps)

Convenience for `useMemo(() -> f, deps)`: returns `f` itself, but only
re-created when `deps` change.
"""
useCallback(f::Function, deps) = useMemo(() -> f, deps)

# ---- context -------------------------------------------------------------

"""
    createContext(default = nothing) -> context

Create a context: a `Provider` component and a value that components read
with `@use`. The nearest `provider` above a component in the fiber tree wins;
without any provider, `default` is used.

```julia
const Theme = createContext((dark = false,))

function App()
    theme = @use Observable((dark = true,))
    @rock Theme.provider(          # provide the value down the tree
        @rock Toolbar();
        value = theme)
end

function Toolbar()
    theme = @use Theme             # the receiver: nearest provided value
    @rock Text("dark mode: ", theme[].dark)
end
```

Provide an `Observable` as the `value` so consumers re-render when it
changes (setting it to an identical value does not re-render). The value may
also be a plain value; consumers then update whenever their subtree
re-renders. The provider renders its children unchanged.
"""
mutable struct Context
    default::Any
    provider::Any
end

function createContext(default = nothing)
    ctx = Context(default, nothing)
    provider = function (; value = default, children = Any[], kwargs...)
        use_provider_slot(ctx, value)
        return flat_children(children) # renders its children unchanged
    end
    ctx.provider = provider
    return ctx
end

mutable struct ProviderSlot
    ctx::Any
    value::Any
end

# Register the provided value on the current fiber (the Provider's fiber) so
# that `@use` lookups find it.
function use_provider_slot(ctx, value)
    hook, _ = use_hook(() -> ProviderSlot(ctx, value))
    hook.ctx = ctx
    hook.value = value
    return nothing
end

# Walk up the fiber tree to the nearest provider of `ctx` and return its
# value; falls back to the context default.
function lookup_context(fiber, ctx)
    f = fiber
    while f !== nothing
        for hook in f.hooks
            hook isa ProviderSlot && hook.ctx === ctx && return hook.value
        end
        f = f.parent
    end
    return ctx.default
end

# ---- timers -------------------------------------------------------------

mutable struct Timer
    f::Function
    interval::Union{Nothing,Float64} # seconds; `nothing` = one-shot
    due::UInt64                      # nanotime
    active::Bool
end

const TIMERS = Timer[]

add_timer(f::Function, ms::Real; repeating = false) = begin
    t = Timer(
        f,
        repeating ? Float64(ms) / 1000 : nothing,
        time_ns() + UInt64(ms * 1e6),
        true,
    )
    push!(TIMERS, t)
    t
end

cancel_timer(t::Timer) = (t.active = false; nothing)

# Fire all due timers. Called from the main loop; callbacks may set state.
function fire_timers!()
    due = Timer[t for t in TIMERS if t.active && t.due <= time_ns()]
    for t in due
        t.active || continue
        if t.interval === nothing
            t.active = false
        else
            t.due = time_ns() + UInt64(round(t.interval * 1e9))
        end
        try
            t.f()
        catch err
            @warn "Rocks: timer callback failed" exception = (err, catch_backtrace())
        end
    end
    filter!(t -> t.active, TIMERS)
    return nothing
end

"""
    useInterval(f, ms)

Calls `f()` every `ms` milliseconds while the component is mounted. The
interval is cancelled automatically on unmount.

```julia
now = @use Observable(Dates.now())
useInterval(() -> set_now(Dates.now()), 1000)
```
"""
function useInterval(f::Function, ms::Real)
    useEffect(() -> add_timer(f, ms; repeating = true), (ms,))
    return nothing
end

"""
    useTimeout(f, ms)

Calls `f()` once after `ms` milliseconds (if the component is still mounted).
"""
function useTimeout(f::Function, ms::Real)
    useEffect(() -> add_timer(f, ms; repeating = false), (ms,))
    return nothing
end
