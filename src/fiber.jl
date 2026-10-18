# Fibers — persistent component instances — and the reconciler.
#
# A `Fiber` is one node of the live UI tree. It persists across renders so
# that hook state, backend resources and layout results survive re-renders.
# Reconciliation walks the new element tree produced by re-running component
# functions and updates matching fibers in place (by index, with kind and key
# compatibility checks, like React's simple reconciler without keyed
# reordering).

"""
A live node of the UI tree. One fiber persists per rendered element across
re-renders and holds hook state, layout results and backend resources. Not
usually touched directly.
"""
mutable struct Fiber
    kind::Any                      # HostKind singleton or component function
    key::Any
    props::Dict{Symbol,Any}        # includes :children => child elements
    parent::Union{Nothing,Fiber}
    children::Vector{Fiber}
    hooks::Vector{Any}             # hook state in call order
    hook_index::Int
    mounted::Bool
    hidden::Bool                   # window closed by the user without on_close
    # layout (see layout.jl); rect is in window-local coordinates
    measured::Tuple{Float64,Float64}
    rect::Tuple{Float64,Float64,Float64,Float64}
    # backend state: WindowState for windows, TextState for text,
    # PressState for pressables, nothing otherwise
    host::Any
end

function Fiber(kind, props, parent)
    return Fiber(
        kind,
        nothing,
        props,
        parent,
        Fiber[],
        Any[],
        0,
        true,
        false,
        (0.0, 0.0),
        (0.0, 0.0, 0.0, 0.0),
        initial_host(kind),
    )
end

initial_host(kind) = if kind === _PRESSABLE
    PressState(false, false)
elseif kind === _SPLIT
    SplitState(0.5, false, (0.0, 0.0, 0.0, 0.0), 0.5, 0.0)
elseif kind === _SLIDER
    SliderState((0.0, 0.0, 0.0, 0.0))
else
    nothing
end

is_window(f::Fiber) = f.kind === _WINDOW
is_text(f::Fiber) = f.kind === _TEXT

# Children of an element: positional children win; otherwise the `children`
# prop (keyword) is used, if any.
function element_children(el::Element)
    isempty(el.children) || return el.children
    props_children = get(el.props, :children, nothing)
    props_children === nothing && return Any[]
    props_children isa Union{Tuple,Vector} && return Any[props_children...]
    return Any[props_children]
end

# Create a fiber for an element and link it into the tree.
function create_fiber(el::Element, parent)
    if el.kind isa Element
        # `@rock(SomeComponent())` — the component was called, so the kind is
        # the Element it returned. Give a helpful hint.
        inner_kind = el.kind.kind
        hint = if inner_kind isa Function
            "Did you mean `@rock($(nameof(inner_kind)))` instead of " *
            "`@rock($(nameof(inner_kind))())`?"
        elseif inner_kind isa HostKind
            name = string(nameof(typeof(inner_kind)))
            startswith(name, "_") && (name = name[2:end])
            endswith(name, "Kind") && (name = name[1:end-4])
            "The element already describes a `$name` — did you call a component " *
            "inside `@rock`, e.g. `@rock(SecondWindow())` instead of " *
            "`@rock(SecondWindow)`?"
        else
            ""
        end
        error(
            "the kind of an element must be a host element kind or a component " *
            "function, but got an already-created Element. $hint",
        )
    end
    props = Dict{Symbol,Any}(el.props)
    key = get(props, :key, nothing)
    delete!(props, :key) # the key prop is consumed by the reconciler
    props[:children] = element_children(el)
    fiber = Fiber(el.kind, props, parent)
    fiber.key = key
    return fiber
end

# Render one fiber: components re-run and their output is reconciled; host
# elements reconcile their child elements. Text fibers hold raw content
# children (no child fibers).
function perform_render!(fiber)
    fiber.kind === _TEXT && return
    if is_host(fiber.kind)
        reconcile_children!(fiber, fiber.props[:children])
    else
        prev = CURRENT_FIBER[]
        CURRENT_FIBER[] = fiber
        fiber.hook_index = 0
        # Components receive their children via the `children` keyword
        # argument; it is only passed when non-empty so child-less components
        # need not declare it.
        kw = filter(p -> !(p.first === :children && isempty(p.second)), pairs(fiber.props))
        out = try
            fiber.kind(; kw...)
        finally
            CURRENT_FIBER[] = prev
        end
        reconcile_children!(fiber, to_elements(out))
    end
    return nothing
end

compatible(fiber::Fiber, el) =
    el isa Element && fiber.kind === el.kind && fiber.key == get(el.props, :key, nothing)

function update!(fiber, el::Element)
    props = Dict{Symbol,Any}(el.props)
    fiber.key = get(props, :key, nothing)
    delete!(props, :key)
    props[:children] = element_children(el)
    fiber.props = props
    perform_render!(fiber)
    return nothing
end

"""
    reconcile_children!(fiber, elements)

Reconcile `fiber.children` against a fresh list of elements: update matching
fibers in place, create missing ones, unmount removed ones.
"""
function reconcile_children!(fiber, elements_raw)
    # Normalize children: strings/values become text, `nothing`/`false` are
    # skipped, tuples/vectors of elements (e.g. from nested `@rock` calls in
    # one invocation) are flattened. Only Elements become fibers.
    elements = push_children!(Any[], elements_raw)
    old = fiber.children
    n = length(elements)
    for i in (n+1):length(old)
        unmount!(old[i])
    end
    resize!(old, min(length(old), n))
    for i in 1:n
        el = elements[i]
        prev = i <= length(old) ? old[i] : nothing
        # An unmounted fiber (e.g. a window closed by the user) must be
        # replaced by a fresh one — it cannot be revived in place.
        if prev !== nothing && prev.mounted && compatible(prev, el)
            update!(prev, el)
        else
            i <= length(old) && unmount!(old[i])
            child = create_fiber(el, fiber)
            if i <= length(old)
                old[i] = child
            else
                push!(old, child)
            end
            perform_render!(child)
        end
    end
    return nothing
end

"""
    unmount!(fiber)

Unmount a fiber: recursively unmount children, run effect cleanups in reverse
hook order and release backend resources.
"""
function unmount!(fiber)
    fiber.mounted || return
    fiber.mounted = false
    for child in fiber.children
        unmount!(child)
    end
    empty!(fiber.children)
    for hook in reverse(fiber.hooks)
        if hook isa EffectHook && hook.cleanup isa Function
            try
                hook.cleanup()
            catch err
                @warn "Rocks: unmount cleanup failed" exception = (err, catch_backtrace())
            end
        elseif hook isa UseHook && hook.subscription !== nothing
            off(hook.subscription)
        end
    end
    empty!(fiber.hooks)
    if is_window(fiber)
        destroy_window!(fiber)
    end
    return nothing
end

# Collect every window fiber in the subtree, including windows nested in
# other windows' subtrees (they are hoisted into their own OS window).
function collect_windows!(out, fiber)
    is_window(fiber) && push!(out, fiber)
    for child in fiber.children
        collect_windows!(out, child)
    end
    return out
end
