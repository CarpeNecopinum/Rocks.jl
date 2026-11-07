---
content: SDL GPU renderer (render(...; gpu = true)) implemented and verified
  on Vulkan/NVIDIA GTX 1080: draw primitives record into a per-frame
  transfer buffer, upload once per copy pass, replay inside one render pass.
  GPU benchmark 4.9 ms/frame (5.3x the SDL baseline), 99.1% pixel-identical
  to the SDL renderer on the same probe scene.
importance: high
tags: gpu, sdl, vulkan, renderer, rocks, benchmark
title: SDL GPU renderer transition — state and gotchas
id: gpu_001
---

The SDL GPU transition (branch `sdlgpu`): `render(...; gpu = true)` renders
through `SDL_gpu` (`src/gpu.jl`). The draw primitives (`set_color`,
`fill_rect`, geometry, textures, clips) branch on `GPU_MODE` and record into
a per-frame transfer buffer; `gpu_end_frame` uploads everything once and
replays the recorded commands inside the frame-end render pass — the
painter's order is preserved. Falls back to the SDL renderer with a warning
when no GPU device is available.

Bugs that were found while getting it to render (all verified by probes):

- **GPU driver name**: `SDL_CreateGPUDevice`'s third argument is the GPU
  *driver* name ("vulkan"/"direct3d12"/"metal"/NULL), not the app name —
  passing anything else fails device creation silently (the fallback then
  masks every later bug). The shaders are SPIR-V, so "vulkan" is requested
  directly.
- **Descriptor sets**: SDL's SPIR-V convention puts vertex uniform buffers
  in **set 1** (set 0 = textures) and fragment samplers in **set 2** —
  `layout(std140, set = 1, binding = 0)` for the projection, `layout(set =
  2, binding = 0)` for the sampler. A uniform block in set 0 reads
  uninitialized data and every draw collapses to nothing. The shaders ship
  as precompiled SPIR-V (`assets/shaders/*.spv`, recompile with `glslc -O`).
- **Transfer buffers must be unmapped** before upload commands are encoded
  (SDL_MapGPUTransferBuffer docs). The staging buffer is mapped per frame
  (`gpu_begin_frame`, cycle=true so an in-flight frame is not overwritten)
  and unmapped in `gpu_end_frame` before the copy pass.
- **`gpu_stage` must copy `sizeof(bytes)`** — `length()` is the element
  count; staging 4 bytes of a 128-byte quad draws nothing.
- **GC lifetime**: arrays referenced only through raw pointers inside a
  create-info struct (vertex descriptions/attributes, shader code) must be
  pinned with `GC.@preserve` across the ccall — otherwise SDL reads freed
  memory (duplicate-location assertion failures).
- **Sample counts are enums**: `SDL_GPU_SAMPLECOUNT_1` is **0** (no MSAA) —
  passing 1 means 2x MSAA and SDL asserts "Multisample textures cannot be
  bound as samplers".
- **Julia pointer arithmetic advances bytes**: `unsafe_store!(idx + k, ...)`
  on a `Ptr{Cint}` overlaps stores; use the element-index form
  `unsafe_store!(idx, v, k + 1)`.
- **Pixel formats are packed, not byte orders**: `SDL_PIXELFORMAT_BGRA8888`
  is little-endian memory A,R,G,B — the swapchain (B8G8R8A8_UNORM) stores
  B,G,R,A, which is `SDL_PIXELFORMAT_ARGB8888` on little-endian. Wrong
  format = channels rotated by one byte.
- SDL's Vulkan backend flips the viewport GL-style, so the Rocks projection
  (y-down flip) maps straight over — GPU captures need no vertical flip.
- Windows claimed by the GPU device must be released
  (`ReleaseWindowFromGPUDevice`) before `DestroyWindow` (dialogs/popups
  close mid-session); the GPU path has no SDL renderer, so text/image
  textures are GPU-only (`SurfaceWidth/Height` accessors in SDL3.jl read the
  opaque surface).
- **Failed SDL assertions pop up a message box** (zenity on Linux) that
  blocks the process until someone clicks it away — this made headless runs
  "hang". Rocks installs a printing assertion handler in `init_backend()`
  (`sdl_assertion_handler` in backend.jl): the failure is logged with
  condition/file/line/function and the response comes from `ROCKS_SDL_ASSERT`
  ("abort" default — print and terminate; "ignore" — print and keep running;
  "dialog" — SDL's interactive box). SDL also natively supports the
  `SDL_ASSERT` environment variable for the default handler, but a custom
  handler replaces it entirely.
- **`@cfunction` at module level goes stale across precompilation**: a
  module-level `const X = @cfunction(...)` is serialized by precompiling and
  points at dead code in every later session (calling it segfaults). Generate
  the pointer at runtime — Rocks keeps it in `SDL_ASSERTION_CFUNCTION::Ref`
  and creates it in `install_assertion_handler()` on first backend init.

SDL3.jl wrapper additions needed by the GPU path: `SDL_GPUFence` +
`SubmitGPUCommandBufferAndAcquireFence`/`WaitForGPUFences`/`ReleaseGPUFence`,
`DownloadFromGPUTexture`/`DownloadFromGPUBuffer`, `BindGPUFragmentSamplers` +
`TextureSamplerBinding`, `SetGPUTextureName`, `GetGPUSwapchainTextureFormat`,
`BlitGPUTexture`/`BlitInfo`/`SDL_GPUBlitRegion`, and the surface accessors
`SurfaceWidth`/`SurfaceHeight`/`SurfacePitch`/`SurfacePixels`/`SurfaceFormat`
(the SDL_Surface layout is public in SDL_surface.h). Also fixed in the
wrapper: `SetGPUScissor` passes the rect as a pointer (`const SDL_Rect *`).

Benchmark (`Benchmark.md`): GPU path 4.9 ms/frame ≈ 208 fps vs the SDL
baseline ~25 ms ≈ 40 fps (5.3×); allocations ≈31% above baseline (per-draw
command recording) — a persistent staging arena is the future optimization.
Screenshots work in GPU mode: `GPU_CAPTURE` copies the next drawn frame out
of the swapchain into a PNG.

## Canvas (escape-hatch) coverage — verified with the full BlazeCraftGUI

The full GUI runs end-to-end in GPU mode (the desktop WM may maximize the
window — the layout re-flows and stays correct). Canvas coverage added:

- `make_canvas` no longer calls raw `SDL_RenderFillRect`/`RenderTexture`
  anywhere: `canvas_clear`/`canvas_points` go through `set_color` +
  `fill_rect` (which branch to GPU recording internally), `canvas_text`
  uploads via `gpu_texture_from_surface` + `gpu_record_texture!(; own=true)`
  (frame-owned texture, freed at frame end), `render_geometry` already
  branches.
- `ctx.texture` accepts **raw ARGB8888 pixels** (`Vector{UInt32}`, the same
  packing `paint_even_odd!` produces). They upload through
  `gpu_texture_from_pixels` (own command buffer + transfer buffer, one copy —
  the pixels are already in texture byte order) and draw via
  `gpu_record_texture!`. The SDL path keeps a cached streaming texture.
- Canvas texture cache lives in `CanvasState.textures` (entries
  `(WeakRef(pixels), w, h, texture)`), created in both `fiber.jl` mount
  state and `canvas_state`. Pruned (and the texture released via
  `release_canvas_texture`, back-end-typed) when the pixels object is gone —
  a rebuild replaces the vector, which refreshes the upload. **Textures are
  Never `Dict` keys by identity/ contents — use `WeakRef` entries.**
- SDL-texture handles (e.g. `ctx.texture(some_sdl_texture)`) **cannot** be
  drawn in GPU mode; apps must pass raw pixels. `LayerFillTexture` in
  BlazeCraftGUI became `LayerFillPixels` (pixels + key), painted with
  `paint_even_odd!` and drawn with `ctx.texture(pixels; w, h)` — pixel
  verified identical between backends (`texpix_sdl/gpu.png` probes).
- Probe scripts in `/tmp/opencode/`: `tex_pixels_probe.jl` (known red/green
  pattern, both backends, exact pixel equality incl. the GUI's own
  workspace run), `tex_debug.jl` (canvas sizing gotcha: a Canvas inside a
  flow parent has zero cross-size unless `width`/`height` are set — the draw
  callback then never runs; `fill=true` doesn't stretch it without a sized
  parent).

Freeze detector: the first main-loop iteration is skipped (`frame > 0`)
before warning "slow loop iteration" — first-use compilation always takes
seconds and is not a freeze.

GUI test flake fixed: the BlazeCraftGUI suite opened a real X11 window, so
the developer's desktop mouse motion raced the synthetic clicks (context
menu anchored at the real cursor). `test/runtests.jl` now sets
`ENV["SDL_VIDEODRIVER"] = "dummy"` before loading the app — deterministic
and green across repeated runs.

Debug tip: `@warn` breadcrumbs in the Enterprise context-menu anchoring
(`ContextMenu` in `Enterprise/bars.jl`, reads `LAST_POINTER[wid]`) showed the
contamination immediately — the anchors were correct; the *last pointer*
before the menu was built had been overwritten by a real event.
