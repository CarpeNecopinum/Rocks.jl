# A tour of the native GTK widgets: CheckButton, Switch, RadioGroup,
# DropDown, Scale, ProgressBar, Entry and Paned, organized in a Notebook.
# Every control is bound to an Observable created with @use.
#
#   julia --project examples/widgets.jl

using Rocks

function ControlsTab()
    checked = @use Observable(true)
    bright = @use Observable(false)
    theme = @use Observable(2)
    @rock Column(
        @rock CheckButton("Show grid"; checked = checked,
                          on_change = () -> println("show-grid: ", checked[])),
        @rock Row(@rock Label("Dark mode"; size = 14),
                  @rock Switch(; on = bright); gap = 8),
        @rock RadioGroup(["Small", "Medium", "Large"]; selected = theme),
        @rock Label("checkbox = ", checked[], ", dark = ", bright[],
                    ", theme = ", theme[];
                    size = 12, color = "#8899aa");
        gap = 10)
end

function InputTab()
    level = @use Observable(0.4)
    font = @use Observable(1)
    progress = @use Observable(0.3)
    name = @use Observable("")
    @rock Column(
        @rock Label("Volume: ", round(Int, level[] * 100), "%"; size = 14),
        @rock Scale(; value = level, min = 0, max = 1, width = 240,
                    on_change = v -> println("level: ", v)),
        @rock DropDown("Sans", "Serif", "Mono"; selected = font),
        @rock Label("font = ", font[] == 1 ? "Sans" : font[] == 2 ? "Serif" : "Mono"),
        @rock ProgressBar(; fraction = progress, width = 240),
        @rock Row(
            @rock Button("+"; on_press = () -> progress[] = clamp(progress[] + 0.1, 0, 1)),
            @rock Button("-"; on_press = () -> progress[] = clamp(progress[] - 0.1, 0, 1));
            gap = 8),
        @rock Entry(; text = name, placeholder = "Type a name, then press Enter",
                    width = 240,
                    on_submit = () -> println("submitted: ", name[]));
        gap = 12)
end

function LayoutTab()
    ratio = @use Observable(0.5)
    @rock Column(
        @rock Label("Drag the handles to resize the panes";
                    size = 12, color = "#8899aa"),
        @rock Paned(
            @rock Box(@rock Label("left pane"); background = (0.22, 0.28, 0.36)),
            @rock Box(@rock Label("right pane"); background = (0.30, 0.24, 0.30));
            ratio = ratio, width = 400, height = 180),
        @rock Paned(
            @rock Box(@rock Label("top pane"); background = (0.24, 0.32, 0.28)),
            @rock Box(@rock Label("bottom pane"); background = (0.34, 0.28, 0.22));
            direction = :vertical, ratio = 0.4, width = 400, height = 120);
        gap = 12)
end

function WidgetsApp()
    tab = @use Observable(1)
    @rock Window(
        @rock Column(
            @rock Notebook(
                @rock ControlsTab(),
                @rock InputTab(),
                @rock LayoutTab();
                tabs = ["Controls", "Input", "Layout"],
                selected = tab),
            @rock Label("A tour of the GTK widgets"; size = 11, color = "#666a75");
            gap = 12);
        title = "Widgets", width = 480, height = 560,
        padding = 16, gap = 12)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(WidgetsApp)
end
