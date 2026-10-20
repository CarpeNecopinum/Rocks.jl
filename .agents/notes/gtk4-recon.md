# GTK4.jl v0.6.1 recon — Rocks.jl SDL2→GTK4 backend port

Verified against **Gtk4.jl 0.6.1** (`/home/cmattes/.julia/packages/Gtk4/7UvLz`) with bundled **GTK 4.12.4**,
running on the session's Weston compositor (Wayland). Every code block marked **VERIFIED** was executed
via the Julia MCP server in the Rocks.jl environment unless noted otherwise. `ASSUMED` = from source reading only.

## 0a. Environment pitfalls (VERIFIED the hard way — read first)

### XDG_RUNTIME_DIR must be writable (GTK 4.12.4 artifact)
- The Gtk4.jl artifact's GTK 4.12.4 was built WITHOUT the memfd_create path in
  its vendored `gdk/wayland/cursor/os-compatibility.c`, so `os_create_anonymous_file`
  creates the cursor-shm tmpfile under `XDG_RUNTIME_DIR` (`/run/user/1000` by default).
- In this sandbox `/run/user/1000` is a READ-ONLY filesystem (EROFS) → the Adwaita
  cursor theme never loads (`Failed to load cursor theme Adwaita` ×2), `cursor_theme_name`
  stays NULL, and the FIRST pointer-frame event on a window hits
  `g_assert(cursor_theme_name)` in `_gdk_wayland_display_get_cursor_theme` and KILLS
  the whole Julia process (signal 6). Flaky/deadly for tests.
- **Fix: run Julia with `XDG_RUNTIME_DIR` pointing at a writable dir.** The weston
  socket is an absolute path (`/tmp/weston.sock`) so it is unaffected. Verified:
  `XDG_RUNTIME_DIR=/tmp/opencode julia --project=... script.jl` → no warning, no crash,
  screenshots work. (weston runs on the HOST; `/tmp/weston.sock` is mounted into the
  sandbox. System GTK 4.24 works without the fix — only the 4.12.4 artifact build is
  affected.)
- The theme dir is found via XDG_DATA_DIRS; a JULIA ARTIFACT's
  `share/icons/Adwaita/cursors` can shadow `/usr/share/icons` — content doesn't matter
  for the crash (theme CREATE only makes an shm pool; cursor files are read lazily).

### julia-mcp tools
- The `julia-mcp` MCP server may drop out of OpenCode's tool catalog after updates
  (config still enabled; server process runs). Julia can then be run directly via the
  shell (user-approved): `julia --startup-file=no --project=/home/cmattes/Development/Rocks.jl script.jl`.
- Keep verification scripts as files under `/tmp/opencode/` (self-contained, re-runnable).

### Wayland/timing gotchas (GTK4 under weston)
- Window mapping/layout is ASYNCHRONOUS: after creating a window, pump the GLib main
  context until `G_.get_width(win) > 0` — needs up to ~35 pumps on weston (compositor
  round trips are slow). `Rocks.wait_windows_mapped!(root)` (backend.jl) does this
  bounded (300 attempts); `render(frames=…)` calls it before the bounded loop and
  `screenshot` before capture. A fixed small pump count RACES with it (blank screenshots).
- Snapshotting a window whose layout is mid-invalidate returns NULL from
  `gtk_snapshot_free_to_node` (silently → blank PNG, later `gsk_render_node_draw`
  Gsk-CRITICALs). Always pump a few iterations after the last mutation before capture.

## 0. Module layout & naming conventions (read this first)

- `using Gtk4` gives the hand-written API + re-exports (`signal_connect`, `start_main_loop`,
  `set_gtk_property!`, widget types, enums, …).
- **All generated methods live in `Gtk4.G_` and `G_` is NOT exported** — you must write `Gtk4.G_`
  or `const G_ = Gtk4.G_`. `G_` contains the merged gen for **gdk4 + gtk4** (methods *and* functions).
  **GSK methods are NOT generated anywhere** — `gsk_*` must be raw `ccall`ed (types/consts exist: `GskRenderer`,
  `GskRenderNode`, `GtkSnapshot`). Gdk "hand-written" source (`src/Gdk4.jl`) is included directly into `Gtk4`,
  it is not a separate module.
- Generated method names: **methods strip the class prefix** (`gtk_paned_set_position` → `G_.set_position(p, 100)`;
  `gtk_widget_get_realized` → `G_.get_realized(w)`), **constructors keep it** (`gtk_picture_new_for_filename` →
  `G_.Picture_new_for_filename(path)`).
- **Enums are named `ClassName_VALUE`, NOT `GtkClassName`**: `Gtk4.Orientation_VERTICAL`,
  `Gtk4.Align_CENTER`, `Gtk4.Justification_CENTER`, `Gtk4.ContentFit_CONTAIN`, `Gtk4.PositionType_LEFT`,
  `Gtk4.EventControllerScrollFlags_VERTICAL`, `Gtk4.ModifierType(0)`. There is **no `GtkOrientation`**.
- Property access works via three forms: `set_gtk_property!(w, :prop, v)` / `get_gtk_property(w, :prop)`,
  generated accessors (`Gtk4.title(w)`, `Gtk4.label(w)`), and **dot syntax** (`w.title = "x"` — verified for
  `.text`, `.label`, `.name`).
- **Not exported (must qualify):** `G_`, `isrealized` (use `G_.get_realized(w)`), `is_loop_running`
  (`Gtk4.GLib.is_loop_running()`), `size_request` (`Gtk4.size_request`), `g_source_remove`
  (`Gtk4.GLib.g_source_remove`), `toplevels` (`Gtk4.toplevels()`), `GObject` (`Gtk4.GObject`),
  `Cairo` (module not exposed — but `Gtk4.CairoSurface`/`Gtk4.CairoContext`/`Gtk4.CairoARGBSurface` types and
  `Gtk4.libcairo`/`Gtk4.libgtk4` lib constants are available).
- Exported and useful: `signal_connect`, `signal_emit`, `signal_handler_*`, `g_timeout_add`, `g_idle_add`,
  `@idle_add`, `@guarded`, `start_main_loop`, `stop_main_loop`, `set_gtk_property!`, `get_gtk_property`,
  `show`, `hide`, `visible`, `isvisible`, `destroy`, `close`, `present`, `push!`, `delete!`, `width`, `height`,
  `selected_string`, `selected_string!`, `pulse`, `fraction`, `adjustment`, `activate`, `grab_focus`,
  `hasparent`, `parent`, `toplevel`, `reveal` (= queue_draw).
- **Julia 1.13 note:** bare `ccall(:sym, …)` does NOT resolve symbols from loaded libraries — always
  lib-qualify: `ccall((:gtk_widget_get_width, Gtk4.libgtk4), …)`, `ccall((:g_main_context_iteration,
  Gtk4.GLib.libglib), …)`, `ccall((:cairo_create, Gtk4.libcairo), …)`.
- GObject wrappers do not implement `unsafe_convert(Ptr{Nothing})` — for raw ccalls pass
  `getfield(w, :handle)` (a `Ptr{GObject}`).

## 1. Property access

### Window (VERIFIED)
```julia
using Gtk4; const G_ = Gtk4.G_
w = GtkWindow("Recon", 400, 300)                 # opens display, shows window; visible==true
set_gtk_property!(w, :title, "Hello GTK4");      get_gtk_property(w, :title)   # "Hello GTK4"
Gtk4.title(w)                                    # accessor form, same value
set_gtk_property!(w, :default_width, 500); set_gtk_property!(w, :default_height, 350)
get_gtk_property(w, :default_width)              # 500
set_gtk_property!(w, :resizable, false)          # Bool; toggling works
# full constructor:
# GtkWindow(title, w=-1, h=-1, resizable=true, show_window=true)
#   resizable=false → sets :resizable=false AND :width_request/:height_request = w,h (fixed size)
# child:
w[] = box          # setindex! → gtk_window_set_child
push!(w, box)      # same (push!(::GtkWindow, ::GtkWidget))
w[]                # get child (getindex → G_.get_child)
```
`close-request` → see §3. `close-request` semantics: **callback returning `true` keeps the window open** (VERIFIED).

### Box (VERIFIED)
```julia
b = GtkBox(:v, 10)      # orientation Symbol is :h or :v ONLY — :vertical/:horizontal RAISES an error
b = GtkBox(:h, 5)       # (convert in src/layout.jl only accepts :h / :v)
get_gtk_property(b, :orientation)   # 1 (= Gtk4.Orientation_VERTICAL); 0 = HORIZONTAL
get_gtk_property(b, :spacing)       # 10; set_gtk_property!(b, :spacing, 12) works
set_gtk_property!(b, :orientation, :horizontal)  # property setter accepts the enum name string too (worked)
```
Direct enum values also work: `Gtk4.Orientation_HORIZONTAL` (=0), `Gtk4.Orientation_VERTICAL` (=1).

### Label (VERIFIED)
```julia
l = GtkLabel("hello")
set_gtk_property!(l, :label, "world")     # sets text
Gtk4.label(l)                             # "world"
l.label = "dot"                           # dot syntax works
set_gtk_property!(l, :wrap, true)
set_gtk_property!(l, :justify, Gtk4.Justification_CENTER)   # LEFT=0 RIGHT=1 CENTER=2 FILL=3
set_gtk_property!(l, :xalign, 0.5)
set_gtk_property!(l, :width_chars, 20)
```

### Button (VERIFIED)
```julia
btn = GtkButton("click me")        # also GtkButton(:label, s), GtkButton(:mnemonic, s), GtkButton(:icon_name, s)
get_gtk_property(btn, :label)      # "click me"
btn[] = GtkLabel("in button")      # set child (setindex! → gtk_button_set_child); get with btn[]
set_gtk_property!(btn, :sensitive, false)   # true/false toggles fine
```

### CheckButton / Switch (VERIFIED)
```julia
cb = GtkCheckButton("check me")            # has :label property
get_gtk_property(cb, :active)              # false; set_gtk_property!(cb, :active, true) works
sw = GtkSwitch(true)                       # constructor GtkSwitch(active::Bool) exists
get_gtk_property(sw, :active)              # 1/true ; :state mirrors :active (both changed together)
```

### Scale (VERIFIED)
```julia
adj = GtkAdjustment(50.0, 0.0, 100.0, 1.0, 5.0, 0.0)   # value, lower, upper, step, page, page_size
sc = GtkScale(:h, adj)                                  # GtkScale(orient, adjustment)
sc2 = GtkScale(:h, 0.0, 100.0, 5.0)                     # GtkScale(orient, min, max, step) — creates its own adjustment
sc3 = GtkScale(:h, 0:100)                               # GtkScale(orient, AbstractRange)
set_gtk_property!(sc, :digits, 2); set_gtk_property!(sc, :draw_value, true)
get_gtk_property(sc, :orientation)          # 0
get_gtk_property(sc, :adjustment) === adj   # true
G_.set_value(get_gtk_property(sc, :adjustment), 42.0)   # programmatic value change (fires value-changed)
G_.get_value(adj)                           # 42.0
# range limits: get_gtk_property(adj, :lower)/:upper/:step_increment
```

### Paned (VERIFIED)
```julia
p = GtkPaned(:h)                  # :h / :v
p[1] = GtkLabel("left")           # start-child;  p[2] = ... end-child;  p[1] reads back
G_.set_position(p, 100); G_.get_position(p)     # 100; also get_gtk_property(p, :position)
G_.set_resize_start_child(p, true)   # pane resize/shrink are METHODS (GTK4 child props are gone)
G_.set_shrink_start_child(p, false)
G_.set_resize_end_child(p, false); G_.set_shrink_end_child(p, true)
```

### Picture (VERIFIED)
```julia
pic = G_.Picture_new_for_filename("/path/img.png")   # NOTE constructor keeps prefix; G_.new_for_filename does NOT exist
set_gtk_property!(pic, :keep_aspect_ratio, false)
set_gtk_property!(pic, :content_fit, Gtk4.ContentFit_CONTAIN)  # FILL=0 CONTAIN=1 COVER=2 SCALE_DOWN=3 (GTK≥4.8)
# also: G_.Picture_new_for_file(gfile), G_.Picture_new_for_paintable(paintable), G_.Picture_new_for_pixbuf
```

### ProgressBar (VERIFIED)
```julia
pb = GtkProgressBar()
set_gtk_property!(pb, :fraction, 0.42)
G_.pulse(pb)                                   # exists; get_gtk_property(pb, :pulse_step) → 0.1
```

### Entry (VERIFIED)
```julia
e = GtkEntry()
e.text = "typed here"
set_gtk_property!(e, :placeholder_text, "type something")
set_gtk_property!(e, :visibility, false)       # password mode; true restores
```

### Notebook (VERIFIED)
```julia
nb = GtkNotebook()
push!(nb, GtkLabel("page one"), "Tab 1")       # append_page with a title label
push!(nb, GtkLabel("page two"), "Tab 2")
length(nb)                                     # 2 (get_n_pages)
G_.set_current_page(nb, 1); G_.get_current_page(nb)   # 1 (0-based)
G_.insert!(nb, 1, GtkLabel("m"), "Middle")     # 1-based position wrapper
child = G_.get_nth_page(nb, 2)
pagenumber(nb, child)                          # 3 (1-based wrapper around page_num)
G_.set_tab_label_text(nb, child, "Renamed")    # also G_.get_tab_label_text
deleteat!(nb, 1); splice!(nb, 1)               # remove page (1-based)
```

### DropDown + GtkStringList (VERIFIED — yes, there is a simple string-list API)
```julia
dd = GtkDropDown(["apple", "banana", "cherry"])   # builds a GtkStringList model from any array
G_.get_selected(dd)          # 0-based index (UInt32)
selected_string(dd)          # "apple"  ← the simple API (G_.get_selected_item(dd).string)
selected_string!(dd, "banana")   # sets by string (error if model isn't a GtkStringList)
it = G_.get_selected_item(dd); it.string     # manual path
# lower level:
sl = GtkStringList(); push!(sl, "x"); push!(sl, "y")
sl[1]                        # "x" — getindex is 1-BASED (wraps get_string(i-1))
length(sl)                   # 2
sl2 = G_.StringList_new(["a", "b"])   # accepts Vector{String} directly
# also GtkStringList supports iterate/collect/keys; deleteat!/empty!
# notification: signal_connect(dd, "notify::selected") fires on selection change (ASSUMED, standard GObject)
```

## 2. CSS styling

**VERIFIED** (label rendered red, box rendered purple + border-radius; pixel counts from a screenshot confirm
both applied: 201 red-ish px + 58213 purple-ish px in a 320×183 render).

```julia
w = GtkWindow("CSS Test", 320, 220)
prov = GtkCssProvider("""
    .test-red    { color: red; }
    .test-purple { background: #800080; border-radius: 12px; }
""")                        # GtkCssProvider(data::AbstractString); GtkCssProvider(nothing, filename) for a file
# apply to the whole display (all windows):
push!(G_.get_display(w), prov)
# → G_.add_provider_for_display(display, provider, priority); default priority = STYLE_PROVIDER_PRIORITY_USER
# per-widget alternative:
# push!(G_.get_style_context(w), prov, Gtk4.STYLE_PROVIDER_PRIORITY_APPLICATION)
#   → G_.add_provider(style_context, provider, priority)

lab = GtkLabel("red text")
G_.add_css_class(lab, "test-red")
box = GtkBox(:v, 10)
G_.add_css_class(box, "test-purple")
push!(box, lab)
w[] = box

# read-back / checks:
G_.get_css_classes(lab)                        # ["test-red"]  (Vector{String})
G_.get_css_classes(box)                        # ["vertical", "test-purple"]
G_.has_class(G_.get_style_context(lab), "test-red") == 1   # true
G_.remove_css_class(lab, "test-red")           # exists
# remove provider: delete!(display_or_style_context, prov)
```
Priority constants (VERIFIED in gen/gtk4_consts): `STYLE_PROVIDER_PRIORITY_FALLBACK = 1`,
`THEME = 200`, `SETTINGS = 400`, `APPLICATION = 600`, `USER = 800`. Use `APPLICATION`/`USER` to override theme.
Color parsing: `GdkRGBA("#800080")` and `GdkRGBA(r,g,b,a)` exist (ColorTypes `RGBA` conversions available —
Rocks already depends on ColorTypes).

## 3. Signals & events

### signal_connect syntax (VERIFIED)
```julia
id = signal_connect(cb, w, "signal")            # GValue version — recommended
id = signal_connect(w, "signal") do w, args...  # do-block, identical
    ...
    nothing        # return nothing for void signals; return Bool for boolean signals
end
# callback receives (widget, signal_args...) — first GValue is the emitting object, converted to a wrapper.
# If a void-signal callback returns a non-nothing value, Gtk4.jl prints
# "ERROR: failed to set return value ... did your callback return an unintentional value?"
# (harmless but noisy — end callbacks with `nothing`.)
# Low-level form (raw Ptr args):
# signal_connect(cb, w, "sig", Nothing, (ArgTypes...), after=false, user_data=w)
```
Handlers: `signal_handler_disconnect(w, id)`, `signal_handler_block/unblock(w, id)`,
`signal_handler_is_connected(w, id)` — all VERIFIED (id is `UInt64`).

Programmatic emission: `signal_emit(w, "clicked", Nothing)` (VERIFIED), with args:
`signal_emit(gc, "pressed", Nothing, Int32(2), 10.5, 20.5)` (VERIFIED).

### Per-widget signals (VERIFIED)
| Widget | Signal | Callback args | Notes |
|---|---|---|---|
| Button | `"clicked"` | `(w)` | fires on real click & `signal_emit`; **`activate(btn)` did NOT fire it** (returned false) |
| CheckButton | `"toggled"` | `(w)` | fires on active change |
| CheckButton/Switch | `"notify::active"` | `(w, pspec)` | 2 args, fires fine |
| Scale/Range | `"value-changed"` | `(range)` | read value via `G_.get_value(adjustment)`; **`"notify::value"` does NOT fire** (no such property on the scale) |
| Paned | `"notify::position"` | `(w, pspec)` | fires on `G_.set_position` |
| Entry | `"changed"` | `(w)` | fires on text set |
| Entry | `"activate"` | `(w)` | fires on Enter key; **`G_.activate(e)` returned false** in test — programmatic: `signal_emit(e, "activate", Nothing)` |
| Window | `"close-request"` | `(w)` → **Bool** | **return `true` ⇒ window stays open**; without a (true-returning) handler, `close(w)` destroys the window |
| Widget | `"destroy"` | `(w)` | `on_signal_destroy(f, w)` helper exists |

Generic property watch: `on_notify(f, w, :prop)` (callback `(ptr, Ptr{GParamSpec}, user_data)`, source in GLib).
Blocking helper `waitforsignal(obj, "signal")` exists in `Gtk4.GLib`.

### Controllers (VERIFIED — attach with `push!`, or use the one-call constructors)
```julia
push!(w, controller)                      # THE way to add: push!(::GtkWidget, ::GtkEventController) → add_controller
delete!(w, controller)                    # remove_controller
# constructors that create AND attach:
g = GtkGestureClick(widget, button=1)     # button filter (set_button for != 1)
m = GtkEventControllerMotion(widget)
k = GtkEventControllerKey(widget)
s = GtkEventControllerScroll(Gtk4.EventControllerScrollFlags_VERTICAL | Gtk4.EventControllerScrollFlags_HORIZONTAL, widget)
f = GtkEventControllerFocus(widget)
find_controller(w, GtkGestureClick)       # for tests (observe_controllers)
```
Signals (all VERIFIED via `signal_emit`, incl. argument conversion):
```julia
signal_connect(g, "pressed")  do gc, n, x, y ... end      # n_press::Int32, x/y::Float64
signal_connect(g, "released") do gc, n, x, y ... end
signal_connect(m, "enter")    do gc, x, y ... end
signal_connect(m, "leave")    do gc ... end
signal_connect(m, "motion")   do gc, x, y ... end
signal_connect(k, "key-pressed")  do gc, keyval, keycode, state
    # keyval/keycode::UInt32, state::GdkModifierType
    true    # return true = handled (stops propagation)
end
signal_connect(k, "key-released") do gc, keyval, keycode, state ... end
signal_connect(s, "scroll")   do gc, dx, dy
    true    # return true = handled
end
```
Key helpers (VERIFIED): `G_.keyval_name(0x0061)` → `"a"`, `Char(G_.keyval_to_unicode(0x0061))` → `'a'`,
`G_.keyval_from_name("Return")` → `65293`, `G_.keyval_convert_case(sym)`.
**Gotcha:** when *emitting* key signals manually you must pass state as `Gtk4.ModifierType(0)` (plain `UInt32`
fails type-check); real key events deliver the proper type so callbacks are unaffected.
Scroll directions enum: `ScrollDirection_UP/DOWN/LEFT/RIGHT/SMOOTH` (Gdk). Also
`G_.get_current_event_state(controller)` (mask with `Gtk4.MODIFIER_MASK`).

## 4. Main loop

**VERIFIED** (all of it):
```julia
Gtk4.GLib.is_loop_running()        # false initially (uv-loop integration is DISABLED on Linux by default)
Gtk4.GLib.start_main_loop(true)    # wait=true blocks until running; returns the loop Task
Gtk4.GLib.is_loop_running()        # true
Gtk4.GLib.stop_main_loop(true)     # stops after next iteration; wait=true blocks until stopped
```
- `start_main_loop` runs `g_main_context_iteration(C_NULL, true)` in a `while` loop inside a Julia Task wrapped
  in `g_sigatom`. `is_loop_running()` = `G_.main_depth() != 0`.
- `g_timeout_add(cb, interval_ms, priority=PRIORITY_DEFAULT)` — **callback is the FIRST argument**
  (do-block form: `g_timeout_add(50) do ... end`). Returns a source id.
- **Callback return semantics VERIFIED:** `true` ⇒ fires again after interval (repeat — got count 3 with
  `tc[] < 3`), `false` ⇒ one-shot. `g_idle_add(cb)` (fires when idle), `@idle_add expr`, and
  `Gtk4.GLib.g_source_remove(id)` (VERIFIED: removed source never fired).
- **GC safety VERIFIED:** a timeout closure with *no external Julia references* survived `GC.gc()` and still
  fired — GLib sources keep the closure alive via `gc_ref_closure`.
- On Linux the loop only runs when started (or manually pumped); `sleep()` in the main script yields to the
  loop task.

### Manual iteration / test `pump()` (VERIFIED — windows realize & map with a few pumps)
```julia
function pump(n=10)
    for _ in 1:n
        ccall((:g_main_context_iteration, Gtk4.GLib.libglib), Cint, (Ptr{Cvoid}, Cint), C_NULL, 0)
    end
end
# pump() processes pending events without blocking (may_block = 0);
# returns immediately when nothing pending. Safe while the loop is NOT running.
w = GtkWindow("T", 320, 220)          # visible=true immediately
pump(40)
G_.get_realized(w)   # true
G_.get_mapped(w)     # true
Gtk4.width(w)        # 320 (allocated size available)
```
For timeout tests without the loop running: `sleep(0.15); pump(20)` (timeouts become "ready" after the delay).
`pause_main_loop(f)` helper exists to pause the loop around a function.

## 5. Window lifecycle

**VERIFIED**:
```julia
wa = GtkWindow("A", 150, 100); wb = GtkWindow("B", 150, 100)   # multiple windows fine
collect(Gtk4.toplevels())          # GListModel of all toplevels — count reflects open windows
hide(wb);  isvisible(wb)           # false; G_.get_mapped(wb) == false
show(wb);  isvisible(wb)           # true
visible(wb, false)                 # = G_.set_visible(w, false)
destroy(wb)                        # removes from toplevels; default handler of close-request does this too
close(w)                           # gtk_window_close → emits "close-request"
# the GLib loop keeps running after ALL windows are destroyed (VERIFIED: is_loop_running()==true)
present(w)                         # raise/focus (also present_with_time via present(w, timestamp))
```
- `destroy(win)` = `G_.destroy(w)` (gtk_window_destroy). After destroy the **Julia wrapper still holds a ref**,
  so the object stays accessible: `get_gtk_property(w, :visible) == false`, `G_.get_mapped(w) == false`
  (VERIFIED — no crash reading properties of a destroyed window).
- Close-request semantics (VERIFIED): handler returning `true` blocks close (window stays visible/alive);
  disconnect the handler (`signal_handler_disconnect`) and `close(w)` again → window is destroyed
  (visible=false, mapped=false, removed from toplevels).
- `GtkWindow(widget, args...)` constructor puts `widget` in as child (shows only if no other args).
- Note: `GtkWindow` creation opens the display; on Weston there are harmless warnings
  ("Failed to load cursor theme Adwaita", MESA-EGL/ZINK noise).

## 6. Screenshot of a widget (IMPORTANT — the framework's screenshot feature)

**`gtk_widget_snapshot` is NOT available** — in GTK 4.12 it is a private symbol (raw ccall fails with
"undefined symbol"; that's why Gtk4.jl never generated it). **`gdk_paintable_snapshot`,
`gtk_widget_paintable_*`, `gtk_snapshot_free_to_node`, `gsk_renderer_render_texture`, `gsk_render_node_draw`,
`gdk_texture_save_to_png`, `gdk_texture_download`, `cairo_surface_write_to_png` all ARE available.**
`G_.snapshot(paintable, snapshot, w, h)` for a `GtkWidgetPaintable` dispatches to the public
`gdk_paintable_snapshot`, which runs GTK's internal widget snapshotting.

### Recommended: WidgetPaintable → render node → Cairo surface → PNG (VERIFIED, works for child widgets)
```julia
using Gtk4; const G_ = Gtk4.G_

function widget_png(widget, path)
    w = Int(G_.get_width(widget))          # gtk_widget_get_width — needs a mapped widget
    h = Int(G_.get_height(widget))
    paintable = G_.WidgetPaintable_new(widget)
    snap = GtkSnapshot()                   # GtkSnapshot() → G_.Snapshot_new()
    G_.snapshot(paintable, snap, Float64(w), Float64(h))   # → gdk_paintable_snapshot → widget render node
    node = ccall((:gtk_snapshot_free_to_node, Gtk4.libgtk4), Ptr{Cvoid}, (Ptr{Gtk4.GObject},), snap.handle)
    surf = Gtk4.CairoARGBSurface(w, h)     # Cairo.jl type, exposed by Gtk4 (Cairo module itself is NOT)
    cr = ccall((:cairo_create, Gtk4.libcairo), Ptr{Cvoid}, (Ptr{Cvoid},), surf.ptr)
    ccall((:gsk_render_node_draw, Gtk4.libgtk4), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), node, cr)
    ccall((:gsk_render_node_unref, Gtk4.libgtk4), Cvoid, (Ptr{Cvoid},), node)
    return ccall((:cairo_surface_write_to_png, Gtk4.libcairo), Cint, (Ptr{Cvoid}, Cstring), surf.ptr, path) == 0
end
# VERIFIED on a toplevel (320×220 → widget.png 4051 B) and on a CHILD GtkBox (→ child.png 1959 B, 320×183);
# pixel check of the child PNG confirmed CSS styling (201 red text px, 58213 purple box px).
```
Pixel access on that surface (VERIFIED, CAIRO_FORMAT_ARGB32 → little-endian byte order B,G,R,A):
```julia
p      = ccall((:cairo_image_surface_get_data, Gtk4.libcairo), Ptr{UInt8}, (Ptr{Cvoid},), surf.ptr)
stride = ccall((:cairo_image_surface_get_stride, Gtk4.libcairo), Int32, (Ptr{Cvoid},), surf.ptr)
w      = ccall((:cairo_image_surface_get_width, Gtk4.libcairo), Int32, (Ptr{Cvoid},), surf.ptr)
h      = ccall((:cairo_image_surface_get_height, Gtk4.libcairo), Int32, (Ptr{Cvoid},), surf.ptr)
# pixel (x,y): B=p[y*stride+x*4+1], G=p[y*stride+x*4+2], R=p[y*stride+x*4+3]
```

### Alternative: render node → GskRenderer texture → PNG (VERIFIED)
```julia
paintable = G_.WidgetPaintable_new(widget)
snap = GtkSnapshot(); G_.snapshot(paintable, snap, Float64(w), Float64(h))
node = ccall((:gtk_snapshot_free_to_node, Gtk4.libgtk4), Ptr{Cvoid}, (Ptr{Gtk4.GObject},), snap.handle)
renderer = G_.get_renderer(G_.get_native(widget))   # the window's own renderer (gtk_native_get_renderer)
tex = ccall((:gsk_renderer_render_texture, Gtk4.libgtk4), Ptr{Gtk4.GObject},
            (Ptr{Gtk4.GObject}, Ptr{Cvoid}, Ptr{Cvoid}), getfield(renderer,:handle), node, C_NULL)
tw = ccall((:gdk_texture_get_width, Gtk4.libgtk4), Int32, (Ptr{Gtk4.GObject},), tex)
th = ccall((:gdk_texture_get_height, Gtk4.libgtk4), Int32, (Ptr{Gtk4.GObject},), tex)
G_.save_to_png(tex, "/tmp/widget.png")   # hmm: G_.save_to_png needs a GdkTexture wrapper; safest:
# ccall((:gdk_texture_save_to_png, Gtk4.libgtk4), Cint, (Ptr{Gtk4.GObject}, Cstring), tex, "/tmp/widget.png")  → 1 (ok)
# pixels: buf = Vector{UInt8}(undef, 4*tw*th);
# ccall((:gdk_texture_download, Gtk4.libgtk4), Cvoid, (Ptr{Gtk4.GObject}, Ptr{UInt8}, UInt64), tex, buf, 4*tw)
```
- `G_.save_to_png(texture, filename)` / `G_.save_to_png_bytes` / `G_.download(texture, buf, stride)` are
  generated (gdk4_methods) if you have a properly typed `GdkTexture` wrapper (raw `Ptr` won't dispatch — ccall it).
- `G_.get_native(widget)` (gtk_widget_get_native, GTK≥4.12) works; `G_.get_renderer(native)` too.
- **`GtkWidgetPaintable` + `get_current_image` is a dead end for texture API**: it returns a
  `GtkRenderNodePaintable` (raw `GObjectLeaf`), NOT a `GdkTexture` — `gdk_texture_get_width` asserts.
- Requirements: widget must be **realized+mapped** (`pump()` first). Unmapped widgets fail/return empty.

### GtkCanvas path (for Rocks' own Cairo drawing only — does NOT capture GTK-styled widgets) (VERIFIED)
```julia
canvas = GtkCanvas(80, 60, true)    # init_back=true → backing store allocated immediately
g = getgc(canvas)                   # canvas.backcc::CairoContext
ccall((:cairo_set_source_rgb, Gtk4.libcairo), Cvoid, (Ptr{Cvoid}, Cdouble, Cdouble, Cdouble), getfield(g,:ptr), 0.0, 1.0, 0.0)
ccall((:cairo_paint, Gtk4.libcairo), Cvoid, (Ptr{Cvoid},), getfield(g,:ptr))
ccall((:cairo_surface_write_to_png, Gtk4.libcairo), Cint, (Ptr{Cvoid}, Cstring), getfield(canvas.back,:ptr), "/tmp/canvas.png")  # 0 = ok
# canvas.back::CairoSurface is the backing store; cairo_surface(canvas) accessor exists.
# With Cairo.jl as a dependency you could also do Cairo.write_to_png(cairo_surface(canvas), path).
```
Note: `Cairo.jl` is an *indirect* dependency (pulled in by Gtk4.jl) and **`using Cairo` fails in the Rocks.jl
environment** ("Package Cairo not found in current path") — Rocks must add Cairo to `[deps]` if it wants the
Cairo module directly. Until then, use `Gtk4.CairoARGBSurface`/`Gtk4.CairoContext` + raw ccalls as above.

## 7. Gotchas (final checklist)

- **Orientation Symbols are `:h`/`:v` ONLY.** `GtkBox(:vertical, …)` throws "can't convert :vertical".
  Enums: `Gtk4.Orientation_HORIZONTAL/VERTICAL`. Same pattern for GtkPaned, GtkSeparator, GtkCenterBox,
  GtkScale, GtkScrollbar, GtkCellAreaBox.
- **`G_` and many helpers are not exported** — qualify (`Gtk4.G_`, `Gtk4.GLib.is_loop_running`,
  `Gtk4.size_request`, `Gtk4.toplevels`, `Gtk4.GLib.g_source_remove`, `G_.get_realized`).
- **Julia 1.13**: every `ccall` symbol must be library-qualified (`(sym, lib)` form).
- **GObject wrappers lack `unsafe_convert(Ptr{Nothing})`** — pass `getfield(w, :handle)` to raw ccalls.
- **Threading/tasking:** signal callbacks run on the GLib loop task once `start_main_loop` is running
  (`g_sigatom` tracks the "glib stack"; a callback asserting `current_task() === g_stack`). With the loop
  stopped and manual `pump()`, callbacks run on the caller task (VERIFIED). From other tasks/threads, defer
  GTK work with `g_sigatom(f)` (queues onto the loop task via the uv source) or `g_idle_add` — both safe
  from any thread. Callbacks that throw are caught by `g_siginterruptible` (blamed + printed, GTK survives),
  but wrap user callbacks in `@guarded` to be safe. Never block the loop task.
- **Return values:** void-signal callbacks should end with `nothing`; boolean-signal callbacks
  (`close-request`, `key-pressed`, `scroll`, …) must return `Bool`. Unexpected return values print an error.
- **GObject lifecycle:** Julia wrappers own a ref. Unparented + unreferenced widgets get finalized by GC
  (that's fine). **A widget parented to a container survives Julia-side GC** (container holds the GObject
  ref — VERIFIED: label pushed in a closure, dropped, GC'd, still in the box), but the **Julia wrapper dies** —
  children fetched later (`collect(box)`, `box[1]`, iteration) are *new wrapper objects*. Rocks must keep its
  own element→widget mapping alive (a `Dict{Element,GtkWidget}` or storing the widget in the element), and
  beware comparing wrappers by identity. Connected Julia closures are kept alive by the signal/source
  registration (`gc_ref_closure`) — no manual guarding needed while the object lives.
- **Container API:** `push!(box, w)` / `pushfirst!` / `delete!(box, w)` / `empty!(box)`; iterate with
  `collect(box)` (iteration yields fresh wrappers; `empty!` collects first for that reason). `push!(win, w)`,
  `win[] = w`. Paned/notebook/dropdown accessors per §1. Controllers attach with `push!(w, ctrl)`.
- **Sizing:** `width_request`/`height_request` are *minimum* sizes (widget can grow). `GtkWindow(title, w, h,
  resizable=false)` sets a fixed size via size_request; `resizable=true` uses `default_width/height`.
  Helpers: `Gtk4.size_request(w, (wd, ht))`, `Gtk4.width(w)`/`Gtk4.height(w)` = *allocated* size (0 until
  mapped), `size(w)`. `G_.get_width/get_height` also exist.
- **Margins per side:** `margin_top`, `margin_bottom`, `margin_start`, `margin_end` (properties; VERIFIED).
- **Align/expand:** `halign`/`valign` with `Gtk4.Align_FILL=0/START=1/END=2/CENTER=3/BASELINE=4`
  (VERIFIED `Align_CENTER`); `hexpand`/`vexpand` Bool. GTK4 boxes have no pack expand/fill child props —
  use hexpand/vexpand + halign/valign on the child.
- **CSS specifics:** one provider per display is enough; `add_css_class` per widget; `get_css_classes` returns
  `Vector{String}` (includes automatic classes like `"vertical"`); `has_class` returns `Cint`.
- **`notify::value` never fires on GtkScale/GtkRange** — use `"value-changed"`.
- **`activate()`/`G_.activate()` returned false** on buttons/entries in tests — for programmatic
  activation use `signal_emit(btn, "clicked", Nothing)` / `signal_emit(e, "activate", Nothing)`.
- **Paned pane resize/shrink are methods** (`G_.set_resize_start_child` etc.), not child properties — GTK4
  removed `gtk_container_child_set`.
- **Screenshots:** widget must be mapped (`pump()` after `show`); `gtk_widget_snapshot` unavailable;
  use the §6 recipes. `gdk_texture_save_to_png` needs GTK ≥ 4.6 (have 4.12.4), `content-fit` needs ≥ 4.8.
- **MCP/testing sessions can restart and lose all Julia state** (observed once) — keep verification scripts
  self-contained.
- **Do NOT start the main loop in library code** that Rocks' host app also drives; prefer manual `pump()` in
  tests, `start_main_loop(wait=true)` for interactive runs, and remember `stop_main_loop(wait=true)` before
  recreating.
