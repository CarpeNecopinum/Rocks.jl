# The classic counter: a Window, a Text and a Pressable. State is an
# Observable created with @use; setting it triggers a re-render.
#
#   julia --project examples/counter.jl

using Rocks
import Rocks: Text # disambiguate Rocks.Text from Base.Text

function App()
    count = @use Observable(0)
    @rock Window(
        @rock Text("Count: ", count[]; size = 32),
        @rock Row(
            @rock Pressable(
                @rock Text("  +  "; size = 20);
                on_press = () -> count[] += 1,
                background = (0.20, 0.45, 0.95),
                hover_background = (0.25, 0.52, 1.00),
                pressed_background = (0.16, 0.38, 0.82),
                padding = 12, align = :center),
            @rock Pressable(
                @rock Text("  -  "; size = 20);
                on_press = () -> count[] -= 1,
                background = (0.30, 0.30, 0.34),
                hover_background = (0.38, 0.38, 0.42),
                pressed_background = (0.24, 0.24, 0.27),
                padding = 12, align = :center),
            @rock Pressable(
                @rock Text(" reset "; size = 20);
                on_press = () -> count[] = 0,
                background = (0.30, 0.30, 0.34),
                hover_background = (0.38, 0.38, 0.42),
                pressed_background = (0.24, 0.24, 0.27),
                padding = 12, align = :center);
            gap = 12);
        title = "Counter", width = 380, height = 180,
        padding = 24, gap = 20)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
