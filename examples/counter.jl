# The classic counter: a Window with a Label and a row of Buttons. State is
# an Observable created with @use; setting it triggers a re-render.
#
#   julia --project examples/counter.jl

using Rocks

function App()
    count = @use Observable(0)
    @rock Window(
        @rock Label("Count: ", count[]; size = 32),
        @rock Row(
            @rock Button("+"; on_press = () -> count[] += 1,
                         padding = 8, size = 20,
                         background = (0.20, 0.45, 0.95),
                         hover_background = (0.25, 0.52, 1.00)),
            @rock Button("-"; on_press = () -> count[] -= 1,
                         padding = 8, background = (0.30, 0.30, 0.34)),
            @rock Button(" reset "; on_press = () -> count[] = 0,
                         padding = 8, background = (0.30, 0.30, 0.34));
            gap = 12);
        title = "Counter", width = 320, height = 180,
        padding = 24, gap = 20)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
