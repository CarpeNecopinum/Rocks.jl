# Dialogs: a component conditionally renders a Window, which opens a dialog.
# The dialog is closed by updating state (`on_close` handles the X button,
# the OK/Cancel buttons set state directly).
#
#   julia --project examples/dialog.jl

using Rocks
import Rocks: Text

function Dialog(; on_confirm = () -> nothing, on_cancel = () -> nothing)
    @rock Window(
        @rock Text("Delete all rocks?"; size = 20),
        @rock Row(
            @rock Pressable(
                @rock Text(" Cancel ");
                on_press = on_cancel,
                background = (0.30, 0.30, 0.34),
                hover_background = (0.38, 0.38, 0.42),
                padding = 10, align = :center),
            @rock Pressable(
                @rock Text(" Delete ");
                on_press = on_confirm,
                background = (0.75, 0.25, 0.25),
                hover_background = (0.85, 0.32, 0.32),
                pressed_background = (0.60, 0.20, 0.20),
                padding = 10, align = :center);
            gap = 16);
        title = "Confirm", width = 300, height = 160,
        padding = 20, gap = 20,
        on_close = on_cancel) # X button cancels
end

function App()
    open = @use Observable(false)
    deleted = @use Observable(false)
    @rock Window(
        @rock Text(deleted[] ? "The rocks are gone." : "All your rocks are safe."; size = 20),
        @rock Pressable(
            @rock Text("Delete rocks...");
            on_press = () -> open[] = true,
            background = (0.20, 0.45, 0.95),
            hover_background = (0.25, 0.52, 1.00),
            pressed_background = (0.16, 0.38, 0.82),
            padding = 12, align = :center);
        title = "Dialogs", width = 360, height = 160,
        padding = 24, gap = 20,
        open[] && @rock Dialog(;
            on_confirm = () -> (open[] = false; deleted[] = true),
            on_cancel = () -> open[] = false))
end

render(App)
