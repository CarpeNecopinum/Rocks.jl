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

const HAND_CURSOR = Ref{Ptr{SDL_Cursor}}(C_NULL)
const ARROW_CURSOR = Ref{Ptr{SDL_Cursor}}(C_NULL)

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
    (x < rx || y < ry || x >= rx + rw || y >= ry + rh) && return nothing
    for child in reverse(fiber.children)
        is_window(child) && continue
        found = hit_test(child, x, y)
        found !== nothing && return found
    end
    return fiber
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

function update_cursor()
    if HAND_CURSOR[] == C_NULL
        HAND_CURSOR[] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_HAND)
        ARROW_CURSOR[] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW)
    end
    SDL_SetCursor(HOVERED_ACTIVE[] ? HAND_CURSOR[] : ARROW_CURSOR[])
    return nothing
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
    request_render()
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
        elseif wev == SDL_WINDOWEVENT_RESIZED || wev == SDL_WINDOWEVENT_SIZE_CHANGED
            fiber = get(WINDOW_BY_ID, wid, nothing)
            if fiber !== nothing && fiber.host isa WindowState
                fiber.host.width = Int(event.window.data1)
                fiber.host.height = Int(event.window.data2)
                request_render()
            end
        end
    elseif ty == SDL_MOUSEBUTTONDOWN
        wid = event.button.windowID
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && return
        mx, my = event.button.x, event.button.y
        target = hit_test(fiber, mx, my)
        pressable = find_pressable(target)
        if pressable !== nothing && !Bool(get(pressable.props, :disabled, false))
            ACTIVE_PRESS[(wid, event.button.button)] = pressable
            pressable.host isa PressState && (pressable.host.pressed = true)
            callback(pressable.props, :on_press_in)
            request_render()
        end
    elseif ty == SDL_MOUSEBUTTONUP
        wid = event.button.windowID
        pressable = pop!(ACTIVE_PRESS, (wid, event.button.button), nothing)
        pressable === nothing && return
        mx, my = event.button.x, event.button.y
        pressable.host isa PressState && (pressable.host.pressed = false)
        callback(pressable.props, :on_press_out)
        if pressable.mounted && pressable.kind === _PRESSABLE &&
           inside(pressable.rect, mx, my) && !Bool(get(pressable.props, :disabled, false))
            callback(pressable.props, :on_press)
        end
        request_render()
    elseif ty == SDL_MOUSEMOTION
        wid = event.motion.windowID
        fiber = get(WINDOW_BY_ID, wid, nothing)
        fiber === nothing && (set_hover!(wid, nothing); return)
        mx, my = event.motion.x, event.motion.y
        target = hit_test(fiber, mx, my)
        set_hover!(wid, find_pressable(target))
    elseif ty == SDL_KEYDOWN
        fiber = get(WINDOW_BY_ID, event.key.windowID, nothing)
        fiber === nothing && return
        key = unsafe_string(SDL_GetKeyName(event.key.keysym.sym))
        callback(fiber.props, :on_key, key)
    elseif ty == SDL_KEYUP
        fiber = get(WINDOW_BY_ID, event.key.windowID, nothing)
        fiber === nothing && return
        key = unsafe_string(SDL_GetKeyName(event.key.keysym.sym))
        callback(fiber.props, :on_key_up, key)
    elseif ty == SDL_TEXTINPUT
        fiber = get(WINDOW_BY_ID, event.text.windowID, nothing)
        fiber === nothing && return
        # The text field is a fixed 32-byte UTF-8 buffer.
        chars = UInt8[]
        for b in event.text.text
            b == 0 && break
            push!(chars, UInt8(b & 0xff))
        end
        callback(fiber.props, :on_text_input, String(chars))
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
    # Hide the window; the fiber stays mounted and is shown again when its
    # element is re-rendered.
    if fiber.host isa WindowState
        SDL_HideWindow(fiber.host.ptr)
        fiber.hidden = true
    end
    request_render()
    return nothing
end
