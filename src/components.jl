# Convenience components. These are plain Julia functions — every component
# in Rocks is just a function — returning Box elements with a direction set.

"""
    Row(; children = [], kwargs...)

Component that lays its children out horizontally. Equivalent to a
[`Box`](@ref) with `direction = :row`.

```julia
@rock(Row, @rock(Text, "left "), @rock(Text, "right"); gap = 8)
```
"""
function Row(; children = Any[], kwargs...)
    props = props_dict(; kwargs...)
    get!(props, :direction, :row)
    return Element(_BOX, props, children)
end

"""
    Column(; children = [], kwargs...)

Component that lays its children out vertically. Equivalent to a
[`Box`](@ref) with `direction = :column` (the default).

```julia
@rock(Column, @rock(Text, "top"), @rock(Text, "bottom"); gap = 12)
```
"""
function Column(; children = Any[], kwargs...)
    props = props_dict(; kwargs...)
    get!(props, :direction, :column)
    return Element(_BOX, props, children)
end
