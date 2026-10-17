---
id: arch_001
title: Rocks.jl architecture decisions
content: SDL2 not SDL3; host elements as singleton constants; whole-tree re-render on dirty; index-based reconciler with kind/key compatibility; components are plain functions called with props as kwargs
importance: high
tags: architecture, rocks, sdl, react
---

Key architecture decisions of Rocks.jl (React-style GUI framework on SDL2):

- **SDL2, not SDL3**: the user requested SDL3 via
  SimpleDirectMediaLayer.jl, but that package only ships SDL2 bindings
  (`LibSDL2` module, no SDL3 branch as of 2026-10). The user accepted SDL2.
- **Host elements are singleton constants** (`Window`, `Box`, `Text`,
  `Pressable`) compared with `===` during reconciliation; components are
  plain Julia functions. `@rock` splits positional children from keyword
  props (macro kwargs arrive as `Expr(:parameters, ...)` first argument).
- **Rendering**: state setters mark the app dirty; the main loop re-runs the
  tree, reconciles persistent fibers in place (index + kind/key
  compatibility, like React without keyed reordering), runs effects, lays
  out (measure + place) and draws each window with vsync + dirty-only
  drawing.
- **Windows are components**: any `Window` element anywhere in the tree is
  hoisted into its own SDL window (multi-window apps and dialogs are
  conditional rendering).
- **Naming**: entry point is `render` (Base.run clash), `Rocks.run` is a
  qualified alias; `Text` clashes with `Base.Text` so examples do
  `import Rocks: Text`.
- **Testing**: headless via `SDL_VIDEODRIVER=dummy`; synthetic events are
  pushed through the real `dispatch_event!`; `FONT_CACHE` must be cleared
  on `TTF_Quit` (stale pointers segfault).
