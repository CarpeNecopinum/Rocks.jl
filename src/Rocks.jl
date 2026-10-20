"""
    Rocks

A React-style GUI framework for Julia built on GTK4 (via
[Gtk4.jl](https://juliagtk.github.io/Gtk4.jl/dev/)).

Components are plain Julia functions — there is no separate component language.
The [`@rock`](@ref) macro plays the role of React's (usually JSX-hidden)
`createElement` call: children are passed as positional arguments of the
call, props as keyword arguments. Hook functions track the lifecycle of a
component between renders, and the [`@use`](@ref) macro creates state as a
`Ref` or `Observable`.

```julia
using Rocks

function Counter()
    count = @use Observable(0)
    @rock Window(
        @rock Label("Count: ", count; size = 28),
        @rock Button("Increment"; on_press = () -> count[] += 1);
        title = "Counter", width = 320, height = 200,
        padding = 20, gap = 16)
end

render(Counter)
```

Every host element kind maps onto a native GTK widget — [`Window`](@ref) is a
`GtkWindow`, [`Box`](@ref) a `GtkBox`, [`Label`](@ref) a `GtkLabel` and so on
— so GTK does the layout, hit-testing, rendering and theming. Windows are
components like everything else: rendering a tree with several `Window`
elements gives a multi-window application, and components can open dialogs by
conditionally rendering a `Window`.

Styling is done with GTK CSS (Rocks maps a few convenience props like
`background` and `color` onto it) and otherwise left to the user.
"""
module Rocks

using Gtk4
using Observables

include("element.jl")
include("hooks.jl")
include("fiber.jl")
include("backend.jl")
include("events.jl")
include("runtime.jl")
include("components.jl")
include("widgets.jl")

export @rock, @use, render, quit!, screenshot,
       Window, Box, Label, Button, Picture, Paned, Scale,
       CheckButton, Switch, ProgressBar, DropDown, Notebook, Entry,
       Row, Column, RadioGroup,
       createContext, Context,
       useEffect, useMemo, useCallback,
       useInterval, useTimeout

import Observables: Observable
export Observable

end # module
