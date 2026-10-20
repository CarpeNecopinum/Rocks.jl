# GTK4 backend: native widget creation, prop application, CSS, screenshots.
#
# Every host element kind maps onto a native GTK widget; GTK does the layout,
# hit-testing, rendering and theming. All GTK calls live in this file (plus
# events.jl for signal wiring), keeping the reconciler and hooks headless
# with respect to GUI state.
#
# The sync model: `perform_render!` (fiber.jl) reconciles the fiber tree
# without touching GTK. `sync_backend!` then walks the tree, creating widgets
# for new fibers, attaching them to their container GTK widgets in document
# order, applying props and creating/destroying OS windows. Component fibers
# are transparent: their children parent to the nearest ancestor container
# (or the implicit root box of an enclosing window).

const G_ = Gtk4.G_

using Downloads
using ColorTypes: Colorant, RGBA

# ---- colors --------------------------------------------------------------

# Normalize a user color into a CSS color string. Accepted: hex strings
# ("#rgb"/"#rrggbb"/"#rrggbbaa"), CSS color names ("red"), tuples/vectors of
# 3-4 numbers (all-integer → 0-255 scale, any float → 0-1 scale), and
# ColorTypes colors.
function css_color(c::AbstractString)
    startswith(c, "#") || return String(c)
    s = c[2:end]
    n = length(s)
    n in (3, 6, 8) || error("hex colors need 3, 6 or 8 digits, got: \"$c\"")
    n == 3 && return string("#", s[1], s[1], s[2], s[2], s[3], s[3])
    return String(c)
end

function css_color(c::Colorant)
    rgba = RGBA{Float64}(c)
    f(x) = round(clamp(x, 0.0, 1.0); digits = 3)
    return "rgba($(round(Int, clamp(rgba.r, 0, 1) * 255)), " *
           "$(round(Int, clamp(rgba.g, 0, 1) * 255)), " *
           "$(round(Int, clamp(rgba.b, 0, 1) * 255)), $(f(rgba.alpha)))"
end

function css_color(c::Union{Tuple,Vector})
    length(c) in 3:4 || error("colors need 3 or 4 components, got: $c")
    rgb = ntuple(i -> begin
        v = c[i]
        all(x -> x isa Integer, c) ? clamp(Int(v), 0, 255) :
        round(Int, clamp(Float64(v), 0.0, 1.0) * 255)
    end, 3)
    a = length(c) == 4 ? c[4] : (all(x -> x isa Integer, c) ? 1.0 : 1.0)
    a = all(x -> x isa Integer, c) ? clamp(Float64(a), 0, 255) / 255 :
        clamp(Float64(a), 0.0, 1.0)
    return "rgba($(rgb[1]), $(rgb[2]), $(rgb[3]), $(round(a; digits = 3)))"
end

# ---- backend state -------------------------------------------------------

"Per-window backend state: the `GtkWindow` and the implicit root `GtkBox`
receiving the window's children."
mutable struct WindowHost
    window::Any
    box::Any
    visible::Bool
end

# Per-widget CSS: the rule for a widget's unique class, carried by a
# GtkCssProvider added to the widget's own style context (so descendants are
# unaffected). widget -> (provider, css class, rule)
const STYLES = Dict{Any,Tuple{Any,String,String}}()
const CSS_ID = Ref(0)
const STYLE_PRIORITY = Gtk4.STYLE_PROVIDER_PRIORITY_APPLICATION

# Per-fiber backend flags (e.g. a Paned whose number `ratio` was seeded).
const SEEDED = WeakKeyDict{Any,Bool}()

# Compare two widget wrappers by their GObject identity (fetched children may
# be fresh wrapper objects for the same GObject).
_same_widget(a, b) =
    a !== nothing && b !== nothing && getfield(a, :handle) == getfield(b, :handle)

"""
    init_backend()

Called once before the first render. GTK initializes lazily — the display
opens when the first `GtkWindow` is created — so there is nothing to do.
"""
init_backend() = nothing

"""
    shutdown_backend()

Called after the application unmounts. Window teardown happens per fiber in
[`backend_unmount!`](@ref); nothing global to release.
"""
shutdown_backend() = nothing

# ---- widget creation -----------------------------------------------------

"G_H / :v symbols from Rocks' direction props."
function _orientation_h(props; default_h::Bool)
    d = Symbol(get(props, :direction, default_h ? :row : :column))
    d === :row && return true
    d === :column && return false
    error("direction must be :row or :column, got $d")
end

function _paned_vertical(props)
    d = Symbol(get(props, :direction, :horizontal))
    d === :vertical && return true
    d === :horizontal && return false
    error("direction must be :horizontal or :vertical, got $d")
end

# Stringified text content of a fiber (label/button children).
function text_content(fiber)
    content = get(fiber.props, :content, nothing)
    content !== nothing && return string(content)
    parts = String[]
    for child in fiber.props[:children]
        (child isa Element || child === nothing || child isa Bool) && continue
        push!(parts, string(child))
    end
    return join(parts, "")
end

# The options of a DropDown: the `options` prop or the call's children.
function dropdown_options(fiber)
    opts = get(fiber.props, :options, nothing)
    opts === nothing && (opts = fiber.props[:children])
    return String[string(o) for o in flat_children(opts)]
end

# Create (or return the existing) GTK widget of a host fiber. Windows are
# created in `sync_window!` instead.
function create_widget!(fiber)
    fiber.host !== nothing && return fiber.host
    props = fiber.props
    host = if fiber.kind === _BOX
        GtkBox(
            _orientation_h(props; default_h = false) ? Gtk4.Orientation_HORIZONTAL :
            Gtk4.Orientation_VERTICAL,
            Int(get(props, :gap, 0)),
        )
    elseif fiber.kind === _LABEL
        GtkLabel(text_content(fiber))
    elseif fiber.kind === _BUTTON
        label = get(props, :label, nothing)
        GtkButton(label === nothing ? text_content(fiber) : string(label))
    elseif fiber.kind === _PICTURE
        path = resolve_image_src(string(get(props, :src, "")))
        path === nothing ? G_.Picture_new() : G_.Picture_new_for_filename(path)
    elseif fiber.kind === _PANED
        GtkPaned(_paned_vertical(props) ? Gtk4.Orientation_VERTICAL :
                 Gtk4.Orientation_HORIZONTAL)
    elseif fiber.kind === _SCALE
        GtkScale(Gtk4.Orientation_HORIZONTAL, float(get(props, :min, 0)),
                 float(get(props, :max, 1)), _scale_step(props))
    elseif fiber.kind === _CHECKBUTTON
        label = get(props, :label, nothing)
        label === nothing ? GtkCheckButton() : GtkCheckButton(string(label))
    elseif fiber.kind === _SWITCH
        on = get(props, :on, nothing)
        GtkSwitch(on isa Observable ? Bool(on[]) : on === true)
    elseif fiber.kind === _PROGRESSBAR
        GtkProgressBar()
    elseif fiber.kind === _DROPDOWN
        GtkDropDown(dropdown_options(fiber))
    elseif fiber.kind === _NOTEBOOK
        GtkNotebook()
    elseif fiber.kind === _ENTRY
        GtkEntry()
    else
        error("no GTK widget for host kind: $(fiber.kind)")
    end
    fiber.host = host
    wire_events!(fiber)
    return host
end

_scale_step(props) = begin
    lo = float(get(props, :min, 0))
    hi = float(get(props, :max, 1))
    max(abs(hi - lo) / 100, 1e-6)
end

# ---- windows -------------------------------------------------------------

function create_window!(fiber)
    props = fiber.props
    title = string(get(props, :title, "Rocks"))
    width = Int(get(props, :width, 800))
    height = Int(get(props, :height, 600))
    resizable = Bool(get(props, :resizable, false))
    win = GtkWindow(title, width, height, resizable, true)
    box = GtkBox(Gtk4.Orientation_VERTICAL, 0)
    win[] = box
    host = WindowHost(win, box, true)
    fiber.host = host
    wire_window_events!(fiber)
    return host
end

function destroy_window!(fiber)
    fiber.host isa WindowHost || return
    delete!(STYLES, fiber.host.box)
    Gtk4.destroy(fiber.host.window)
    fiber.host = nothing
    return nothing
end

# Re-apply window props that the user may have changed between renders, and
# create the OS window on first sight.
function sync_window!(fiber)
    fiber.host isa WindowHost || create_window!(fiber)
    host = fiber.host
    props = fiber.props
    title = string(get(props, :title, "Rocks"))
    Gtk4.title(host.window) != title &&
        Gtk4.set_gtk_property!(host.window, :title, title)
    resizable = Bool(get(props, :resizable, false))
    Bool(Gtk4.get_gtk_property(host.window, :resizable)) != resizable &&
        Gtk4.set_gtk_property!(host.window, :resizable, resizable)
    # the window's implicit root box takes the box props (`direction`, `gap`,
    # `padding`, `align`, `background`, `border_*`, `radius`)
    apply_box_props!(host.box, props; sizeable = false)
    return host
end

# ---- images --------------------------------------------------------------

const IMAGE_CACHE_DIR = Ref{Union{Nothing,String}}(nothing)

# Resolve a `Picture` `src` prop: local paths pass through; URLs are fetched
# with `Downloads` into a per-session cache directory. Returns `nothing` when
# the source cannot be resolved.
function resolve_image_src(src)
    isempty(src) && return nothing
    if startswith(src, "http://") || startswith(src, "https://")
        if IMAGE_CACHE_DIR[] === nothing
            IMAGE_CACHE_DIR[] = mkpath(joinpath(tempdir(), "rocks-images"))
        end
        name = string(hash(src), ".", lowercase(splitext(src)[2]))
        path = joinpath(IMAGE_CACHE_DIR[], name)
        isfile(path) && return path
        try
            Downloads.download(src, path)
        catch err
            @warn "Rocks: could not download image" src exception = err
            return nothing
        end
        return path
    end
    return isfile(src) ? src : nothing
end

# ---- CSS -----------------------------------------------------------------

# Apply a per-widget CSS rule. `f(cls)` builds the rule text for the widget's
# unique CSS class (`cls`); an empty result styles nothing. Re-rendering with
# a changed rule reloads the provider in place.
function style!(f::Function, widget)
    entry = get(STYLES, widget, nothing)
    if entry === nothing
        CSS_ID[] += 1
        cls = "rocks-$(CSS_ID[])"
        rule = String(f(cls))
        isempty(strip(rule)) && return
        prov = GtkCssProvider(rule)
        push!(G_.get_style_context(widget), prov, STYLE_PRIORITY)
        G_.add_css_class(widget, cls)
        STYLES[widget] = (prov, cls, rule)
    else
        rule = String(f(entry[2]))
        rule == entry[3] && return
        G_.load_from_data(entry[1], rule, -1)
        STYLES[widget] = (entry[1], entry[2], rule)
    end
    return nothing
end

# The base styling rules shared by box-like widgets.
function box_css_parts(props)
    parts = String[]
    bg = get(props, :background, nothing)
    bg !== nothing && push!(parts, "background: $(css_color(bg));")
    bc = get(props, :border_color, nothing)
    bw = Int(get(props, :border_width, 0))
    bc !== nothing && bw > 0 &&
        push!(parts, "border: $(bw)px solid $(css_color(bc));")
    radius = get(props, :radius, nothing)
    radius !== nothing && push!(parts, "border-radius: $(Int(radius))px;")
    return parts
end

# ---- prop application ----------------------------------------------------

function margins!(widget, props)
    padding = get(props, :padding, nothing)
    padding === nothing && return
    p = Int(padding)
    for m in (:margin_start, :margin_end, :margin_top, :margin_bottom)
        Gtk4.set_gtk_property!(widget, m, p)
    end
    return nothing
end

function size_requests!(widget, props)
    w = get(props, :width, nothing)
    h = get(props, :height, nothing)
    (w === nothing && h === nothing) && return
    Gtk4.size_request(
        widget,
        (w === nothing ? -1 : Int(w), h === nothing ? -1 : Int(h)),
    )
    return nothing
end

# GTK align name (:start/:center/:end) → Gtk4.Align_* value; nothing = FILL.
function _gtk_align(v)
    v === nothing && return nothing
    a = Symbol(v)
    a === :start && return Gtk4.Align_START
    a === :center && return Gtk4.Align_CENTER
    a === :end && return Gtk4.Align_END
    error("align must be :start, :center or :end, got $v")
end

# Apply the box props (`direction`, `gap`, `align`, `padding`, `background`,
# `border_*`, `radius`) to a GtkBox. Shared by `Box` elements and each
# `Window`'s implicit root box. `sizeable` also applies `width`/`height` size
# requests — disabled for a window's root box, whose size is the top-level
# window's.
function apply_box_props!(box, props; sizeable = true)
    horizontal = _orientation_h(props; default_h = false)
    Gtk4.set_gtk_property!(
        box, :orientation,
        horizontal ? Gtk4.Orientation_HORIZONTAL : Gtk4.Orientation_VERTICAL,
    )
    Gtk4.set_gtk_property!(box, :spacing, Int(get(props, :gap, 0)))
    align = _gtk_align(get(props, :align, nothing))
    align !== nothing &&
        Gtk4.set_gtk_property!(box, horizontal ? :valign : :halign, align)
    margins!(box, props)
    sizeable && size_requests!(box, props)
    style!(box) do cls
        parts = box_css_parts(props)
        isempty(parts) ? "" : ".$cls { $(join(parts, " ")) }"
    end
    return nothing
end

# Apply the props of a host fiber to its widget. Called on every sync pass;
# setting a GTK property to its current value is a cheap no-op.
function apply_props!(fiber)
    kind = fiber.kind
    kind === _WINDOW && return sync_window!(fiber)
    host = fiber.host
    host === nothing && return
    props = fiber.props

    if kind === _BOX
        apply_box_props!(host, props)
    elseif kind === _LABEL
        Gtk4.set_gtk_property!(host, :label, text_content(fiber))
        Gtk4.set_gtk_property!(host, :wrap, get(props, :wrap, false) === true)
        align = Symbol(get(props, :align, :start))
        xalign = align === :center ? 0.5 : align === :end ? 1.0 : 0.0
        Gtk4.set_gtk_property!(host, :xalign, xalign)
        style!(host) do cls
            parts = box_css_parts(props)
            color = get(props, :color, nothing)
            color !== nothing && push!(parts, "color: $(css_color(color));")
            size = get(props, :size, nothing)
            size !== nothing && push!(parts, "font-size: $(Float64(size))px;")
            isempty(parts) ? "" : ".$cls { $(join(parts, " ")) }"
        end
    elseif kind === _BUTTON
        # the label is only shown when there are no element children (a child
        # widget, if any, attaches in `sync_container_children!`)
        if !any(c -> c isa Element, props[:children])
            label = get(props, :label, nothing)
            Gtk4.set_gtk_property!(
                host, :label,
                label === nothing ? text_content(fiber) : string(label),
            )
        end
        Gtk4.set_gtk_property!(host, :sensitive, get(props, :disabled, false) !== true)
        margins!(host, props)
        size_requests!(host, props)
        style!(host) do cls
            parts = box_css_parts(props)
            base = isempty(parts) ? "" : ".$cls { $(join(parts, " ")) }"
            hover = get(props, :hover_background, nothing)
            hover === nothing ||
                (base = string(base, " .$cls:hover { background: $(css_color(hover)); }"))
            pressed = get(props, :pressed_background, nothing)
            pressed === nothing ||
                (base = string(base, " .$cls:active { background: $(css_color(pressed)); }"))
            return base
        end
    elseif kind === _PICTURE
        src = string(get(props, :src, ""))
        path = isempty(src) ? nothing : resolve_image_src(src)
        G_.set_filename(host, path)  # accepts nothing
        w = get(props, :width, nothing)
        h = get(props, :height, nothing)
        both = w !== nothing && h !== nothing
        Gtk4.set_gtk_property!(host, :keep_aspect_ratio, !both)
        Gtk4.set_gtk_property!(
            host, :content_fit,
            both ? Gtk4.ContentFit_FILL : Gtk4.ContentFit_CONTAIN,
        )
        size_requests!(host, props)
    elseif kind === _PANED
        _sync_paned_position!(fiber)
        size_requests!(host, props)
    elseif kind === _SCALE
        adj = Gtk4.adjustment(host)
        lo = float(get(props, :min, 0))
        hi = float(get(props, :max, 1))
        (G_.get_lower(adj) != lo || G_.get_upper(adj) != hi) &&
            Gtk4.configure!(adj; lower = lo, upper = hi)
        value = get(props, :value, nothing)
        want = value isa Observable ? Float64(value[]) : float(value)
        G_.get_value(adj) != want && G_.set_value(adj, clamp(want, lo, hi))
        size_requests!(host, props)
        style!(host) do cls
            parts = box_css_parts(props)
            isempty(parts) ? "" : ".$cls { $(join(parts, " ")) }"
        end
    elseif kind === _CHECKBUTTON
        checked = get(props, :checked, nothing)
        want = checked isa Observable ? Bool(checked[]) : checked === true
        Bool(Gtk4.get_gtk_property(host, :active)) != want &&
            Gtk4.set_gtk_property!(host, :active, want)
        label = get(props, :label, nothing)
        label !== nothing &&
            Gtk4.set_gtk_property!(host, :label, string(label))
        Gtk4.set_gtk_property!(host, :sensitive, get(props, :disabled, false) !== true)
        margins!(host, props)
    elseif kind === _SWITCH
        on = get(props, :on, nothing)
        want = on isa Observable ? Bool(on[]) : on === true
        Bool(Gtk4.get_gtk_property(host, :active)) != want &&
            Gtk4.set_gtk_property!(host, :active, want)
        Gtk4.set_gtk_property!(host, :sensitive, get(props, :disabled, false) !== true)
        # a stretched switch looks odd; keep it at one end unless aligned
        align = _gtk_align(get(props, :align, :start))
        align !== nothing && Gtk4.set_gtk_property!(host, :halign, align)
        margins!(host, props)
    elseif kind === _PROGRESSBAR
        fraction = get(props, :fraction, 0.0)
        f = fraction isa Observable ? Float64(fraction[]) : Float64(fraction)
        f = clamp(f, 0.0, 1.0)
        Gtk4.fraction(host) != f && Gtk4.set_gtk_property!(host, :fraction, f)
    elseif kind === _DROPDOWN
        _sync_dropdown!(fiber)
        size_requests!(host, props)
        margins!(host, props)
    elseif kind === _NOTEBOOK
        selected = get(props, :selected, nothing)
        want = selected isa Observable ? Int(selected[]) : selected
        if want !== nothing && 1 <= want <= length(host)
            G_.get_current_page(host) + 1 != want &&
                G_.set_current_page(host, want - 1)
        end
    elseif kind === _ENTRY
        text = get(props, :text, nothing)
        want = text isa Observable ? String(text[]) :
               text === nothing ? nothing : string(text)
        if want !== nothing && Gtk4.get_gtk_property(host, :text) != want
            Gtk4.set_gtk_property!(host, :text, want)
        end
        ph = get(props, :placeholder, nothing)
        ph === nothing ||
            Gtk4.set_gtk_property!(host, :placeholder_text, string(ph))
        size_requests!(host, props)
    end
    return nothing
end

# Paned `ratio`: a number seeds the position once (so dragging is not
# overwritten on re-renders); an Observable is applied on every sync (the
# notify::position handler writes back the dragged fraction, and values agree
# so no loop occurs).
function _sync_paned_position!(fiber)
    host = fiber.host
    ratio = get(fiber.props, :ratio, nothing)
    vertical = Int(Gtk4.get_gtk_property(host, :orientation)) == 1
    size = vertical ? Int(Gtk4.G_.get_height(host)) : Int(Gtk4.G_.get_width(host))
    size > 0 || return
    if ratio isa Observable
        pos = clamp(round(Int, Float64(ratio[]) * size), 0, size)
        G_.get_position(host) != pos && G_.set_position(host, pos)
    else
        want = ratio === nothing ? 0.5 : Float64(ratio)
        get!(SEEDED, fiber) do
            G_.set_position(host, clamp(round(Int, want * size), 0, size))
            true
        end
    end
    return nothing
end

# DropDown options/selection: rebuild the string model when the options
# changed (selection resets; the `selected` prop re-applies it).
function _sync_dropdown!(fiber)
    host = fiber.host
    props = fiber.props
    opts = dropdown_options(fiber)
    model = G_.get_model(host)
    current = model === nothing ? String[] : String[string(s) for s in collect(model)]
    if current != opts
        G_.set_model(host, G_.StringList_new(opts))
    end
    selected = get(props, :selected, nothing)
    want = selected isa Observable ? Int(selected[]) : selected
    if want !== nothing && 1 <= want <= length(opts)
        Int(G_.get_selected(host)) + 1 != want &&
            G_.set_selected(host, UInt32(want - 1))
    end
    return nothing
end

# ---- container children --------------------------------------------------

# Attach `kids` (the host widgets of a container's subtree, in document
# order) to the container's GTK widget.
function sync_container_children!(fiber, kids)
    kind = fiber.kind
    kind === _WINDOW && return sync_box_children!(fiber.host.box, kids)
    kind === _BOX && return sync_box_children!(fiber.host, kids)
    if kind === _PANED
        pane = fiber.host
        set_pane!(pane, 1, length(kids) >= 1 ? kids[1] : nothing)
        set_pane!(pane, 2, length(kids) >= 2 ? kids[2] : nothing)
    elseif kind === _BUTTON
        btn = fiber.host
        if isempty(kids)
            _same_widget(Gtk4.G_.get_child(btn), nothing) || (btn[] = nothing)
        else
            _same_widget(Gtk4.G_.get_child(btn), kids[1]) || (btn[] = kids[1])
        end
    elseif kind === _NOTEBOOK
        sync_notebook_pages!(fiber, kids)
    end
    return nothing
end

# Keep a GtkBox's children in document order. A mismatch (insertion, removal
# or replacement) rebuilds the list: removal only unparents (the fiber keeps
# the widget alive), so re-appending is cheap.
function sync_box_children!(box, kids)
    current = collect(box)
    if length(current) == length(kids) &&
       all(i -> _same_widget(current[i], kids[i]), eachindex(kids))
        return
    end
    empty!(box)
    for w in kids
        push!(box, w)
    end
    return nothing
end

function set_pane!(pane, i::Int, widget)
    current = i == 1 ? Gtk4.G_.get_start_child(pane) : Gtk4.G_.get_end_child(pane)
    _same_widget(current, widget) && return
    if i == 1
        pane[1] = widget
    else
        pane[2] = widget
    end
    return nothing
end

function sync_notebook_pages!(fiber, kids)
    nb = fiber.host
    tabs = get(fiber.props, :tabs, nothing)
    tab_label(i) = begin
        t = tabs === nothing ? nothing : (i <= length(tabs) ? tabs[i] : nothing)
        t === nothing ? "Page $i" : string(t)
    end
    pages = length(nb)
    mismatch = pages != length(kids)
    if !mismatch
        for i in 1:pages
            page = Gtk4.G_.get_nth_page(nb, i - 1)
            if !_same_widget(page, kids[i])
                mismatch = true
                break
            end
        end
    end
    if mismatch
        empty!(nb)
        for (i, w) in enumerate(kids)
            push!(nb, w, tab_label(i))
        end
    else
        for (i, w) in enumerate(kids)
            G_.set_tab_label_text(nb, w, tab_label(i))
        end
    end
    return nothing
end

# ---- the sync walk -------------------------------------------------------

# Walk a fiber subtree: create widgets, attach container children in document
# order, apply props. Returns the widgets this subtree contributes to the
# enclosing container (windows contribute nothing — they are toplevels; every
# other host fiber contributes its widget; component fibers are transparent).
function sync_backend!(fiber)
    if is_window(fiber)
        sync_window!(fiber)
        kids = Any[]
        for child in fiber.children
            append!(kids, sync_backend!(child))
        end
        sync_container_children!(fiber, kids)
        return Any[]
    elseif is_host(fiber.kind)
        host = create_widget!(fiber)
        kids = Any[]
        for child in fiber.children
            append!(kids, sync_backend!(child))
        end
        sync_container_children!(fiber, kids)
        apply_props!(fiber)
        return Any[host]
    else
        kids = Any[]
        for child in fiber.children
            append!(kids, sync_backend!(child))
        end
        return kids
    end
end

# ---- unmount -------------------------------------------------------------

# Release the widget of an unmounting fiber: windows are destroyed, regular
# widgets are unparented (dropped) and freed by the GC.
function backend_unmount!(fiber)
    if is_window(fiber)
        return destroy_window!(fiber)
    end
    widget = fiber.host
    widget === nothing && return
    unparent_widget!(widget)
    delete!(STYLES, widget)
    fiber.host = nothing
    return nothing
end

"Drop `widget` from its GTK parent so it disappears immediately."
function unparent_widget!(widget)
    Gtk4.hasparent(widget) || return
    parent = Gtk4.parent(widget)
    if parent isa Gtk4.GtkBox
        delete!(parent, widget)
    elseif parent isa Gtk4.GtkPaned
        for i in 1:2
            current = i == 1 ? Gtk4.G_.get_start_child(parent) :
                      Gtk4.G_.get_end_child(parent)
            _same_widget(current, widget) && set_pane!(parent, i, nothing)
        end
    elseif parent isa Gtk4.GtkNotebook
        for i in 1:length(parent)
            _same_widget(Gtk4.G_.get_nth_page(parent, i - 1), widget) &&
                (deleteat!(parent, i); break)
        end
    elseif parent isa Union{Gtk4.GtkWindow,Gtk4.GtkButton}
        _same_widget(parent[], widget) && (parent[] = nothing)
    end
    return nothing
end

# ---- screenshots ---------------------------------------------------------

# The first fiber in a subtree with a live OS window.
function find_window_fiber(fiber)
    is_window(fiber) && fiber.host isa WindowHost && return fiber
    for child in fiber.children
        found = find_window_fiber(child)
        found !== nothing && return found
    end
    return nothing
end

# Pump the GLib main context until every visible window is mapped and has a
# size allocation. Mapping/layout is asynchronous (the compositor needs
# several context iterations) — a fixed small pump count races with it, which
# made screenshots intermittent. Bounded; returns whether all were mapped.
function wait_windows_mapped!(root; attempts = 300)
    for _ in 1:attempts
        wins = collect_windows!(Fiber[], root)
        visible = [w for w in wins if w.host isa WindowHost && !w.hidden]
        isempty(visible) && return true
        mapped_and_sized(w) = begin
            win = w.host.window
            Bool(Gtk4.G_.get_mapped(win)) && Int(Gtk4.G_.get_width(win)) > 0 &&
                Int(Gtk4.G_.get_height(win)) > 0
        end
        all(mapped_and_sized, visible) && return true
        pump(1)
    end
    return false
end

"""
    screenshot(window, path) -> path

Capture the current appearance of a window into a PNG file at `path` and
return `path`. `window` is the root fiber of a rendered tree (the first
window found in the tree is captured) or a window fiber. The window must be
mapped — in the interactive loop it always is; in bounded `frames` runs the
frames pump the GLib main context first.

For trees with several windows, pass the specific window fiber to capture a
different one.
"""
function screenshot(window, path::AbstractString)
    window isa Fiber ||
        error("screenshot expects a rendered window or root fiber, got: $(typeof(window))")
    fiber = find_window_fiber(window)
    fiber === nothing && error("no rendered window found in the given fiber tree")
    fiber.host isa WindowHost || error("the window has not been synced/created yet")
    wait_windows_mapped!(fiber) ||
        error("the window is still not mapped after pumping (no compositor/display?)")
    return widget_png(fiber.host.window, String(path))
end

# GtkWidgetPaintable → render node → Cairo ARGB surface → PNG. Requires the
# widget to be mapped. (`gtk_widget_snapshot` is GTK-private in 4.12.)
#
# A snapshot taken while the widget is mid-invalidate (its layout was just
# changed) yields a NULL render node — the PNG would be blank. Pumping the
# main context lets GTK re-layout, so the snapshot is retried until it
# produces a node.
function widget_png(widget, path)
    w = Int(Gtk4.G_.get_width(widget))
    h = Int(Gtk4.G_.get_height(widget))
    (w > 0 && h > 0) || error("widget is not mapped yet (zero allocation)")
    surf = Gtk4.CairoARGBSurface(w, h)
    cr = ccall((:cairo_create, Gtk4.libcairo), Ptr{Cvoid}, (Ptr{Cvoid},),
               getfield(surf, :ptr))
    node = Ptr{Cvoid}(C_NULL)
    for _ in 1:60
        paintable = Gtk4.G_.WidgetPaintable_new(widget)
        snap = GtkSnapshot()
        Gtk4.G_.snapshot(paintable, snap, Float64(w), Float64(h))
        node = ccall((:gtk_snapshot_free_to_node, Gtk4.libgtk4), Ptr{Cvoid},
                     (Ptr{Gtk4.GObject},), getfield(snap, :handle))
        node != C_NULL && break
        pump(2) # let the pending layout settle
    end
    node == C_NULL &&
        error("could not snapshot the widget (the render node stayed empty)")
    ccall((:gsk_render_node_draw, Gtk4.libgtk4), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}), node, cr)
    ccall((:gsk_render_node_unref, Gtk4.libgtk4), Cvoid, (Ptr{Cvoid},), node)
    ok = ccall((:cairo_surface_write_to_png, Gtk4.libcairo), Cint,
               (Ptr{Cvoid}, Cstring), getfield(surf, :ptr), path)
    ok == 0 || error("could not write PNG to $path")
    return path
end
