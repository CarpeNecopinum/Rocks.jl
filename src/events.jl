# SDL event routing: pointer events are hit-tested against the layout tree
# and dispatched to pressables (bubbling up to the nearest `Pressable`
# ancestor, like DOM event targets), keyboard events are delivered to the
# window's `on_key`/`on_text_input` callbacks, and window events manage the
# OS windows.

"windowID -> window fiber"
const WINDOW_BY_ID = Dict{UInt32,Fiber}()

"(windowID, button) -> pressable fiber currently held down"
const ACTIVE_PRESS = Dict{Tuple{UInt32,UInt8},Fiber}()

"windowID -> hovered pressable fiber"
const HOVERED = Dict{UInt32,Fiber}()

"windowID -> last pointer position (wheel events carry no coordinates)"
const LAST_POINTER = Dict{UInt32,Tuple{Float64,Float64}}()

# Raw SDL modifier flags (`KMOD_*` bits) of the most recent `SDL_KEYDOWN`, so
# text fields can distinguish Ctrl-combos from plain typed characters.
const LAST_KEYMODS = Ref(Cuint(0))

const HAND_CURSOR = Ref{Ptr{SDL_Cursor}}(C_NULL)
const ARROW_CURSOR = Ref{Ptr{SDL_Cursor}}(C_NULL)
const TEXT_CURSOR = Ref{Ptr{SDL_Cursor}}(C_NULL)

const HOVERED_ACTIVE = Ref(false)

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

"Deepest fiber whose layout rect contains the point (windows are excluded —
nested windows are hit-tested through their own OS window)."
function hit_test(fiber, x, y)
    rx, ry, rw, rh = fiber.rect
    inside_parent = !(x < rx || y < ry || x >= rx + rw || y >= ry + rh)
    if !inside_parent && Symbol(get(fiber.props, :overflow, :hidden)) !== :visible
        return nothing
    end
    for child in reverse(fiber.children)
        is_window(child) && continue
        found = hit_test(child, x, y)
        found !== nothing && return found
    end
    inside_parent || return nothing
    # A transparent overlay can let pointer events fall through to the content
    # below while still keeping its interactive children hittable.
    Symbol(get(fiber.props, :pointer_events, :auto)) === :none && return nothing
    # Component fibers are not interactive themselves; their host output (or a
    # descendant) is the event target.
    return is_host(fiber.kind) ? fiber : nothing
end

"Mark the OS window with the given SDL windowID as needing a redraw. This
redraws the window without re-running components."
function mark_window_draw!(window_id)
    fiber = get(WINDOW_BY_ID, window_id, nothing)
    if fiber !== nothing && fiber.host isa WindowState
        fiber.host.needs_draw = true
    end
    return nothing
end

"Mark the OS window containing `fiber` as needing a re-layout and redraw,
without re-running components. Used while dragging Splits and Sliders."
function mark_window_layout!(fiber)
    f = fiber
    while f !== nothing && !is_window(f)
        f = f.parent
    end
    if f !== nothing && f.host isa WindowState
        f.host.needs_layout = true
        f.host.needs_draw = true
    end
    return nothing
end

# ---- scrolling -----------------------------------------------------------

# Wheel events carry no coordinates, so use the last motion/press position
# and fall back to SDL's current pointer position.
function pointer_position(wid)
    pos = get(LAST_POINTER, wid, nothing)
    pos !== nothing && return pos
    x, y = Ref{Cint}(0), Ref{Cint}(0)
    SDL_GetMouseState(x, y)
    return (Float64(x[]), Float64(y[]))
end

"Nearest scrollable ancestor of a hit target, not crossing window boundaries."
function find_scrollable(target)
    f = target
    while f !== nothing
        is_scrollable(f) && return f
        is_window(f) && return nothing
        f = f.parent
    end
    return nothing
end

# Positive SDL wheel deltas scroll up/away; invert them so a conventional
# wheel-down gesture increases the offset. Returns whether the offset moved.
function scroll_by!(fiber, dx, dy)
    dir = scroll_direction(fiber)
    dir === nothing && return false
    state = scroll_state!(fiber)
    delta = dir === :vertical ? -dy : -dx
    step = float(get(fiber.props, :scroll_step, 48))
    new = clamp(state.offset + delta * step, 0.0, state.max_offset)
    new == state.offset && return false
    state.offset = new
    callback(fiber.props, :on_scroll, new)
    mark_window_layout!(fiber)
    return true
end

# ---- dragging Splits and Sliders ----------------------------------------

"Drag state: the fiber currently being dragged, if any."
const ACTIVE_DRAG = Ref{Union{Nothing,Fiber}}(nothing)

"Nearest draggable ancestor (`Split` handle or `Slider`) of a hit target, not
crossing window boundaries."
function find_draggable(target, x, y)
    f = target
    while f !== nothing
        if (f.kind === _SPLIT || f.kind === _SLIDER) && f.host !== nothing &&
           inside(f.host.handle_rect, x, y)
            return f
        end
        if is_scrollable(f) && f.host isa ScrollState &&
           inside(f.host.thumb_rect, x, y)
            return f
        end
        is_window(f) && return nothing
        f = f.parent
    end
    return nothing
end

# A click on the scrollbar track (outside the thumb) pages the viewport.
function find_scrollbar_track(target, x, y)
    f = target
    while f !== nothing
        if is_scrollable(f) && f.host isa ScrollState
            st = f.host
            inside(st.track_rect, x, y) && !inside(st.thumb_rect, x, y) && return f
        end
        is_window(f) && return nothing
        f = f.parent
    end
    return nothing
end

"Invoke a press callback, passing the pointer position when the callback takes
two arguments (e.g. text fields that place their caret where you click) and
the button when it takes three (left down/up vs. right-click for a text
field's popup menu)."
function callback_press!(props, name::Symbol, x, y, button = 1)
    f = get(props, name, nothing)
    f isa Function || return
    try
        if hasmethod(f, Tuple{Any,Any,Any})
            f(x, y, button)
        elseif hasmethod(f, Tuple{Any,Any})
            f(x, y)
        else
            f()
        end
    catch err
        @warn "Rocks: callback :$name failed" exception = (err, catch_backtrace())
    end
    return nothing
end

"The scrollable fiber whose scrollbar arrow button contains the point (the
bitwise `:start` is the top/left arrow, `:stop` the bottom/right one), or
`nothing` when the press misses the arrows."
function find_scrollbar_arrow(target, x, y)
    f = target
    while f !== nothing
        if is_scrollable(f) && f.host isa ScrollState
            st = f.host
            inside(st.arrow_a_rect, x, y) && return (f, :start)
            inside(st.arrow_b_rect, x, y) && return (f, :stop)
        end
        is_window(f) && return nothing
        f = f.parent
    end
    return nothing
end

function drag_start!(fiber, x, y)
    if fiber.kind === _SPLIT
        fiber.host isa SplitState || return
        fiber.host.drag_start_ratio = split_ratio(fiber)
        dir = Symbol(get(fiber.props, :direction, :horizontal))
        fiber.host.drag_start_pos = dir === :vertical ? y : x
    elseif fiber.kind === _SLIDER
        slider_drag_update!(fiber, x, y) # clicking jumps to the position
    elseif is_scrollable(fiber) && fiber.host isa ScrollState
        fiber.host.drag_start_offset = fiber.host.offset
        dir = scrollbar_direction(fiber)
        fiber.host.drag_start_pos = dir === :horizontal ? x : y
    end
    return nothing
end

function drag_update!(fiber, x, y)
    if fiber.kind === _SPLIT
        st = fiber.host
        st isa SplitState || return
        dir = Symbol(get(fiber.props, :direction, :horizontal))
        rx, ry, rw, rh = fiber.rect
        t = float(get(fiber.props, :handle, 6))
        main = dir === :vertical ? rh - t : rw - t
        main <= 0 && return
        pos = dir === :vertical ? y : x
        delta = (pos - st.drag_start_pos) / main
        set_split_ratio!(fiber, st.drag_start_ratio + delta)
        mark_window_layout!(fiber)
    elseif fiber.kind === _SLIDER
        slider_drag_update!(fiber, x, y)
    elseif is_scrollable(fiber) && fiber.host isa ScrollState
        st = fiber.host
        dir = scrollbar_direction(fiber)
        tx, ty, tw, th = st.track_rect
        hx, hy, hw, hh = st.thumb_rect
        if dir === :horizontal
            travel = tw - hw
            pos = x
            start = st.drag_start_pos
        else
            travel = th - hh
            pos = y
            start = st.drag_start_pos
        end
        travel <= 0 && return nothing
        st.offset = clamp(st.drag_start_offset + (pos - start) / travel * st.max_offset,
                          0.0, st.max_offset)
        callback(fiber.props, :on_scroll, st.offset)
        mark_window_layout!(fiber)
    end
    return nothing
end

function drag_end!(fiber)
    return nothing
end

function slider_drag_update!(fiber, x, y)
    value = get(fiber.props, :value, nothing)
    value isa Observable || return
    lo = float(get(fiber.props, :min, 0))
    hi = float(get(fiber.props, :max, 1))
    hi > lo || return
    rx, _, rw, _ = fiber.rect
    rw <= 0 && return
    # The knob center travels across `rw - knob_w` pixels, so map pointer
    # positions onto that interval (a plain `frac` makes the thumbnail lag
    # the cursor by half the knob width and the end ticks unreachable).
    knob_w = float(get(fiber.props, :thumb_width, 0)) > 0 ? 0.0 :
             float(get(fiber.props, :thumb_size, 12))
    frac = clamp((x - rx - knob_w / 2) / max(rw - knob_w, 1.0), 0.0, 1.0)
    new = lo + frac * (hi - lo)
    value[] = new
    mark_window_layout!(fiber)
    cb = get(fiber.props, :on_change, nothing)
    cb isa Function && try
        cb(new)
    catch err
        @warn "Rocks: Slider :on_change failed" exception = (err, catch_backtrace())
    end
    return nothing
end

"Nearest `Pressable` ancestor of a fiber, not crossing window boundaries."
function find_pressable(fiber)
    while fiber !== nothing
        fiber.kind === _PRESSABLE && return fiber
        is_window(fiber) && return nothing
        fiber = fiber.parent
    end
    return nothing
end

inside((rx, ry, rw, rh), x, y) = rx <= x < rx + rw && ry <= y < ry + rh

# ---- keyboard focus -------------------------------------------------------

# The fiber keyboard events are dispatched to (the deepest one under the last
# press carrying `on_key`/`on_text_input` props); `nothing` means the window.
const FOCUSED = Ref{Union{Nothing,Fiber}}(nothing)

"""
    focus!(fiber)

Give keyboard focus to a fiber (its `on_key`/`on_text_input` props receive
keyboard events until focus moves). Focus normally follows the press and is
rarely set manually.
"""
function focus!(fiber)
    FOCUSED[] === fiber && return
    FOCUSED[] = fiber
    request_render()
    return nothing
end

"""
    unfocus!()

Clear keyboard focus (events return to the window).
"""
function unfocus!()
    FOCUSED[] === nothing && return
    FOCUSED[] = nothing
    request_render()
    return nothing
end

# Does `fiber` live inside `ancestor`'s subtree?
function inside_subtree(fiber, ancestor)
    f = fiber
    while f !== nothing
        f === ancestor && return true
        f = f.parent
    end
    return false
end

# The nearest fiber (or ancestor) handling keyboard events.
function find_focusable(fiber)
    f = fiber
    while f !== nothing
        (haskey(f.props, :on_key) || haskey(f.props, :on_text_input)) && return f
        f = f.parent
    end
    return nothing
end

# The fiber keyboard events go to: the focused fiber when it is mounted and
# belongs to the event's window, the window otherwise.
function keyboard_target(fiber)
    focused = FOCUSED[]
    focused === nothing && return fiber
    focused.mounted && inside_subtree(focused, fiber) && return focused
    return fiber
end

"""
    has_focus() -> Bool

Whether the fiber currently being rendered holds keyboard focus. Components
use it to draw focus indicators and carets.
"""
function has_focus()
    CURRENT_FIBER[] !== nothing || return false
    FOCUSED[] !== nothing || return false
    return inside_subtree(FOCUSED[], CURRENT_FIBER[])
end

function update_cursor()
    if HAND_CURSOR[] == C_NULL
        HAND_CURSOR[] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_HAND)
        ARROW_CURSOR[] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW)
        TEXT_CURSOR[] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_IBEAM)
    end
    cursor = ARROW_CURSOR[]
    if HOVERED_ACTIVE[]
        # A hovered pressable that asks for a text pointer (e.g. a TextBox)
        # shows the I-beam; everything else hoverable is a clickable control.
        wants_text = any(get(p.props, :cursor, nothing) === :text
                         for p in values(HOVERED))
        cursor = wants_text ? TEXT_CURSOR[] : HAND_CURSOR[]
    end
    SDL_SetCursor(cursor)
    return nothing
end

"Close every popup menu window except the one with window id `except` (0
closes all). The menu's `:menu_open` observable is set to `0`/`false`;
returns true when any menu was closed, so the invoking press can be
swallowed as the dismiss gesture."
function close_open_menus!(except)
    closed = false
    for (id, f) in WINDOW_BY_ID
        obs = get(f.props, :menu_open, nothing)
        (obs isa Observable && id != except) || continue
        obs[] = 0
        closed = true
    end
    closed && request_render()
    return closed
end

function set_hover!(window_id, pressable)
    current = get(HOVERED, window_id, nothing)
    current === pressable && return
    if current !== nothing && current.mounted && current.host isa PressState
        current.host.hovered = false
        callback(current.props, :on_hover_out)
    end
    if pressable !== nothing && pressable.mounted && pressable.host isa PressState
        pressable.host.hovered = true
        callback(pressable.props, :on_hover_in)
    end
    if pressable === nothing
        delete!(HOVERED, window_id)
    else
        HOVERED[window_id] = pressable
    end
    HOVERED_ACTIVE[] = !isempty(HOVERED)
    update_cursor()
    # Hover styling is drawn from the PressState flags — the window needs a
    # redraw, not a re-render.
    mark_window_draw!(window_id)
    return nothing
end

"""
    dispatch_event!(event)

Route one SDL event to the UI tree. Called by the main loop in runtime.jl.
"""
function dispatch_event!(event::SDL_Event)
    ty = event.type
    if ty == SDL_QUIT
        quit!()
    elseif ty == SDL_WINDOWEVENT
        wid = event.window.windowID
        wev = event.window.event
        if wev == SDL_WINDOWEVENT_CLOSE
            handle_close!(wid)
        elseif wev == SDL_WINDOWEVENT_EXPOSED
            # The window manager wants the window repainted (it was covered,
            # restored, ...).
            mark_window_draw!(wid)
        elseif wev == SDL_WINDOWEVENT_RESIZED || wev == SDL_WINDOWEVENT_SIZE_CHANGED
            # Resized windows are re-laid out and redrawn without re-running
            # components.
            fiber = get(WINDOW_BY_ID, wid, nothing)
            if fiber !== nothing && fiber.host isa WindowState
                fiber.host.width = Int(event.window.data1)
                fiber.host.height = Int(event.window.data2)
                fiber.host.needs_layout = true
                fiber.host.needs_draw = true
            end
        end
    elseif ty == SDL_MOUSEBUTTONDOWN
        wid = event.button.windowID
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && return
        mx, my = event.button.x, event.button.y
        LAST_POINTER[wid] = (Float64(mx), Float64(my))
        # The first click only dismisses open popup menus (Windows gesture).
        close_open_menus!(wid) && return
        target = hit_test(fiber, mx, my)

        # Focus follows the press: the nearest fiber handling keyboard events
        # gets them (the window when nothing in the tree handles them).
        focusable = find_focusable(target)
        if focusable !== FOCUSED[]
            FOCUSED[] = focusable
            request_render()
        end

        # Scrollbar arrows step the viewport up/down..
        arrow = find_scrollbar_arrow(target, mx, my)
        if arrow !== nothing
            pager, which = arrow
            st = pager.host
            step = max(st.viewport_extent * 0.15, 24.0)
            st.offset = clamp(st.offset + (which === :start ? -step : step),
                              0.0, st.max_offset)
            callback(pager.props, :on_scroll, st.offset)
            mark_window_layout!(pager)
            return
        end

        # Clicking the scrollbar track pages the viewport.
        pager = find_scrollbar_track(target, mx, my)
        if pager !== nothing
            st = pager.host
            dir = scrollbar_direction(pager)
            _, _, _, th = st.track_rect
            _, _, _, hh = st.thumb_rect
            page = max(st.viewport_extent * 0.9, 24.0)
            delta = dir === :horizontal ?
                    (mx < st.thumb_rect[1] ? -page : page) :
                    (my < st.thumb_rect[2] ? -page : page)
            st.offset = clamp(st.offset + delta, 0.0, st.max_offset)
            callback(pager.props, :on_scroll, st.offset)
            mark_window_layout!(pager)
            return
        end

        # start a drag when the press lands on a Split handle or a Slider
        drag = find_draggable(target, mx, my)
        if drag !== nothing
            ACTIVE_DRAG[] = drag
            drag_start!(drag, mx, my)
            return
        end

        pressable = find_pressable(target)
        if pressable !== nothing && !Bool(get(pressable.props, :disabled, false))
            ACTIVE_PRESS[(wid, event.button.button)] = pressable
            pressable.host isa PressState && (pressable.host.pressed = true)
            callback_press!(pressable.props, :on_press_in,
                            Float64(mx), Float64(my), Int(event.button.button))
            mark_window_draw!(wid)
        end
    elseif ty == SDL_MOUSEBUTTONUP
        wid = event.button.windowID
        if ACTIVE_DRAG[] !== nothing
            drag_end!(ACTIVE_DRAG[])
            ACTIVE_DRAG[] = nothing
            return
        end
        pressable = pop!(ACTIVE_PRESS, (wid, event.button.button), nothing)
        pressable === nothing && return
        mx, my = event.button.x, event.button.y
        pressable.host isa PressState && (pressable.host.pressed = false)
        callback(pressable.props, :on_press_out)
        if pressable.mounted && pressable.kind === _PRESSABLE &&
           inside(pressable.rect, mx, my) && !Bool(get(pressable.props, :disabled, false))
            callback_press!(pressable.props, :on_press, Float64(mx), Float64(my),
                            Int(event.button.button))
        end
        mark_window_draw!(wid)
    elseif ty == SDL_MOUSEMOTION
        wid = event.motion.windowID
        mx, my = event.motion.x, event.motion.y
        LAST_POINTER[wid] = (Float64(mx), Float64(my))
        if ACTIVE_DRAG[] !== nothing
            drag_update!(ACTIVE_DRAG[], mx, my)
            return
        end
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && (set_hover!(wid, nothing); return)
        # Holding the pointer down over a text field and dragging extends its
        # selection (the field's `on_drag` sees pointer positions).
        pressable = get(ACTIVE_PRESS, (wid, 1), nothing)
        if pressable !== nothing && haskey(pressable.props, :on_drag)
            f = pressable.props[:on_drag]
            if f isa Function
                try
                    f(Float64(mx), Float64(my))
                catch err
                    @warn "Rocks: callback :on_drag failed" exception =
                        (err, catch_backtrace())
                end
            end
            mark_window_draw!(wid)
        end
        target = hit_test(fiber, mx, my)
        set_hover!(wid, find_pressable(target))
    elseif ty == SDL_MOUSEWHEEL
        wid = event.wheel.windowID
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && return
        x, y = pointer_position(wid)
        target = hit_test(fiber, x, y)
        scroll = find_scrollable(target)
        scroll === nothing && return
        dx = Float64(event.wheel.x)
        dy = Float64(event.wheel.y)
        if dx == 0.0 && dy == 0.0
            dx = Float64(event.wheel.preciseX)
            dy = Float64(event.wheel.preciseY)
        end
        if event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED
            dx, dy = -dx, -dy
        end
        scroll_by!(scroll, dx, dy)
    elseif ty == SDL_KEYDOWN
        fiber = get(WINDOW_BY_ID, event.key.windowID, nothing)
        fiber === nothing && return
        target = keyboard_target(fiber)
        key = unsafe_string(SDL_GetKeyName(event.key.keysym.sym))
        LAST_KEYMODS[] = event.key.keysym.mod
        # Escape first dismisses open popup menus (before fields see it).
        if key == "Escape" && close_open_menus!(0)
            return
        end
        # `on_key_mods(key, mods)` sees the raw SDL modifier flags and wins:
        # when it returns `:handled`, plain `on_key` is not called (this lets
        # text fields own Ctrl+C/V/X/A and Shift+cursor selection).
        if haskey(target.props, :on_key_mods)
            handled = nothing
            mf = target.props[:on_key_mods]
            if mf isa Function
                try
                    handled = mf(key, Int(event.key.keysym.mod))
                catch err
                    @warn "Rocks: callback :on_key_mods failed" exception =
                        (err, catch_backtrace())
                end
            end
            handled === :handled || handled === nothing ||
                @warn "Rocks: `on_key_mods` must return `:handled` or `nothing`"
            handled === :handled && return
        end
        callback(target.props, :on_key, key)
    elseif ty == SDL_KEYUP
        fiber = get(WINDOW_BY_ID, event.key.windowID, nothing)
        fiber === nothing && return
        target = keyboard_target(fiber)
        key = unsafe_string(SDL_GetKeyName(event.key.keysym.sym))
        callback(target.props, :on_key_up, key)
    elseif ty == SDL_TEXTINPUT
        fiber = get(WINDOW_BY_ID, event.text.windowID, nothing)
        fiber === nothing && return
        # The text field is a fixed 32-byte UTF-8 buffer.
        chars = UInt8[]
        for b in event.text.text
            b == 0 && break
            push!(chars, UInt8(b & 0xff))
        end
        target = keyboard_target(fiber)
        callback(target.props, :on_text_input, String(chars))
    end
    return nothing
end

# Default X-button behavior: if the app handles `on_close` it is called
# (return `false` to keep the window); otherwise the window is hidden — or
# the application quits when it was the last visible window.
function handle_close!(wid)
    fiber = get(WINDOW_BY_ID, wid, nothing)
    fiber === nothing && return
    if haskey(fiber.props, :on_close)
        result = nothing
        f = fiber.props[:on_close]
        if f isa Function
            try
                result = f()
            catch err
                @warn "Rocks: callback :on_close failed" exception = (err, catch_backtrace())
            end
        end
        result === false && return # keep the window
        unmount!(fiber)
        request_render()
        return
    end
    if count(f -> f.host isa WindowState, values(WINDOW_BY_ID)) <= 1
        quit!()
        return
    end
    # Hide the window; the fiber stays mounted. It becomes visible again only
    # when the component rendering it remounts (a fresh fiber is created).
    if fiber.host isa WindowState
        SDL_HideWindow(fiber.host.ptr)
        fiber.hidden = true
    end
    return nothing
end
