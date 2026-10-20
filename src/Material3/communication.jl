# M3 communication: badge, snackbar.

# ---- Badge ----------------------------------------------------------------

"""
    Material3.Badge(count; dot, child)

A Material 3 badge. With a `count` it renders as a 16dp pill with the number
(large badge), without one as a 6dp dot (small badge), both in `error` color.
Pass `child` (an element such as an icon) to place the badge on top of it.

```julia
@rock Material3.Badge(3; child = (@rock Material3.Icon("mail"; size = 24)))
```
"""
function Badge(; count = nothing, dot = false, child = nothing, children = Any[])
    isempty(children) || (count = flat_children(children)[1])
    t = theme()
    show_dot = dot || count === nothing || count == 0
    if show_dot
        marker = @rock Box(;
            width = 6, height = 6, radius = 3,
            background = t.error)
    else
        marker = @rock Box(
            @rock Text(string(count); size = t.typescale.label_small,
                       color = t.on_error);
            height = 16, radius = 8,
            padding_x = 4, padding_y = 0, background = t.error,
            direction = :row, align = :center, justify = :center)
    end
    child === nothing && return marker
    return @rock Box(
        child,
        (@rock Box(;
            position = :absolute, align = :top_right, x = -4, y = -4,
            children = Any[marker]));
        direction = :row, align = :start)
end

# ---- Snackbar -------------------------------------------------------------

"""
    Material3.Snackbar(text; action, on_action, on_dismiss, duration, width)

A Material 3 snackbar: an `inverseSurface` bar with `inverseOnSurface` text
and an optional action button in `inversePrimary`. The snackbar dismisses
itself after `duration` ms (default 4000) by calling `on_dismiss()`.
"""
function Snackbar(text; action = "", on_action = () -> nothing,
                  on_dismiss = () -> nothing, duration = 4000, width = 320)
    t = theme()
    useTimeout(on_dismiss, duration)
    action_kid = action == "" ? nothing :
                 (@rock Pressable(
                     @rock Text(action; size = t.typescale.label_large,
                                color = t.inverse_primary);
                     on_press = () -> begin
                         on_action()
                         on_dismiss()
                     end,
                     padding = 12, align = :center))
    return @rock Box(
        @rock Row(
            @rock Text(text; size = t.typescale.body_medium,
                       color = t.inverse_on_surface),
            action_kid;
            gap = 8, align = :center);
        width = width, height = 48, radius = t.shapes.extra_small,
        padding = 16, background = t.inverse_surface,
        direction = :row, align = :center)
end
