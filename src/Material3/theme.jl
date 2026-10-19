# The Material Design 3 theme: color roles, type scale and shape scale.

"""
    Material3.Theme(; ...)

The Material Design 3 theme: color roles as hex strings (the M3 color system),
a `typescale::NamedTuple` of point sizes per M3 type role and a `shapes::NamedTuple`
of corner radii. `Theme` is immutable — a theme change creates a new instance,
provided to components through [`ThemeContext`](@ref):

```julia
const dark = Observable(Material3.dark_theme())
function App()
    @rock Material3.ThemeContext.provider(
        @rock MyScreen();
        value = dark)
end
```

Components read the active theme with `Material3.theme()` and re-render
whenever the provided value changes.
"""
Base.@kwdef struct Theme
    primary::String = "#6750A4"
    on_primary::String = "#FFFFFF"
    primary_container::String = "#EADDFF"
    on_primary_container::String = "#21005D"
    secondary::String = "#625B71"
    on_secondary::String = "#FFFFFF"
    secondary_container::String = "#E8DEF8"
    on_secondary_container::String = "#1D192B"
    tertiary::String = "#7D5260"
    on_tertiary::String = "#FFFFFF"
    tertiary_container::String = "#FFD8E4"
    on_tertiary_container::String = "#31111D"
    error::String = "#B3261E"
    on_error::String = "#FFFFFF"
    error_container::String = "#F9DEDC"
    on_error_container::String = "#410E0B"
    surface::String = "#FEF7FF"
    on_surface::String = "#1D1B20"
    surface_variant::String = "#E7E0EC"
    on_surface_variant::String = "#49454F"
    surface_container_lowest::String = "#FFFFFF"
    surface_container_low::String = "#F7F2FA"
    surface_container::String = "#F3EDF7"
    surface_container_high::String = "#ECE6F0"
    surface_container_highest::String = "#E6E0E9"
    surface_dim::String = "#DED8E1"
    surface_bright::String = "#FEF7FF"
    outline::String = "#79747E"
    outline_variant::String = "#CAC4D0"
    inverse_surface::String = "#322F35"
    inverse_on_surface::String = "#F5EFF7"
    inverse_primary::String = "#D0BCFF"
    shadow::String = "#000000"
    scrim::String = "#000000"
    typescale::NamedTuple = (
        display_large = 57, display_medium = 45, display_small = 36,
        headline_large = 32, headline_medium = 28, headline_small = 24,
        title_large = 22, title_medium = 16, title_small = 14,
        body_large = 16, body_medium = 14, body_small = 12,
        label_large = 14, label_medium = 12, label_small = 11)
    shapes::NamedTuple = (
        none = 0, extra_small = 4, small = 8, medium = 12,
        large = 16, extra_large = 28, full = 1000)
end

"""
    Material3.light_theme() -> Theme

The Material Design 3 baseline light color scheme.
"""
light_theme() = Theme()

"""
    Material3.dark_theme() -> Theme

The Material Design 3 baseline dark color scheme.
"""
dark_theme() = Theme(
    primary = "#D0BCFF",
    on_primary = "#381E72",
    primary_container = "#4F378B",
    on_primary_container = "#EADDFF",
    secondary = "#CCC2DC",
    on_secondary = "#332D41",
    secondary_container = "#4A4458",
    on_secondary_container = "#E8DEF8",
    tertiary = "#EFB8C8",
    on_tertiary = "#492532",
    tertiary_container = "#633B48",
    on_tertiary_container = "#FFD8E4",
    error = "#F2B8B5",
    on_error = "#601410",
    error_container = "#8C1D18",
    on_error_container = "#F9DEDC",
    surface = "#141218",
    on_surface = "#E6E0E9",
    surface_variant = "#49454F",
    on_surface_variant = "#CAC4D0",
    surface_container_lowest = "#0F0D13",
    surface_container_low = "#1D1B20",
    surface_container = "#211F26",
    surface_container_high = "#2B2930",
    surface_container_highest = "#36343B",
    surface_dim = "#141218",
    surface_bright = "#3B383E",
    outline = "#938F99",
    outline_variant = "#49454F",
    inverse_surface = "#E6E0E9",
    inverse_on_surface = "#332D41",
    inverse_primary = "#6750A4",
    shadow = "#000000",
    scrim = "#000000")

"""
    Material3.ThemeContext

The context providing the active [`Theme`](@ref) to every Material3
component. Components read it with `Material3.theme()`; the nearest
`ThemeContext.provider` above them wins and the default is the baseline light
theme. Provide an `Observable{Theme}` as the `value` to make theme switches
re-render the whole tree.
"""
const ThemeContext = createContext(light_theme())

"""
    Material3.theme() -> Theme

The active theme of the calling component: the value provided by the nearest
`ThemeContext.provider`, the baseline light theme otherwise. Must be called
during a component's render (it subscribes, so theme changes re-render).
"""
function theme()
    t = @use ThemeContext
    return t isa Observable ? t[] : t
end
