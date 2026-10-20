# Material Design 3 showcase: every Rocks.Material3 component, themed through
# ThemeContext with a live light/dark switch.
#
#   julia --project examples/material3.jl
#   SDL_VIDEODRIVER=dummy julia --project examples/material3.jl   # headless
#
# The theme is an `Observable{Theme}` provided through ThemeContext.provider —
# toggling the switch replaces the Theme instance and every component
# re-renders with the new palette. The content lives in a full-window
# ScrollView; the top app bar stays pinned and switches to the M3 on-scroll
# surfaceContainer fill once content moves behind it.

using Rocks
import Rocks: Text, Window, Box, Row, Column, ScrollView
import Rocks.Material3
const M3 = Rocks.Material3

theme_obs = Observable(M3.light_theme())
sel = Observable(2)
checked = Observable(true)
switch_on = Observable(false)
text = Observable("Ada")
progress = Observable(0.6)
radio = Observable(1)
multi = Observable(Int[1])
confirm = Observable(false)
snack = Observable(false)
scrolled = Observable(false)

function Section(title, kids...)
    @rock Column(
        (@rock Text(title; size = 12, color = M3.theme().on_surface_variant)),
        kids...;
        gap = 8)
end

function App()
    t = theme_obs[] # App sits outside its own provider: read the theme directly
    appbar_actions = @rock M3.IconButton("settings"; variant = :standard)
    cancel_btn = @rock M3.Button("Cancel"; on_press = () -> confirm[] = false)
    delete_btn = @rock M3.Button("Delete"; variant = :tonal;
        on_press = () -> confirm[] = false)
    @rock M3.ThemeContext.provider(
        @rock Window(
            @rock ScrollView(
                @rock Column(
                    (@rock Box(; height = 48)),
                    Section("Theme",
                        @rock M3.Row(
                            @rock Text("Dark theme"; color = t.on_surface),
                            @rock M3.Switch(on = switch_on;
                                on_change = () -> theme_obs[] =
                                    switch_on[] ? M3.dark_theme() : M3.light_theme());
                            gap = 12, align = :center)),
                    Section("Buttons",
                        @rock M3.Row(
                            @rock M3.Button("Filled"),
                            @rock M3.Button("Tonal"; variant = :tonal),
                            @rock M3.Button("Elevated"; variant = :elevated),
                            @rock M3.Button("Outlined"; variant = :outlined),
                            @rock M3.Button("Text"; variant = :text),
                            @rock M3.Button("Disabled"; disabled = true);
                            gap = 10, align = :center)),
                    Section("Floating action buttons",
                        @rock M3.Row(
                            @rock M3.FAB(),
                            @rock M3.FAB(; size = :small),
                            @rock M3.FAB(; variant = :tertiary),
                            @rock M3.FAB(; label = "Extended");
                            gap = 12, align = :center)),
                    Section("Icon buttons",
                        @rock M3.Row(
                            @rock M3.IconButton("favorite"; variant = :standard),
                            @rock M3.IconButton("favorite"; variant = :filled),
                            @rock M3.IconButton("favorite"; variant = :tonal),
                            @rock M3.IconButton("favorite"; variant = :outlined);
                            gap = 12, align = :center)),
                    Section("Selection",
                        @rock M3.Row(
                            @rock M3.Checkbox(checked = checked, label = "Check"),
                            @rock M3.Checkbox(checked = checked, label = "Off", disabled = true),
                            @rock M3.Switch(on = switch_on),
                            @rock M3.Switch(on = switch_on, disabled = true);
                            gap = 16, align = :center),
                        @rock M3.Row(
                            @rock M3.RadioGroup(["One", "Two", "Three"]; selected = radio),
                            @rock M3.SegmentedButton(["Day", "Week", "Month"]; selection = sel),
                            @rock M3.SegmentedButton(["A", "B", "C"]; selection = multi, multiple = true);
                            gap = 20, align = :center)),
                    Section("Chips",
                        @rock M3.Row(
                            @rock M3.Chip("Assist"; kind = :assist, icon = "settings"),
                            @rock M3.Chip("Filter"; kind = :filter, selected = checked),
                            @rock M3.Chip("Input"; kind = :input, icon = "close"),
                            @rock M3.Chip("Suggestion"; kind = :suggestion);
                            gap = 8, align = :center)),
                    Section("Slider and progress",
                        @rock M3.Slider(value = progress),
                        @rock M3.LinearProgress(value = progress)),
                    Section("Text fields",
                        @rock M3.TextField(text = text, label = "Name", placeholder = "Ada"),
                        @rock M3.TextField(text = text, label = "Email", variant = :outlined)),
                    Section("Cards",
                        @rock M3.Row(
                            @rock M3.Card(
                                @rock Text("Elevated"; size = 15, color = t.on_surface),
                                @rock Text("Body text"; size = 13, color = t.on_surface_variant);
                                variant = :elevated),
                            @rock M3.Card(
                                @rock Text("Filled"; size = 15, color = t.on_surface),
                                @rock Text("Body text"; size = 13, color = t.on_surface_variant);
                                variant = :filled),
                            @rock M3.Card(
                                @rock Text("Outlined"; size = 15, color = t.on_surface),
                                @rock Text("Body text"; size = 13, color = t.on_surface_variant);
                                variant = :outlined),
                            @rock M3.Badge(3; child = (@rock M3.Icon("mail"; size = 28)));
                            gap = 16, align = :center)),
                    Section("List",
                        @rock M3.List(
                            @rock M3.ListItem("First item"; leading = "mail"),
                            @rock M3.ListItem("Second item"; supporting = "with supporting text",
                                trailing = (@rock M3.IconButton("more"; variant = :standard))))),
                    Section("Tabs and navigation",
                        @rock M3.Tabs(["Overview", "Details", "Settings"]; selected = sel),
                        @rock M3.NavigationBar(
                            destinations = [("Home", "home"), ("Favorite", "favorite"),
                                            ("Profile", "person")];
                            selected = radio)),
                    Section("Overlays",
                        @rock M3.Row(
                            @rock M3.Button("Dialog"; variant = :tonal;
                                on_press = () -> confirm[] = true),
                            @rock M3.Button("Snackbar"; variant = :tonal;
                                on_press = () -> snack[] = true);
                            gap = 10, align = :center),
                        snack[] && (@rock Box(;
                            position = :absolute, align = :bottom, y = 24,
                            children = Any[@rock M3.Snackbar("Archived";
                                action = "Undo",
                                on_action = () -> nothing,
                                on_dismiss = () -> snack[] = false)])),
                        @rock M3.Dialog(
                            @rock Text("Delete this item?"; size = 16, color = t.on_surface);
                            open = confirm, actions = (cancel_btn, delete_btn)));
                    gap = 16, fill = true);
                position = :absolute, fill = true, padding = 16,
                background = t.surface,
                on_scroll = offset -> scrolled[] = offset > 0),
            @rock M3.TopAppBar("Material 3"; leading = "menu",
                actions = appbar_actions, scrolled = scrolled, height = 64,
                position = :absolute, fill = true);
            title = "Material 3", width = 620, height = 800,
            background = t.surface);
        value = theme_obs)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
