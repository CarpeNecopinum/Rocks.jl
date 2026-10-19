# M3 progress: linear progress indicator.

"""
    Material3.LinearProgress(; value, width, stops)

A Material 3 linear progress indicator: a 4dp rounded track in
`surfaceContainerHighest` with the active portion in `primary` and a stop
indicator dot at the end. `value` is an `Observable` between 0 and 1.
"""
function LinearProgress(; value, width = 240, stops = true)
    t = theme()
    return Mechanics.Progress(; value = value, width = width, height = 4,
        track_color = t.surface_container_highest, active_color = t.primary,
        radius = 2, stop_color = stops ? t.primary : nothing)
end
