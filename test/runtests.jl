using Test
using Rocks
using ColorTypes: RGB, RGBA
using SimpleDirectMediaLayer.LibSDL2:
    SDL_PollEvent,
    SDL_PushEvent,
    SDL_GetWindowTitle,
    SDL_GetWindowPosition,
    SDL_GetMouseState,
    SDL_SaveBMP_RW,
    SDL_RWFromFile,
    SDL_CreateRGBSurfaceWithFormat,
    SDL_FillRect,
    SDL_MapRGB,
    SDL_FreeSurface,
    SDL_GetError,
    SDL_ConvertSurfaceFormat,
    IMG_Load,
    SDL_PIXELFORMAT_RGBA32,
    SDL_PIXELFORMAT_RGB24,
    SDL_SCANCODE_ESCAPE,
    SDLK_ESCAPE
import Rocks: Text, Element, Window, Box, Pressable, Row, Column

# All GUI-ish tests run against SDL's dummy video driver, so they work
# without a display.
ENV["SDL_VIDEODRIVER"] = "dummy"

# Render `app` (a component function) into a fiber tree, run mount effects,
# call `f(root)` and tear everything down afterwards.
function with_tree(f, app; kwargs...)
    Rocks.RUNNING[] = true
    Rocks.DIRTY[] = true
    Rocks.init_backend()
    root = Rocks.create_root(app, values(kwargs))
    Rocks.perform_render!(root)
    Rocks.run_effects!()
    try
        f(root)
    finally
        Rocks.RUNNING[] = false
        Rocks.unmount!(root)
        Rocks.shutdown_backend()
    end
end

# Create OS windows for all window fibers of the tree and lay them out —
# what one dirty frame of the render loop does.
function sync_windows!(root)
    windows = Rocks.collect_windows!(Rocks.Fiber[], root)
    for w in windows
        w.host isa Rocks.WindowState || Rocks.create_window!(w)
        Rocks.sync_window!(w)
        Rocks.measure!(w)
        Rocks.place!(w, 0.0, 0.0)
    end
    return windows
end

drain_events!() = begin
    ev = Ref{Rocks.SDL_Event}()
    while SDL_PollEvent(ev) == 1
        Rocks.dispatch_event!(ev[])
    end
end

# (r, g, b, a) of the pixel at (x, y) of a PNG file.
function png_pixel(path, x, y)
    surf = IMG_Load(path)
    surf == C_NULL && error("could not load $path: $(unsafe_string(SDL_GetError()))")
    conv = SDL_ConvertSurfaceFormat(surf, UInt32(SDL_PIXELFORMAT_RGBA32), UInt32(0))
    SDL_FreeSurface(surf)
    conv == C_NULL && error("could not convert surface for $path")
    s = unsafe_load(conv)
    bytes = unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(s.pixels), Int(s.pitch) * Int(s.h))
    i = (y - 1) * Int(s.pitch) + 4 * (x - 1)
    px = (bytes[i+1], bytes[i+2], bytes[i+3], bytes[i+4])
    SDL_FreeSurface(conv)
    return px
end

function push_mouse!(fiber, type, x, y; button = 1)
    window = fiber
    while !Rocks.is_window(window)
        window = window.parent
    end
    ev = Ref{Rocks.SDL_Event}()
    p = Base.unsafe_convert(Ptr{Rocks.SDL_Event}, ev)
    Rocks.setproperty!(p, :type, UInt32(type))
    mouse = Rocks.SDL_MouseButtonEvent(
        UInt32(type),
        UInt32(0),
        UInt32(window.host.id),
        UInt32(0),
        UInt8(button),
        UInt8(1),
        UInt8(1),
        UInt8(0),
        Int32(x),
        Int32(y),
    )
    unsafe_store!(Rocks.getproperty(p, :button), mouse)
    @assert SDL_PushEvent(p) >= 0
    return nothing
end

function push_window_event!(fiber, wev; data1 = 0, data2 = 0)
    ev = Ref{Rocks.SDL_Event}()
    p = Base.unsafe_convert(Ptr{Rocks.SDL_Event}, ev)
    Rocks.setproperty!(p, :type, UInt32(Rocks.SDL_WINDOWEVENT))
    window_event = Rocks.SDL_WindowEvent(
        UInt32(Rocks.SDL_WINDOWEVENT),
        UInt32(0),
        UInt32(fiber.host.id),
        UInt8(wev),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        Int32(data1),
        Int32(data2),
    )
    unsafe_store!(Rocks.getproperty(p, :window), window_event)
    @assert SDL_PushEvent(p) >= 0
    return nothing
end

center_of(fiber) = (
    round(Int, fiber.rect[1] + fiber.rect[3] / 2),
    round(Int, fiber.rect[2] + fiber.rect[4] / 2),
)

fmt(r) = "(" * join(round.(Int, collect(r)), ", ") * ")"

@testset "Rocks" begin
    @testset "elements" begin
        el = @rock Box(@rock Text("a"), @rock Text("b"); direction = :row, gap = 8)
        @test el.kind === Box
        @test el.props[:direction] === :row
        @test el.props[:gap] == 8
        @test length(el.children) == 2
        @test all(c -> c isa Element, el.children)
        @test el.children[1].kind === Text

        # string children are stringified, nothing/false are skipped
        el = @rock Text("Count: ", 42, nothing, false && @rock Text("no"))
        @test el.children[1] == "Count: "
        @test el.children[2] == 42

        # keys are stored as props
        el = @rock Text("x"; key = "k1", color = (1, 0, 0))
        @test el.props[:key] == "k1"

        # an element whose kind is another element (e.g. from calling a
        # component inside an element constructor by hand) errors with a hint
        inner = @rock Window(@rock Text("second"); title = "Second")
        broken_el = Element(inner, Rocks.props_dict(), Any[])
        @test_throws "but got an already-created Element. The element already " *
                     "describes a `Window`" Rocks.create_fiber(broken_el, nothing)

        # splatted props after the semicolon (`kwargs...` idiom)
        extra = (x = 7, y = 9)
        el = @rock Window(@rock Text("a"); title = "t", extra...)
        @test el.props[:x] == 7 && el.props[:y] == 9 && el.props[:title] == "t"
        @test length(el.children) == 1 # the splat must not become children

        # the old @rock(Kind, children...) syntax errors with guidance
        @test_throws LoadError include_string(Main, "@rock(Text, \"hello\")")
    end

    @testset "components" begin
        calls = Ref(0)
        function Widget(; label = "n/a", children = Any[])
            calls[] += 1
            @test label == "hello"
            @test length(children) == 1
            @rock Box(children...)
        end

        with_tree(@rock Widget(@rock Text("child"); label = "hello")) do root
            @test calls[] == 1
            # the root fiber wraps the element tree of the component
            @test root.kind === Widget
        end
    end

    @testset "hooks" begin
        log = String[]
        function App()
            count = @use Observable(0)
            useEffect(() -> push!(log, "mount:$(count[])"), ())
            useEffect(() -> push!(log, "render:$(count[])"))
            useEffect(() -> push!(log, "dep:$(count[])"), (count[],))
            ref = @use Ref(0)
            memo = useMemo(() -> count[] * 10, (count[],))
            @rock Box(@rock Text("count: ", count[], " memo: ", memo, " ref: ", ref[]))
        end

        with_tree(App) do root
            @test log == ["mount:0", "render:0", "dep:0"]
            text = root.children[1].children[1]
            @test Rocks.text_content(text) == "count: 0 memo: 0 ref: 0"

            # set the observable (the hook state holds it)
            count = root.hooks[1].value
            @test count isa Observable
            count[] = 2
            @test count[] == 2
            count[] += 1
            @test count[] == 3
            # setting an identical value does not trigger a re-render
            Rocks.DIRTY[] = false
            count[] = 3
            @test Rocks.DIRTY[] == false
            count[] = 4
            @test Rocks.DIRTY[] == true

            Rocks.perform_render!(root)
            Rocks.run_effects!()
            # no-deps effect ran every render; deps effect only on change
            @test log == ["mount:0", "render:0", "dep:0", "render:4", "dep:4"]
            @test Rocks.text_content(root.children[1].children[1]) ==
                  "count: 4 memo: 40 ref: 0"
        end
    end

    @testset "@use" begin
        # local state via Observable
        function App()
            count = @use Observable(0)
            @rock Box(@rock Text("count: ", count[]))
        end
        with_tree(App) do root
            count = root.hooks[1].value
            @test count[] == 0
            @test Rocks.text_content(root.children[1].children[1]) == "count: 0"
            Rocks.DIRTY[] = false
            count[] = 3
            @test Rocks.DIRTY[] == true # setting triggers a re-render
            Rocks.perform_render!(root)
            @test Rocks.text_content(root.children[1].children[1]) == "count: 3"
        end

        # refs are silent
        function RefApp()
            r = @use Ref(0)
            @rock Box(@rock Text("ref: ", r[]))
        end
        with_tree(RefApp) do root
            r = root.hooks[1].value
            Rocks.DIRTY[] = false
            r[] = 5
            @test Rocks.DIRTY[] == false # refs do not trigger re-renders
            @test r[] == 5
            Rocks.perform_render!(root)
            @test Rocks.text_content(root.children[1].children[1]) == "ref: 5"
        end

        # the expression is evaluated exactly once (on the first render)
        evals = Ref(0)
        function OnceApp()
            x = @use begin
                evals[] += 1
                Observable(0)
            end
            @rock Box(@rock Text("x: ", x[]))
        end
        with_tree(OnceApp) do root
            @test evals[] == 1
            Rocks.perform_render!(root)
            Rocks.perform_render!(root)
            @test evals[] == 1 # not re-evaluated on re-renders
        end

        # shared/global observables; unmounting unsubscribes
        shared = Observable(0)
        function SharedApp()
            x = @use shared
            @rock Box(@rock Text("shared: ", x[]))
        end
        with_tree(SharedApp) do root
            @test Rocks.text_content(root.children[1].children[1]) == "shared: 0"
            Rocks.DIRTY[] = false
            shared[] = 1
            @test Rocks.DIRTY[] == true # subscribed while mounted
            Rocks.perform_render!(root)
            @test Rocks.text_content(root.children[1].children[1]) == "shared: 1"
        end
        Rocks.DIRTY[] = false
        shared[] = 2
        @test Rocks.DIRTY[] == false # unsubscribed after unmount

        # derived sub-state with map: re-renders only when it changes
        state = Observable((a = 1, b = 2))
        effect_runs = Ref(0)
        function SubApp()
            b = @use map(s -> s.b, state)
            useEffect(() -> (effect_runs[] += 1), (b[],))
            @rock Box(@rock Text("b: ", b[]))
        end
        with_tree(SubApp) do root
            @test effect_runs[] == 1
            Rocks.DIRTY[] = false
            state[] = (a = 5, b = 2) # b unchanged -> no re-render
            @test Rocks.DIRTY[] == false
            @test effect_runs[] == 1
            state[] = (a = 5, b = 9) # b changed -> re-render
            @test Rocks.DIRTY[] == true
            Rocks.perform_render!(root)
            Rocks.run_effects!()
            @test effect_runs[] == 2
            @test Rocks.text_content(root.children[1].children[1]) == "b: 9"
        end

        # unmounting runs the observable subscription cleanup
        obs = Observable(0)
        hook_obs = nothing
        function CleanupApp()
            x = @use obs
            hook_obs = x
            @rock Box(@rock Text("x: ", x[]))
        end
        with_tree(CleanupApp) do root
            @test length(obs.listeners) == 1
        end
        @test length(obs.listeners) == 0 # unsubscribed on unmount
    end

    @testset "effect cleanup on unmount" begin
        log = String[]
        function App()
            useEffect(() -> () -> push!(log, "cleanup"), ())
            @rock Box()
        end
        with_tree(App) do root
            @test isempty(log)
        end
        @test log == ["cleanup"]
    end

    @testset "reconciler" begin
        function App()
            which = @use Observable(:a)
            @rock Box(which[] === :a ? (@rock Text("A")) : (@rock Box(@rock Text("B"))))
        end
        with_tree(App) do root
            box = root.children[1]
            @test box.kind === Box
            @test box.children[1].kind === Text # slot holds Text first
            which = root.hooks[1].value
            which[] = :b
            Rocks.perform_render!(root)
            @test box.children[1].kind === Box # kind change => new fiber
            @test Rocks.text_content(box.children[1].children[1]) == "B"
        end

        # growing and shrinking lists
        function List()
            n = @use Observable(1)
            @rock Column((@rock Text("item ", i) for i in 1:n[])...)
        end
        with_tree(List) do root
            box = root.children[1].children[1] # Column -> Box
            @test length(box.children) == 1
            n = root.hooks[1].value
            n[] = 3
            Rocks.perform_render!(root)
            @test length(box.children) == 3
            n[] = 2
            Rocks.perform_render!(root)
            @test length(box.children) == 2
        end
    end

    @testset "layout" begin
        function App()
            @rock Window(
                @rock Column(
                    @rock Text("hello"; size = 16),
                    @rock Row(
                        @rock Pressable(@rock Text("A"); padding = 8),
                        @rock Pressable(@rock Text("B"); padding = 8);
                        gap = 6);
                    gap = 4);
                title = "layout", width = 400, height = 300,
                padding = 20, gap = 8, align = :center)
        end
        with_tree(App) do root
            windows = sync_windows!(root)
            @test length(windows) == 1
            w = windows[1]
            @test w.rect[3] == 400 && w.rect[4] == 300

            col = w.children[1].children[1] # Column -> Box
            text = col.children[1]
            rowbox = col.children[2].children[1] # Row component -> Box
            pa, pb = rowbox.children

            # window aligns the column box (60px wide) centered
            @test fmt(col.rect) == "(170, 20, 60, 58)"
            # text measured with the font
            @test text.measured[1] > 0
            @test text.rect[1] == 170
            # children stacked with gap 4: text 19px high, then row
            @test rowbox.rect[2] == 20 + 19 + 4
            # pressables side by side with gap 6
            @test pb.rect[1] == pa.rect[1] + pa.rect[3] + 6
            # pressables have padding around their text
            @test pa.rect[3] == pa.children[1].measured[1] + 16

            # hit testing finds the deepest node and bubbles to the pressable
            cx, cy = center_of(pb)
            @test Rocks.hit_test(w, cx, cy).kind === Text
            @test Rocks.find_pressable(Rocks.hit_test(w, cx, cy)) === pb
            @test Rocks.hit_test(w, 5, 5) === w
        end
    end

    @testset "headless run" begin
        renders = Ref(0)
        ticks = Ref(0)
        function App()
            useTimeout(quit!, 250)
            useInterval(() -> (ticks[] += 1), 50)
            renders[] += 1
            @rock Window(@rock Text("ticks: ", ticks[]); title = "t", width = 200, height = 100)
        end
        t0 = time()
        render(App)
        dt = time() - t0
        @test dt < 10 # did not hang
        @test renders[] >= 2
        @test ticks[] >= 2
    end

    @testset "pointer events" begin
        clicks = Ref(0)
        pressed_log = Ref(0)
        hover_log = Ref(0)
        function App()
            n = @use Observable(0)
            @rock Window(
                @rock Pressable(
                    @rock Text("clicked ", n[], " times");
                    on_press = () -> (clicks[] += 1; n[] += 1),
                    on_press_in = () -> (pressed_log[] += 1),
                    on_hover_in = () -> (hover_log[] += 1),
                    padding = 10);
                title = "events", width = 300, height = 200)
        end
        with_tree(App) do root
            windows = sync_windows!(root)
            w = windows[1]
            pressable = w.children[1]
            cx, cy = center_of(pressable)

            push_mouse!(pressable, Rocks.SDL_MOUSEBUTTONDOWN, cx, cy)
            drain_events!()
            @test pressable.host.pressed == true
            @test pressed_log[] == 1

            push_mouse!(pressable, Rocks.SDL_MOUSEBUTTONUP, cx, cy)
            drain_events!()
            @test clicks[] == 1
            @test pressable.host.pressed == false

            # motion triggers hover
            push_mouse!(pressable, Rocks.SDL_MOUSEMOTION, cx, cy)
            drain_events!()
            @test pressable.host.hovered == true
            @test hover_log[] == 1

            # release far away: no press
            push_mouse!(pressable, Rocks.SDL_MOUSEBUTTONDOWN, cx, cy)
            drain_events!()
            push_mouse!(pressable, Rocks.SDL_MOUSEBUTTONUP, 280, 180)
            drain_events!()
            @test clicks[] == 1

            # outside the pressable entirely: nothing happens
            push_mouse!(pressable, Rocks.SDL_MOUSEBUTTONDOWN, 290, 190)
            push_mouse!(pressable, Rocks.SDL_MOUSEBUTTONUP, 290, 190)
            drain_events!()
            @test clicks[] == 1

            # the state update re-rendered the label
            Rocks.perform_render!(root)
            Rocks.run_effects!()
            @test Rocks.text_content(pressable.children[1]) == "clicked 1 times"
        end
    end

    @testset "pressable styling" begin
        function App()
            @rock Window(
                @rock Pressable(
                    @rock Text("btn");
                    background = (0.2, 0.45, 0.95),
                    hover_background = (0.25, 0.52, 1.0),
                    pressed_background = (0.16, 0.38, 0.82),
                    padding = 10);
                title = "styling", width = 200, height = 100)
        end
        with_tree(App) do root
            w = sync_windows!(root)[1]
            pressable = w.children[1]
            @test Rocks.background_for(pressable) == (0.2, 0.45, 0.95)

            # drawing in every state must not error (hover styling used to
            # crash the draw pass)
            Rocks.draw_window!(w)
            pressable.host.hovered = true
            @test Rocks.background_for(pressable) == (0.25, 0.52, 1.0)
            Rocks.draw_window!(w)
            pressable.host.pressed = true
            @test Rocks.background_for(pressable) == (0.16, 0.38, 0.82)
            Rocks.draw_window!(w)
            pressable.host.hovered = false
            @test Rocks.background_for(pressable) == (0.16, 0.38, 0.82)
        end
    end

    @testset "multi-window" begin
        function Dialog(; children = Any[])
            @rock Window(@rock Text("dialog"); title = "Dialog", width = 250, height = 150)
        end
        function App()
            open = @use Observable(false)
            @rock Column(
                @rock Window(
                    @rock Text("main"),
                    @rock Pressable(@rock Text("toggle"); on_press = () -> open[] = !open[]);
                    title = "Main", width = 300, height = 200),
                open[] && @rock Dialog();
                padding = 0)
        end
        with_tree(App) do root
            windows = sync_windows!(root)
            @test length(windows) == 1
            @test unsafe_string(SDL_GetWindowTitle(windows[1].host.ptr)) == "Main"

            open = root.hooks[1].value
            open[] = true
            Rocks.perform_render!(root)
            Rocks.run_effects!()
            windows = sync_windows!(root)
            @test length(windows) == 2
            titles = Set(unsafe_string(SDL_GetWindowTitle(w.host.ptr)) for w in windows)
            @test titles == Set(["Main", "Dialog"])

            open[] = false
            Rocks.perform_render!(root)
            Rocks.run_effects!()
            windows = sync_windows!(root)
            @test length(windows) == 1
            @test length(Rocks.WINDOW_BY_ID) == 1
        end
    end

    @testset "draw scheduling" begin
        function App()
            @rock Window(
                @rock Pressable(@rock Text("btn"); padding = 10);
                title = "sched", width = 200, height = 100, resizable = true)
        end
        with_tree(App) do root
            w = sync_windows!(root)[1]
            state = w.host
            state.needs_draw = false

            # exposure marks the window for redraw
            push_window_event!(w, Rocks.SDL_WINDOWEVENT_EXPOSED)
            drain_events!()
            @test state.needs_draw == true
            state.needs_draw = false

            # resize updates the size and marks for re-layout + redraw
            push_window_event!(w, Rocks.SDL_WINDOWEVENT_RESIZED; data1 = 320, data2 = 240)
            drain_events!()
            @test state.width == 320 && state.height == 240
            @test state.needs_layout == true && state.needs_draw == true

            # hover motion over the pressable marks for redraw
            state.needs_draw = false
            state.needs_layout = false
            cx, cy = center_of(w.children[1])
            push_mouse!(w, Rocks.SDL_MOUSEMOTION, cx, cy)
            drain_events!()
            @test state.needs_draw == true
            @test state.needs_layout == false # no re-layout on hover
            @test w.children[1].host.hovered == true

            # motion over empty space with unchanged hover state: no redraw
            state.needs_draw = false
            push_mouse!(w, Rocks.SDL_MOUSEMOTION, cx, cy)
            drain_events!()
            @test state.needs_draw == false

            # event_wait_timeout_ms is bounded by the next due timer
            @test Rocks.event_wait_timeout_ms() == 250 # no timers
            Rocks.add_timer(() -> nothing, 50; repeating = true)
            @test 0 <= Rocks.event_wait_timeout_ms() <= 50
            empty!(Rocks.TIMERS)
            @test Rocks.event_wait_timeout_ms() == 250
        end
    end

    @testset "window positioning" begin
        # NOTE: the dummy video driver ignores requested positions (it centers
        # and cascades windows itself), so these tests assert the positions
        # Rocks *requests* (`window_position`), which is the logic under test.
        Rocks.RUNNING[] = true
        Rocks.init_backend()
        try
            function window_fiber(; kwargs...)
                el = @rock Window(@rock Text("x"); title = "pos", width = 200, height = 100, kwargs...)
                f = Rocks.create_fiber(el, nothing)
                Rocks.perform_render!(f)
                f
            end

            # x/y without position implies :manual
            f1 = window_fiber(x = 123, y = 45)
            @test Rocks.window_position(f1) == (123, 45)

            # explicit :manual
            f2 = window_fiber(position = :manual, x = 50, y = 60)
            @test Rocks.window_position(f2) == (50, 60)

            # :mouse puts the top-left corner at the pointer
            f3 = window_fiber(position = :mouse)
            mx, my = Ref{Cint}(0), Ref{Cint}(0)
            SDL_GetMouseState(mx, my)
            @test Rocks.window_position(f3) == (Int(mx[]), Int(my[]))

            # :centered places the window in the middle of the display bounds
            f4 = window_fiber(position = :centered)
            bx, by, bw, bh = Rocks.display_bounds(nothing)
            @test Rocks.window_position(f4) ==
                  (bx + (bw - 200) ÷ 2, by + (bh - 100) ÷ 2)

            # :cascade offsets successive windows by 32px
            f5 = window_fiber(position = :cascade)
            p5 = Rocks.window_position(f5)
            Rocks.create_window!(f5)
            f6 = window_fiber(position = :cascade)
            p6 = Rocks.window_position(f6)
            Rocks.create_window!(f6)
            @test p6[1] - p5[1] == 32
            @test p6[2] - p5[2] == 32

            # explicit display index is honored
            f7 = window_fiber(position = :centered, display = 0)
            @test Rocks.window_position(f7) ==
                  (bx + (bw - 200) ÷ 2, by + (bh - 100) ÷ 2)

            for f in (f5, f6)
                Rocks.destroy_window!(f)
            end
        finally
            Rocks.RUNNING[] = false
            Rocks.shutdown_backend()
        end
    end

    @testset "widgets" begin
        # Button variants (components are plain functions — call them directly)
        b = Button(; label = "Save", variant = :contained, color = :primary)
        @test b.kind === Pressable
        @test b.props[:background] == Rocks.ACCENTS[:primary]
        outlined = Button(; label = "Cancel", variant = :outlined, color = :error)
        @test outlined.props[:background] === nothing
        @test outlined.props[:border_color] == Rocks.ACCENTS[:error]
        @test outlined.props[:border_width] == 1
        textbtn = Button(; label = "Text", variant = :text)
        @test textbtn.props[:border_color] === nothing
        disabled = Button(; label = "Off", disabled = true)
        @test disabled.props[:disabled] == true

        # Checkbox flips its observable and fires on_change
        checked = Observable(false)
        changed = Ref(0)
        cb = Checkbox(; label = "grid", value = checked, on_change = () -> (changed[] += 1))
        with_tree(cb) do root
            @test root.kind === Pressable
            root.props[:on_press]()
            @test checked[] == true
            @test changed[] == 1
            root.props[:on_press]()
            @test checked[] == false
        end

        # Toggle
        on = Observable(false)
        tg = Toggle(; value = on)
        with_tree(tg) do root
            root.props[:on_press]()
            @test on[] == true
            root.props[:on_press]()
            @test on[] == false
        end

        # RadioGroup selects an index
        sel = Observable(2)
        changed = Ref(0)
        rg = RadioGroup(; options = ["Small", "Medium", "Large"], selected = sel,
                        on_change = () -> (changed[] += 1))
        with_tree(rg) do root
            @test length(root.children) == 3
            root.children[1].props[:on_press]()
            @test sel[] == 1
            @test changed[] == 1
        end

        # DropDownMenu opens, selects and closes (uses @use internally, so it
        # needs a component context)
        sel = Observable(1)
        changed = Ref(0)
        function MenuApp()
            DropDownMenu(; options = ["Sans", "Serif"], selected = sel,
                         on_change = () -> (changed[] += 1))
        end
        with_tree(MenuApp) do root
            menu = root.children[1] # the DropDownMenu's outer Box
            @test length(menu.children) == 1 # menu closed: only the toggle
            menu.children[1].props[:on_press]() # open the menu
            Rocks.perform_render!(root)
            @test length(menu.children) == 2 # toggle + expanded list
            list = menu.children[2]
            @test length(list.children) == 2
            list.children[2].props[:on_press]() # pick "Serif"
            @test sel[] == 2
            @test changed[] == 1
        end

        # Tabber switches content by index (the component must re-run, so it
        # is wrapped in a component function)
        tab = Observable(1)
        function TabApp()
            Tabber(; tabs = ["A", "B"], selected = tab,
                   children = [@rock Text("one"), @rock Text("two")])
        end
        with_tree(TabApp) do root
            box = root.children[1] # the Tabber's outer Box
            @test length(box.children) == 2 # tab bar + content
            @test Rocks.text_content(box.children[2]) == "one"
            tab[] = 2
            Rocks.perform_render!(root)
            @test Rocks.text_content(box.children[2]) == "two"
        end

        # ProgressBar tracks its observable
        progress = Observable(0.0)
        function ProgressApp()
            ProgressBar(; value = progress, width = 100, height = 10)
        end
        with_tree(ProgressApp) do root
            bar = root.children[1] # the track
            @test bar.kind === Box
            @test bar.props[:background] == (0.25, 0.25, 0.29)
            @test bar.children[1].props[:width] == 0 # the fill
            progress[] = 0.5
            Rocks.perform_render!(root)
            @test bar.children[1].props[:width] == 50
        end

        # widgets need Observable props
        @test_throws "Checkbox needs an `Observable`" Checkbox(; value = false)
        @test_throws "Toggle needs an `Observable`" Toggle(; value = true)
        @test_throws "ProgressBar needs an `Observable`" ProgressBar(; value = 0.5)
    end

    @testset "split and slider" begin
        ratio = Observable(0.5)
        value = Observable(0.5)
        function App()
            @rock Window(
                @rock Split(
                    @rock Box(; background = (0.3, 0.3, 0.35), children = [@rock Text("left")]),
                    @rock Box(; background = (0.2, 0.2, 0.25), children = [@rock Text("right")]);
                    direction = :horizontal, ratio = ratio,
                    width = 400, height = 300),
                @rock Slider(; value = value, width = 200);
                title = "split", width = 500, height = 400,
                padding = 10, gap = 10)
        end
        with_tree(App) do root
            windows = sync_windows!(root)
            @test length(windows) == 1
            w = windows[1]
            split = w.children[1]
            @test split.kind === Split
            st = split.host
            @test st isa Rocks.SplitState

            # panes fill their sides: split width 400, handle 6 -> 197 each
            pane1, pane2 = split.children
            @test pane1.rect[1] == 10 && pane1.rect[3] == 197
            @test pane2.rect[1] == 10 + 197 + 6
            @test pane2.rect[3] == 197

            # dragging the handle resizes the panes (ratio observable updated)
            hx, hy = round(Int, st.handle_rect[1] + st.handle_rect[3] / 2),
                     round(Int, st.handle_rect[2] + st.handle_rect[4] / 2)
            push_mouse!(split, Rocks.SDL_MOUSEBUTTONDOWN, hx, hy)
            drain_events!()
            @test Rocks.ACTIVE_DRAG[] === split
            push_mouse!(split, Rocks.SDL_MOUSEMOTION, hx + 95, hy) # +95px => ratio ~0.75
            drain_events!()
            @test Rocks.ACTIVE_DRAG[] === split
            push_mouse!(split, Rocks.SDL_MOUSEBUTTONUP, hx + 95, hy)
            drain_events!()
            @test Rocks.ACTIVE_DRAG[] === nothing
            @test ratio[] > 0.6
            sync_windows!(root) # re-layout after the drag
            @test split.children[1].rect[3] > 197 # the left pane grew

            # the slider: clicking sets its value from the x position
            slider = w.children[2]
            @test slider.kind === Slider
            sx, sy = round(Int, slider.rect[1] + slider.rect[3] / 2),
                     round(Int, slider.rect[2] + slider.rect[4] / 2)
            push_mouse!(slider, Rocks.SDL_MOUSEBUTTONDOWN, sx, sy)
            drain_events!()
            push_mouse!(slider, Rocks.SDL_MOUSEBUTTONUP, sx, sy)
            drain_events!()
            @test 0.45 <= value[] <= 0.55
        end
    end

    @testset "image" begin
        # load a generated BMP through the Image element
        path = joinpath(tempdir(), "rocks-test-image.bmp")
        Rocks.init_backend()
        surface = SDL_CreateRGBSurfaceWithFormat(0, 16, 8, 24, SDL_PIXELFORMAT_RGB24)
        SDL_FillRect(surface, C_NULL, SDL_MapRGB(unsafe_load(surface).format, 200, 100, 50))
        rw = SDL_RWFromFile(path, "wb")
        @assert SDL_SaveBMP_RW(surface, rw, 1) == 0 # frees the RWops
        SDL_FreeSurface(surface)

        el = @rock Image(; src = path)
        f = Rocks.create_fiber(el, nothing)
        Rocks.perform_render!(f)
        # the image loads at measure/draw time and reports its natural size
        @test Rocks.measure_image(f) == (16.0, 8.0)
        # scaled: width 32 -> height scales by aspect (32 * 8/16 = 16)
        el2 = @rock Image(; src = path, width = 32)
        f2 = Rocks.create_fiber(el2, nothing)
        Rocks.perform_render!(f2)
        @test Rocks.measure_image(f2) == (32.0, 16.0)

        # drawing creates the texture through the window's renderer
        win = @rock Window(@rock Image(; src = path); width = 100, height = 100)
        wroot = Rocks.create_root(win, NamedTuple())
        Rocks.perform_render!(wroot)
        windows = sync_windows!(wroot)
        Rocks.draw_window!(windows[1]) # the texture is created at draw time
        img = windows[1].children[1]
        @test img.kind === Image
        @test img.host isa Rocks.ImageState
        @test img.host.texture != C_NULL

        for w in windows
            Rocks.destroy_window!(w)
        end
        Rocks.unmount!(wroot)
        delete!(Rocks.IMAGE_SURFACES, path)
        rm(path; force = true)
    end

    @testset "context" begin
        Theme = createContext((dark = false,))
        theme_obs = Observable((dark = true,))

        function Consumer()
            theme = @use Theme
            dark = theme isa Observable ? theme[].dark : theme.dark
            @rock Box(@rock Text("dark: ", string(dark)))
        end

        # no provider -> the context default
        with_tree(Consumer) do root
            @test Rocks.text_content(root.children[1].children[1]) == "dark: false"
        end

        # provider with an Observable value; setting it re-renders the consumer
        function ProviderApp()
            @rock Theme.provider(
                @rock Consumer();
                value = theme_obs)
        end
        with_tree(ProviderApp) do root
            consumer = root.children[1].children[1] # Provider -> Consumer
            @test Rocks.text_content(consumer.children[1].children[1]) == "dark: true"
            @test length(theme_obs.listeners) == 1 # subscribed via @use
            Rocks.DIRTY[] = false
            theme_obs[] = (dark = false,)
            @test Rocks.DIRTY[] == true
            Rocks.perform_render!(root)
            @test Rocks.text_content(consumer.children[1].children[1]) == "dark: false"
        end
        Rocks.DIRTY[] = false
        theme_obs[] = (dark = true,)
        @test Rocks.DIRTY[] == false # unsubscribed after unmount

        # nested providers: the nearest one wins; plain values work too
        function NestedApp()
            @rock Theme.provider(
                @rock Theme.provider(
                    @rock Consumer();
                    value = (dark = false,));
                value = (dark = true,))
        end
        with_tree(NestedApp) do root
            inner = root.children[1].children[1] # the inner Provider
            consumer = inner.children[1]
            @test Rocks.text_content(consumer.children[1].children[1]) == "dark: false"
        end

        # the provider renders its children unchanged
        function PassthroughApp()
            @rock Theme.provider(
                @rock Text("hello");
                value = (dark = true,))
        end
        with_tree(PassthroughApp) do root
            provider = root.children[1]
            @test Rocks.text_content(provider.children[1]) == "hello"
        end

        # createContext needs its context object for @use lookups
        @test Theme.provider isa Function
        @test Theme.default == (dark = false,)
    end

    @testset "on_key" begin
        last_key = Ref("")
        function App()
            @rock Window(@rock Text("k"); title = "keys", on_key = k -> (last_key[] = k))
        end
        with_tree(App) do root
            windows = sync_windows!(root)
            w = windows[1]
            ev = Ref{Rocks.SDL_Event}()
            p = Base.unsafe_convert(Ptr{Rocks.SDL_Event}, ev)
            Rocks.setproperty!(p, :type, UInt32(Rocks.SDL_KEYDOWN))
            key = Rocks.SDL_KeyboardEvent(
                UInt32(Rocks.SDL_KEYDOWN),
                UInt32(0),
                UInt32(w.host.id),
                UInt8(1),
                UInt8(0),
                UInt8(0),
                UInt8(0),
                Rocks.SDL_Keysym(SDL_SCANCODE_ESCAPE, SDLK_ESCAPE, UInt16(0), UInt32(0)),
            )
            unsafe_store!(Rocks.getproperty(p, :key), key)
            @assert SDL_PushEvent(p) >= 0
            drain_events!()
            @test last_key[] == "Escape"
        end
    end

    @testset "colors" begin
        @test Rocks._to_rgba((1.0, 0.0, 0.0)) == (0xff, 0x00, 0x00, 0xff)
        @test Rocks._to_rgba((255, 0, 0)) == (0xff, 0x00, 0x00, 0xff)
        @test Rocks._to_rgba((0.0, 0.5, 1.0, 0.5)) == (0x00, 0x80, 0xff, 0x80)
        @test Rocks._to_rgba("#f00") == (0xff, 0x00, 0x00, 0xff)
        @test Rocks._to_rgba("#00ff00") == (0x00, 0xff, 0x00, 0xff)
        @test Rocks._to_rgba(RGBA(1.0, 0.0, 0.0, 0.5)) == (0xff, 0x00, 0x00, 0x80)
        @test Rocks._to_rgba(RGB(0.0, 0.0, 1.0)) == (0x00, 0x00, 0xff, 0xff)
    end

    @testset "screenshots" begin
        # Even headlessly (dummy driver + software renderer) the framebuffer
        # holds real pixels, so screenshots can be captured and verified.
        RED = (0.9, 0.2, 0.2)
        GREEN = (0.1, 0.7, 0.3)
        function App()
            @rock Window(
                @rock Box(@rock Text("screenshot"); background = RED, width = 400, height = 300);
                title = "shots", width = 400, height = 300)
        end
        with_tree(App) do root
            windows = sync_windows!(root)
            tmp = mktempdir()
            path = joinpath(tmp, "window.png")
            @test Rocks.screenshot(root, path) == path
            @test isfile(path)
            # the box fills the window: the center pixel is its background
            @test png_pixel(path, 200, 150) == Rocks._to_rgba(RED)
            # a specific window fiber can be captured directly
            @test Rocks.screenshot(windows[1], joinpath(tmp, "second.png")) == joinpath(tmp, "second.png")
            @test isfile(joinpath(tmp, "second.png"))
            # error cases: an element is not a rendered tree; a tree without
            # a rendered window has nothing to capture
            @test_throws ErrorException Rocks.screenshot(App(), path)
            @test_throws ErrorException Rocks.screenshot(
                Rocks.create_root(() -> nothing, NamedTuple()), path)
        end

        # render with bounded frames + capture — the headless workflow.
        shot = joinpath(mktempdir(), "render.png")
        function CounterApp()
            @rock Window(
                @rock Box(background = GREEN, width = 200, height = 100);
                title = "green", width = 200, height = 100)
        end
        render(CounterApp; frames = 1, screenshot = shot)
        @test isfile(shot)
        @test png_pixel(shot, 100, 50) == Rocks._to_rgba(GREEN)

        # render must reject the runtime kwargs as component props.
        @test_throws MethodError render(CounterApp; frames = 1, nonsense = 2)

        # Several windows: each window fiber can be captured individually.
        function TwoApp()
            @rock Window(
                @rock Box(background = RED, width = 300, height = 200);
                title = "red", width = 300, height = 200),
            @rock Window(
                @rock Box(background = GREEN, width = 200, height = 150);
                title = "green", width = 200, height = 150)
        end
        with_tree(TwoApp) do root
            windows = sync_windows!(root)
            tmp = mktempdir()
            red = joinpath(tmp, "red.png")
            green = joinpath(tmp, "green.png")
            Rocks.screenshot(windows[1], red)
            Rocks.screenshot(windows[2], green)
            @test png_pixel(red, 150, 100) == Rocks._to_rgba(RED)
            @test png_pixel(green, 100, 75) == Rocks._to_rgba(GREEN)
        end
    end
end
