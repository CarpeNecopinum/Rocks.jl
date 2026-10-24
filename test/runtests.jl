using Test
using Rocks
using ColorTypes: RGB, RGBA
import SDL3
import Rocks: Text, Element, Window, Box, Pressable, Row, Column, ScrollView

# All GUI-ish tests run against SDL's dummy video driver, so they work
# without a display.
ENV["SDL_VIDEO_DRIVER"] = "dummy"

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
    # Mirror the runtime loop: close OS windows whose fibers left the tree.
    for (_, f) in collect(pairs(Rocks.WINDOW_BY_ID))
        f in windows || Rocks.destroy_window!(f)
    end
    return windows
end

drain_events!() = begin
    for ev in SDL3.PollEvents()
        Rocks.dispatch_event!(ev)
    end
end

# (r, g, b, a) of the pixel at (x, y) of a PNG file.
function png_pixel(path, x, y)
    surf = SDL3.LoadPNG(path)
    return SDL3.ReadSurfacePixel(surf, x - 1, y - 1)
end

# The first fiber in a subtree whose kind matches, and all of them.
function find_kind(f, kind)
    f.kind === kind && return f
    for c in f.children
        found = find_kind(c, kind)
        found !== nothing && return found
    end
    return nothing
end

function collect_kind(f, kind)
    out = Rocks.Fiber[]
    f.kind === kind && push!(out, f)
    for c in f.children
        append!(out, collect_kind(c, kind))
    end
    return out
end

# SDL3 delivers every event through one 128 byte union. The wrapper keeps
# the union intact and offers typed views, so a synthetic event is built by
# storing the concrete payload struct into the event's memory.
function push_event!(::Type{P}, type::Integer, payload::P) where {P}
    event = SDL3.SDL_Event(type = type)
    GC.@preserve event begin
        unsafe_store!(Ptr{P}(pointer_from_objref(event)), payload)
    end
    @assert SDL3.PushEvent(event)
    return event
end

function push_mouse!(fiber, type, x, y; button = 1)
    window = fiber
    while !Rocks.is_window(window)
        window = window.parent
    end
    push_event!(SDL3.SDL_MouseButtonEvent, type,
                SDL3.SDL_MouseButtonEvent(
                    Int32(type), UInt32(0), UInt64(0),
                    UInt32(window.host.id), UInt32(0),
                    UInt8(button), true, UInt8(1), UInt8(0),
                    Float32(x), Float32(y),
                ))
    return nothing
end

function push_motion!(fiber, x, y)
    window = fiber
    while !Rocks.is_window(window)
        window = window.parent
    end
    push_event!(SDL3.SDL_MouseMotionEvent, SDL3.SDL_EVENT_MOUSE_MOTION,
                SDL3.SDL_MouseMotionEvent(
                    Int32(SDL3.SDL_EVENT_MOUSE_MOTION), UInt32(0), UInt64(0),
                    UInt32(window.host.id), UInt32(0),
                    UInt32(0x0001), # left button held
                    Float32(x), Float32(y), Float32(0), Float32(0),
                ))
    return nothing
end

function push_wheel!(fiber, x, y; dx = 0, dy = -1)
    window = fiber
    while !Rocks.is_window(window)
        window = window.parent
    end
    # Wheel events have no coordinates; real gestures follow mouse motion.
    Rocks.LAST_POINTER[window.host.id] = (Float64(x), Float64(y))
    push_event!(SDL3.SDL_MouseWheelEvent, SDL3.SDL_EVENT_MOUSE_WHEEL,
                SDL3.SDL_MouseWheelEvent(
                    Int32(SDL3.SDL_EVENT_MOUSE_WHEEL), UInt32(0), UInt64(0),
                    UInt32(window.host.id), UInt32(0),
                    Float32(dx), Float32(dy), Int32(0),
                    Float32(0), Float32(0), Int32(dx), Int32(dy),
                ))
    return nothing
end

function push_window_event!(fiber, wev; data1 = 0, data2 = 0)
    push_event!(SDL3.SDL_WindowEvent, wev,
                SDL3.SDL_WindowEvent(
                    Int32(wev), UInt32(0), UInt64(0),
                    UInt32(fiber.host.id), Int32(data1), Int32(data2),
                ))
    return nothing
end

# A key event (down or up) carrying `key` and the SDL modifier bits.
function push_key!(fiber, key; type = SDL3.SDL_EVENT_KEY_DOWN, mod = UInt16(0))
    push_event!(SDL3.SDL_KeyboardEvent, type,
                SDL3.SDL_KeyboardEvent(
                    Int32(type), UInt32(0), UInt64(0),
                    UInt32(fiber.host.id), UInt32(0), Int32(0),
                    UInt32(key), mod, UInt16(0),
                    type == SDL3.SDL_EVENT_KEY_DOWN, false,
                ))
    return nothing
end

center_of(fiber) = (
    round(Int, fiber.rect[1] + fiber.rect[3] / 2),
    round(Int, fiber.rect[2] + fiber.rect[4] / 2),
)

fmt(r) = "(" * join(round.(Int, collect(r)), ", ") * ")"

@testset "Rocks" begin
    @testset "text rendering available" begin
        # The whole suite renders text, so SDL3_ttf has to be installed. A
        # missing library is a failure, not a skip: a broken installation
        # must not pass the suite silently.
        if !SDL3.ttf_library_available()
            error("SDL3_ttf is not available — install it (on Debian/Ubuntu: " *
                  "libsdl3-ttf-dev) or point SDL3_TTF_LIBRARY_PATH at it")
        end
        @test SDL3.ttf_library_available()
        # Initialising is the real check: it throws when the library cannot
        # be loaded.
        @test (SDL3.TTF_Init(); true)
        @test SDL3.TTF_WasInit() >= 1
    end

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

    @testset "flexbox layout" begin
        # A component that renders a box, used to check that the flexbox
        # props size the component itself.
        function Card(; label = "card")
            @rock Box(@rock Text(label); background = "#eef2f7", padding = 8)
        end

        # `flex` is the React Native shorthand: `flex = 1` means grow 1,
        # shrink 1 and a basis of 0, so the child takes the free space of
        # its parent.
        function FlexApp()
            @rock Window(
                @rock Column(
                    @rock Box(; width = 40, height = 20; flex = 1),
                    @rock Box(; width = 40, height = 20);
                    width = 200, height = 120, gap = 10);
                title = "flex", width = 240, height = 160)
        end
        with_tree(FlexApp) do root
            w = sync_windows!(root)[1]
            col = w.children[1].children[1]
            grown, fixed = col.children
            # The window is 160 high, the column 120: the free 80px go to
            # the flexible child.
            @test grown.rect[4] == 120 - 20 - 10
            @test fixed.rect[4] == 20
            @test fixed.rect[2] == grown.rect[2] + grown.rect[4] + 10
        end

        # Two growing children share the free space proportionally.
        function GrowApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 20, height = 10; flex = 1),
                    @rock Box(; width = 20, height = 10; flex = 3);
                    width = 200, height = 40, gap = 0);
                title = "grow", width = 240, height = 80)
        end
        with_tree(GrowApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b = row.children
            @test a.rect[3] == 50
            @test b.rect[3] == 150
            @test a.rect[1] == 0
            @test b.rect[1] == 50
        end

        # `flex_grow` grows, `flex_shrink` shrinks: a row that is too narrow
        # shrinks its children into the available width.
        function ShrinkApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 100, height = 10; flex_shrink = 1),
                    @rock Box(; width = 100, height = 10; flex_shrink = 1);
                    width = 100, height = 20, gap = 0);
                title = "shrink", width = 140, height = 60)
        end
        with_tree(ShrinkApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b = row.children
            @test a.rect[3] == 50
            @test b.rect[3] == 50
        end

        # `flex_basis` sets the size before the free space is distributed: the
        # basis of 60px is the starting point, the free space is then split
        # between the two growing children.
        function BasisApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 10, height = 10; flex = 1, flex_basis = 60),
                    @rock Box(; width = 10, height = 10; flex = 1);
                    width = 200, height = 20, gap = 0);
                title = "basis", width = 240, height = 60)
        end
        with_tree(BasisApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b = row.children
            @test a.rect[3] == 130
            @test b.rect[3] == 70
        end

        # `justify` distributes the children along the main axis, `align`
        # across the cross axis.  The React Native spellings work too.
        function JustifyApp()
            @rock Window(
                @rock Column(
                    @rock Box(; width = 20, height = 10),
                    @rock Box(; width = 20, height = 10);
                    width = 100, height = 100, gap = 0, justify = :center);
                title = "justify", width = 140, height = 140)
        end
        with_tree(JustifyApp) do root
            w = sync_windows!(root)[1]
            col = w.children[1].children[1]
            a, b = col.children
            # The two 10px children sit centered in the 100px column.
            @test a.rect[2] == 40
            @test b.rect[2] == 50
        end

        function SpaceApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 20, height = 10),
                    @rock Box(; width = 20, height = 10),
                    @rock Box(; width = 20, height = 10);
                    width = 120, height = 20, gap = 0, justify = :space_between);
                title = "space", width = 160, height = 60)
        end
        with_tree(SpaceApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b, c = row.children
            @test a.rect[1] == 0
            @test b.rect[1] == 50
            @test c.rect[1] == 100
        end

        # `align = :stretch` (and `align_self`) stretch across the cross axis.
        # A child with an explicit size keeps it.
        function StretchApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 20; flex = 1),
                    @rock Box(; width = 20, height = 20; flex = 1, align_self = :end);
                    width = 100, height = 60, align = :stretch);
                title = "stretch", width = 140, height = 100)
        end
        with_tree(StretchApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b = row.children
            # The first child stretches to the full height of the row, the
            # second keeps its own height and sits at the end.
            @test a.rect[4] == 60
            @test a.rect[2] == 0
            @test b.rect[4] == 20
            @test b.rect[2] == 40
        end

        # Percentages resolve against the parent, `margin` pushes a child
        # away from the edges.
        function PercentApp()
            @rock Window(
                @rock Column(
                    @rock Box(; width = "50%", height = 10),
                    @rock Box(; width = 20, height = 10; margin = 5);
                    width = 200, height = 100, gap = 0);
                title = "percent", width = 240, height = 140)
        end
        with_tree(PercentApp) do root
            w = sync_windows!(root)[1]
            col = w.children[1].children[1]
            half, margined = col.children
            @test half.rect[3] == 100
            @test margined.rect[1] == 5
            @test margined.rect[2] == 15
        end

        # `min_width`/`max_width` clamp the flexed size.
        function BoundsApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 10, height = 10; flex = 1, max_width = 40),
                    @rock Box(; width = 10, height = 10; flex = 1);
                    width = 200, height = 20, gap = 0);
                title = "bounds", width = 240, height = 60)
        end
        with_tree(BoundsApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b = row.children
            @test a.rect[3] == 40
            @test b.rect[3] == 160
        end

        # Wrapping children form lines: the children that do not fit into the
        # main axis move to the next line.
        function WrapApp()
            @rock Window(
                @rock Row(
                    @rock Box(; width = 40, height = 20),
                    @rock Box(; width = 40, height = 20),
                    @rock Box(; width = 40, height = 20);
                    width = 100, height = 60, gap = 0, flex_wrap = :wrap);
                title = "wrap", width = 140, height = 100)
        end
        with_tree(WrapApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1].children[1]
            a, b, c = row.children
            # Two children fit on the first line, the third wraps below.
            @test a.rect[2] == 0
            @test b.rect[2] == 0
            @test c.rect[2] == 20
        end

        # A component is sized by the box around it: the flexbox props belong
        # to the component, so any component can be laid out by flexbox.
        function CardApp()
            @rock Window(
                @rock Column(
                    @rock Card(; label = "fixed"),
                    @rock Card(; label = "grows"; flex = 1);
                    width = 200, height = 120, gap = 0, align = :stretch);
                title = "component", width = 240, height = 160)
        end
        with_tree(CardApp) do root
            w = sync_windows!(root)[1]
            col = w.children[1].children[1]
            fixed, grows = col.children
            # The card is as tall as its text plus the padding.
            @test fixed.rect[4] == 35
            # The flexible card takes the rest of the column.
            @test grows.rect[4] == 85
            @test grows.rect[3] == 200
            # The element the component returns fills the space it was given.
            @test only(grows.children).rect == grows.rect
        end

        # A child never falls out of its container: a control with a fixed
        # width is clipped to the content box when the window gets narrower.
        function SqueezeApp()
            @rock Window(
                @rock Column(
                    @rock Box(; width = 200, height = 20);
                    width = 120, height = 60);
                title = "squeeze", width = 160, height = 100)
        end
        with_tree(SqueezeApp) do root
            w = sync_windows!(root)[1]
            col = w.children[1].children[1]
            @test col.children[1].rect[3] == 120
        end
    end

    @testset "padding axes and justify" begin
        function App()
            @rock Window(
                @rock Box(
                    @rock Box(; width = 20, height = 10);
                    width = 100, height = 40,
                    padding = (10, 5), direction = :row,
                    align = :center, justify = :center);
                title = "pad", width = 200, height = 100)
        end
        with_tree(App) do root
            w = sync_windows!(root)[1]
            box = w.children[1]
            child = box.children[1]
            # padding is (horizontal, vertical); the child is centered inside
            # the padded content box on both axes.
            @test fmt(child.rect) == "(40, 15, 20, 10)"
        end

        # Text is measured at its natural rendered height: descenders such as
        # the "g" in "Floating" make the surface one pixel taller than the
        # font height, and squashing it into TTF_FontHeight used to clip
        # glyph strokes.
        function TextApp()
            @rock Window(@rock Text("Floating"; size = 12);
                         title = "text", width = 200, height = 100)
        end
        with_tree(TextApp) do root
            w = sync_windows!(root)[1]
            text = w.children[1]
            font = Rocks.load_font(Rocks.default_font(), 12)
            _, h = SDL3.TTF_GetStringSize(font, "Floating")
            @test text.measured[2] == h
        end
    end

    @testset "scroll view" begin
        offset_seen = Ref(-1.0)
        function App()
            @rock Window(
                @rock ScrollView(
                    @rock Box(; width = 200, height = 80, background = (0.9, 0.2, 0.2)),
                    @rock Box(; width = 200, height = 80, background = (0.2, 0.7, 0.3));
                    position = :absolute, fill = true, scroll_step = 40,
                    on_scroll = offset -> offset_seen[] = offset);
                title = "scroll", width = 200, height = 100)
        end
        with_tree(App) do root
            w = sync_windows!(root)[1]
            sv = w.children[1]
            @test sv.kind === ScrollView
            @test sv.host isa Rocks.ScrollState
            @test fmt(sv.rect) == "(0, 0, 200, 100)"
            @test sv.host.max_offset == 60
            @test sv.children[1].rect[2] == 0

            # one wheel notch scrolls one step; the callback sees the offset
            push_wheel!(sv, 100, 50; dy = -1)
            drain_events!()
            @test sv.host.offset == 40
            @test offset_seen[] == 40
            # the runtime re-lays out on the next frame, translating content
            Rocks.measure!(w)
            Rocks.place!(w, 0.0, 0.0)
            @test sv.children[1].rect[2] == -40
            @test sv.children[2].rect[2] == 40
            # hit testing follows the translated rects
            @test Rocks.hit_test(w, 100, 5) === sv.children[1]
            @test Rocks.hit_test(w, 100, 45) === sv.children[2]

            # reversing reaches the top and reports the new offset; another
            # upward notch at the top is a no-op
            push_wheel!(sv, 100, 50; dy = 1)
            drain_events!()
            @test sv.host.offset == 0
            @test offset_seen[] == 0
            offset_seen[] = -1.0
            push_wheel!(sv, 100, 50; dy = 1)
            drain_events!()
            @test sv.host.offset == 0
            @test offset_seen[] == -1.0
        end

        # Content is clipped to the scroll viewport (a screenshot check: with
        # no clip, the red box would paint above the viewport at y < 50).
        RED = (0.9, 0.2, 0.2)
        GREEN = (0.1, 0.7, 0.3)
        BLUE = (0.15, 0.25, 0.85)
        function ClipApp()
            @rock Window(
                @rock ScrollView(
                    @rock Box(; width = 200, height = 80, background = RED),
                    @rock Box(; width = 200, height = 80, background = GREEN);
                    position = :absolute, y = 50, width = 200, height = 50,
                    scroll_step = 40);
                title = "clip", width = 200, height = 100, background = BLUE)
        end
        with_tree(ClipApp) do root
            w = sync_windows!(root)[1]
            sv = w.children[1]
            Rocks.scroll_by!(sv, 0.0, -1.0)
            Rocks.measure!(w)
            Rocks.place!(w, 0.0, 0.0)
            path = joinpath(mktempdir(), "scroll.png")
            Rocks.screenshot(root, path)
            @test png_pixel(path, 100, 25) == Rocks._to_rgba(BLUE)
            @test png_pixel(path, 100, 60) == Rocks._to_rgba(RED)
            @test png_pixel(path, 100, 95) == Rocks._to_rgba(GREEN)
        end

        # An absolute fill child keeps its fixed height (used by pinned app
        # bars), while filling the parent's width.
        function FillHeightApp()
            @rock Window(
                @rock Box(; position = :absolute, fill = true, height = 50,
                          background = RED);
                title = "fill height", width = 200, height = 100)
        end
        with_tree(FillHeightApp) do root
            w = sync_windows!(root)[1]
            @test fmt(w.children[1].rect) == "(0, 0, 200, 50)"
        end
    end

    @testset "canvas wheel" begin
        seen = Ref{Any}(nothing)
        function App()
            @rock Window(
                @rock MouseArea(
                    @rock Canvas(; draw = _ -> nothing);
                    on_wheel = (dx, dy, x, y) -> seen[] = (dx, dy, x, y),
                    flex = 1, fill = true);
                title = "wheel", width = 200, height = 100)
        end
        with_tree(App) do root
            w = sync_windows!(root)[1]
            area = w.children[1]
            @test area.kind === MouseArea
            @test area.children[1].kind === Canvas
            # `dy = -1` is one wheel notch; the callback sees the raw delta and
            # the pointer in area-local coordinates (the canvas underneath
            # share the same rect, so these are canvas-local too)
            push_wheel!(w, 120, 70; dx = 0, dy = -1)
            drain_events!()
            @test seen[] == (0.0, -1.0, 120.0, 70.0)
        end

        # An `on_wheel` area zooms inside a scroll view instead of scrolling
        # it; wheel over a sibling without the prop scrolls the view as usual.
        zooms = Ref(0)
        function BothApp()
            @rock Window(
                @rock ScrollView(
                    @rock MouseArea(
                        @rock Canvas(; draw = _ -> nothing,
                                     width = 200, height = 50);
                        on_wheel = (dx, dy, x, y) -> zooms[] += 1),
                    @rock Box(; width = 200, height = 2_000,
                              background = (0.2, 0.7, 0.3));
                    position = :absolute, fill = true, scroll_step = 40);
                title = "both", width = 200, height = 100)
        end
        with_tree(BothApp) do root
            w = sync_windows!(root)[1]
            sv = w.children[1]
            push_wheel!(w, 100, 20)              # over the canvas → zoom
            drain_events!()
            @test zooms[] == 1
            @test sv.host.offset == 0
            push_wheel!(w, 100, 70; dy = -1)     # over the box → scroll
            drain_events!()
            @test zooms[] == 1
            @test sv.host.offset == 40
        end
    end

    @testset "mouse area" begin
        downs = Any[]
        ups = Any[]
        clicks = Any[]
        moves = Any[]
        enters = Ref(0)
        leaves = Ref(0)
        legacy_press = Ref(0)
        wheels = Any[]
        function App()
            @rock Window(
                @rock MouseArea(;
                    position = :absolute, x = 50, y = 40,
                    width = 100, height = 60,
                    on_down = (x, y, b) -> push!(downs, (x, y, b)),
                    on_up = (x, y, b) -> push!(ups, (x, y, b)),
                    on_click = (x, y, b) -> push!(clicks, (x, y, b)),
                    on_move = (x, y) -> push!(moves, (x, y)),
                    on_enter = () -> (enters[] += 1; nothing),
                    on_leave = () -> (leaves[] += 1; nothing),
                    on_press = () -> (legacy_press[] += 1; nothing),
                    on_wheel = (dx, dy, x, y) -> push!(wheels, (dx, dy, x, y)));
                title = "mouse area", width = 300, height = 200)
        end
        with_tree(App) do root
            w = sync_windows!(root)[1]
            area = w.children[1]
            @test area.kind === MouseArea
            @test fmt(area.rect) == "(50, 40, 100, 60)"

            # Pointer callbacks receive area-local coordinates. A press and
            # a release inside is a click; releasing outside only reports
            # `on_up` (the legacy `on_press` stays click-only).
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, 100, 60)
            drain_events!()
            @test downs == [(50.0, 20.0, 1)]
            @test area.host.pressed
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, 190, 150)
            drain_events!()
            @test ups == [(140.0, 110.0, 1)]
            @test clicks == []
            @test !area.host.pressed
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, 100, 60)
            drain_events!()
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, 100, 60)
            drain_events!()
            @test ups == [(140.0, 110.0, 1), (50.0, 20.0, 1)]
            @test clicks == [(50.0, 20.0, 1)]
            @test legacy_press[] == 1

            # Hover motion: enter once, then moves; leaving stops the moves.
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, 100, 60)
            drain_events!()
            @test enters[] == 1
            @test moves == [(50.0, 20.0)]
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, 140, 70)
            drain_events!()
            @test moves == [(50.0, 20.0), (90.0, 30.0)]
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, 290, 190)
            drain_events!()
            @test leaves[] == 1

            # Press capture: while the button is held the area keeps seeing
            # moves (even outside), then stops after the release.
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, 60, 45)
            drain_events!()
            n_before = length(moves)
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, 190, 150)
            drain_events!()
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, 290, 190)
            drain_events!()
            @test moves[n_before+1:end] == [(140.0, 110.0), (240.0, 150.0)]
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, 290, 190)
            drain_events!()
            @test ups[end] == (240.0, 150.0, 1)
            @test clicks == [(50.0, 20.0, 1)]  # release outside → no click
            n_moves = length(moves)
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, 290, 190)
            drain_events!()
            @test length(moves) == n_moves

            # Wheel over the area: raw deltas, area-local coordinates.
            push_wheel!(w, 100, 60; dx = 0, dy = -1)
            drain_events!()
            @test wheels == [(0.0, -1.0, 50.0, 20.0)]
        end
    end

    @testset "mouse area layout" begin
        # Styled controls (Buttons, tab headers, …) are MouseAreas like any
        # other: their single streamed label keeps flex-flow placement, so a
        # center-aligned control centers its text vertically.
        function CenteredApp()
            @rock Window(
                @rock Pressable(
                    @rock Text("mid");
                    align = :center, justify = :center, direction = :row,
                    height = 40, padding_x = 16);
                title = "centered", width = 200, height = 80)
        end
        with_tree(CenteredApp) do root
            w = sync_windows!(root)[1]
            p = w.children[1]
            t = p.children[1]
            offset = (t.rect[2] + t.rect[4] / 2) - (p.rect[2] + p.rect[4] / 2)
            @test abs(offset) <= 1.0
        end

        # The wrapper use: a single `fill = true` child fills the MouseArea
        # exactly, no-op visually.
        function FillWrapApp()
            @rock Window(
                @rock Row(
                    @rock MouseArea(
                        @rock Canvas(draw = _ -> nothing, fill = true);
                        flex = 1, fill = true);
                    position = :absolute, fill = true);
                title = "wrap", width = 200, height = 80)
        end
        with_tree(FillWrapApp) do root
            w = sync_windows!(root)[1]
            row = w.children[1]
            box = row.children[1]      # Row is a component; its output Box
            area = box.children[1]
            canvas = area.children[1]
            @test area.kind === MouseArea && canvas.kind === Canvas
            @test fmt(canvas.rect) == fmt(area.rect)
        end

        # …while a non-fill single child keeps its natural flow size.
        function FlowWrapApp()
            @rock Window(
                @rock MouseArea(
                    @rock Text("hi"; size = 20);
                    height = 80);
                title = "flow", width = 200, height = 80)
        end
        with_tree(FlowWrapApp) do root
            w = sync_windows!(root)[1]
            area = w.children[1]
            t = area.children[1]
            @test area.rect[4] == 80
            @test t.rect[4] < area.rect[4] # no vertical stretching
        end
    end

    @testset "component overflow hit testing" begin
        # A component fiber transparently forwards hit tests into its output
        # subtree: pointer events in a popup that overflows the component's
        # own rect must reach the popup's pressables (this is where every
        # dropdown lives).
        clicks = Ref(0)
        function Popup()
            @rock Box(
                @rock Pressable(
                    @rock Text("entry");
                    position = :absolute, x = 0, y = 30,
                    width = 60, height = 20,
                    on_press = () -> (clicks[] += 1));
                overflow = :visible, width = 60, height = 20)
        end
        function OverflowApp()
            @rock Window(@rock Popup();
                         title = "overflow", width = 200, height = 150)
        end
        with_tree(OverflowApp) do root
            w = sync_windows!(root)[1]
            entry = first(collect_kind(w, Pressable))
            ex, ey = (entry.rect[1] + entry.rect[3] / 2,
                      entry.rect[2] + entry.rect[4] / 2)
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, ex, ey)
            drain_events!()
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, ex, ey)
            drain_events!()
            @test clicks[] == 1
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

            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, cx, cy)
            drain_events!()
            @test pressable.host.pressed == true
            @test pressed_log[] == 1

            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, cx, cy)
            drain_events!()
            @test clicks[] == 1
            @test pressable.host.pressed == false

            # motion triggers hover
            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_MOTION, cx, cy)
            drain_events!()
            @test pressable.host.hovered == true
            @test hover_log[] == 1

            # release far away: no press
            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, cx, cy)
            drain_events!()
            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, 280, 180)
            drain_events!()
            @test clicks[] == 1

            # outside the pressable entirely: nothing happens
            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, 290, 190)
            push_mouse!(pressable, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, 290, 190)
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
            @test SDL3.GetWindowTitle(windows[1].host.ptr) == "Main"

            open = root.hooks[1].value
            open[] = true
            Rocks.perform_render!(root)
            Rocks.run_effects!()
            windows = sync_windows!(root)
            @test length(windows) == 2
            titles = Set(SDL3.GetWindowTitle(w.host.ptr) for w in windows)
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
            push_window_event!(w, SDL3.SDL_EVENT_WINDOW_EXPOSED)
            drain_events!()
            @test state.needs_draw == true
            state.needs_draw = false

            # resize updates the size and marks for re-layout + redraw
            push_window_event!(w, SDL3.SDL_EVENT_WINDOW_RESIZED; data1 = 320, data2 = 240)
            drain_events!()
            @test state.width == 320 && state.height == 240
            @test state.needs_layout == true && state.needs_draw == true

            # hover motion over the pressable marks for redraw
            state.needs_draw = false
            state.needs_layout = false
            cx, cy = center_of(w.children[1])
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, cx, cy)
            drain_events!()
            @test state.needs_draw == true
            @test state.needs_layout == false # no re-layout on hover
            @test w.children[1].host.hovered == true

            # motion over empty space with unchanged hover state: no redraw
            state.needs_draw = false
            push_mouse!(w, SDL3.SDL_EVENT_MOUSE_MOTION, cx, cy)
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
            _, mx, my = SDL3.GetGlobalMouseState()
            @test Rocks.window_position(f3) == (round(Int, mx), round(Int, my))

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
            push_mouse!(split, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, hx, hy)
            drain_events!()
            @test Rocks.ACTIVE_DRAG[] === split
            push_mouse!(split, SDL3.SDL_EVENT_MOUSE_MOTION, hx + 95, hy) # +95px => ratio ~0.75
            drain_events!()
            @test Rocks.ACTIVE_DRAG[] === split
            push_mouse!(split, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, hx + 95, hy)
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
            push_mouse!(slider, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, sx, sy)
            drain_events!()
            push_mouse!(slider, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, sx, sy)
            drain_events!()
            @test 0.45 <= value[] <= 0.55
        end
    end

    @testset "image" begin
        # load a generated BMP through the Image element
        path = joinpath(tempdir(), "rocks-test-image.bmp")
        Rocks.init_backend()
        surface = SDL3.CreateSurface(16, 8, SDL3.SDL_PIXELFORMAT_RGB24)
        details = SDL3.GetPixelFormatDetails(SDL3.SDL_PIXELFORMAT_RGB24)
        color = SDL3.MapRGB(details, C_NULL, 200, 100, 50)
        SDL3.FillSurfaceRect(surface, nothing, color)
        SDL3.SaveBMP(surface, path)
        SDL3.DestroySurface(surface)

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
            push_key!(w, SDL3.SDLK_ESCAPE)
            drain_events!()
            @test last_key[] == "Escape"
        end
    end

    # ---- Material3 ------------------------------------------------------------

    @testset "material3" begin
        M3 = Rocks.Material3

        @testset "theme" begin
            # the default theme is the baseline light scheme
            @test M3.ThemeContext.default == M3.light_theme()
            @test M3.light_theme().primary == "#6750A4"
            @test M3.dark_theme().primary == "#D0BCFF"
            @test M3.light_theme() != M3.dark_theme()
            # the theme struct is immutable
            @test !ismutabletype(typeof(M3.light_theme()))
            @test M3.light_theme().typescale.body_large isa Int
            @test M3.light_theme().shapes.full > 100
        end

        @testset "theme context" begin
            dark = Observable(M3.dark_theme())
            function ThemedApp()
                @rock M3.ThemeContext.provider(
                    @rock M3.Button("Filled");
                    value = dark)
            end
            # theme switches re-render the components with the new palette
            with_tree(ThemedApp) do root
                button = find_kind(root, Mechanics.Button)
                pressable = find_kind(root, Pressable)
                @test pressable.props[:background] == M3.dark_theme().primary
                # the positional string label is themed too
                @test find_kind(root, Text).props[:color] ==
                      M3.dark_theme().on_primary
                dark[] = M3.light_theme()
                Rocks.perform_render!(root)
                @test find_kind(root, Pressable).props[:background] ==
                      M3.light_theme().primary
                @test find_kind(root, Text).props[:color] ==
                      M3.light_theme().on_primary
            end
        end

        @testset "variants" begin
            function BtnApp()
                @rock M3.Button("Save"; variant = :filled)
            end
            with_tree(BtnApp) do root
                pressable = find_kind(root, Pressable)
                @test pressable.props[:background] == M3.light_theme().primary
                @test pressable.props[:radius] == M3.light_theme().shapes.full
                @test pressable.props[:height] == 40
            end
            function OutlinedApp()
                @rock M3.Button("Save"; variant = :outlined)
            end
            with_tree(OutlinedApp) do root
                pressable = find_kind(root, Pressable)
                @test pressable.props[:background] === nothing
                @test pressable.props[:border_color] == M3.light_theme().outline
                @test pressable.props[:border_width] == 1
            end
            # a disabled filled button uses the M3 disabled container
            function DisabledApp()
                @rock M3.Button("Off"; disabled = true)
            end
            with_tree(DisabledApp) do root
                pressable = find_kind(root, Pressable)
                rgba = pressable.props[:background]
                @test rgba[4] == 0x1f # on-surface at 12%
            end
        end

        @testset "checkbox and switch" begin
            checked = Observable(true)
            changed = Ref(0)
            function CbApp()
                @rock M3.Checkbox(checked = checked, label = "grid";
                                  on_change = () -> (changed[] += 1))
            end
            with_tree(CbApp) do root
                pressables = collect_kind(root, Pressable)
                @test length(pressables) >= 1
                pressables[1].props[:on_press]()
                @test checked[] == false
                @test changed[] == 1
                pressables[1].props[:on_press]()
                @test checked[] == true
            end

            on = Observable(false)
            function SwApp()
                @rock Window(@rock M3.Switch(on = on);
                             title = "switch", width = 200, height = 100)
            end
            with_tree(SwApp) do root
                sync_windows!(root)
                pressable = find_kind(root, Pressable)
                boxes = collect_kind(root, Box)
                i = findfirst(b -> get(b.props, :width, nothing) == 16 &&
                                   get(b.props, :radius, nothing) == 8, boxes)
                thumb, track = boxes[i], boxes[i].parent
                # unchecked: concentric with the track's left cap
                @test thumb.rect[1] - track.rect[1] == 8
                @test thumb.rect[2] - track.rect[2] == 8
                @test thumb.rect[1] + thumb.rect[3] / 2 ==
                      track.rect[1] + track.rect[4] / 2
                pressable.props[:on_press]()
                @test on[] == true
                Rocks.perform_render!(root)
                sync_windows!(root)
                boxes = collect_kind(root, Box)
                i = findfirst(b -> get(b.props, :width, nothing) == 24 &&
                                   get(b.props, :radius, nothing) == 12, boxes)
                thumb, track = boxes[i], boxes[i].parent
                # checked: concentric with the track's right cap
                @test thumb.rect[1] - track.rect[1] == 52 - 24 - 4
                @test thumb.rect[2] - track.rect[2] == 4
                @test thumb.rect[1] + thumb.rect[3] / 2 ==
                      track.rect[1] + track.rect[3] - track.rect[4] / 2
            end
        end

        @testset "segmented" begin
            selection = Observable(1)
            function SegApp()
                @rock M3.SegmentedButton(["Day", "Week"]; selection = selection)
            end
            with_tree(SegApp) do root
                segments = collect_kind(root, Pressable)
                @test length(segments) == 2
                segments[2].props[:on_press]()
                @test selection[] == 2
            end

            multi = Observable(Int[1])
            function MultiApp()
                @rock M3.SegmentedButton(["A", "B", "C"]; selection = multi, multiple = true)
            end
            with_tree(MultiApp) do root
                segments = collect_kind(root, Pressable)
                @test length(segments) == 3
                full = M3.light_theme().shapes.full
                # only the outer corners of the group are rounded
                @test segments[1].props[:radius] == (full, 0.0, 0.0, full)
                @test segments[2].props[:radius] == (0.0, 0.0, 0.0, 0.0)
                @test segments[3].props[:radius] == (0.0, full, full, 0.0)
                segments[2].props[:on_press]()
                @test multi[] == [1, 2]
                segments[1].props[:on_press]()
                @test multi[] == [2]
            end
        end

        @testset "radio group" begin
            selected = Observable(1)
            function RadioApp()
                @rock M3.RadioGroup(["One", "Two"]; selected = selected)
            end
            with_tree(RadioApp) do root
                radios = collect_kind(root, Pressable)
                @test length(radios) == 2
                radios[2].props[:on_press]()
                @test selected[] == 2
            end
        end

        @testset "slider" begin
            value = Observable(0.5)
            function SliderApp()
                @rock M3.Slider(value = value)
            end
            with_tree(SliderApp) do root
                slider = find_kind(root, Slider)
                @test slider.kind === Slider
                @test slider.props[:thumb_width] == 10 # gap around the handle
                @test slider.props[:handle_width] == 4
                @test slider.props[:track_height] == 16
                @test slider.props[:active_color] == M3.light_theme().primary
            end
        end

        @testset "dialog overlay" begin
            open = Observable(true)
            function DlgApp()
                @rock M3.Dialog(
                    @rock Text("Delete this item?"; size = 16);
                    open = open)
            end
            with_tree(DlgApp) do root
                scrim = find_kind(root, Box)
                @test scrim.props[:fill] == true      # covers the window
                @test scrim.props[:position] === :absolute
                card = scrim.children[1]
                @test card.props[:align] === :center  # centered in the scrim
                @test card.props[:width] == 320
                # closing the dialog renders nothing
                open[] = false
                Rocks.perform_render!(root)
                @test find_kind(root, Box) === nothing
            end
        end

        @testset "list item" begin
            function ListApp()
                @rock M3.List(
                    @rock M3.ListItem("First"; leading = "mail"),
                    @rock M3.ListItem("Second"; supporting = "supporting"))
            end
            with_tree(ListApp) do root
                # two rows (pressables) + two dividers below them
                rows = collect_kind(root, Pressable)
                @test length(rows) == 2
                dividers = [f for f in collect_kind(root, Box) if
                            get(f.props, :height, nothing) == 1]
                @test length(dividers) == 2
            end
        end

        @testset "text field" begin
            text = Observable("")
            function FieldApp()
                @rock M3.TextField(text = text, label = "Name", variant = :filled)
            end
            with_tree(FieldApp) do root
                fields = collect_kind(root, Pressable)
                @test length(fields) >= 1
                field = fields[1]
                # typed characters land in the observable
                field.props[:on_text_input]("Ada")
                @test text[] == "Ada"
                field.props[:on_key]("Backspace")
                @test text[] == "Ad"
                # the filled variant uses the theme's highest container
                @test field.props[:background] == M3.light_theme().surface_container_highest
            end
        end

        @testset "badge" begin
            function BadgeApp()
                @rock M3.Badge(3)
            end
            with_tree(BadgeApp) do root
                marker = find_kind(root, Box)
                @test marker.props[:background] == M3.light_theme().error
            end
        end

        @testset "navigation" begin
            selected = Observable(1)
            function NavApp()
                @rock M3.NavigationBar(
                    destinations = [("Home", "home"), ("Favorite", "favorite")];
                    selected = selected)
            end
            with_tree(NavApp) do root
                bar = find_kind(root, Box)
                @test bar.props[:height] == 80
                @test bar.props[:fill] == true
                destinations = collect_kind(bar, Pressable)
                @test length(destinations) == 2
                destinations[2].props[:on_press]()
                @test selected[] == 2
            end
        end

        @testset "top app bar scroll color" begin
            scrolled = Observable(false)
            function AppBarApp()
                @rock M3.TopAppBar("Title"; scrolled = scrolled)
            end
            with_tree(AppBarApp) do root
                bar = find_kind(root, Box)
                @test bar.props[:background] == M3.light_theme().surface
                scrolled[] = true
                Rocks.perform_render!(root)
                bar = find_kind(root, Box)
                @test bar.props[:background] == M3.light_theme().surface_container
            end
        end
    end

    @testset "enterprise" begin
        E = Rocks.Enterprise
        text_of(f) = f.kind === Text ? Rocks.text_content(f) :
                     join((text_of(c) for c in f.children), "")
        function pressable_with(f, needle)
            # Exact label first: a parent pressable's text includes its whole
            # subtree (e.g. a TextBox with a right-click menu inside), so
            # substring matching could otherwise hit the wrapper first.
            for p in collect_kind(f, Pressable)
                text_of(p) == needle && return p
            end
            for p in collect_kind(f, Pressable)
                occursin(needle, text_of(p)) && return p
            end
            return nothing
        end

        @testset "theme, gradients and primitives" begin
            t = E.light_theme()
            @test t.metrics.button_height == 23
            @test t.gradients.button isa LinearGradient
            @test E.classic_theme().gradients.button isa LinearGradient
            @test E.high_contrast_theme().colors.border == "#000000"

            function GradApp()
                @rock Window(
                    @rock Box(; width = 100, height = 100,
                        background = LinearGradient("#000000", "#ffffff"));
                    title = "gradient", width = 100, height = 100)
            end
            with_tree(GradApp) do root
                sync_windows!(root)
                path = joinpath(mktempdir(), "gradient.png")
                Rocks.screenshot(root, path)
                @test png_pixel(path, 50, 5)[1] < 20
                @test png_pixel(path, 50, 95)[1] > 235
            end

            function HoriGradApp()
                @rock Window(
                    @rock Box(; width = 100, height = 100,
                        background = LinearGradient("#000000", "#ffffff";
                                                    direction = :horizontal));
                    title = "gradient", width = 100, height = 100)
            end
            with_tree(HoriGradApp) do root
                sync_windows!(root)
                path = joinpath(mktempdir(), "hgradient.png")
                Rocks.screenshot(root, path)
                @test png_pixel(path, 5, 50)[1] < 20
                @test png_pixel(path, 95, 50)[1] > 235
            end

            clicks = Ref(0)
            function BtnApp()
                @rock E.Button("OK"; default = true,
                               on_press = () -> clicks[] += 1)
            end
            with_tree(BtnApp) do root
                button = find_kind(root, Pressable)
                @test button.props[:bevel] === :raised
                @test button.props[:background] isa LinearGradient
                button.props[:on_press]()
                @test clicks[] == 1
            end

            # A pointer-transparent overlay lets events fall through to content
            # below, while its own children stay hittable.
            function OverlayApp()
                under = @rock Box(
                    @rock Pressable(; position = :absolute, x = 10, y = 10,
                                    width = 40, height = 40,
                                    on_press = () -> nothing);
                    position = :absolute, fill = true, background = (1, 1, 1))
                overlay = @rock Box(
                    @rock Box(; position = :absolute, x = 60, y = 10,
                              width = 20, height = 20, background = (1, 0, 0));
                    position = :absolute, fill = true,
                    pointer_events = :none)
                @rock Window(under, overlay; width = 100, height = 100)
            end
            with_tree(OverlayApp) do root
                w = sync_windows!(root)[1]
                @test Rocks.hit_test(w, 20.0, 20.0).kind === Pressable
                hit = Rocks.hit_test(w, 70.0, 20.0)
                @test hit !== nothing && get(hit.props, :background, nothing) == (1, 0, 0)
                hit = Rocks.hit_test(w, 90.0, 90.0)
                @test hit !== nothing && get(hit.props, :background, nothing) == (1, 1, 1)
            end

            # `overflow = :visible` keeps positioned children hittable outside
            # the parent's rect.
            function OverflowApp()
                child = @rock Pressable(; position = :absolute, x = 0, y = 30,
                                        width = 20, height = 20,
                                        on_press = () -> nothing)
                box = @rock Box(child; position = :absolute, x = 10, y = 10,
                                width = 50, height = 20, overflow = :visible)
                @rock Window(box; width = 100, height = 100)
            end
            with_tree(OverflowApp) do root
                w = sync_windows!(root)[1]
                @test Rocks.hit_test(w, 20.0, 45.0).kind === Pressable
            end
        end

        @testset "controls" begin
            clicked = Ref(0)
            text = Observable("Ada")
            checked = Observable(false)
            radio = Observable(1)
            progress = Observable(0.25)
            tab = Observable(1)
            function App()
                t = E.light_theme()
                return @rock E.ThemeContext.provider(
                    @rock E.Column(
                        @rock E.Button("Go"; on_press = () -> clicked[] += 1),
                        @rock E.TextBox(text = text),
                        @rock E.CheckBox(checked = checked, label = "Check"),
                        @rock E.RadioButton(selected = radio, value = 1,
                                            label = "One"),
                        @rock E.RadioButton(selected = radio, value = 2,
                                            label = "Two"),
                        @rock E.ProgressBar(value = progress, width = 100),
                        @rock E.Slider(value = progress, width = 100, ticks = 8),
                        @rock E.TabControl(tabs = ["A", "B"], selected = tab,
                            children = Any[@rock E.Label("Alpha"),
                                           @rock E.Label("Beta")],
                            fill = true);
                        gap = 8, fill = true);
                    value = t)
            end
            with_tree(App) do root
                go = pressable_with(root, "Go")
                go.props[:on_press]()
                @test clicked[] == 1

                field = [f for f in collect_kind(root, Pressable)
                         if haskey(f.props, :on_text_input)][1]
                field.props[:on_text_input]("!")
                @test text[] == "Ada!"
                field.props[:on_key]("Backspace")
                @test text[] == "Ada"

                pressable_with(root, "Check").props[:on_press]()
                @test checked[]
                pressable_with(root, "Two").props[:on_press]()
                @test radio[] == 2

                slider = find_kind(root, Slider)
                @test slider.props[:thumb_size] == 11
                @test slider.props[:track_height] == 4
                @test slider.props[:ticks] == 8

                progress[] = 0.5
                Rocks.perform_render!(root)
                bar = [b for b in collect_kind(root, Box)
                       if get(b.props, :background, nothing) ==
                          E.light_theme().colors.progress_track &&
                          get(b.props, :bevel, nothing) === :sunken][1]
                # The fill is a share of the bar, so it follows the bar when
                # the bar is squeezed.
                @test bar.children[1].props[:width] == "50.0%"
                @test bar.children[1].props[:height] == "100%"

                pressable_with(root, "B").props[:on_press]()
                @test tab[] == 2
                Rocks.perform_render!(root)
                @test occursin("Beta", text_of(root))
                @test !occursin("Alpha", text_of(root))
            end

            # Password fields render bullets and still edit the real value.
            password = Observable("secret")
            function PasswordApp()
                @rock E.TextBox(text = password, password = true)
            end
            with_tree(PasswordApp) do root
                @test occursin("●●●●●●", text_of(root))
            end
        end

        @testset "data controls" begin
            list = Observable(0)
            grid = Observable(0)
            combo = Observable(1)
            changed = Ref(0)
            function DataApp()
                @rock E.Column(
                    @rock E.ListView(items = ["one", "two"], selected = list),
                    @rock E.GridView(
                        columns = [("Name", 80), ("Kind", 60)],
                        rows = [("x", "a"), ("y", "b")], selected = grid),
                    @rock E.ComboBox(items = ["one", "two"], selected = combo,
                                     on_change = () -> changed[] += 1);
                    gap = 8)
            end
            with_tree(DataApp) do root
                pressable_with(root, "two").props[:on_press]()
                @test list[] == 2
                pressable_with(root, "y").props[:on_press]()
                @test grid[] == 2

                combo_component = find_kind(root, E.ComboBox)
                field = first(p for p in collect_kind(combo_component, Pressable)
                              if get(p.props, :width, nothing) == 160)
                field.props[:on_press]()
                Rocks.perform_render!(root)
                combo_component = find_kind(root, E.ComboBox)
                item = pressable_with(combo_component, "two")
                @test item !== nothing
                item.props[:on_press]()
                @test combo[] == 2
                @test changed[] == 1
            end
        end

        @testset "combo box pointer clicks" begin
            # The dropdown popup overflows the ComboBox's own rect, so real
            # pointer clicks must reach it through the component fiber's
            # output (hit-test forwarding): open via the arrow, then select
            # an entry.
            combo = Observable(1)
            changes = Ref(0)
            function ComboClickApp()
                @rock Window(
                    @rock E.ComboBox(items = ["one", "two"]; selected = combo,
                                     on_change = () -> changes[] += 1);
                    title = "combo clicks", width = 300, height = 240)
            end
            with_tree(ComboClickApp) do root
                w = sync_windows!(root)[1]
                combo_component = find_kind(root, E.ComboBox)
                arrow = first(p for p in collect_kind(combo_component, Pressable)
                              if p.rect[3] < 20)
                ax, ay = (arrow.rect[1] + arrow.rect[3] / 2,
                          arrow.rect[2] + arrow.rect[4] / 2)
                push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, ax, ay)
                drain_events!()
                push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, ax, ay)
                drain_events!()
                Rocks.perform_render!(root)
                sync_windows!(root)
                combo_component = find_kind(root, E.ComboBox)
                # Both entries are 156 wide; the second one ("two") makes the
                # selection assertion meaningful. They live in the popup's
                # own borderless window now, so the click is pushed on the
                # entry fiber itself (resolved to the popup window).
                entries = [p for p in collect_kind(combo_component, Pressable)
                           if p.rect[3] == 156]
                @test length(entries) == 2
                popup_window = entries[1]
                while !Rocks.is_window(popup_window)
                    popup_window = popup_window.parent
                end
                @test popup_window !== w
                ex, ey = (entries[2].rect[1] + entries[2].rect[3] / 2,
                          entries[2].rect[2] + entries[2].rect[4] / 2)
                push_mouse!(popup_window, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, ex, ey)
                drain_events!()
                push_mouse!(popup_window, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, ex, ey)
                drain_events!()
                @test combo[] == 2
                @test changes[] == 1
            end
        end

        @testset "combo box long list popup" begin
            # A long options list caps the popup height and scrolls inside
            # it instead of growing past the screen.
            combo = Observable(1)
            items = ["item $i" for i in 1:30]
            function ComboLongApp()
                @rock Window(
                    @rock E.ComboBox(items = items; selected = combo,
                                     width = 200);
                    title = "combo long", width = 400, height = 220)
            end
            with_tree(ComboLongApp) do root
                w = sync_windows!(root)[1]
                combo_component = find_kind(root, E.ComboBox)
                arrow = first(p for p in collect_kind(combo_component, Pressable)
                              if p.rect[3] < 20)
                ax, ay = (arrow.rect[1] + arrow.rect[3] / 2,
                          arrow.rect[2] + arrow.rect[4] / 2)
                push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, ax, ay)
                drain_events!()
                push_mouse!(w, SDL3.SDL_EVENT_MOUSE_BUTTON_UP, ax, ay)
                drain_events!()
                Rocks.perform_render!(root)
                windows = sync_windows!(root)
                popup = windows[findfirst(x -> Bool(get(x.props, :popup, false)),
                                          windows)]
                @test popup.rect == (0, 0, 200, 300)
                scrollers = [c for c in collect_kind(popup, Box)
                             if get(c.props, :scroll, false)]
                @test length(scrollers) == 1
            end
        end

        @testset "bars and dialogs" begin
            fired = Ref(0)
            menus = [E.Menu("File", items = [
                E.MenuItem(label = "Exit", on_press = () -> fired[] += 1),
            ])]
            function MenuApp()
                @rock E.Form(
                    @rock E.Label("Body");
                    menu = (@rock E.MenuBar(menus = menus)),
                    title = "menu", width = 300, height = 200)
            end
            with_tree(MenuApp) do root
                sync_windows!(root)
                # The menu bar's row is also pressable and contains every menu
                # label; the actual menu button carries an explicit width.
                file = first(p for p in collect_kind(root, Pressable)
                             if text_of(p) == "File" &&
                                get(p.props, :width, nothing) !== nothing)
                file.props[:on_press]()
                Rocks.perform_render!(root)
                sync_windows!(root)
                exit_item = pressable_with(root, "Exit")
                @test exit_item !== nothing
                exit_item.props[:on_press]()
                @test fired[] == 1
                Rocks.perform_render!(root)
                @test pressable_with(root, "Exit") === nothing
            end

            # Menu titles stay flat — including on hover (no highlight, so the
            # plastic bar look survives) — and carry the recessed plastic
            # highlight only while their menu is open.
            with_tree(MenuApp) do root
                sync_windows!(root)
                tt = E.light_theme()
                file() = first(p for p in collect_kind(root, Pressable)
                               if text_of(p) == "File" &&
                                  get(p.props, :width, nothing) !== nothing)
                @test get(file().props, :background, nothing) === nothing
                # No hover highlight while closed…
                @test get(file().props, :hover_background, nothing) === nothing
                file().props[:on_press]()
                Rocks.perform_render!(root)
                sync_windows!(root)
                # …but the open title keeps its highlight under hover.
                @test file().props[:background] == tt.gradients.item_hot
                @test file().props[:hover_background] == tt.gradients.item_hot
                @test file().props[:border_color] == tt.colors.hot_border
                file().props[:on_press]()
                Rocks.perform_render!(root)
                sync_windows!(root)
                @test get(file().props, :background, nothing) === nothing
            end

            # Toolbar buttons: no hover highlight; highlight only while
            # pressed, and toggles stay plastic-highlighted while on.
            toggle = Observable(false)
            function ToolToggle()
                @rock E.ToolButton(label = "Bold", toggle = toggle)
            end
            with_tree(ToolToggle) do root
                tt = E.light_theme()
                btn = first(collect_kind(root, Pressable))
                @test get(btn.props, :background, nothing) === nothing
                # No hover highlight while off…
                @test get(btn.props, :hover_background, nothing) === nothing
                @test get(btn.props, :pressed_background, nothing) ==
                    tt.gradients.item_hot
                btn.props[:on_press]()
                @test toggle[] == true
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                btn = first(collect_kind(root, Pressable))
                @test btn.props[:background] == tt.gradients.item_hot
                # A toggled-on button keeps its highlight under hover too.
                @test btn.props[:hover_background] == tt.gradients.item_hot
                @test btn.props[:border_color] == tt.colors.hot_border
            end

            tool_clicks = Ref(0)
            function BarsApp()
                toolbar = @rock E.ToolBar(
                    (@rock E.ToolButton(label = "New", icon = "new",
                        on_press = () -> tool_clicks[] += 1)),
                    (@rock E.ToolSeparator()))
                status = @rock E.StatusBar(panels = [
                    E.StatusPanel(text = "Ready"),
                    E.StatusPanel(text = "3 objects", width = 100),
                ])
                @rock E.Form(
                    @rock E.Label("Client area");
                    toolbar = toolbar, status = status,
                    title = "bars", width = 320, height = 220)
            end
            with_tree(BarsApp) do root
                sync_windows!(root)
                @test occursin("Ready", text_of(root))
                @test occursin("3 objects", text_of(root))
                pressable_with(root, "New").props[:on_press]()
                @test tool_clicks[] == 1
                bars = [b for b in collect_kind(root, Box)
                        if get(b.props, :bevel, nothing) === :raised &&
                           get(b.props, :height, nothing) in (22, 28)]
                @test length(bars) >= 2
                # Resizing re-derives the client area: the scrolled client
                # starts below the toolbar and stops above the status bar.
                w = sync_windows!(root)[1]
                sv = find_kind(root, E.ScrollView)
                sv_y = sv.rect[2]
                stat = only(c for c in w.children if
                            c isa Rocks.Fiber &&
                            get(c.props, :anchor, nothing) === :bottom_left)
                w.host.height = 120
                w.host.needs_layout = true
                Rocks.measure!(w)
                Rocks.place!(w, 0.0, 0.0)
                @test sv.rect[2] == sv_y             # still below the toolbar
                @test sv.rect[2] + sv.rect[4] == stat.rect[2]  # above status
            end

            open = Observable(true)
            result = Observable(:none)
            function DialogApp()
                @rock E.MessageBox(open = open, title = "Confirm",
                    message = "Proceed?", buttons = :okcancel,
                    result = result)
            end
            with_tree(DialogApp) do root
                # The dialog mounts as its own OS window.
                wins = sync_windows!(root)
                @test count(w -> w.host isa Rocks.WindowState, wins) == 1
                @test occursin("Proceed?", text_of(root))
                dwin = wins[1]
                @test get(dwin.props, :title, "") == "Confirm"
                @test get(dwin.props, :resizable, true) == false
                pressable_with(root, "OK").props[:on_press]()
                @test result[] == :ok
                @test !open[]
                Rocks.perform_render!(root)
                wins = sync_windows!(root)
                @test pressable_with(root, "OK") === nothing
                # The dialog window closed with it.
                @test count(w -> w.host isa Rocks.WindowState, wins) == 0
            end

            ctx_open = Observable(true)
            ctx_fired = Ref(0)
            function ContextApp()
                @rock Window(
                    @rock E.ContextMenu(open = ctx_open, x = 10, y = 10,
                        items = [E.MenuItem(label = "Copy",
                            on_press = () -> ctx_fired[] += 1)]);
                    width = 200, height = 150)
            end
            with_tree(ContextApp) do root
                sync_windows!(root)
                copy = pressable_with(root, "Copy")
                @test copy !== nothing
                copy.props[:on_press]()
                @test ctx_fired[] == 1
                @test !ctx_open[]
                Rocks.perform_render!(root); Rocks.run_effects!()
                clean = sync_windows!(root)
                # The context menu mounts as its own borderless popup window
                # (owner + menu) and closes with its observable.
                @test count(w -> w.host isa Rocks.WindowState, clean) == 1
                @test pressable_with(root, "Copy") === nothing

                # Reopening creates the popup window again; a press anywhere
                # in the owner window then dismisses the menu (swallowed —
                # the item underneath never fires).
                ctx_open[] = true
                Rocks.perform_render!(root); Rocks.run_effects!()
                wins = sync_windows!(root)
                @test count(w -> w.host isa Rocks.WindowState, wins) == 2
                menu = [w for w in wins if Bool(get(w.props, :popup, false))][1]
                @test Bool(get(menu.props, :resizable, false)) == false
                @test get(menu.props, :menu_open, nothing) === ctx_open
                # Syncing a popup window must not touch its title or its
                # resizability: SDL3 rejects both on popup windows.
                @test (Rocks.sync_window!(menu); true)
                @test (Rocks.sync_window!([w for w in wins
                                           if !Bool(get(w.props, :popup, false))][1]); true)
                owner = [w for w in wins if !Bool(get(w.props, :popup, false))][1]
                push_mouse!(owner, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, 100, 100)
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                wins = sync_windows!(root)
                @test !ctx_open[]
                @test ctx_fired[] == 1
                @test count(w -> w.host isa Rocks.WindowState, wins) == 1

                # Escape dismisses menus too.
                ctx_open[] = true
                Rocks.perform_render!(root); Rocks.run_effects!()
                wins = sync_windows!(root)
                push_key!(wins[1], SDL3.SDLK_ESCAPE)
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                wins = sync_windows!(root)
                @test !ctx_open[]
                @test count(w -> w.host isa Rocks.WindowState, wins) == 1
            end

            function TipApp()
                @rock E.ToolTip((@rock E.Button("Hover")); text = "Tip text")
            end
            with_tree(TipApp) do root
                @test !occursin("Tip text", text_of(root))
                pressable_with(root, "Hover").props[:on_hover_in]()
                Rocks.perform_render!(root)
                @test occursin("Tip text", text_of(root))
                pressable_with(root, "Hover").props[:on_hover_out]()
                Rocks.perform_render!(root)
                @test !occursin("Tip text", text_of(root))
            end
        end

        @testset "scrollbars" begin
            function ScrollApp()
                @rock Window(
                    @rock ScrollView(
                        @rock Box(; width = 100, height = 300,
                                  background = (1, 1, 1));
                        position = :absolute, fill = true, scrollbar = true,
                        scrollbar_width = 17);
                    width = 100, height = 100)
            end
            with_tree(ScrollApp) do root
                w = sync_windows!(root)[1]
                sv = find_kind(w, ScrollView)
                @test sv.host.max_offset == 200
                @test sv.host.track_rect[3] == 17
                @test sv.host.thumb_rect[4] > 0
                # The thumb spans the full scrollbar width like the arrow
                # buttons (the stroke paints over the track edges).
                @test sv.host.thumb_rect[3] == 17
                @test sv.host.thumb_rect[1] == sv.host.arrow_a_rect[1]
                before = sv.host.offset
                tx, ty, tw, th = sv.host.track_rect
                push_mouse!(sv, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, tx + tw / 2), round(Int, ty + th - 5))
                drain_events!()
                sync_windows!(root)
                @test sv.host.offset > before
            end

            # Win7-style scrollbar: arrow buttons at each end. Clicking the
            # bottom arrow steps the viewport down; the top arrow steps up.
            with_tree(ScrollApp) do root
                w = sync_windows!(root)[1]
                sv = find_kind(w, ScrollView)
                a, b = sv.host.arrow_a_rect, sv.host.arrow_b_rect
                @test a[4] == 17 && b[4] == 17
                @test a[2] == 0
                @test b[2] + b[4] == 100
                @test sv.host.track_rect[2] == a[4]
                push_mouse!(sv, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, b[1] + b[3] / 2),
                            round(Int, b[2] + b[4] / 2))
                drain_events!()
                sync_windows!(root)
                @test sv.host.offset > 0
                push_mouse!(sv, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, a[1] + a[3] / 2),
                            round(Int, a[2] + a[4] / 2))
                drain_events!()
                sync_windows!(root)
                @test sv.host.offset == 0
            end
        end

        @testset "window resize re-layout" begin
            function ResizeApp()
                @rock Window(
                    @rock Box(fill = true, position = :absolute, height = 40,
                              background = (1.0, 1.0, 1.0));
                    width = 300, height = 200)
            end
            with_tree(ResizeApp) do root
                w = sync_windows!(root)[1]
                @test w.measured[1] == 300
                # What one SDL_WINDOWEVENT_RESIZED frame does: the host already
                # carries the new OS size and a full re-layout re-derives the
                # tree from it (the creation width must not win).
                w.host.width = 500
                Rocks.measure!(w)
                @test w.measured[1] == 500
                Rocks.place!(w, 0.0, 0.0)
                bar = find_kind(w, Box)
                @test bar.rect[3] == 500
            end
        end

        @testset "text input editing" begin
            text = Observable("Hello world")
            submitted = Ref(0)
            function EditApp()
                @rock E.TextBox(text = text, width = 240,
                                on_submit = () -> submitted[] += 1)
            end
            with_tree(EditApp) do root
                field = [f for f in collect_kind(root, Pressable)
                         if haskey(f.props, :on_key_mods)][1]
                # Plain keys: Backspace at the caret end removes the last
                # character; typing goes wherever the caret sits.
                field.props[:on_key_mods]("End", 0)
                field.props[:on_key]("Backspace")
                @test text[] == "Hello worl"
                field.props[:on_key_mods]("Home", 0)
                field.props[:on_text_input]("J")
                @test text[] == "JHello worl"
                # Shift+End selects forward from the Home caret; Backspace
                # wipes the selection.
                field.props[:on_key_mods]("End", 0x0001)
                field.props[:on_key]("Backspace")
                # The selection ran from the caret (after the inserted "J")
                # to the end, so only "J" survives.
                @test text[] == "J"
                # Ctrl+A select-all, then type over it.
                field.props[:on_text_input]("abc def")
                field.props[:on_key_mods]("a", 0x0040)
                field.props[:on_text_input]("X")
                @test text[] == "X"
                # Ctrl+Left jumps to the start of the current word.
                field.props[:on_text_input]("two words") # "X" + "two words"
                @test text[] == "Xtwo words"
                field.props[:on_key_mods]("End", 0)
                field.props[:on_key_mods]("Left", 0x0040) # before "words"
                field.props[:on_key]("Backspace")         # eats the separator
                @test text[] == "Xtwowords"
                field.props[:on_text_input](" ")          # types it back
                @test text[] == "Xtwo words"
                # Shift+Left selects the separator; Delete wipes it.
                field.props[:on_key_mods]("Left", 0x0001)
                field.props[:on_key]("Delete")
                @test text[] == "Xtwowords"
            end
        end

        @testset "selection resets on blur" begin
            text = Observable("a small field")
            function SelApp()
                @rock E.TextBox(text = text, width = 240)
            end
            with_tree(SelApp) do root
                field = first(f for f in collect_kind(root, Pressable)
                              if haskey(f.props, :on_key_mods))
                sel_boxes() = [b for b in collect_kind(root, Box)
                               if get(b.props, :position, nothing) === :absolute &&
                                  get(b.props, :background, nothing) ==
                                  E.light_theme().colors.selection]
                t = E.light_theme()
                # Focus the field and select the whole content.
                Rocks.FOCUSED[] = field
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                field.props[:on_key_mods]("Home", 0x0000)
                field.props[:on_key_mods]("End", 0x0001)
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                @test length(sel_boxes()) == 1
                # Blurring collapses the selection back to the caret.
                Rocks.FOCUSED[] = nothing
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                @test isempty(sel_boxes())
            end
        end

        @testset "text mouse selection and edit menu" begin
            text = Observable("copy me")
            function MouseApp()
                @rock Window(@rock E.TextBox(text = text, width = 200);
                             width = 300, height = 80)
            end
            with_tree(MouseApp) do root
                t = E.light_theme()
                tw(s) = Rocks.Enterprise.text_width(s, t)
                sync_windows!(root)
                field = first(f for f in collect_kind(root, Pressable)
                              if haskey(f.props, :on_key_mods))
                fx, fy, _, _ = field.rect
                rowx = first(collect_kind(root, Row)).rect[1]
                caret() = [b for b in collect_kind(root, Box) if
                           get(b.props, :position, nothing) === :absolute &&
                           get(b.props, :background, nothing) == t.colors.text &&
                           float(get(b.props, :width, 0)) == 1.0]
                sels() = [b for b in collect_kind(root, Box) if
                          get(b.props, :position, nothing) === :absolute &&
                          get(b.props, :background, nothing) == t.colors.selection]
                # Clicking right after the "copy " prefix places the caret
                # there (the caret box sits one selected char in).
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, rowx + tw("copy ") - 1),
                            round(Int, fy + 10))
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                sync_windows!(root)
                # A hovered text field shows the I-beam pointer. Headless
                # video drivers have no system cursors at all, so the
                # pointer is only checked where the driver supports it.
                if !Rocks.CURSORS_UNAVAILABLE[]
                    @test SDL3.GetCursor() == Rocks.TEXT_CURSOR[]
                end
                # The click completes: the caret stays at the boundary.
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                            round(Int, rowx + tw("copy ") - 1),
                            round(Int, fy + 10))
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                sync_windows!(root)
                @test length(caret()) == 1
                @test isapprox(caret()[1].rect[1] - rowx,
                               tw("copy ") + 1; atol = 2.0)
                # Hovering off the field (and other pressables) falls back to
                # the arrow pointer.
                push_motion!(field, 200, 60)
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                sync_windows!(root)
                if !Rocks.CURSORS_UNAVAILABLE[]
                    @test SDL3.GetCursor() == Rocks.ARROW_CURSOR[]
                end

                # Hold-and-drag selects: press after the "c" and drag to the
                # end → selection "opy me".
                s0 = round(Int, rowx + tw("c") - 1)
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN, s0,
                            round(Int, fy + 10))
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!(); sync_windows!(root)
                push_motion!(field, round(Int, rowx + tw("copy me")) + 30, round(Int, fy + 10))
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                            round(Int, rowx + tw("copy me")) + 30,
                            round(Int, fy + 10))
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!(); sync_windows!(root)
                @test length(sels()) == 1
                @test isapprox(sels()[1].rect[3],
                               tw("opy me"); atol = 3.0)
                # Copy through the field's right-click menu.
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, rowx + 5), round(Int, fy + 10);
                            button = 3)
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!(); sync_windows!(root)
                # The right-button release must not disturb the selection
                # (the caret used to jump to the click point on release and
                # collapse the drag selection).
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_UP,
                            round(Int, rowx + 5), round(Int, fy + 10);
                            button = 3)
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!(); sync_windows!(root)
                @test length(sels()) == 1
                @test isapprox(sels()[1].rect[3], tw("opy me"); atol = 3.0)
                copy_item = pressable_with(root, "Copy")
                @test copy_item !== nothing
                copy_item.props[:on_press]()
                @test Rocks.Enterprise.clipboard_get_text() == "opy me"
                # The item press closes the menu; re-render so the overlay is
                # gone before the next interaction.
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                sync_windows!(root)
                @test pressable_with(root, "Copy") === nothing

                # Paste through the menu at the start of the field.
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, rowx - 2), round(Int, fy + 10))
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!(); sync_windows!(root)
                push_mouse!(field, SDL3.SDL_EVENT_MOUSE_BUTTON_DOWN,
                            round(Int, rowx + 5), round(Int, fy + 10);
                            button = 3)
                drain_events!()
                Rocks.perform_render!(root)
                Rocks.run_effects!(); sync_windows!(root)
                paste_item = pressable_with(root, "Paste")
                @test paste_item !== nothing
                paste_item.props[:on_press]()
                @test text[] == "opy mecopy me"
            end
        end

        @testset "slider knob and ticks" begin
            value = Observable(2.0)
            function TickApp()
                @rock Window(
                    @rock Slider(value = value, min = 0, max = 4, width = 100,
                                 ticks = 4, tick_color = (1.0, 0.0, 0.0));
                    width = 100, height = 24)
            end
            with_tree(TickApp) do root
                # A second render cycle stabilizes the freshly built tree.
                win = sync_windows!(root)[1]
                Rocks.perform_render!(root)
                Rocks.run_effects!()
                win = sync_windows!(root)[1]
                path = joinpath(mktempdir(), "slider.png")
                Rocks.screenshot(win, path)
                isred(px) = px[1] > 200 && px[2] < 200
                bg = (0x1f, 0x1f, 0x24, 0xff) # the default window background
                # Ticks sit exactly where the knob's center lands: at value 2
                # the middle tick, knob center and x=50 agree; the end ticks
                # sit a half-knob in from the widget edges (which the knob
                # cannot reach — the old mapping put ticks at x=0 and x=100).
                @test isred(png_pixel(path, 7, 22))
                @test isred(png_pixel(path, 51, 22))
                @test isred(png_pixel(path, 95, 22))
                @test png_pixel(path, 1, 22) == bg
                @test png_pixel(path, 100, 22) == bg
            end
        end

        @testset "tab seam and label sizes" begin
            tab = Observable(1)
            function SeamApp()
                @rock E.ThemeContext.provider(
                    @rock E.TabControl(tabs = ["A", "B"], selected = tab,
                        children = Any[@rock E.Label("Alpha"),
                                       @rock E.Label("Beta")],
                        fill = true);
                    value = E.light_theme())
            end
            with_tree(SeamApp) do root
                t = E.light_theme()
                # The selected tab is two pixels taller (Winforms raise).
                tall = [p for p in collect_kind(root, Pressable) if
                        float(get(p.props, :height, 0)) ==
                        float(t.metrics.tab_height + 2)]
                @test length(tall) == 1
                # A three-pixel patch paints over the seam band under the
                # selected tab (its bottom ring, the blank raise row and the
                # page's top border slice) so the tab merges into the page;
                # the tab's side border columns stay untouched.
                seams() = [b for b in collect_kind(root, Box) if
                           get(b.props, :position, nothing) === :absolute &&
                           float(get(b.props, :height, 0)) == 3.0]
                @test length(seams()) == 1
                @test seams()[1].props[:background] == t.colors.document
                @test float(seams()[1].props[:x]) == 1
                @test float(seams()[1].props[:y]) == float(t.metrics.tab_height)
                tab[] = 2
                Rocks.perform_render!(root)
                @test length(seams()) == 1
                @test float(seams()[1].props[:x]) > 0
            end

            function LabelsTheme()
                @rock E.ThemeContext.provider(
                    @rock E.Column(
                        @rock E.CheckBox(checked = Observable(true),
                                         label = "Check"),
                        @rock E.RadioButton(selected = Observable(1),
                                            value = 1, label = "One");
                        gap = 8);
                    value = E.light_theme())
            end
            with_tree(LabelsTheme) do root
                fs = float(E.light_theme().metrics.font_size)
                for needle in ("Check", "One")
                    hits = [tx for tx in collect_kind(root, Text) if
                            Rocks.text_content(tx) == needle]
                    @test length(hits) == 1
                    @test float(hits[1].props[:size]) == fs
                end
            end
        end

        @testset "tab seam geometry" begin
            tab = Observable(2)
            function SeamWin()
                @rock Window(
                    E.ThemeContext.provider(
                        children = Any[
                            E.TabControl(tabs = ["A", "B", "C"],
                                         selected = tab,
                                         children = Any[E.Label(; text = "One"),
                                                        E.Label(; text = "Two"),
                                                        E.Label(; text = "Three")],
                                         fill = true)],
                        value = E.light_theme());
                    width = 200, height = 120)
            end
            with_tree(SeamWin) do root
                t = E.light_theme()
                sync_windows!(root)
                tab[] = 3
                Rocks.perform_render!(root)
                sync_windows!(root)
                seams() = [b for b in collect_kind(root, Box) if
                           get(b.props, :position, nothing) === :absolute &&
                           float(get(b.props, :height, 0)) == 3.0]
                @test length(seams()) == 1
                # No cumulative drift: the patch hugs the placed tab exactly
                # one pixel inside on the x sides, however late in the strip
                # the selected tab runs.
                tabs = [p for p in collect_kind(root, Pressable) if
                        float(get(p.props, :height, 0)) in
                        (float(t.metrics.tab_height),
                         float(t.metrics.tab_height + 2))]
                raised = [p for p in tabs if
                          p.rect[4] == float(t.metrics.tab_height + 2)]
                @test length(tabs) == 3
                @test length(raised) == 1
                patch = seams()[1]
                @test patch.rect[1] == raised[1].rect[1] + 1
                @test patch.rect[3] == raised[1].rect[3] - 2
            end
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

        @testset "clipping" begin
            # `overflow = :hidden` keeps the content of a box inside it: a
            # text that is wider than the box is clipped instead of running
            # over its border.
            RED = (0.9, 0.2, 0.2)
            function ClipApp()
                @rock Window(
                    @rock Box(
                        @rock Text("a long text that does not fit";
                                   color = (1.0, 1.0, 1.0));
                        background = RED, width = 60, height = 40,
                        overflow = :hidden);
                    title = "clip", width = 200, height = 120)
            end
            with_tree(ClipApp) do root
                windows = sync_windows!(root)
                path = joinpath(mktempdir(), "clip.png")
                @test Rocks.screenshot(windows[1], path) == path
                white(x, y) = png_pixel(path, x, y) == (0xff, 0xff, 0xff, 0xff)
                whites(xs) = sum(x -> sum(y -> white(x, y) ? 1 : 0, 1:39), xs)
                # The text is painted inside the box ...
                @test whites(1:59) > 0
                # ... and clipped away right of it.
                @test whites(61:190) == 0
            end
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
