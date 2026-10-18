# Effects and timers: a clock driven by useInterval, demonstrating
# useEffect with dependencies and useTimeout.
#
#   julia --project examples/clock.jl

using Rocks
using Dates
import Rocks: Text

function App()
    now, set_now = useState(Dates.now())
    started, set_started = useState(Dates.now())

    # runs once on mount
    useEffect(() -> println("clock started at ", Dates.now()), ())

    # tick every second
    useInterval(() -> set_now(Dates.now()), 1000)

    # runs whenever `now` changes
    useEffect(() -> println("second passed: ", Dates.format(now, "HH:MM:SS")), (now,))

    elapsed = max(0, (now - started) / Millisecond(1) ÷ 1000)

    @rock Window(
        @rock Text(Dates.format(now, "HH:MM:SS"); size = 48),
        @rock Text("running for ", elapsed, "s"; size = 16, color = "#8899aa"),
        @rock Pressable(
            @rock Text(elapsed > 0 ? "Restart" : "Start");
            on_press = () -> set_started(Dates.now()),
            background = (0.30, 0.30, 0.34),
            hover_background = (0.38, 0.38, 0.42),
            pressed_background = (0.24, 0.24, 0.27),
            padding = 10, align = :center);
        title = "Clock", width = 320, height = 200,
        padding = 24, gap = 16, align = :center)
end

render(App)
