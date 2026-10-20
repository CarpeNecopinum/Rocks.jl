# Dialogs: a component conditionally renders a Window, which opens a dialog.
# The dialog is closed by updating state (`on_close` handles the X button,
# the OK/Cancel buttons set state directly).
#
#   julia --project examples/dialog.jl

using Rocks

function Dialog(; on_confirm = () -> nothing, on_cancel = () -> nothing)
    @rock Window(
        @rock Label("Delete all rocks?"; size = 20),
        @rock Row(
            @rock Button("Cancel"; on_press = on_cancel),
            @rock Button(" Delete "; on_press = on_confirm,
                         background = (0.75, 0.25, 0.25),
                         hover_background = (0.85, 0.32, 0.32));
            gap = 16);
        title = "Confirm", width = 300, height = 160,
        padding = 20, gap = 20,
        on_close = on_cancel) # the X button cancels
end

function App()
    open = @use Observable(false)
    deleted = @use Observable(false)
    @rock Window(
        @rock Label(deleted[] ? "The rocks are gone." : "All your rocks are safe."; size = 20),
        @rock Button("Delete rocks..."; on_press = () -> open[] = true);
        title = "Dialogs", width = 360, height = 160,
        padding = 24, gap = 20,
        open[] && @rock Dialog(;
            on_confirm = () -> (open[] = false; deleted[] = true),
            on_cancel = () -> open[] = false))
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
