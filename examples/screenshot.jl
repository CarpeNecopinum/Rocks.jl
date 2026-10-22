# Semi-headless rendering: run the app for a few frames and capture a
# screenshot of its window into a PNG file — no event loop, no waiting for
# input. Useful for tests, CI and README images:
#
#   julia --project examples/screenshot.jl                        # real window
#   SDL_VIDEO_DRIVER=dummy julia --project examples/screenshot.jl  # headless
#
# On a desktop the window flashes briefly, under the dummy driver nothing
# appears (the software renderer still writes real pixels), and
# `screenshot.png` is written either way.

using Rocks
import Rocks: Text # disambiguate Rocks.Text from Base.Text

function App()
    count = @use Observable(42)
    @rock Window(
        @rock Text("The answer is ", count[]; size = 32);
        title = "Screenshot demo", width = 420, height = 160,
        padding = 24, align = :center)
end

if abspath(PROGRAM_FILE) == @__FILE__
    # `frames` bounds the event loop, `screenshot` captures the first window
    # into a PNG right before the app shuts down.
    render(App; frames = 3, screenshot = joinpath(@__DIR__, "screenshot.png"))
    println("wrote examples/screenshot.png")
end
