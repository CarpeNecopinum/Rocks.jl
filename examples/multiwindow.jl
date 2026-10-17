# Multi-window: the root component renders two Window elements; the second
# one is toggled via state, like any other conditional element.
#
#   julia --project examples/multiwindow.jl

using Rocks
import Rocks: Text

function SecondWindow()
    @rock(Window,
        @rock(Text, "I am a second window.");
        title = "Second window", width = 280, height = 140,
        padding = 20,
        x = 700, y = 300) # open somewhere next to the main window
end

function App()
    open, set_open = useState(false)
    @rock(Window,
        @rock(Text, "Multi-window demo"; size = 24),
        @rock(Text, "Toggle the second window:"),
        @rock(Pressable,
            @rock(Text, open ? "Close second window" : "Open second window");
            on_press = () -> set_open(o -> !o),
            background = (0.20, 0.45, 0.95),
            hover_background = (0.25, 0.52, 1.00),
            pressed_background = (0.16, 0.38, 0.82),
            padding = 12, align = :center),
        @rock(Pressable,
            @rock(Text, "Quit");
            on_press = quit!,
            background = (0.55, 0.22, 0.22),
            hover_background = (0.65, 0.28, 0.28),
            pressed_background = (0.45, 0.18, 0.18),
            padding = 12, align = :center);
        title = "Main window", width = 340, height = 260,
        padding = 24, gap = 16,
        open && @rock(SecondWindow()))
end

render(App)
