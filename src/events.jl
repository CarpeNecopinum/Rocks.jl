# GTK signal wiring: connects widget signals to Rocks callback props.
#
# GTK delivers the events (clicks, drags, keyboard input, window closes) —
# there is no event polling or hit-testing anymore. Signal callbacks run on
# the GLib loop task; they update state (usually Observables) and call user
# callbacks. Widgets' state props (`checked`, `on`, `value`, `selected`,
# `text`, `ratio`) are two-way: the widget writes the Observable, and the
# re-render triggered by it re-applies the (now equal) value — a no-op — so
# no feedback loop occurs.

# Call a callback prop, guarding against user errors.
function callback(props, name::Symbol, args...)
    f = get(props, name, nothing)
    f isa Function || return
    try
        f(args...)
    catch err
        @warn "Rocks: callback :$name failed" exception = (err, catch_backtrace())
    end
    return nothing
end

const Callable = Function

# Wire the widget signals of a host fiber. Called on widget creation (so a
# fiber's handlers live as long as its widget). Handlers capture the fiber
# and read `fiber.props` at call time, so re-rendered callbacks are picked up.
function wire_events!(fiber)
    kind = fiber.kind
    host = fiber.host
    if kind === _BUTTON
        signal_connect(host, "clicked") do _
            callback(fiber.props, :on_press)
            nothing
        end
    elseif kind === _CHECKBUTTON
        signal_connect(host, "toggled") do _
            checked = get(fiber.props, :checked, nothing)
            checked isa Observable &&
                (checked[] = Bool(Gtk4.get_gtk_property(fiber.host, :active)))
            callback(fiber.props, :on_change)
            nothing
        end
    elseif kind === _SWITCH
        signal_connect(host, "notify::active") do _, _
            on = get(fiber.props, :on, nothing)
            on isa Observable &&
                (on[] = Bool(Gtk4.get_gtk_property(fiber.host, :active)))
            callback(fiber.props, :on_change)
            nothing
        end
    elseif kind === _SCALE
        signal_connect(host, "value-changed") do _
            v = Gtk4.G_.get_value(Gtk4.adjustment(fiber.host))
            value = get(fiber.props, :value, nothing)
            value isa Observable && (value[] = v)
            callback(fiber.props, :on_change, v)
            nothing
        end
    elseif kind === _PANED
        signal_connect(host, "notify::position") do _, _
            ratio = get(fiber.props, :ratio, nothing)
            ratio isa Observable || return nothing
            vertical = Int(Gtk4.get_gtk_property(fiber.host, :orientation)) == 1
            size = vertical ? Int(Gtk4.G_.get_height(fiber.host)) :
                   Int(Gtk4.G_.get_width(fiber.host))
            size > 0 && (ratio[] = Gtk4.G_.get_position(fiber.host) / size)
            nothing
        end
    elseif kind === _DROPDOWN
        signal_connect(host, "notify::selected") do _, _
            sel = Int(Gtk4.G_.get_selected(fiber.host))
            sel == 0xffffffff && return nothing # no selection (model just swapped)
            selected = get(fiber.props, :selected, nothing)
            selected isa Observable && (selected[] = sel + 1)
            callback(fiber.props, :on_change)
            nothing
        end
    elseif kind === _NOTEBOOK
        signal_connect(host, "switch-page") do _, _, page_num
            selected = get(fiber.props, :selected, nothing)
            selected isa Observable && (selected[] = Int(page_num) + 1)
            callback(fiber.props, :on_change)
            nothing
        end
    elseif kind === _ENTRY
        signal_connect(host, "changed") do _
            text = get(fiber.props, :text, nothing)
            text isa Observable || return nothing
            text[] = String(Gtk4.get_gtk_property(fiber.host, :text))
            callback(fiber.props, :on_change)
            nothing
        end
        signal_connect(host, "activate") do _
            callback(fiber.props, :on_submit)
            nothing
        end
    end
    return nothing
end

# Window signals: close-request implements Rocks' on_close semantics.
function wire_window_events!(fiber)
    signal_connect(fiber.host.window, "close-request") do _
        props = fiber.props
        if haskey(props, :on_close)
            f = props[:on_close]
            result = nothing
            f isa Callable && begin
                try
                    result = f()
                catch err
                    @warn "Rocks: callback :on_close failed" exception = (err, catch_backtrace())
                end
            end
            result === false && return true # keep the window open
            unmount!(fiber)
            return true # we destroyed it ourselves
        end
        # No on_close: quit when this was the last visible window, otherwise
        # hide it (the fiber stays mounted; it re-opens only when the
        # component rendering it remounts).
        root = fiber
        while root.parent !== nothing
            root = root.parent
        end
        windows = collect_windows!(Fiber[], root)
        live = count(w -> w !== fiber && w.host isa WindowHost && !w.hidden, windows)
        if live == 0
            quit!()
        else
            Gtk4.visible(fiber.host.window, false)
            fiber.hidden = true
        end
        return true
    end
    return nothing
end
