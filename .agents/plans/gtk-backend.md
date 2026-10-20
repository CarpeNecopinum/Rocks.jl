---
id: plan_002
title: GTK4 backend for Rocks.jl
importance: high
tags: plan, gtk4, backend, pivot
---

# Plan: replace the SDL backend with GTK4 (native widgets)

**Status: IN PROGRESS.** A pivot from the SDL2 backend to GTK4
(Gtk4.jl v0.6.1, https://juliagtk.github.io/Gtk4.jl/dev/). The front-end
components are re-done to resemble GTK widgets (drop the "Gtk" prefix, mostly
forward props to native widgets). Material3 is parked for the time being.

## Architecture

Host elements map 1:1 onto NATIVE GTK widgets; GTK does layout, hit-testing
and rendering. The reconciler creates/updates GTK widgets and forwards props;
component fibers have no widget — their children parent to the nearest host
ancestor.

| Rocks host | GTK widget | Notes |
| --- | --- | --- |
| `Window` | `GtkWindow` | title, size, resizable; a vertical `GtkBox` root |
| `Box` | `GtkBox` | direction → orientation, gap → spacing, padding → margins, align → halign/valign, width/height → size requests, background/border/radius → CSS |
| `Label` | `GtkLabel` | replaces `Text`; color/size via CSS, wrap |
| `Button` | `GtkButton` | replaces `Pressable`; on_press → "clicked", disabled → sensitive, hover/pressed via CSS |
| `Image` | `GtkPicture` | src file, keep-aspect-ratio |
| `Paned` | `GtkPaned` | replaces `Split`; ratio ↔ position (two-way) |
| `Scale` | `GtkScale` | replaces `Slider`; min/max/value ↔ adjustment (two-way) |

Forwarding components (thin, over native widgets — GTK names without the
"Gtk" prefix, mostly forwarding props):

- `CheckButton` (GtkCheckButton; checked ↔ active) — replaces Checkbox
- `Switch` (GtkSwitch; on ↔ active) — replaces Toggle
- `ProgressBar` (GtkProgressBar; fraction)
- `DropDown` (GtkDropDown; options, selected) — replaces DropDownMenu
- `Notebook` (GtkNotebook; tabs) — replaces Tabber
- `Entry` (GtkEntry; text, placeholder) — native text input
- `Row`/`Column` — Box forwards with a preset direction
- `RadioGroup` — CheckButtons in a group

Renames: `Text` → `Label`, `Pressable` → `Button`, `Split` → `Paned`,
`Slider` → `Scale`, `Image` → `Picture`. Removed with the SDL backend: the
measure/place layout engine (`layout.jl` — GTK lays out), the TTF font system
(CSS/Pango handles text), SDL event polling (rewritten to signal/controller
wiring), `SDL_RenderReadPixels` screenshots (→ GTK4 snapshot path from
recon), the custom hit-testing. Mechanics and Material3 are parked (excluded
from the build) pending a redo on the GTK hosts.

## Phases

1. **Recon (subagent)** — verified Gtk4.jl API reference written to
   `.agents/notes/gtk4-recon.md`: property syntax, CSS, signals/controllers,
   main loop, window lifecycle, widget screenshots, threading gotchas.
   (Wayland/weston is the test display; Xvfb stays as a fallback.)
2. **Core backend** — `src/backend.jl` rewritten: widget creation per host,
   prop application (properties + CSS + margins + size requests), event
   wiring, the screenshot path; `src/runtime.jl` rewritten around the GLib
   main loop (`start_main_loop`) with Rocks' timers as GLib timeouts and
   dirty-driven re-renders; `src/element.jl` host kinds renamed;
   `layout.jl`/SDL code removed. ✅ `element.jl`, `fiber.jl`, `Rocks.jl`
   updated (hosts, reconciler hook points, includes/exports).
3. **Front-end components** — `components.jl` (Row/Column), `widgets.jl`
   (RadioGroup; the widget kinds are host elements) re-done as thin forwards.
   ✅ `widgets.jl` rewritten, `components.jl` unchanged (already forwards to
   `Box`). Mechanics/Material3 parked (excluded from the build) pending a redo
   on the GTK hosts.
4. **Tests** — GTK needs a display: the suite runs against the weston
   wayland compositor (env pre-configured) and skips GUI tests gracefully
   without a display; widget-tree tests (structure, props, state) pump the
   GLib main context (`g_main_context_iteration`).
5. **Examples** — counter, widgets tour, multiwindow, dialog, screenshot
   re-done against the GTK hosts.
6. **Docs** — README rewrite of the rendering-model sections, `.agents`
   updates, this plan marked done.

## Verification

- weston-based runs (Xvfb fallback); widget property/structure assertions;
  the screenshot feature (from recon) captures real widget appearance.
