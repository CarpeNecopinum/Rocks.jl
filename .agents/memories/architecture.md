---
id: arch_001
title: Rocks.jl architecture decisions
content: SDL3 via the SDL3.jl wrapper; host elements as singleton constants; whole-tree re-render on dirty; index-based reconciler with kind/key compatibility; components are plain functions called with props as kwargs
importance: high
tags: architecture, rocks, sdl, react
---

Key architecture decisions of Rocks.jl (React-style GUI framework on SDL3):

- **SDL3, through the local SDL3.jl wrapper**: the wrapper lives next to
  Rocks (`../SDL3.jl`, wired up as a path dependency) and binds SDL3 and
  SDL3_ttf directly.  The earlier SDL2 binding (SimpleDirectMediaLayer.jl)
  was dropped in October 2026 — it could not set window titles reliably and
  had no SDL3 support.  Two consequences: the video driver is selected with
  `SDL_VIDEO_DRIVER` (not `SDL_VIDEODRIVER`), and SDL3 exports a `Window`
  *type*, so `using Rocks` and `using SDL3` in one session make the bare
  name `Window` ambiguous — qualify it or `import SDL3` qualified.
- **Host elements are singleton constants** (`Window`, `Box`, `Text`,
  `Pressable`) compared with `===` during reconciliation; components are
  plain Julia functions. `@rock` splits positional children from keyword
  props (macro kwargs arrive as `Expr(:parameters, ...)` first argument).
- **Rendering**: state setters mark the app dirty; the main loop re-runs the
  tree, reconciles persistent fibers in place (index + kind/key
  compatibility, like React without keyed reordering), runs effects, lays
  out (measure + place) and draws each window with vsync + dirty-only
  drawing.
- **Layout is React Native style flexbox**: a container has a main axis
  (`direction`) and a cross axis; a child has a flex basis (`flex_basis`, or
  its measured size) and shares the free space by `flex_grow`/`flex_shrink`
  (`flex = 1` is the shorthand for grow 1, shrink 1, basis 0).  `justify`
  distributes along the main axis, `align` across the cross axis, and
  `flex_wrap = :wrap` breaks the children into lines.  The measure pass
  computes the natural sizes (a flex basis counts, not the grown size); the
  place pass distributes the free space of the *final* container size, which
  is where a child that hits its `max_width` leaves the space to the others.
  `align` defaults to `:start` (React Native defaults to `:stretch`) so the
  existing look is kept.
- **Nothing falls out of the window**: a flow child's width is clipped to the
  content box of its parent (the cross axis of a column), so shrinking the
  window shrinks the controls in it.  Along the main axis the children shrink
  when they carry `flex_shrink`; taller content is left alone and scrolls.
- **Painting can be clipped**: `overflow = :hidden` on a box clips its
  children to its content box (the draw pass sets a renderer clip rect,
  `draw_clipped!` in backend.jl).  The text field, the combo box and the
  panel use it so their text never runs over the border; the group box clips
  its content to the frame (the caption in the notch is a sibling of the
  content, so it stays outside the clip) and the split container clips its
  panes.  Note that a *clipped* text is cut mid-glyph: the layout clips the
  text's box, but the glyphs are still painted at their natural width.
- **Components are sized by their parent, not by their own props**: the
  flexbox props (`flex`, `max_width`, …) live on the *component fiber*, so
  the box around a component lays it out with them.  The reconciler
  (`perform_render!` in fiber.jl) therefore does not pass them on to the
  component function — every component, including user written ones, can be
  sized by flexbox without declaring the props.  The element a component
  returns fills the space the component was given.
- **Windows are components**: any `Window` element anywhere in the tree is
  hoisted into its own SDL window (multi-window apps and dialogs are
  conditional rendering).
- **Naming**: entry point is `render` (Base.run clash), `Rocks.run` is a
  qualified alias; `Text` clashes with `Base.Text` so examples do
  `import Rocks: Text`.
- **Testing**: headless via `SDL_VIDEO_DRIVER=dummy`; synthetic events are
  pushed through the real `dispatch_event!`.  SDL3 delivers every event
  through one 128 byte union, so a synthetic event is built by storing the
  concrete payload struct into the event's memory (the wrapper's `as_*`
  views then read it).  `FONT_CACHE` must be cleared on `TTF_Quit` and
  `IMAGE_SURFACES` on `SDL_Quit` (stale pointers crash).
- **Screenshots**: `screenshot(window, path)` redraws the window without
  presenting, reads the backbuffer with `SDL_RenderReadPixels` (which returns
  a surface in SDL3) and saves it with `SDL_SavePNG`. The
  pixels come from the renderer, not the video driver: the dummy driver
  implements window framebuffers, so pixel tests work fully headless with
  `SDL_VIDEO_DRIVER=dummy` (verified: dummy, `offscreen` and x11/Xvfb produce
  identical pixels; an xvfb layer was built and then dropped as
  unnecessary). Headless runs use `render(app; frames, screenshot)`.
- **Material3**: a submodule (`src/Material3/`) with M3-themed components
  built on `Rocks.Mechanics` (vanilla, appearance-prop-driven controls in
  `src/mechanics.jl`). Theming via `createContext` with a non-mutable
  `Theme` (color roles + typescale + shapescale); components `@use` their
  state and theme Observables so toggles and theme switches re-render.
  Rounded shapes use `SDL_RenderGeometry` (`fill_round_rect`/`ring_round_rect`);
  `Box`/`Pressable` take a `radius` prop. Overlays use absolute children with
  `fill`/corner anchors; text fields use a focus concept in events.jl.
- **@rock macro**: nested `;` groups parse as nested `parameters` blocks and
  are flattened; positional `...` splats are children, parameter-group splats
  are props; the `:kw` case in the argument visit must not be dropped.
