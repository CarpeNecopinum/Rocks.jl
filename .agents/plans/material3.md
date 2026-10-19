---
id: plan_001
title: MaterialDesign3 components for Rocks.jl
importance: high
tags: plan, material3, theming, components
---

# Plan: `Rocks.Material3` — Material Design 3 components

**Status: DONE (2026-10-19).** Everything below was implemented; the deferred
list at the bottom is the remaining future work.

Goal: implement as much of https://m3.material.io/components as Rocks.jl
primitives allow, in a `Rocks.Material3` submodule, themed via `createContext`
with a non-mutable `Theme` struct, with vanilla "mechanics" components in the
main package and the design filled in on the Material3 side. Every component
is visually verified via the screenshot infrastructure (headless dummy driver
→ PNG → image review), in light and dark themes.

## Key decisions

- **Submodule**: `src/Material3/Material3.jl` defines `module Material3`
  inside `Rocks` (included after mechanics.jl; `using ..Rocks: ...` for the
  parent bindings). Components keep M3 names (`Material3.Button` does not
  clash with the existing `Rocks.Button` widget). Do not import the host
  singletons that share a name with an M3 component (`Slider`) — defining
  `function Slider(...)` in the submodule would try to extend the imported
  constant; use `_SLIDER` directly instead.
- **Theming**: non-mutable `Base.@kwdef struct Theme` — M3 color roles as hex
  strings, `typescale::NamedTuple`, `shapes::NamedTuple`. `light_theme()` /
  `dark_theme()` build instances. `ThemeContext = createContext(light_theme())`
  provides them; components read `theme = @use ThemeContext` (an Observable
  when the app provides one, so a theme switch re-renders everything) and
  unwrap with `theme()`. Users theme by providing a new `Theme` instance
  through `ThemeContext.provider(; value = Observable(Theme(...)))` — the
  non-mutable struct makes updates atomic. NOTE: a component *outside* its own
  provider (e.g. the app root rendering the provider) reads the context
  *default*, not the provided value — such code must read the theme
  Observable directly.
- **Vanilla mechanics**: `src/mechanics.jl` defines `module Mechanics` with
  appearance-prop-driven, minimally-styled controls: `Button`, `Checkbox`,
  `Switch`, `Radio`, `Chip`, `Segmented`, `TextField`, `Progress`. All state
  is controlled through `Observable`s (same pattern as the existing widgets).
  Material3 passes theme-derived colors/shapes into them and adds M3 structure
  (state layers, indicators, elevation surfaces). Raw string/value children
  are wrapped in `Text` with the control's colors (`styled_children`) — raw
  strings would otherwise render unstyled white.
- **Reactivity**: the M3 components `@use` their state Observables
  (subscribing), so toggles re-render even when the app does not subscribe.
- **Icons**: no icon infrastructure — a documented `ICONS` dict of Unicode
  glyphs (DejaVu Sans covers ✓ ✕ ☰ ← → ● ○ ▼ …) rendered as `Text`.
- **Rounded shapes**: M3 is shape-driven; SDL has no rounded-rect primitive,
  so `backend.jl` gains `fill_round_rect` / `ring_round_rect` built on
  `SDL_RenderGeometry` (center fan / quad strip, 6 segments per corner;
  `r = min(w, h)/2` draws circles). `Box`/`Pressable` gained a `radius` prop
  (ring + inset fill keeps outlined containers transparent inside).
- **Overlays** (Dialog, Snackbar, Tooltip, modal Drawer): layout.jl absolute
  children gained `fill = true` (measure to the parent's size — scrim) and
  corner anchors (`align = :top_left/:top_right/:bottom_left/:bottom_right`,
  x/y as inward offsets), `:center` and `:bottom`. Flow children also fill
  across the cross axis (`fill = true` in `measure_box`).
- **Focus** (TextField): events.jl gained a focus concept — a press focuses
  the deepest fiber under it carrying `:on_key`/`:on_text_input` props;
  keyboard and text-input events dispatch to the focused fiber when set,
  otherwise to the window. `has_focus()` tells a component whether it holds
  focus; focus is released when the fiber unmounts.
- **@rock macro fixes** (discovered while building this):
  nested `;` groups (`f(a; k = v; k2 = w)`) parse as *nested* `parameters`
  blocks and are now flattened (they were silently becoming children); the
  `:kw` case must stay in the macro's argument visit (dropping it turns every
  kwarg into a child); positional `...` splats are children, parameter-group
  splats are props; `flat_children` accepts single elements and `nothing`.

## Component checklist (M3 category → components)

- **Actions**: `Button` (filled, tonal, elevated, outlined, text), `FAB`
  (small/medium/large, extended, primary/secondary/tertiary/surface),
  `IconButton` (standard, filled, tonal, outlined), `SegmentedButton`
  (single/multi select). ✓
- **Selection**: `Checkbox`, `Switch`, `RadioGroup`, `Slider` (M3-styled
  track/thumb via Slider style props), `Chip` (assist, filter, input,
  suggestion). ✓
- **Communication**: `Badge` (dot/large), `Snackbar` (action + auto-dismiss
  via `useTimeout`). ✓
- **Containment**: `Card` (elevated, filled, outlined), `Dialog` (scrim +
  centered card), `Divider`, `List`/`ListItem`, `Tooltip` (hover). ✓
- **Navigation**: `NavigationBar`, `NavigationRail`, `NavigationDrawer`
  (permanent), `Tabs` (primary, active indicator), `TopAppBar`. ✓
- **Text input**: `TextField` (filled, outlined; helper/supporting text). ✓
- **Progress**: `LinearProgress` (determinate; M3 stop indicator). ✓
- **Deferred** (not feasible with current primitives): date/time pickers,
  circular/wavy progress indicators (no arcs), search view, bottom/side
  sheets, menus beyond `Rocks.DropDownMenu`. Recorded as future work.

## Phases

1. **Plan + framework primitives** — rounded-rect geometry, `radius` prop,
   Slider style props, focus routing, overlay anchors/layout (`fill`,
   corner anchors for absolute children, cross-axis fill for flow children).
   Headless-tested. ✓
2. **Theme system** — `Theme` struct, palettes (light/dark), typescale,
   shapescale, `ThemeContext` + `theme()` helper; `Material3` module skeleton. ✓
3. **Mechanics** — `Mechanics` module controls, prop-driven appearance. ✓
4. **Material3 components** — by category (actions → selection →
   communication → containment → navigation → text input → progress),
   verifying visually after each batch. ✓
5. **Examples + visual verification** — `examples/material3.jl` showcase with
   a live light/dark theme switch; headless screenshots of both themes
   reviewed by eye; pixel-sampled theme application verified exact
   (`#D0BCFF` filled button on dark, `#4A4458` selected chip, …). ✓
6. **Tests** — headless: theme context (default, provider, reactivity on
   theme change), per-component structure/state (toggling writes the
   Observable, disabled blocks presses), variant colors from the theme,
   overlay layout. 233 tests pass. ✓
7. **Docs** — README section, `.agents` skill updates, memory update, this
   plan updated with outcomes. ✓

## Verification strategy

- Screenshots via the existing infrastructure: headless dummy driver +
  `screenshot(window, path)`; PNGs reviewed by eye (image reading) after each
  component batch — layout, colors, radii, type scale — and again with the
  dark theme to verify theme propagation.
- Pixel sampling (`png_pixel` / darkest-in-region) verifies theme colors
  exactly.
- Headless tests assert state behavior (Observables), variant colors taken
  from the theme, and structure.

## Gotchas worth remembering

- Julia 1.13 soft scope: top-level `try` blocks treat assignments of existing
  globals as new locals — declare `global x` inside.
- Arrays containing spaced `@rock` macrocalls cannot have trailing commas
  (parse error); ternaries with spaced macrocalls need parens around the
  macrocall; commas after spaced macrocalls get swallowed into tuples
  (flattened downstream).
- Spaced macrocall followed by a ternary `:` breaks parsing — parenthesize.
- Component `children` arrive via the `children` keyword (never positionally);
  "main" arguments (titles, labels) should fall back to reading them from
  children.
