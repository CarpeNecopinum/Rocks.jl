# SDL event routing: pointer events are hit-tested against the layout tree
# and dispatched to mouse areas (bubbling up to the nearest `MouseArea`
# ancestor — `Pressable` is its legacy alias — like DOM event targets),
# keyboard events are delivered to the window's `on_key`/`on_text_input`
# callbacks, and window events manage the OS windows.

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

const HAND_CURSOR = Ref{SDL3.Cursor}(C_NULL)
const ARROW_CURSOR = Ref{SDL3.Cursor}(C_NULL)
const TEXT_CURSOR = Ref{SDL3.Cursor}(C_NULL)
const GRAB_CURSOR = Ref{SDL3.Cursor}(C_NULL)      # open hand (pan-ready)
const GRABBING_CURSOR = Ref{SDL3.Cursor}(C_NULL)  # closed hand (panning)
const CROSSHAIR_CURSOR = Ref{SDL3.Cursor}(C_NULL) # creation-tool drags

# SDL3 appended GRAB and GRABBING after the pointer names this SDL3.jl
# binding knows; the enum is ABI-stable (new values are appended, never
# renumbered), so they are requested directly and the code falls back to the
# pointing hand when the native library predates them.
# SDL 3.4 dropped the dedicated grab cursors (SDL_SYSTEM_CURSOR_COUNT is 20
# and ids beyond it corrupt SDL's cursor list); pan uses the move cursor.
const _SDL_SYSTEM_CURSOR_GRAB = SDL3.SDL_SYSTEM_CURSOR_MOVE
const _SDL_SYSTEM_CURSOR_GRABBING = SDL3.SDL_SYSTEM_CURSOR_MOVE

# Set when the video driver has no system cursors (headless drivers).
const CURSORS_UNAVAILABLE = Ref(false)

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
    # Host fibers represent visible boxes, so they clip by default and an
    # `:overflow => :visible` consciously punches a hit-test (and rendering)
    # hole. Component fibers are transparent forwards to their output: their
    # props come from the call site, where `overflow` is not a meaningful
    # prop, so hitting a popup that overflows the component's own rect must
    # still descend into the (typically smaller) output subtree.
    default_overflow = is_host(fiber.kind) ? :hidden : :visible
    if !inside_parent && Symbol(get(fiber.props, :overflow, default_overflow)) !== :visible
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
    _, x, y = SDL3.GetMouseState()
    return (Float64(x), Float64(y))
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

"Nearest fiber carrying an explicit `:on_wheel` prop, innermost first. Such a
fiber consumes the wheel before scroll containers, so a `MouseArea` wrapping
a canvas can zoom while sitting inside a `ScrollView`."
function find_wheel_target(target)
    f = target
    while f !== nothing
        haskey(f.props, :on_wheel) && return f
        is_window(f) && return nothing
        f = f.parent
    end
    return nothing
end

# Wheel callback`: `on_wheel(dx, dy, x, y)` where dx/dy are the raw (not
# step-multiplied) wheel deltas and (x, y) the pointer in consumer-local
# coordinates; `(dx, dy)` and no-argument forms are also accepted.
function callback_wheel!(props, dx, dy, x, y)
    f = get(props, :on_wheel, nothing)
    f isa Function || return
    try
        if hasmethod(f, Tuple{Any,Any,Any,Any})
            f(dx, dy, x, y)
        elseif hasmethod(f, Tuple{Any,Any})
            f(dx, dy)
        else
            f()
        end
    catch err
        @warn "Rocks: callback :on_wheel failed" exception = (err, catch_backtrace())
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

"Nearest interactive ancestor of a fiber (a `MouseArea`; `Pressable` is its
legacy alias), not crossing window boundaries."
function find_pressable(fiber)
    while fiber !== nothing
        is_pressable_kind(fiber.kind) && return fiber
        is_window(fiber) && return nothing
        fiber = fiber.parent
    end
    return nothing
end

"Whether a host kind responds to pointer events. The `Canvas` is a pure
drawing surface and is deliberately absent: wrap it in a `MouseArea` to make
it interactive."
is_pressable_kind(kind) = kind === _PRESSABLE

# Mouse callbacks receive area-local coordinates (0,0 = the interactive
# area's top-left, sharing one transform with a wrapped canvas's draw space);
# other kinds (e.g. TextBox-like hosts) keep the window-coordinate semantics.
_locals(fiber, x, y) =
    fiber.kind === _PRESSABLE ?
        (x - fiber.rect[1], y - fiber.rect[2]) : (x, y)

inside((rx, ry, rw, rh), x, y) = rx <= x < rx + rw && ry <= y < ry + rh

# ---- keyboard focus -------------------------------------------------------

# The fiber keyboard events are dispatched to (the deepest one under the last
# press carrying `on_key`/`on_text_input` props); `nothing` means the window.
const FOCUSED = Ref{Union{Nothing,Fiber}}(nothing)

# SDL3 delivers no SDL_EVENT_TEXT_INPUT (the typed characters) by default —
# text input must be started per window with SDL_StartTextInput. Its lifetime
# follows the keyboard focus: while the focused fiber carries an
# `on_text_input` prop, text input is active for the window it belongs to;
# without a focused text field it stops, so plain key presses keep their
# normal meaning everywhere else.
function sync_text_input!(fiber)
    f = fiber
    while f isa Fiber && !is_window(f)
        f = f.parent
    end
    f isa Fiber || return
    host = f.host isa WindowState ? f.host : nothing
    host === nothing && return
    want = fiber isa Fiber && haskey(fiber.props, :on_text_input)
    if want
        SDL3.TextInputActive(host.ptr) || SDL3.StartTextInput(host.ptr)
    elseif SDL3.TextInputActive(host.ptr)
        SDL3.StopTextInput(host.ptr)
    end
    return nothing
end

"Stop SDL text input on every open window (the leaving focus's window is
unknown)."
function stop_all_text_input!()
    for f in values(WINDOW_BY_ID)
        f.host isa WindowState || continue
        SDL3.TextInputActive(f.host.ptr) && SDL3.StopTextInput(f.host.ptr)
    end
    return nothing
end

"""
    focus!(fiber)

Give keyboard focus to a fiber (its `on_key`/`on_text_input` props receive
keyboard events until focus moves). Focus normally follows the press and is
rarely set manually.
"""
function focus!(fiber)
    FOCUSED[] === fiber && return
    FOCUSED[] = fiber
    sync_text_input!(fiber)
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
    stop_all_text_input!()
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
    if HAND_CURSOR[] == C_NULL && !CURSORS_UNAVAILABLE[]
        try
            HAND_CURSOR[] = SDL3.CreateSystemCursor(SDL3.SDL_SYSTEM_CURSOR_POINTER)
            ARROW_CURSOR[] = SDL3.CreateSystemCursor(SDL3.SDL_SYSTEM_CURSOR_DEFAULT)
            TEXT_CURSOR[] = SDL3.CreateSystemCursor(SDL3.SDL_SYSTEM_CURSOR_TEXT)
            grab = SDL3.CreateSystemCursor(_SDL_SYSTEM_CURSOR_GRAB)
            grabbing = SDL3.CreateSystemCursor(_SDL_SYSTEM_CURSOR_GRABBING)
            GRAB_CURSOR[] = grab
            GRABBING_CURSOR[] = grabbing
            cross = SDL3.CreateSystemCursor(SDL3.SDL_SYSTEM_CURSOR_CROSSHAIR)
            CROSSHAIR_CURSOR[] = cross
        catch
            # Headless video drivers have no system cursors; the pointer then
            # stays whatever the window manager shows.
            CURSORS_UNAVAILABLE[] = true
        end
        GRAB_CURSOR[] == C_NULL && (GRAB_CURSOR[] = HAND_CURSOR[])
        GRABBING_CURSOR[] == C_NULL && (GRABBING_CURSOR[] = HAND_CURSOR[])
        CROSSHAIR_CURSOR[] == C_NULL && (CROSSHAIR_CURSOR[] = HAND_CURSOR[])
    end
    cursor = ARROW_CURSOR[]
    # An actively-pressed pan surface (`cursor = :grab`) shows the closed
    # grabbing hand wherever the pointer is until release; a `:pan` surface
    # grabs with a non-left button (the workspace's middle-drag) and keeps
    # the plain arrow for left presses (a selection click is not a grab). A
    # pressed `:crosshair` is a creation-tool drag.
    grabbing_now = false
    crosshair_now = false
    for ((_, button), pressable) in ACTIVE_PRESS
        shape = get(pressable.props, :cursor, nothing)
        if shape === :grab
            grabbing_now = true
        elseif shape === :pan
            grabbing_now |= button != 0x01
        elseif shape === :crosshair
            crosshair_now = true
        end
    end
    if grabbing_now
        cursor = GRABBING_CURSOR[]
    elseif crosshair_now
        cursor = CROSSHAIR_CURSOR[]
    elseif HOVERED_ACTIVE[]
        # A hovered pressable that asks for a text pointer (e.g. a TextBox)
        # shows the I-beam; one asking to pan shows the open grab hand; a
        # creation-tool surface shows the crosshair; `:pan`/`:arrow`
        # surfaces keep the plain arrow (only grabbing changes the
        # pointer); everything else hoverable is a clickable control.
        hovered = [get(p.props, :cursor, nothing) for p in values(HOVERED)]
        cursor = :text in hovered ? TEXT_CURSOR[] :
                 :grab in hovered ? GRAB_CURSOR[] :
                 :crosshair in hovered ? CROSSHAIR_CURSOR[] :
                 all(c -> c === :pan || c === :arrow, hovered) ? ARROW_CURSOR[] :
                 HAND_CURSOR[]
    end
    cursor == C_NULL && return nothing
    try
        SDL3.SetCursor(cursor)
    catch err
        # A cosmetic failure (e.g. a stale cursor after a re-init) must never
        # kill the event loop: give up on custom cursors for this session and
        # let the window manager's pointer stay.
        CURSORS_UNAVAILABLE[] = true
        @warn "Rocks: cursor could not be set; staying with the system pointer" exception = err
    end
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
        callback(current.props, :on_leave)
    end
    if pressable !== nothing && pressable.mounted && pressable.host isa PressState
        pressable.host.hovered = true
        callback(pressable.props, :on_hover_in)
        callback(pressable.props, :on_enter)
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
function dispatch_event!(event::SDL3.Event)
    ty = event.type
    if ty == SDL3.SDL_EVENT_QUIT
        quit!()
    elseif ty == SDL3.SDL_EVENT_WINDOW_CLOSE_REQUESTED
        handle_close!(SDL3.as_window(event).windowID)
    elseif ty == SDL3.SDL_EVENT_WINDOW_EXPOSED
        # The window manager wants the window repainted (it was covered,
        # restored, ...).
        mark_window_draw!(SDL3.as_window(event).windowID)
    elseif ty == SDL3.SDL_EVENT_WINDOW_RESIZED ||
           ty == SDL3.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
        # Resized windows are re-laid out and redrawn without re-running
        # components.
        wev = SDL3.as_window(event)
        fiber = get(WINDOW_BY_ID, wev.windowID, nothing)
        if fiber !== nothing && fiber.host isa WindowState
            fiber.host.width = Int(wev.data1)
            fiber.host.height = Int(wev.data2)
            fiber.host.needs_layout = true
            fiber.host.needs_draw = true
        end
    elseif ty == SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN
        mev = SDL3.as_mouse_button(event)
        wid = mev.windowID
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && return
        mx, my = Float64(mev.x), Float64(mev.y)
        button = Int(mev.button)
        LAST_POINTER[wid] = (mx, my)
        # A click sees the modifiers held *at click time* (Shift picks up a
        # multi-select click): refresh the app-visible keymods from SDL.
        # Mouse events do not update SDL's modifier state, so without this a
        # Shift that was pressed and released long before would keep
        # multi-selecting every click until the next key event.
        LAST_KEYMODS[] = SDL3.GetModState()
        # The first click only dismisses open popup menus (Windows gesture).
        close_open_menus!(wid) && return
        target = hit_test(fiber, mx, my)

        # Focus follows the press: the nearest fiber handling keyboard events
        # gets them (the window when nothing in the tree handles them).
        # `focus!` also couples SDL text input activation to the focus.
        focusable = find_focusable(target)
        focusable === FOCUSED[] || focus!(focusable)

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
            ACTIVE_PRESS[(wid, UInt8(button))] = pressable
            pressable.host isa PressState && (pressable.host.pressed = true)
            lx, ly = _locals(pressable, mx, my)
            callback_press!(pressable.props, :on_press_in, lx, ly, button)
            callback_press!(pressable.props, :on_down, lx, ly, button)
            mark_window_draw!(wid)
            update_cursor()
        end
    elseif ty == SDL3.SDL_EVENT_MOUSE_BUTTON_UP
        mev = SDL3.as_mouse_button(event)
        wid = mev.windowID
        if ACTIVE_DRAG[] !== nothing
            drag_end!(ACTIVE_DRAG[])
            ACTIVE_DRAG[] = nothing
            return
        end
        button = Int(mev.button)
        pressable = pop!(ACTIVE_PRESS, (wid, UInt8(button)), nothing)
        pressable === nothing && return
        mx, my = Float64(mev.x), Float64(mev.y)
        pressable.host isa PressState && (pressable.host.pressed = false)
        callback(pressable.props, :on_press_out)
        lx, ly = _locals(pressable, mx, my)
        # `on_up` fires on the area the press started in, even when the
        # pointer has left it (a released-elsewhere up still ends a drag).
        pressable.mounted && is_pressable_kind(pressable.kind) &&
            !Bool(get(pressable.props, :disabled, false)) &&
            callback_press!(pressable.props, :on_up, lx, ly, button)
        if pressable.mounted && is_pressable_kind(pressable.kind) &&
           inside(pressable.rect, mx, my) && !Bool(get(pressable.props, :disabled, false))
            # SDL counts consecutive clicks; a double press routes to the
            # `on_double_press` handler instead of the plain press pair.
            dbl = Int(mev.clicks) >= 2 ?
                  get(pressable.props, :on_double_press, nothing) : nothing
            if dbl !== nothing
                callback_press!(pressable.props, :on_double_press, lx, ly, button)
            else
                callback_press!(pressable.props, :on_press, lx, ly, button)
                callback_press!(pressable.props, :on_click, lx, ly, button)
            end
        end
        mark_window_draw!(wid)
        update_cursor()
    elseif ty == SDL3.SDL_EVENT_MOUSE_MOTION
        mev = SDL3.as_mouse_motion(event)
        wid = mev.windowID
        mx, my = Float64(mev.x), Float64(mev.y)
        LAST_POINTER[wid] = (mx, my)
        if ACTIVE_DRAG[] !== nothing
            drag_update!(ACTIVE_DRAG[], mx, my)
            return
        end
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && (set_hover!(wid, nothing); return)
        # Holding any button over a control and dragging keeps feeding the
        # pressed fiber's on_move/on_drag — press capture ignores which
        # button is down (a `:pan` pan surface pans with the middle button),
        # and the moves keep arriving even when the pointer leaves the area.
        last_pressed = nothing
        for ((w, _), pressed) in ACTIVE_PRESS
            w == wid || continue
            lx, ly = _locals(pressed, mx, my)
            callback_press!(pressed.props, :on_move, lx, ly)
            callback_press!(pressed.props, :on_drag, lx, ly)
            (haskey(pressed.props, :on_move) || haskey(pressed.props, :on_drag)) &&
                mark_window_draw!(wid)
            last_pressed = pressed
        end
        target = hit_test(fiber, mx, my)
        hovered = find_pressable(target)
        set_hover!(wid, hovered)
        # Plain hover motion: the innermost mouse area under the pointer sees
        # moves that are not already delivered through the press capture.
        if hovered !== nothing && hovered !== last_pressed &&
           haskey(hovered.props, :on_move)
            lx, ly = _locals(hovered, mx, my)
            callback_press!(hovered.props, :on_move, lx, ly)
        end
    elseif ty == SDL3.SDL_EVENT_MOUSE_WHEEL
        wev = SDL3.as_mouse_wheel(event)
        wid = wev.windowID
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && return
        x, y = pointer_position(wid)
        dx = Float64(wev.x)
        dy = Float64(wev.y)
        if dx == 0.0 && dy == 0.0
            dx = Float64(wev.integer_x)
            dy = Float64(wev.integer_y)
        end
        if wev.direction == SDL3.SDL_MOUSEWHEEL_FLIPPED
            dx, dy = -dx, -dy
        end
        target = hit_test(fiber, x, y)
        # A fiber with an explicit `:on_wheel` prop (e.g. a MouseArea that
        # zooms) consumes the wheel before scroll containers: the innermost
        # handler wins.
        wheel = find_wheel_target(target)
        if wheel !== nothing && !Bool(get(wheel.props, :disabled, false))
            lx, ly = _locals(wheel, x, y)
            callback_wheel!(wheel.props, dx, dy, lx, ly)
            mark_window_draw!(wid)
            return
        end
        scroll = find_scrollable(target)
        scroll === nothing && return
        scroll_by!(scroll, dx, dy)
    elseif ty == SDL3.SDL_EVENT_KEY_DOWN
        kev = SDL3.as_keyboard(event)
        fiber = get(WINDOW_BY_ID, kev.windowID, nothing)
        fiber === nothing && return
        target = keyboard_target(fiber)
        key = SDL3.GetKeyName(kev.key)
        LAST_KEYMODS[] = kev.mod
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
                    handled = mf(key, Int(kev.mod))
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
    elseif ty == SDL3.SDL_EVENT_KEY_UP
        kev = SDL3.as_keyboard(event)
        fiber = get(WINDOW_BY_ID, kev.windowID, nothing)
        fiber === nothing && return
        target = keyboard_target(fiber)
        key = SDL3.GetKeyName(kev.key)
        LAST_KEYMODS[] = SDL3.GetModState()
        callback(target.props, :on_key_up, key)
    elseif ty == SDL3.SDL_EVENT_TEXT_INPUT
        tev = SDL3.as_text_input(event)
        fiber = get(WINDOW_BY_ID, tev.windowID, nothing)
        fiber === nothing && return
        text = tev.text == C_NULL ? "" : unsafe_string(tev.text)
        target = keyboard_target(fiber)
        callback(target.props, :on_text_input, text)
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
        SDL3.HideWindow(fiber.host.ptr)
        fiber.hidden = true
    end
    return nothing
end
