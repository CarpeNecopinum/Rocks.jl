# Windows 7 / Winforms-style components for Rocks.jl.
#
# `Enterprise` is a second themed component library alongside
# `Rocks.Material3`. It uses the same mechanics and theme-context pattern, but
# with silver gradients, sunken bevels, compact metrics and classic desktop
# controls.

module Enterprise

using ..Rocks: @rock, @use, Observable, Element, props_dict, _PRESSABLE, _BOX,
    _SLIDER, _SCROLLVIEW, _SPLIT, _WINDOW, flat_children, Row, Column, Box,
    Text, Pressable, ScrollView, Mechanics, createContext, has_focus, unfocus!,
    LinearGradient, default_font, load_font, TTF_SizeUTF8

include("theme.jl")
include("common.jl")
include("controls.jl")
include("bars.jl")
include("data.jl")
include("dialogs.jl")

export Theme, light_theme, classic_theme, high_contrast_theme, ThemeContext,
    ICONS, Icon,
    Button, Label, LinkLabel, TextBox, CheckBox, RadioButton, GroupBox, Panel,
    ProgressBar, Slider, SplitContainer,
    MenuItem, Menu, MenuSeparator, MenuBar, ContextMenu,
    ToolBar, ToolButton, ToolSeparator, ToolGrip,
    StatusBar, StatusPanel, ToolTip,
    TabControl, ListView, GridView, ComboBox,
    MessageBox, Form

end # module Enterprise
