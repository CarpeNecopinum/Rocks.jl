# Flexbox layout: React Native style sizing for dynamically laid out
# interfaces.
#
#   julia --project examples/flexbox.jl
#
# The panels below show the pieces of the flexbox model:
#
#   * `flex = 1`          — take the free space of the parent
#   * `flex_grow`         — share the free space proportionally
#   * `flex_shrink`       — shrink into a parent that is too small
#   * `flex_basis`        — the size before the free space is shared
#   * `justify`           — distribute along the main axis
#   * `align`             — align across the cross axis
#   * `width = "50%"`     — a percentage of the parent
#   * `margin`            — space around a child
#   * `flex_wrap = :wrap` — children that do not fit start a new line
#
# Click the buttons to change the layout while it runs.

using Rocks
import Rocks: Text, Box, Window, Pressable
using Observables

# A flat chip with a label.
function Chip(label, color = "#e3e9f0"; kwargs...)
    @rock Box(@rock Text(label; size = 11, color = "#303030");
              background = color,
              padding = 6,
              radius = 10,
              kwargs...)
end

function App()
    # The top row: a fixed sidebar and a growing content area.
    header = @rock Box(
        @rock Text("Flexbox"; size = 16, color = "#1c2b3a"),
        @rock Text("the free space goes to the flexible child";
                   size = 12, color = "#5a6b7c");
        direction = :row,
        gap = 8,
        align = :center,
        padding = 8,
        background = "#eef2f7")

    # `flex = 1` makes the middle panel take the space that is left.
    content = @rock Box(
        @rock Text("Content", size = 12, color = "#404040");
        flex = 1,
        margin = 8,
        padding = 12,
        radius = 6,
        background = "#ffffff",
        border_color = "#c8d2dc",
        border_width = 1)

    # Three children that share the width of their row: 1, 2 and 3 parts.
    split = @rock Box(
        @rock Box(; background = "#f2b8b5", flex = 1),
        @rock Box(; background = "#f7d9a0", flex = 2),
        @rock Box(; background = "#b8d8f2", flex = 3);
        direction = :row,
        gap = 6,
        height = 34,
        align = :stretch,
        margin = 8)

    # Wrapped chips: the row is narrow, so the last chip starts a new line.
    chips = @rock Box(
        Chip("one"), Chip("two"), Chip("three"), Chip("four");
        direction = :row,
        gap = 6,
        flex_wrap = :wrap,
        width = 150,
        margin = 8)

    # Half the width, centered on the cross axis.
    half = @rock Box(
        @rock Text("50% wide, centered", size = 11, color = "#404040");
        width = "50%",
        align = :center,
        padding = 6,
        margin = 8)

    controls = @rock Box(
        @rock Pressable(@rock Text("toggle grow / shrink"; size = 12, color = "#1c2b3a");
                        on_press = () -> nothing,
                        padding = 8,
                        background = "#dce6f2",
                        radius = 4),
        @rock Pressable(@rock Text("more / fewer items"; size = 12, color = "#1c2b3a");
                        on_press = () -> nothing,
                        padding = 8,
                        background = "#dce6f2",
                        radius = 4);
        direction = :row,
        gap = 8,
        padding = 8)

    @rock Window(
        @rock Box(header, content, split, chips, half, controls;
                  direction = :column,
                  gap = 0,
                  flex = 1,
                  fill = true,
                  # React Native stretches the children of a column across its
                  # width by default; Rocks keeps the narrower `:start`
                  # default for backwards compatibility.
                  align = :stretch);
        title = "Flexbox layout",
        width = 520,
        height = 460,
        # Resizable, so the flexing can be seen while the window is dragged.
        resizable = true,
        padding = 12,
        gap = 8,
        background = "#f6f8fa")
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
