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

mutable struct StateHook
    value::Any
    setter::Any
end

"""
    useState(initial) -> (value, set_value)

State hook. Returns the current value and a setter. The setter accepts either
a new value or an updater function `value -> new_value`. Setting an identical
value (`===`) does not trigger a re-render.

```julia
count, set_count = useState(0)
set_count(1)
set_count(c -> c + 1)
```
"""
function useState(initial = nothing)
    hook, _ = use_hook(() -> begin
        s = StateHook(initial, nothing)
        s.setter = v -> begin
            new = v isa Function ? v(s.value) : v
            new === s.value && return nothing
            s.value = new
            request_render()
        end
        s
    end)
    return hook.value, hook.setter
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

mutable struct RefHook
    current::Any
end

"""
    useRef(initial = nothing) -> ref

Ref hook. Returns a mutable box with a `current` field that persists across
renders. Mutating `ref.current` does not trigger a re-render — refs are for
values that must survive re-renders without being rendered (counters, cached
handles, previous values, ...).
"""
function useRef(initial = nothing)
    hook, _ = use_hook(() -> RefHook(initial))
    return hook
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
now, set_now = useState(Dates.now())
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
