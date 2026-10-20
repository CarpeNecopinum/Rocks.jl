# Multi-window: the root component renders two Window elements; the second
# one is toggled via state, like any other conditional element.
#
#   julia --project examples/multiwindow.jl

using Rocks

function SecondWindow()
    @rock Window(
        @rock Label("I am a second window.");
        title = "Second window", width = 280, height = 140,
        padding = 20)
end

function App()
    open = @use Observable(false)
    @rock Window(
        @rock Label("Multi-window demo"; size = 24),
        @rock Label("Toggle the second window:"),
        @rock Button(open[] ? "Close second window" : "Open second window";
                     on_press = () -> open[] = !open[]),
        @rock Button("Quit"; on_press = () -> quit!(),
                     background = (0.55, 0.22, 0.22),
                     hover_background = (0.65, 0.28, 0.28));
        title = "Main window", width = 340, height = 240,
        padding = 24, gap = 16,
        open[] && @rock SecondWindow())
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
