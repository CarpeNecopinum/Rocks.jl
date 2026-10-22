"""
    Rocks

A React(Native)-style GUI framework for Julia built on SDL3
(via [SDL3.jl](https://github.com/CarpeNecopinum/SDL3.jl)).

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
        @rock Text("Count: ", count; size = 28),
        @rock Pressable(
            @rock Text("Increment");
            on_press = () -> count[] += 1);
        title = "Counter", width = 320, height = 200,
        padding = 20, gap = 16)
end

render(Counter)
```

Windows are components like everything else: rendering a tree with several
`Window` elements gives a multi-window application, and components can open
dialogs by conditionally rendering a `Window`.

Styling is deliberately left to the user (React-Native style). Rocks only
provides the primitives: [`Window`](@ref), [`Box`](@ref), [`Text`](@ref) and
[`Pressable`](@ref).
"""
module Rocks

import SDL3
using ColorTypes
using Observables

include("element.jl")
include("hooks.jl")
include("fiber.jl")
include("backend.jl")
include("layout.jl")
include("events.jl")
include("runtime.jl")
include("components.jl")
include("widgets.jl")
include("mechanics.jl")
include(joinpath("Material3", "Material3.jl"))
include(joinpath("Enterprise", "Enterprise.jl"))

export @rock, @use, render, quit!, screenshot,
       Window, Box, Text, Pressable, Row, Column, ScrollView,
       Image, Split, Slider, LinearGradient,
       Button, Checkbox, Toggle, RadioGroup, DropDownMenu, Tabber, ProgressBar,
       createContext, Context,
       useEffect, useMemo, useCallback, use_fiber,
       useInterval, useTimeout,
       set_default_font!, load_font,
       Mechanics

import Observables: Observable
export Observable

end # module
