# Material Design 3 components for Rocks.jl.
#
# A submodule themed through `ThemeContext` (a `createContext` holding a
# non-mutable `Theme`): apps provide a theme with
# `ThemeContext.provider(; value = Observable(Theme(...)))` and every
# component picks the theme up and re-renders when it changes.
#
# The interactive behavior lives in `Rocks.Mechanics` (vanilla, appearance
# prop-driven); this module fills in the Material Design: color roles from the
# theme, M3 shapes (corner radii), the type scale and state layers.

module Material3

using ..Rocks: @rock, @use, Observable, Element, props_dict, _PRESSABLE, _BOX,
    _SLIDER, flat_children, Row, Column, Box, Text, Pressable,
    Mechanics, _to_rgba, createContext, useTimeout

include("theme.jl")
include("common.jl")
include("actions.jl")
include("selection.jl")
include("communication.jl")
include("containment.jl")
include("navigation.jl")
include("textinput.jl")
include("progress.jl")

export Theme, light_theme, dark_theme, ThemeContext, ICONS, Icon,
    Button, FAB, IconButton, SegmentedButton,
    Checkbox, Switch, RadioGroup, Slider, Chip,
    Badge, Snackbar,
    Card, Dialog, Divider, List, ListItem, Tooltip,
    NavigationBar, NavigationRail, NavigationDrawer, Tabs, TopAppBar,
    TextField, LinearProgress

end # module Material3
