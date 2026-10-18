# A tour of the pre-styled widgets: Button variants, Checkbox, Toggle,
# RadioGroup, DropDownMenu, Slider, ProgressBar and the Tabber that organizes
# them. Every control is bound to an Observable created with @use.
#
#   julia --project examples/widgets.jl

using Rocks
import Rocks: Text

function ControlsTab()
    checked = @use Observable(true)
    toggled = @use Observable(false)
    size = @use Observable(2)
    @rock Column(
        @rock Row(
            @rock Button("Contained"; on_press = () -> println("contained pressed")),
            @rock Button("Outlined"; variant = :outlined, color = :secondary),
            @rock Button("Text"; variant = :text, color = :info);
            gap = 8),
        @rock Row(
            @rock Button("Danger"; variant = :outlined, color = :error),
            @rock Button("Success"; color = :success),
            @rock Button("Large"; color = :warning, size = :large),
            @rock Button("Disabled"; disabled = true);
            gap = 8),
        @rock Checkbox("Show grid"; value = checked),
        @rock Toggle(; value = toggled),
        @rock RadioGroup(["Small", "Medium", "Large"]; selected = size),
        @rock Text("checkbox = $(checked[]), toggle = $(toggled[]), size = $(size[])";
                   size = 12, color = "#8899aa");
        gap = 10)
end

function InputTab()
    level = @use Observable(0.4)
    font = @use Observable(1)
    progress = @use Observable(0.3)
    @rock Column(
        @rock Text("Volume: ", round(Int, level[] * 100), "%"),
        @rock Slider(; value = level, min = 0, max = 1, width = 240),
        @rock DropDownMenu(["Sans", "Serif", "Mono"]; selected = font),
        @rock Text("font = ", font[] == 1 ? "Sans" : font[] == 2 ? "Serif" : "Mono"),
        @rock ProgressBar(; value = progress, width = 240),
        @rock Row(
            @rock Button("+"; on_press = () -> progress[] = clamp(progress[] + 0.1, 0, 1),
                         size = :small),
            @rock Button("-"; on_press = () -> progress[] = clamp(progress[] - 0.1, 0, 1),
                         size = :small);
            gap = 8);
        gap = 12)
end

function LayoutTab()
    ratio = @use Observable(0.5)
    @rock Column(
        @rock Text("Drag the handles to resize the panes";
                   size = 12, color = "#8899aa"),
        @rock Split(
            @rock Box(; background = (0.22, 0.28, 0.36),
                      children = [@rock Text("left pane")]),
            @rock Box(; background = (0.30, 0.24, 0.30),
                      children = [@rock Text("right pane")]);
            direction = :horizontal, ratio = ratio,
            width = 400, height = 180),
        @rock Split(
            @rock Box(; background = (0.24, 0.32, 0.28),
                      children = [@rock Text("top pane")]),
            @rock Box(; background = (0.34, 0.28, 0.22),
                      children = [@rock Text("bottom pane")]);
            direction = :vertical, ratio = 0.4,
            width = 400, height = 120);
        gap = 12)
end

function WidgetsApp()
    tab = @use Observable(1)
    @rock Window(
        @rock Column(
            @rock Tabber(;
                tabs = ["Controls", "Input", "Layout"],
                selected = tab,
                children = [
                    @rock ControlsTab(),
                    @rock InputTab(),
                    @rock LayoutTab()
                ]),
            @rock Text("A tour of the built-in widgets"; size = 11, color = "#666a75"));
        title = "Widgets", width = 480, height = 560,
        padding = 16, gap = 12)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(WidgetsApp)
end
