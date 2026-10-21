# Windows 7 / Winforms design tokens.

default_colors() = (
    window = "#F0F0F0",
    control = "#F0F0F0",
    document = "#FFFFFF",
    text = "#000000",
    disabled_text = "#838383",
    border = "#8E8F8F",
    border_light = "#FFFFFF",
    border_dark = "#6F6F6F",
    focus = "#3C7FB1",
    selection = "#3399FF",
    selection_text = "#FFFFFF",
    hot = "#CBE8F6",
    hot_border = "#7DA2CE",
    menu = "#F0F0F0",
    status = "#F0F0F0",
    grid_line = "#E4E4E4",
    header = "#F5F5F5",
    input = "#FFFFFF",
    input_border = "#7A7A7A",
    button_text = "#000000",
    default_border = "#3C7FB1",
    disabled_bg = "#F0F0F0",
    selection_inactive = "#F0F0F0",
    tooltip = "#FFFFE1",
    scrollbar_track = "#F0F0F0",
    scrollbar_thumb_top = "#F7F7F7",
    scrollbar_thumb_bottom = "#CFCFCF",
    scrollbar_border = "#A0A0A0",
    tab_selected = "#FFFFFF",
    tab_unselected_text = "#1A1A1A",
    status_text = "#000000",
    progress_track = "#E0E0E0",
    progress_border = "#8A8A8A",
)

default_gradients() = (
    button = LinearGradient("#F5F5F5", "#DDDDDD"),
    button_hover = LinearGradient("#F8F8F8", "#E8E8E8"),
    button_pressed = LinearGradient("#D8D8D8", "#C4C4C4"),
    button_default = LinearGradient("#F5F9FF", "#DCE8F5"),
    button_default_hover = LinearGradient("#FAFCFF", "#E8F1FA"),
    button_default_pressed = LinearGradient("#DCE8F5", "#C8D8E8"),
    toolbar = LinearGradient("#F7F7F7", "#E7E7E7"),
    status = LinearGradient("#F5F5F5", "#E9E9E9"),
    tab = LinearGradient("#F2F2F2", "#E2E2E2"),
    tab_selected = LinearGradient("#FFFFFF", "#F7F7F7"),
    grid_header = LinearGradient("#FAFAFA", "#E8E8E8"),
    progress = LinearGradient("#C8F0B8", "#5FBF4A"),
    input_button = LinearGradient("#F7F7F7", "#DCDCDC"),
    slider_thumb = LinearGradient("#FCFCFC", "#D8D8D8"),
    scrollbar_thumb = LinearGradient("#F7F7F7", "#CFCFCF"),
)

default_metrics() = (
    button_height = 23,
    input_height = 23,
    control_radius = 3,
    border = 1,
    padding = 6,
    gap = 4,
    menu_height = 22,
    toolbar_height = 28,
    status_height = 22,
    tab_height = 24,
    row_height = 18,
    header_height = 21,
    scrollbar = 17,
    font_size = 12,
    title_size = 12,
)

"""
    Enterprise.Theme(; font, colors, gradients, metrics)

The immutable Windows 7 / Winforms design tokens used by every
`Rocks.Enterprise` component. `colors` and `metrics` are named tuples;
`gradients` holds [`LinearGradient`](@ref) fills for buttons, bars and
progress. Provide a theme through [`ThemeContext`](@ref).
"""
Base.@kwdef struct Theme
    font::Union{Nothing,String} = nothing
    colors::NamedTuple = default_colors()
    gradients::NamedTuple = default_gradients()
    metrics::NamedTuple = default_metrics()
end

"""
    Enterprise.light_theme() -> Theme

The baseline Windows 7 Aero-inspired light theme.
"""
light_theme() = Theme()

"""
    Enterprise.classic_theme() -> Theme

A flatter silver variant with barely visible gradients, for a Windows
Classic-style look.
"""
classic_theme() = Theme(
    gradients = merge(default_gradients(), (
        button = LinearGradient("#F0F0F0", "#E4E4E4"),
        button_hover = LinearGradient("#F8F8F8", "#EAEAEA"),
        button_pressed = LinearGradient("#DCDCDC", "#CFCFCF"),
        toolbar = LinearGradient("#F2F2F2", "#E8E8E8"),
        status = LinearGradient("#F2F2F2", "#E8E8E8"),
        tab = LinearGradient("#F0F0F0", "#E4E4E4"),
    )),
)

"""
    Enterprise.high_contrast_theme() -> Theme

A high-contrast light variant (black borders and text, white surfaces).
"""
high_contrast_theme() = Theme(
    colors = merge(default_colors(), (
        window = "#FFFFFF",
        control = "#FFFFFF",
        document = "#FFFFFF",
        text = "#000000",
        border = "#000000",
        border_light = "#FFFFFF",
        border_dark = "#000000",
        input_border = "#000000",
        disabled_text = "#404040",
        selection = "#000080",
        selection_text = "#FFFFFF",
        hot = "#D0D0D0",
        hot_border = "#000000",
        menu = "#FFFFFF",
        status = "#FFFFFF",
        tooltip = "#FFFFFF",
    )),
)

"""
    Enterprise.ThemeContext

Context providing the active [`Theme`](@ref). The nearest
`ThemeContext.provider` wins; without one, the baseline light theme is used.
Provide an `Observable{Theme}` to switch themes reactively.
"""
const ThemeContext = createContext(light_theme())

"""
    Enterprise.theme() -> Theme

Read the active theme of the calling component. Must be called during a
component render; it subscribes to the provided `Observable` when present.
"""
function theme()
    t = @use ThemeContext
    return t isa Observable ? t[] : t
end
