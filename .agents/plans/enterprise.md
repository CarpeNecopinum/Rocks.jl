---
id: plan_002
title: Enterprise (Winforms / Windows 7 style) components for Rocks.jl
importance: high
tags: plan, enterprise, winforms, components, theming
---

# Plan: `Rocks.Enterprise` — Winforms / Windows 7 components

**Status: PLANNED (2026-10-20).** No implementation yet. This document is the
design and delivery plan for a second component submodule alongside
`Rocks.Material3`.

Goal: add `Rocks.Enterprise`, a themed component library that looks and feels
like Windows 7-era Winforms: silver raised gradient buttons, sunken text
fields, `GroupBox`, `MenuBar`, `ToolBar`, `StatusBar`, tab controls, list and
grid views, combo boxes, progress bars, sliders, and the supporting controls
needed to build a complete desktop form. Everything is built on the existing
primitives and the screenshot/test infrastructure.

## Visual target

Windows 7 "Aero" client-area controls, not a pixel-exact recreation of the OS
window chrome:

- Light control surface (`#F0F0F0`), white document/input surfaces.
- 1px dark outer borders with light inner highlights; raised buttons,
  sunken inputs, etched separators.
- Subtle vertical gradients on buttons, toolbars, status bars, tab strips,
  grid headers and progress fills.
- 3px corner radius on buttons/group boxes; square or 2px corners on dense
  controls.
- Segoe UI 9pt (12px) when available; fall back to the framework default font
  on Linux.
- Compact metrics: 23px buttons/inputs, 22px menu/status bars, 28px toolbar,
  17px scrollbars, 18px list rows.

Native OS title bars, Aero glass/blur and window drop shadows are outside the
framework's control; the library skins the client area only.

## Key decisions

- **Submodule, not replacement widgets**: `src/Enterprise/Enterprise.jl`
  defines `module Enterprise` inside `Rocks`, included after Material3. Apps
  use `import Rocks.Enterprise` and qualify names (`Enterprise.Button`) to
  avoid clashes with the existing flat widgets and with Material3.
- **Theme**: immutable `Enterprise.Theme` provided through
  `Enterprise.ThemeContext`, mirroring Material3. One baseline `light_theme()`
  (Aero); optional `classic_theme()` and `high_contrast_theme()` can be added
  after the core is stable. Theme switching stays reactive via an
  `Observable{Theme}`.
- **Design tokens**: colors, gradients and metrics are nested named tuples
  (`t.colors`, `t.gradients`, `t.metrics`) instead of dozens of flat fields.
- **Reuse mechanics where it fits**: extend `Rocks.Mechanics` with optional
  gradient/bevel/focus props for Button, Checkbox, Radio, TextField, Progress
  and Slider behavior. Richer controls (MenuBar, ToolBar, StatusBar,
  TabControl, ListView, GridView, ComboBox) live in Enterprise and compose
  primitives.
- **No new icon font dependency**: a small `Enterprise.ICONS` dictionary of
  Unicode/ASCII glyphs (`▾`, `✓`, `►`, `✕`, `☰`, `⌂`, `⚙`, arrows, etc.),
  rendered through an `Enterprise.Icon` text element. Missing/tiny glyphs are
  acceptable for v1; bitmap icon sets can come later.
- **Mouse-first interaction**, with keyboard support where the framework
  already supports it (text inputs, focused menus, Escape/Return). Full
  Tab-order traversal, access-key mnemonics and screen-reader semantics are
  explicitly deferred rather than half-implemented.
- **Visual verification is part of each phase**: every batch is rendered
  headlessly, captured to PNG and inspected before moving on.

## Framework prerequisites

These are small core additions that the look and popup behavior need. They
should be implemented before the first component batch.

1. **Linear gradients as fills** (`backend.jl`, `element.jl`)
   - Add `Rocks.LinearGradient(top, bottom; direction = :vertical)` (two-stop
     v1; multi-stop can come later).
   - Let `background`, `hover_background` and `pressed_background` accept
     either a color or a gradient.
   - Draw gradients through `SDL_RenderGeometry`, with per-vertex colors.
     Rounded gradients reuse the existing adaptive rounded-rect mesh and the
     1px alpha fringe. Radius 0 uses a simple quad.
   - Keep `fill_round_rect`/`ring_round_rect` behavior unchanged for solid
     colors.

2. **Bevel borders** (`backend.jl`, `element.jl`)
   - Add optional props to `Box`/`Pressable`:
     `bevel = :none | :raised | :sunken | :etched`,
     `bevel_light`, `bevel_dark`.
   - Draw 1px highlight/shadow edges inside the normal border. This gives
     sunken text fields, raised buttons, group-box frames and etched
     separators without nesting three boxes per control.
   - Border and bevel are independent: outer border first, then bevel, then
     content.

3. **Popup host** (`element.jl`, `layout.jl`, `backend.jl`, `events.jl`)
   - Add an internal `_POPUP` host for menus, combo dropdowns and tooltips.
   - It measures as zero in normal layout, anchors to the fiber that renders
     it (previous-frame rect is sufficient), and is painted after normal
     window children.
   - Hit testing tests popups first, then the normal tree.
   - Popup props: `x`/`y` offsets, `width`, `anchor`, `pointer_events`
     (`:auto`/`:none`), `dismiss_on_outside_press`.
   - This avoids clipping by `ScrollView` parents and guarantees dropdowns
     draw above later siblings.
   - If `_POPUP` proves too invasive, the fallback is a full-window
     `position = :absolute, fill = true, pointer_events = :none` overlay
     hosted by an `Enterprise.Form`; MenuBar and MessageBox work either way,
     ComboBox is the deciding case.

4. **Scrollbars for `ScrollView`** (`layout.jl`, `backend.jl`, `events.jl`)
   - Add optional `scrollbar = :auto | :always | :never` (`:auto` default for
     Enterprise) plus track/thumb color, width and radius props.
   - Store track/thumb rects in `ScrollState`; draw them after clipped
     content.
   - Hit testing and dragging: click track to page, drag thumb to scroll,
     wheel continues to work. One vertical scrollbar first; horizontal can
     follow with the same machinery.
   - ListView/GridView use this rather than reimplementing scrollbars.

5. **Small polish primitives**
   - `pointer_events = :none` on containers (skip returning the container
     itself in hit testing, still test its children). Needed for transparent
     overlay layers/tooltips.
   - Optional `focus_border_color`/`focus_border_width` for input focus rings.
   - A helper for dotted focus rectangles may be added if cheap; full
     tab-order focus management is not part of v1.
   - Ensure `background_for` and `draw_background!` preserve alpha/blending
     for gradients over transparent parents.

## Theme and design tokens

Create `src/Enterprise/theme.jl`:

```julia
Base.@kwdef struct Theme
    font::Union{Nothing,String} = nothing
    colors::NamedTuple = (...)
    gradients::NamedTuple = (...)
    metrics::NamedTuple = (...)
end

light_theme() = Theme()
classic_theme() = Theme(colors = ..., gradients = ...)
```

Baseline tokens (Aero-ish):

- `colors`: `window #F0F0F0`, `document #FFFFFF`, `text #000000`,
  `disabled_text #838383`, `border #8E8F8F`, `border_light #FFFFFF`,
  `border_dark #6F6F6F`, `focus #3C7FB1`, `selection #3399FF`,
  `selection_text #FFFFFF`, `hot #CBE8F6`, `menu #F0F0F0`,
  `status #F0F0F0`, `grid_line #E4E4E4`, `header #F5F5F5`.
- `gradients`: `button = #F5F5F5 → #DDDDDD`,
  `button_hover = #F8F8F8 → #E8E8E8`,
  `button_pressed = #D8D8D8 → #C4C4C4`,
  `toolbar = #F7F7F7 → #E7E7E7`,
  `status = #F5F5F5 → #E9E9E9`,
  `tab = #F2F2F2 → #E2E2E2`,
  `grid_header = #FAFAFA → #E8E8E8`,
  `progress = #C8F0B8 → #5FBF4A`.
- `metrics`: `button_height = 23`, `input_height = 23`,
  `control_radius = 3`, `border = 1`, `padding = 6`, `gap = 4`,
  `menu_height = 22`, `toolbar_height = 28`, `status_height = 22`,
  `tab_height = 24`, `row_height = 18`, `header_height = 21`,
  `scrollbar = 17`, `font_size = 12`.

`Enterprise.theme()` follows the Material3 pattern: `@use ThemeContext`,
unwrap an `Observable{Theme}` if provided, otherwise return the default light
theme. Components call `@use` on their own Observables so they also re-render
when app state changes.

## Shared helpers

`src/Enterprise/common.jl`:

- `Icon(name; size, color)` and `ICONS`.
- `styled_children(kids, color, size, font)` wrapper for raw strings.
- `label_row(...)`, `bevel_frame(...)`, `toolbar_buttons(...)` helpers.
- `menu_item`, `separator`, `status_panel` constructors.
- A small `PopupMenu` renderer shared by MenuBar and ComboBox.
- No dependency on `Rocks.Material3`; only `..Rocks` and `..Rocks.Mechanics`.

## Component inventory

### Basic controls

- `Button(; label, on_press, default = false, disabled = false, icon,
  width, height)` — raised gradient, 1px border, inner highlight, pressed
  gradient and optional blue default-button border. Accepts children.
- `Label(; text, color, size)` and `LinkLabel` (hand cursor + underlined text).
- `TextBox(; text, read_only = false, password = false, placeholder,
  width = 160)` — sunken white field, focus border, caret, Backspace/Return,
  password masking. Single-line v1; multiline deferred.
- `CheckBox(; checked, label, on_change, disabled)` — 13px sunken box,
  check glyph, label.
- `RadioButton(; selected, value, label, on_change, disabled)` — 13px
  circular indicator plus label.
- `GroupBox(; title, children...)` — etched 1px frame with a caption notch,
  8px content padding, transparent/control background.
- `Panel` — plain control/document container with optional border/bevel.
- `ProgressBar(; value, width = 200, height = 17, marquee = false)` —
  sunken track, green gradient fill; marquee optional via `useInterval`.
- `Slider(; value, min = 0, max = 1, ticks = 0, width = 200)` — sunken
  groove, raised thumb, optional tick marks; wraps the `_SLIDER` host with
  Enterprise style props.

### Menus, toolbars, status

- `MenuBar(; menus)` — 22px bar; menu buttons; open/close state; hover
  highlighting; supports nested `Menu`/`MenuItem`/separator. Dropdowns use
  the popup host so they draw above content and are not clipped.
- `Menu(label; items)` — data constructor.
- `MenuItem(; label, on_press, shortcut, checked, enabled, submenu)`.
- `ContextMenu(...)` — same menu renderer, opened by a child press or an
  explicit `Observable{Bool}`.
- `ToolBar(; children, grip = true)` — 28px gradient strip, grip dots,
  separators, tool buttons.
- `ToolButton(; icon, label = "", tooltip = "", on_press, toggle = nothing,
  disabled = false)` — raised on hover/press, optional pressed toggle
  (`Observable{Bool}` or a group selection).
- `ToolSeparator()` and `ToolGrip()`.
- `StatusBar(; panels, grip = true)` — 22px gradient bar with sunken panels;
  `StatusPanel(; text, width, spring = false)`.

### Tabs and data controls

- `TabControl(; tabs, selected, children, on_change)` — Win7 tab strip with
  raised inactive tabs and a selected tab merged into the page; one content
  child per tab.
- `ListView(; items, selected, multi = false, checkboxes = false, icons =
  false, height = 240)` — white list, selected blue row, hover row, optional
  checkboxes and small icons; scrollbar. `selected` is `Observable{Int}`
  (0 = none) or `Observable{Vector{Int}}` when `multi = true`.
- `GridView(; columns, rows, selected, on_select, sortable = true, height =
  240)` — white grid with gradient header, column widths/alignment,
  gridlines, selected row, sort indicators, scrollbar.
  `columns = [(label, width, align), ...]`, `rows = [("a", "b"), ...]`.
  Sorting is internal by default (`Observable` sort state optional).
- `ComboBox(; items, selected, on_change, width = 160, editable = false)` —
  sunken field plus raised drop button and a popup list. Non-editable v1;
  editable text entry deferred.
- `TreeView` — stretch goal: collapsible nodes, selection, scrollbar; use
  the same row renderer as ListView.
- `SplitContainer` — stretch goal: Enterprise-styled wrapper around the
  existing `Split` host.

### Dialogs and misc

- `MessageBox(; open, title, message, icon = :info, buttons = :ok)` —
  full-window scrim + centered dialog with Win7-styled buttons; result
  written to an `Observable{Symbol}`.
- `ToolTip(; text, child)` — hover-triggered popup, painted above content.
- `Form(; menu = nothing, toolbar = nothing, status = nothing, children,
  title, width, height)` — convenience scaffold: control-colored window,
  optional menu/toolbar/status bars, scrollable client area and a popup
  layer. Keeps examples and real apps from re-assembling the same layout.

## Reactivity and data conventions

- All interactive state is controlled through `Observable`s, matching M3 and
  the widgets: `checked::Observable{Bool}`, `selected::Observable{Int}`,
  `text::Observable{String}`, `value::Observable{Float64}`.
- Indices are 1-based; `0` means "no selection" for single-select controls.
- Multi-select uses `Observable{Vector{Int}}` (kept sorted).
- `on_change`/`on_select`/`on_press` callbacks are optional and run after the
  Observable is written.
- Components `@use` their state Observables so they re-render even when the
  app root does not subscribe.
- Raw string/value children are wrapped in themed `Text`; element children
  pass through.
- Disabled controls ignore presses and use the disabled palette.
- Row/item data remains plain Julia values (strings/tuples); no data-binding
  framework or virtualized model in v1.

## Phases

1. **Framework prerequisites** — gradient fills, bevels,
   `pointer_events = :none`, popup host and ScrollView scrollbars.
   Headless tests + a small visual fixture verifying gradient direction,
   rounded corners, bevel pixels and popup z-order. `_POPUP` is the riskiest
   item; prototype it first and fall back to the `Form` overlay if necessary.
2. **Theme + module skeleton + common helpers** — `Enterprise.jl`,
   `theme.jl`, `common.jl`, icons, metrics, `ThemeContext`/`theme()`, and the
   `Form` scaffold. No components beyond Label/Panel yet.
3. **Basic controls** — Button, TextBox, CheckBox, RadioButton, GroupBox,
   Label/LinkLabel, ProgressBar, Slider. Verify the classic form look at
   100% scale: gradient button states, sunken field, group frame, progress.
4. **Bars and menus** — MenuBar/Menu/MenuItem/ContextMenu, ToolBar/
   ToolButton/Separator/Grip, StatusBar/StatusPanel, ToolTip. Verify popup
   placement, hover/dropdown behavior and toolbar/status gradients.
5. **Tabs and data controls** — TabControl, ComboBox, ListView, GridView.
   Add selection, sorting, checkbox rows, scrollbars and empty states.
   This is the largest phase; do ListView/GridView after ComboBox and re-use
   the scrollbar and row helpers.
6. **Dialogs and polish** — MessageBox, SplitContainer, TreeView (stretch),
   focus/keyboard polish, disabled states, default-button behavior.
7. **Showcase + visual review** — `examples/enterprise.jl`: a mock
   "System Properties" form with menu, toolbar, tabs, group boxes, text
   fields/combo, checkboxes, buttons, status bar; a second tab/page with
   ListView/GridView, progress and slider. Capture and review PNGs.
8. **Tests, docs, cleanup** — add the Enterprise test set, README section,
   skill updates, plan outcome notes and test count. Run the full suite.
9. **Optional themes** — `classic_theme()` and `high_contrast_theme()` once
   the Aero baseline is stable.

## Verification strategy

- **API/behavior tests**: theme context and reactivity; button press and
  disabled behavior; text input/backspace/password masking; checkbox/radio
  toggles; combo open/select; tab switching; list/grid selection and sort;
  menu open/callback; toolbar toggle; status panels; progress/slider values;
  scrollbar drag/page/wheel.
- **Layout tests**: fixed metrics, tab content sizing, group-box padding,
  toolbar/status/menu heights, list/grid row geometry, popup anchor rects,
  ScrollView thumb geometry and clamping.
- **Pixel tests** (`png_pixel`): gradient top vs bottom colors, border/bevel
  highlight/shadow pixels, sunken input background/border, selected row
  blue, disabled text/button colors, progress fill width, popup drawn above
  later siblings.
- **Screenshot review**: `examples/enterprise.jl` in a normal and high-DPI-ish
  window size; inspect at full size rather than relying on downscaled chat
  previews.
- **Regression**: full existing suite must keep passing (currently 268 tests);
  Enterprise additions should not alter Material3 or vanilla widget output.

## Risks and deferred work

- **Popup host**: the only framework change with unclear effort. Prototype
  early. If hoisting popups to the window layer is too invasive, `Form` can
  own an overlay layer and MenuBar/ComboBox must be used inside it.
- **Native chrome/Aero**: OS title bars and glass cannot be reproduced with
  SDL; only client-area controls are in scope.
- **Fonts**: Segoe UI is not guaranteed on Linux; metric differences may make
  screenshots look slightly off. Keep `font = nothing` as the default and
  document the fallback.
- **Full keyboard accessibility**: Tab order, access-key mnemonics, screen
  readers and focus traversal are deferred. Text fields and focused menus
  still accept keys through the existing focus system.
- **Editable ComboBox, multiline/password-perfect TextBox, virtualized or
  editable grids, TreeView drag/drop, DPI scaling and native file dialogs**
  are follow-up work.
- **Gradient complexity**: v1 supports two-stop linear gradients only. That
  covers Win7 buttons/bars; multi-stop/radial gradients are unnecessary.
- **Scrollbars**: vertical first. Horizontal and custom thumb paging can
  follow after ListView/GridView prove the API.

## Definition of done

- `import Rocks.Enterprise` exposes a themed, documented component set with
  the controls listed above (stretch items explicitly marked).
- `examples/enterprise.jl` renders a convincing Windows 7-style form without
  custom drawing in app code.
- Headless screenshots and pixel assertions cover gradients, bevels,
  selection colors, popups and scrolling.
- Full test suite passes; README, `.agents` skills and this plan reflect the
  final API and test count.
- No Material3 or vanilla-widget regressions; shared framework additions are
  opt-in and documented.

## Gotchas worth remembering

- Spaced `@rock` macrocalls swallow following commas into tuples; parenthesize
  a macro call before a direct component call (e.g. `(@rock Box(...)),`).
- A component that needs an explicit height while absolutely filling must
  receive that height as a prop; parent layout cannot see function defaults.
- `_POPUP`/overlay drawing order matters: draw after normal children and
  hit-test before them.
- Keep gradient meshes compatible with the existing 1px alpha fringe;
  otherwise rounded buttons show hard edges.
- Reuse `Rocks.Mechanics` behavior instead of duplicating toggle/input logic;
  new appearance props must default to the old flat behavior so Material3
  tests stay green.
