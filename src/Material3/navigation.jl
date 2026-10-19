# M3 navigation: navigation bar/rail/drawer, tabs, top app bar.

# The shared M3 destination look: an active-indicator pill behind the icon of
# the selected destination (secondaryContainer) with a label below.
function destination(t, label, icon, i, selected, on_change, disabled, icon_size,
                     label_size)
    active = selected[] == i
    icon_color = active ? t.on_secondary_container : t.on_surface_variant
    label_color = active ? t.on_secondary_container : t.on_surface_variant
    indicator = active ? (@rock Box(
        @rock Icon(icon; size = icon_size, color = icon_color);
        width = 64, height = 32, radius = t.shapes.full,
        background = t.secondary_container,
        direction = :row, align = :center)) : (@rock Box(
        @rock Icon(icon; size = icon_size, color = icon_color);
        width = 64, height = 32, radius = t.shapes.full,
        direction = :row, align = :center))
    return @rock Pressable(
        indicator,
        (@rock Text(label; size = label_size, color = label_color));
        on_press = () -> begin
            selected[] = i
            on_change()
        end,
        disabled = disabled,
        direction = :column, align = :center, gap = 4, padding = 4)
end

"""
    Material3.NavigationBar(; destinations, selected, on_change, disabled)

A Material 3 navigation bar: an 80dp `surfaceContainer` bar at the bottom with
one destination per `(label, icon)` pair of `destinations::Vector{Tuple}`.
`selected` is an `Observable{Int}`; the active destination gets the
secondary-container indicator pill.

```julia
@rock Material3.NavigationBar(
    destinations = [("Home", "home"), ("Profile", "person")];
    selected = tab)
```
"""
function NavigationBar(; destinations, selected, on_change = () -> nothing,
                       disabled = false)
    selected = @use selected # subscribe so selection changes re-render
    t = theme()
    items = Element[]
    for (i, (label, icon)) in enumerate(destinations)
        push!(items, destination(t, label, icon, i, selected, on_change,
                                 disabled, 24, t.typescale.label_medium))
    end
    return Element(
        _BOX,
        props_dict(
            :direction => :row, :align => :center, :gap => 8,
            :height => 80, :padding => 12,
            :fill => true, :background => t.surface_container,
        ),
        items,
    )
end

"""
    Material3.NavigationRail(; destinations, selected, on_change, disabled)

A Material 3 navigation rail: the vertical variant of the navigation bar, an
80dp `surfaceContainer` column.
"""
function NavigationRail(; destinations, selected, on_change = () -> nothing,
                        disabled = false)
    selected = @use selected # subscribe so selection changes re-render
    t = theme()
    items = Element[]
    for (i, (label, icon)) in enumerate(destinations)
        push!(items, destination(t, label, icon, i, selected, on_change,
                                 disabled, 24, t.typescale.label_medium))
    end
    return Element(
        _BOX,
        props_dict(
            :direction => :column, :align => :center, :gap => 8,
            :width => 80, :padding => 12,
            :background => t.surface_container,
        ),
        items,
    )
end

"""
    Material3.NavigationDrawer(items...; selected, on_change, width, disabled)

A Material 3 (permanent) navigation drawer: a 360dp `surfaceContainerLow`
column of drawer items. `items` are `(label, icon)` pairs (or plain label
strings); the active item gets the secondary-container indicator pill.
"""
function NavigationDrawer(; selected, on_change = () -> nothing,
                          width = 360, disabled = false, children = Any[])
    selected = @use selected # subscribe so selection changes re-render
    t = theme()
    entries = Element[]
    for (i, item) in enumerate(flat_children(children))
        label, icon = item isa Tuple ? item : (string(item), nothing)
        active = selected[] == i
        icon_color = active ? t.on_secondary_container : t.on_surface_variant
        label_color = active ? t.on_secondary_container : t.on_surface_variant
        leading = icon === nothing ? nothing :
                  (@rock Box(
                      @rock Icon(icon; size = 24, color = icon_color);
                      width = 24, height = 24, direction = :row, align = :center))
        pill = @rock Pressable(
            @rock Row(
                leading,
                (@rock Text(label; size = t.typescale.label_large,
                            color = label_color));
                gap = 12, align = :center);
            on_press = () -> begin
                selected[] = i
                on_change()
            end,
            disabled = disabled,
            height = 56, radius = t.shapes.full, padding = 16,
            background = active ? t.secondary_container : nothing,
            hover_background = disabled ? nothing :
                              (overlay(t.on_surface, 0.08)),
            align = :center)
        push!(entries, pill)
    end
    return Element(
        _BOX,
        props_dict(
            :direction => :column, :gap => 4, :padding => 12,
            :width => width, :background => t.surface_container_low,
        ),
        entries,
    )
end

"""
    Material3.Tabs(children...; tabs, selected, on_change, disabled)

Material 3 (primary) tabs: a row of tab labels on `surface` with the active
tab in `primary` and a rounded indicator pill below it. One entry of
`tabs::Vector{String}` per element in `children` (only the selected child is
rendered).
"""
function Tabs(; selected, on_change = () -> nothing, disabled = false,
              tabs = nothing, children = Any[])
    selected = @use selected # subscribe so tab changes re-render
    t = theme()
    # String children are the tab labels; element children are the per-tab
    # content panels. `tabs` may also be given explicitly.
    if tabs === nothing
        str_kids = String[string(c) for c in children if c isa AbstractString]
        isempty(str_kids) || (tabs = str_kids)
        children = Any[c for c in children if !isa(c, AbstractString)]
    end
    tabs === nothing && error("Material3.Tabs needs `tabs` (a Vector{String})")
    tabbar = Element[]
    for (i, tab) in enumerate(tabs)
        active = selected[] == i
        color = active ? t.primary : t.on_surface_variant
        tab_item = @rock Pressable(
            @rock Column(
                @rock Text(string(tab); size = t.typescale.title_small,
                           color = color),
                (@rock Box(;
                    width = 64, height = 3, radius = t.shapes.full,
                    background = active ? t.primary : nothing));
                direction = :column, align = :center, gap = 6, padding = 0);
            on_press = () -> begin
                selected[] = i
                on_change()
            end,
            disabled = disabled,
            padding = 12, align = :center)
        push!(tabbar, tab_item)
    end
    kids = flat_children(children)
    content = length(kids) >= selected[] && selected[] >= 1 ? kids[selected[]] : nothing
    return Element(
        _BOX,
        props_dict(:direction => :column, :gap => 12, :padding => 0),
        Any[
            (@rock Box(tabbar...; direction = :row, gap = 4,
                       height = 64, background = t.surface,
                       border_color = t.surface_container_highest,
                       border_width = 1)),
            content,
        ],
    )
end

"""
    Material3.TopAppBar(title; leading, actions)

A Material 3 (small) top app bar: a 64dp `surface` bar with a
`titleLarge`-sized title, optional `leading` icon and `actions` row.
"""
function TopAppBar(; title = "", leading = nothing, actions = nothing,
                   height = 64, children = Any[])
    isempty(children) || (title = string(flat_children(children)[1]))
    t = theme()
    leading_kid = leading === nothing ? nothing :
                  (@rock Box(
                      @rock Icon(leading; size = 24, color = t.on_surface_variant);
                      width = 24, height = 24, direction = :row, align = :center))
    action_row = actions === nothing ? nothing :
                 (@rock Row(flat_children(actions)...; gap = 4, align = :center))
    return Element(
        _BOX,
        props_dict(
            :direction => :row, :align => :center, :gap => 12,
            :height => height, :padding => 16,
            :fill => true, :background => t.surface,
        ),
        Any[
            leading_kid,
            (@rock Text(title; size = t.typescale.title_large,
                        color = t.on_surface)),
            action_row,
        ],
    )
end
