# Hooks and timers: a clock driven by useInterval, demonstrating useEffect
# with dependencies. State is an Observable created with @use.
#
#   julia --project examples/clock.jl

using Rocks
using Dates

function App()
    now = @use Observable(Dates.now())
    started = @use Observable(Dates.now())

    # runs once on mount
    useEffect(() -> println("clock started at ", Dates.now()), ())

    # tick every second
    useInterval(() -> now[] = Dates.now(), 1000)

    # runs whenever `now` changes
    useEffect(() -> println("second passed: ", Dates.format(now[], "HH:MM:SS")), (now[],))

    elapsed = max(0, (now[] - started[]) / Millisecond(1) ÷ 1000)

    @rock Window(
        @rock Label(Dates.format(now[], "HH:MM:SS"); size = 48),
        @rock Label("running for ", elapsed, "s"; size = 16, color = "#8899aa"),
        @rock Button(elapsed > 0 ? "Restart" : "Start";
                     on_press = () -> started[] = Dates.now(),
                     padding = 10, background = (0.30, 0.30, 0.34),
                     hover_background = (0.38, 0.38, 0.42));
        title = "Clock", width = 320, height = 200,
        padding = 24, gap = 16, align = :center)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
