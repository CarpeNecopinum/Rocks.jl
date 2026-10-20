# Convenience components built on top of the native GTK widget kinds. These
# are plain Julia functions like every component in Rocks. The widget kinds
# themselves ([`CheckButton`](@ref), [`Switch`](@ref), [`ProgressBar`](@ref),
# [`DropDown`](@ref), [`Notebook`](@ref), [`Entry`](@ref)) are used directly
# with `@rock`.

"""
    RadioGroup(; options, selected, on_change = () -> nothing,
                direction = :column, disabled = false)

Group of radio buttons, one per entry of `options::Vector{String}` (or the
options given as positional children). `selected` is an `Observable{Int}`
holding the 1-based index of the active option; clicking a button writes it
and calls `on_change()`.

```julia
@rock RadioGroup(["Small", "Medium", "Large"]; selected = size)
```
"""
function RadioGroup(; selected, on_change = () -> nothing,
                    direction = :column, disabled = false, options = nothing,
                    children = Any[])
    selected isa Observable ||
        error("RadioGroup needs an `Observable` as its `selected` prop")
    # the options are either the `options` prop or the call's children
    opts = String[string(o) for o in flat_children(options !== nothing ? options : children)]
    isempty(opts) &&
        error("RadioGroup needs options (positional children or the `options` prop)")
    items = Any[
        @rock CheckButton(;
            label = option,
            checked = selected[] == i,
            on_change = () -> (selected[] = i; on_change()),
            disabled = disabled,
        ) for (i, option) in enumerate(opts)
    ]
    return Element(_BOX, props_dict(:direction => Symbol(direction), :gap => 6), items)
end
