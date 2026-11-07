# The GPU device state, the pipelines and the per-frame draw path. Opt-in via
# `render(...; gpu = true)`: the draw primitives branch on `GPU_MODE` and
# record into a per-frame transfer buffer; the frame end uploads everything
# and replays the recorded commands inside the render pass — the painter's
# order is preserved, the uploads happen once per frame.
#
# The vertex format matches SDL_Vertex's layout (position float2 + color
# float4 + tex_coord float2, 32 bytes) so the tessellated geometry built for
# `SDL_RenderGeometry` uploads as-is, and the pipelines are created from
# precompiled SPIR-V blobs (assets/shaders/*.spv) for the Vulkan backend.

# SDL3.jl's GPU constants carry the SDL_ prefix and are not exported; gpu.jl
# refers to them without the prefix (aliased here).
import SDL3: SDL_GPU_SHADERSTAGE_VERTEX as GPU_SHADERSTAGE_VERTEX,
             SDL_GPU_SHADERSTAGE_FRAGMENT as GPU_SHADERSTAGE_FRAGMENT,
             SDL_GPU_FILTER_LINEAR as GPU_FILTER_LINEAR,
             SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE as GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
             SDL_GPU_COMPAREOP_ALWAYS as GPU_COMPAREOP_ALWAYS,
             SDL_GPU_VERTEXINPUTRATE_VERTEX as GPU_VERTEXINPUTRATE_VERTEX,
             SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2 as GPU_VERTEXELEMENTFORMAT_FLOAT2,
             SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4 as GPU_VERTEXELEMENTFORMAT_FLOAT4,
             SDL_GPU_FILLMODE_FILL as GPU_FILLMODE_FILL,
             SDL_GPU_CULLMODE_NONE as GPU_CULLMODE_NONE,
             SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE as GPU_FRONTFACE_COUNTER_CLOCKWISE,
             SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM as GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
             SDL_GPU_LOADOP_CLEAR as GPU_LOADOP_CLEAR,
             SDL_GPU_STOREOP_STORE as GPU_STOREOP_STORE,
             SDL_GPU_SWAPCHAINCOMPOSITION_SDR as GPU_SWAPCHAINCOMPOSITION_SDR,
             SDL_GPU_PRESENTMODE_IMMEDIATE as GPU_PRESENTMODE_IMMEDIATE

const GPU_TRANSFER_SIZE = UInt32(16 * 1024 * 1024)   # the vertex/index staging
const GPU_BUFFER_SIZE = UInt32(16 * 1024 * 1024)     # the vertex/index buffers
const GPU_SHADER_DIR = joinpath(@__DIR__, "..", "assets", "shaders")

mutable struct SDLGPUState
    device::Ptr{SDL3.SDL_GPUDevice}
    color_pipeline::Ptr{SDL3.SDL_GPUGraphicsPipeline}
    tex_pipeline::Ptr{SDL3.SDL_GPUGraphicsPipeline}
    sampler::Ptr{SDL3.SDL_GPUSampler}
    transfer_buffer::Ptr{SDL3.SDL_GPUTransferBuffer}
    transfer_ptr::Ptr{Cvoid}
    vertex_buffer::Ptr{SDL3.SDL_GPUBuffer}
    index_buffer::Ptr{SDL3.SDL_GPUBuffer}
    cursor::UInt32                      # the transfer-buffer byte cursor
    cmdbuf::Ptr{SDL3.SDL_GPUCommandBuffer}
    render_pass::Ptr{SDL3.SDL_GPURenderPass}
    swapchain_texture::Ptr{SDL3.SDL_GPUTexture}
    swapchain_w::Int
    swapchain_h::Int
    color::NTuple{4,UInt8}              # the current draw color (set_color)
    scissor::Union{Nothing,Tuple{Int,Int,Int,Int}}
    windows::Vector{SDL3.Window}        # claimed windows
    commands::Vector{Any}               # the recorded draw commands
    frame_textures::Vector{Ptr{SDL3.SDL_GPUTexture}}  # released at frame end
end

const GPU_MODE = Ref(false)
const GPU_STATE = Ref{Union{Nothing,SDLGPUState}}(nothing)
# A screenshot request for the next drawn frame (`screenshot` in GPU mode):
# the frame is copied out of the swapchain into a PNG at this path.
const GPU_CAPTURE = Ref{Union{Nothing,String}}(nothing)

function gpu_load_shader(device, name, stage, num_samplers, num_uniform_buffers)
    code = read(joinpath(GPU_SHADER_DIR, name))
    # The SPIR-V bytes are referenced through a raw pointer — keep them alive
    # across the ccall.
    shader = GC.@preserve code begin
        info = SDL3.ShaderCreateInfo(sizeof(code), pointer(code), pointer("main"),
                                     SDL3.SDL_GPU_SHADERFORMAT_SPIRV, stage,
                                     UInt32(num_samplers), UInt32(0), UInt32(0),
                                     UInt32(num_uniform_buffers), UInt32(0))
        SDL3.CreateGPUShader(device, info)
    end
    shader == C_NULL && error("SDL GPU: could not create the shader $name")
    return shader
end

# The blend state of every pipeline: source alpha / one minus source alpha,
# matching SDL_BLENDMODE_BLEND.
const GPU_BLEND = SDL3.ColorTargetBlendState(
    SDL3.SDL_GPU_BLENDFACTOR_SRC_ALPHA, SDL3.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    SDL3.SDL_GPU_BLENDOP_ADD,
    SDL3.SDL_GPU_BLENDFACTOR_ONE, SDL3.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
    SDL3.SDL_GPU_BLENDOP_ADD,
    0xF, true, false, UInt8(0), UInt8(0))

function gpu_state_create()
    # The GPU driver name (the third SDL_CreateGPUDevice argument), not the
    # app name: the shaders ship as SPIR-V, so "vulkan" is the only driver
    # that can run them — ask for it directly and let non-Vulkan platforms
    # fall back with a clean warning.
    device = SDL3.CreateGPUDevice(SDL3.SDL_GPU_SHADERFORMAT_SPIRV, true,
                                  "vulkan")
    device == C_NULL && error("SDL GPU: could not create a device (SPIR-V/Vulkan)")
    color_vs = gpu_load_shader(device, "color.vert.spv", GPU_SHADERSTAGE_VERTEX, 0, 1)
    color_fs = gpu_load_shader(device, "color.frag.spv", GPU_SHADERSTAGE_FRAGMENT, 0, 0)
    tex_vs = gpu_load_shader(device, "tex.vert.spv", GPU_SHADERSTAGE_VERTEX, 0, 1)
    tex_fs = gpu_load_shader(device, "tex.frag.spv", GPU_SHADERSTAGE_FRAGMENT, 1, 0)
    sampler_info = SDL3.SamplerCreateInfo(
        GPU_FILTER_LINEAR, GPU_FILTER_LINEAR, Int32(0),
        GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE, GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE, 0.0f0, 0.0f0, GPU_COMPAREOP_ALWAYS,
        0.0f0, 1000.0f0, false, UInt8(0), UInt8(0), UInt8(0))
    sampler = SDL3.CreateGPUSampler(device, sampler_info)
    vdesc = [SDL3.VertexBufferDescription(UInt32(0), UInt32(32),
                                          GPU_VERTEXINPUTRATE_VERTEX, UInt32(0))]
    color_attrs = [SDL3.VertexAttribute(UInt32(0), UInt32(0),
                                        GPU_VERTEXELEMENTFORMAT_FLOAT2, UInt32(0)),
                   SDL3.VertexAttribute(UInt32(1), UInt32(0),
                                        GPU_VERTEXELEMENTFORMAT_FLOAT4, UInt32(8))]
    tex_attrs = [SDL3.VertexAttribute(UInt32(0), UInt32(0),
                                      GPU_VERTEXELEMENTFORMAT_FLOAT2, UInt32(0)),
                 SDL3.VertexAttribute(UInt32(1), UInt32(0),
                                      GPU_VERTEXELEMENTFORMAT_FLOAT4, UInt32(8)),
                 SDL3.VertexAttribute(UInt32(2), UInt32(0),
                                      GPU_VERTEXELEMENTFORMAT_FLOAT2, UInt32(24))]
    rasterizer = SDL3.RasterizerState(GPU_FILLMODE_FILL, GPU_CULLMODE_NONE,
                                      GPU_FRONTFACE_COUNTER_CLOCKWISE, 0.0f0, 0.0f0,
                                      0.0f0, false, false, UInt8(0), UInt8(0))
    multisample = SDL3.MultisampleState(SDL3.SDL_GPU_SAMPLECOUNT_1, UInt32(0),
                                        false, false, UInt8(0), UInt8(0))
    depth = SDL3.DepthStencilState(GPU_COMPAREOP_ALWAYS,
        SDL3.StencilOpState(Int32(0), Int32(0), Int32(0), GPU_COMPAREOP_ALWAYS),
        SDL3.StencilOpState(Int32(0), Int32(0), Int32(0), GPU_COMPAREOP_ALWAYS),
        UInt8(0), UInt8(0), false, false, false, UInt8(0), UInt8(0), UInt8(0))
    targets = [SDL3.ColorTargetDescription(GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
                                           GPU_BLEND)]
    # The arrays are referenced through raw pointers only — keep them alive
    # across the two ccall:s (a GC run in between frees them and SDL reads
    # freed memory: duplicate-location assertion failures).
    color_pipeline, tex_pipeline = GC.@preserve vdesc color_attrs tex_attrs targets begin
        color_pipeline = SDL3.CreateGPUGraphicsPipeline(device,
            SDL3.GraphicsPipelineCreateInfo(
                color_vs, color_fs,
                SDL3.VertexInputState(pointer(vdesc), UInt32(1), pointer(color_attrs),
                                      UInt32(2)),
                Int32(0), rasterizer, multisample, depth,
                SDL3.GraphicsPipelineTargetInfo(pointer(targets), UInt32(1), Int32(0),
                                                false, UInt8(0), UInt8(0), UInt8(0)),
                UInt32(0)))
        color_pipeline == C_NULL && error("SDL GPU: could not create the color pipeline")
        tex_pipeline = SDL3.CreateGPUGraphicsPipeline(device,
            SDL3.GraphicsPipelineCreateInfo(
                tex_vs, tex_fs,
                SDL3.VertexInputState(pointer(vdesc), UInt32(1), pointer(tex_attrs),
                                      UInt32(3)),
                Int32(0), rasterizer, multisample, depth,
                SDL3.GraphicsPipelineTargetInfo(pointer(targets), UInt32(1), Int32(0),
                                                false, UInt8(0), UInt8(0), UInt8(0)),
                UInt32(0)))
        (color_pipeline, tex_pipeline)
    end
    tex_pipeline == C_NULL && error("SDL GPU: could not create the texture pipeline")
    vbuffer = SDL3.CreateGPUBuffer(device, SDL3.BufferCreateInfo(
        SDL3.SDL_GPU_BUFFERUSAGE_VERTEX, GPU_BUFFER_SIZE, UInt32(0)))
    ibuffer = SDL3.CreateGPUBuffer(device, SDL3.BufferCreateInfo(
        SDL3.SDL_GPU_BUFFERUSAGE_INDEX, GPU_BUFFER_SIZE, UInt32(0)))
    tb = SDL3.CreateGPUTransferBuffer(device, SDL3.TransferBufferCreateInfo(
        SDL3.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, GPU_TRANSFER_SIZE, UInt32(0)))
    tb == C_NULL && error("SDL GPU: could not create the transfer buffer")
    # The transfer buffer is mapped per frame (gpu_begin_frame) and unmapped
    # before the copy pass encodes the upload — SDL requires the buffer to be
    # unmapped when upload commands are encoded.
    return SDLGPUState(device, color_pipeline, tex_pipeline, sampler, tb, C_NULL,
                       vbuffer, ibuffer, UInt32(0), C_NULL, C_NULL, C_NULL, 0, 0,
                       (UInt8(0), UInt8(0), UInt8(0), UInt8(255)), nothing,
                       SDL3.Window[], Any[], Ptr{SDL3.SDL_GPUTexture}[])
end

"Init the GPU mode (once): the device, the pipelines, the staging buffers."
function gpu_init()
    GPU_STATE[] === nothing || return
    GPU_STATE[] = gpu_state_create()
    return nothing
end

function gpu_shutdown()
    st = GPU_STATE[]
    st === nothing && return
    for w in st.windows
        SDL3.ReleaseWindowFromGPUDevice(st.device, w)
    end
    empty!(st.windows)
    SDL3.ReleaseGPUGraphicsPipeline(st.device, st.color_pipeline)
    SDL3.ReleaseGPUGraphicsPipeline(st.device, st.tex_pipeline)
    SDL3.ReleaseGPUSampler(st.device, st.sampler)
    SDL3.ReleaseGPUBuffer(st.device, st.vertex_buffer)
    SDL3.ReleaseGPUBuffer(st.device, st.index_buffer)
    st.transfer_ptr != C_NULL &&
        SDL3.UnmapGPUTransferBuffer(st.device, st.transfer_buffer)
    SDL3.ReleaseGPUTransferBuffer(st.device, st.transfer_buffer)
    SDL3.DestroyGPUDevice(st.device)
    GPU_STATE[] = nothing
    return nothing
end

"Claim a window for the GPU device (once per window)."
function gpu_claim(window::SDL3.Window)
    st = GPU_STATE[]
    window in st.windows && return nothing
    SDL3.ClaimWindowForGPUDevice(st.device, window) ||
        error("SDL GPU: could not claim the window")
    SDL3.SetGPUSwapchainParameters(st.device, window,
                                   GPU_SWAPCHAINCOMPOSITION_SDR,
                                   GPU_PRESENTMODE_IMMEDIATE) ||
        @warn "Rocks: could not set the GPU swapchain parameters"
    push!(st.windows, window)
    return nothing
end

# ---- the per-frame flow ----------------------------------------------------

"Begin a frame for one window: the command buffer, the swapchain texture and
the vertex uniform (the projection). The draws are recorded, not executed."
function gpu_begin_frame(window_fiber)
    st = GPU_STATE[]
    gpu_claim(window_fiber.host.ptr)
    # Map the staging buffer for this frame's records (cycle=true: a previous
    # frame may still be in flight on the GPU).
    st.transfer_ptr = SDL3.MapGPUTransferBuffer(st.device, st.transfer_buffer, true)
    st.transfer_ptr == C_NULL && return false
    st.cmdbuf = SDL3.AcquireGPUCommandBuffer(st.device)
    st.cmdbuf == C_NULL && return false
    (texture, tw, th) = SDL3.WaitAndAcquireGPUSwapchainTexture(st.cmdbuf,
                                                               window_fiber.host.ptr)
    (texture == C_NULL || tw == 0 || th == 0) && return false
    st.swapchain_texture = texture
    st.swapchain_w = tw
    st.swapchain_h = th
    st.cursor = UInt32(0)
    empty!(st.commands)
    empty!(st.frame_textures)
    # The projection: an orthographic mapping with the y-down flip, column
    # major.
    w, h = Float32(tw), Float32(th)
    proj = Float32[2/w, 0, 0, 0,  0, -2/h, 0, 0,  0, 0, 1, 0,  -1, 1, 0, 1]
    SDL3.PushGPUVertexUniformData(st.cmdbuf, 0, proj)
    return true
end

"Append `bytes` to the transfer buffer; returns the byte offset."
function gpu_stage(bytes)
    st = GPU_STATE[]
    off = st.cursor
    n = UInt32(sizeof(bytes))
    unsafe_copyto!(convert(Ptr{UInt8}, st.transfer_ptr + off),
                   convert(Ptr{UInt8}, pointer(bytes)), n)
    st.cursor += n
    return off
end

"""
    gpu_record!(pipeline_kind, verts, idx; texture = C_NULL) -> Bool

Append a draw command: the vertices and indices are staged into the
transfer buffer, the command is recorded for the frame-end replay. Returns
false when the staging buffer is exhausted (the frame is drawn truncated).
"""
function gpu_record!(pipeline_kind::Symbol, verts::Vector{SDL3.SDL_Vertex},
                     idx::Vector{Cint}; texture = C_NULL)
    st = GPU_STATE[]
    (st.cursor + UInt32(sizeof(verts) + sizeof(idx)) > GPU_TRANSFER_SIZE) &&
        return false
    voff = gpu_stage(verts)
    ioff = gpu_stage(idx)
    push!(st.commands, (pipeline_kind, UInt32(sizeof(verts)), UInt32(length(idx)),
                        UInt32(voff), UInt32(ioff), texture))
    return true
end

"""
    gpu_end_frame(clear_color) -> Bool

Upload the staged vertices/indices, then replay the recorded commands inside
the render pass (cleared to `clear_color`), and submit. The painter's order
is preserved: the commands replay in record order. A `GPU_CAPTURE` request
(`screenshot` in GPU mode) copies the swapchain out to a PNG instead of
presenting.
"""
function gpu_end_frame(clear_color)
    st = GPU_STATE[]
    (st.cmdbuf == C_NULL || st.swapchain_texture == C_NULL) && return false
    # Unmap before encoding the upload (SDL requires it).
    SDL3.UnmapGPUTransferBuffer(st.device, st.transfer_buffer)
    st.transfer_ptr = C_NULL
    copy_pass = SDL3.BeginGPUCopyPass(st.cmdbuf)
    # The index data stages after the vertex data: one combined upload from
    # the start covers both.
    SDL3.UploadToGPUBuffer(copy_pass,
        SDL3.TransferBufferLocation(st.transfer_buffer, UInt32(0)),
        SDL3.BufferRegion(st.vertex_buffer, UInt32(0), st.cursor))
    SDL3.UploadToGPUBuffer(copy_pass,
        SDL3.TransferBufferLocation(st.transfer_buffer, UInt32(0)),
        SDL3.BufferRegion(st.index_buffer, UInt32(0), st.cursor))
    SDL3.EndGPUCopyPass(copy_pass)
    (r, g, b, a) = _to_rgba(clear_color)
    target = SDL3.ColorTargetInfo(st.swapchain_texture, UInt32(0), UInt32(0),
                                  (Float32(r / 255), Float32(g / 255),
                                   Float32(b / 255), Float32(a / 255)),
                                  GPU_LOADOP_CLEAR, GPU_STOREOP_STORE,
                                  C_NULL, UInt32(0), UInt32(0), false, false,
                                  UInt8(0), UInt8(0))
    st.render_pass = SDL3.BeginGPURenderPass(st.cmdbuf, target)
    st.render_pass == C_NULL && return false
    SDL3.SetGPUScissor(st.render_pass,
                       SDL3.Rect(0, 0, st.swapchain_w, st.swapchain_h))
    current = :none
    for cmd in st.commands
        # A scissor change recorded by set_render_clip!/restore_render_clip!:
        # the record phase has no render pass, so the clips replay here, in
        # record order around the draws they wrap.
        if cmd[1] === :scissor
            rect = cmd[2]
            SDL3.SetGPUScissor(st.render_pass, rect === nothing ?
                SDL3.Rect(0, 0, st.swapchain_w, st.swapchain_h) : rect)
            continue
        end
        (kind, vsize, nidx, voff, ioff, texture) = cmd
        pipeline = kind === :tex ? st.tex_pipeline : st.color_pipeline
        pipeline !== current && (SDL3.BindGPUGraphicsPipeline(st.render_pass,
                                                              pipeline);
                                 current = pipeline)
        if kind === :tex
            SDL3.BindGPUFragmentSamplers(st.render_pass, 0,
                SDL3.TextureSamplerBinding(texture, st.sampler))
        end
        SDL3.BindGPUVertexBuffers(st.render_pass,
                                  SDL3.BufferBinding(st.vertex_buffer, voff))
        SDL3.BindGPUIndexBuffer(st.render_pass,
                                SDL3.BufferBinding(st.index_buffer, ioff))
        SDL3.DrawGPUIndexedPrimitives(st.render_pass, nidx, UInt32(0))
    end
    SDL3.EndGPURenderPass(st.render_pass)
    st.render_pass = C_NULL
    capture = GPU_CAPTURE[]
    if capture !== nothing
        GPU_CAPTURE[] = nothing
        gpu_capture_swapchain!(st, capture)
        return true
    end
    SDL3.SubmitGPUCommandBuffer(st.cmdbuf)
    st.cmdbuf = C_NULL
    st.swapchain_texture = C_NULL
    # Textures owned by one frame (the debug overlay's fresh per-draw texture)
    # are released only after the submit, once the GPU is done reading them.
    for texture in st.frame_textures
        SDL3.ReleaseGPUTexture(st.device, texture)
    end
    empty!(st.frame_textures)
    return true
end

"""
    gpu_capture_swapchain!(state, path) -> Bool

Copy the rendered swapchain texture of the just-submitted command buffer into
a PNG at `path` (the GPU side of `SDL_RenderReadPixels` + `SDL_SavePNG`): a
copy pass downloads the swapchain, a fence waits for it, and the mapped
pixels become a `BGRA8888` surface.
"""
function gpu_capture_swapchain!(st, path::AbstractString)
    w, h = st.swapchain_w, st.swapchain_h
    tb = SDL3.CreateGPUTransferBuffer(st.device, SDL3.TransferBufferCreateInfo(
        SDL3.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, UInt32(w * h * 4), UInt32(0)))
    tb == C_NULL && (@warn "Rocks: could not create the screenshot download buffer"; return false)
    copy_pass = SDL3.BeginGPUCopyPass(st.cmdbuf)
    SDL3.DownloadFromGPUTexture(copy_pass,
        SDL3.TextureRegion(st.swapchain_texture, UInt32(0), UInt32(0), UInt32(0),
                           UInt32(0), UInt32(0), UInt32(w), UInt32(h), UInt32(1)),
        SDL3.TextureTransferInfo(tb, UInt32(0), UInt32(w), UInt32(h)))
    SDL3.EndGPUCopyPass(copy_pass)
    fence = SDL3.SubmitGPUCommandBufferAndAcquireFence(st.cmdbuf)
    st.cmdbuf = C_NULL
    st.swapchain_texture = C_NULL
    ok = fence != C_NULL
    ok = ok && SDL3.WaitForGPUFences(st.device, true, [fence])
    fence != C_NULL && SDL3.ReleaseGPUFence(st.device, fence)
    if !ok
        SDL3.ReleaseGPUTransferBuffer(st.device, tb)
        @warn "Rocks: the GPU screenshot did not complete"
        return false
    end
    ptr = SDL3.MapGPUTransferBuffer(st.device, tb, false)
    ok = ptr != C_NULL
    if ok
        try
            # The surface references the mapped download buffer (no copy);
            # it must be destroyed before the buffer is unmapped below.
            # The swapchain (B8G8R8A8_UNORM) stores the components in memory
            # order B, G, R, A — the packed ARGB8888 format's little-endian
            # byte order.
            surface = SDL3.CreateSurfaceFrom(w, h, SDL3.SDL_PIXELFORMAT_ARGB8888,
                                             convert(Ptr{UInt8}, ptr), w * 4)
            try
                SDL3.SavePNG(surface, String(path))
            finally
                SDL3.DestroySurface(surface)
            end
        catch err
            @warn "Rocks: could not write the GPU screenshot" path exception = err
            ok = false
        end
    end
    SDL3.UnmapGPUTransferBuffer(st.device, tb)
    SDL3.ReleaseGPUTransferBuffer(st.device, tb)
    return ok
end

# ---- the draw primitives (the GPU side of set_color/fill_rect/geometry) ----

"Set the current draw color (the GPU side of `SDL_SetRenderDrawColor`)."
gpu_set_color!(rgba::NTuple{4,UInt8}) =
    (GPU_STATE[].color = rgba; nothing)

"""
    gpu_record_fill_rect!(x, y, w, h) -> Bool

The GPU side of `fill_rect`: one colored quad, two triangles. The vertices
are written straight into the staging buffer (no intermediate vectors).
"""
function gpu_record_fill_rect!(x, y, w, h)
    (w <= 0 || h <= 0) && return true
    st = GPU_STATE[]
    vsize = UInt32(4 * 32)              # 4 SDL_Vertex (32 bytes each)
    isize = UInt32(6 * 4)               # 6 Cint indices
    (st.cursor + vsize + isize > GPU_TRANSFER_SIZE) && return false
    (r, g, b, a) = st.color
    fr, fg, fb, fa = Float32(r / 255), Float32(g / 255), Float32(b / 255),
                     Float32(a / 255)
    voff = st.cursor
    ioff = voff + vsize
    dst = convert(Ptr{UInt8}, st.transfer_ptr)
    # 4 vertices: position (2 f32), color (4 f32), uv (2 f32) each.
    xs = (Float32(x), Float32(x + w), Float32(x), Float32(x + w))
    ys = (Float32(y), Float32(y), Float32(y + h), Float32(y + h))
    us = (0.0f0, 1.0f0, 0.0f0, 1.0f0)
    vs_ = (0.0f0, 0.0f0, 1.0f0, 1.0f0)
    for i in 1:4
        base = dst + (voff + (i - 1) * 32)
        unsafe_store!(convert(Ptr{Float32}, base), xs[i])
        unsafe_store!(convert(Ptr{Float32}, base + 4), ys[i])
        for (k, c) in ((8, fr), (12, fg), (16, fb), (20, fa))
            unsafe_store!(convert(Ptr{Float32}, base + k), c)
        end
        unsafe_store!(convert(Ptr{Float32}, base + 24), us[i])
        unsafe_store!(convert(Ptr{Float32}, base + 28), vs_[i])
    end
    # Indices: two triangles (0,1,2), (2,1,3).
    idx = convert(Ptr{Cint}, dst + ioff)
    for (k, v) in ((0, 0), (1, 1), (2, 2), (3, 2), (4, 1), (5, 3))
        unsafe_store!(idx, Cint(v), k + 1)
    end
    st.cursor += vsize + isize
    push!(st.commands, (:color, vsize, UInt32(6), UInt32(voff), UInt32(ioff),
                        C_NULL))
    return true
end

"""
    gpu_record_geometry!(verts, idx) -> Bool

The GPU side of `SDL_RenderGeometry`: arbitrary colored vertices (the
tessellated rounded rects and gradients upload as-is).
"""
gpu_record_geometry!(verts::Vector{SDL3.SDL_Vertex}, idx::Vector{Cint}) =
    gpu_record!(:color, verts, idx)

"""
    gpu_record_texture!(texture, x, y, w, h; own = false) -> Bool

The GPU side of `SDL_RenderTexture`: one textured quad (the texture
pipeline, the uv (0,0)-(1,1), the color white — the tint is baked into the
texture). `own = true` marks a texture that exists for this one draw (the
debug overlay's fresh texture); it is released at frame end. The vertices
are written straight into the staging buffer (no intermediate vectors).
"""
function gpu_record_texture!(texture, x, y, w, h; own = false)
    (w <= 0 || h <= 0) && return true
    st = GPU_STATE[]
    if own
        texture in st.frame_textures || push!(st.frame_textures, texture)
    end
    vsize = UInt32(4 * 32)              # 4 SDL_Vertex (32 bytes each)
    isize = UInt32(6 * 4)               # 6 Cint indices
    (st.cursor + vsize + isize > GPU_TRANSFER_SIZE) && return false
    voff = st.cursor
    ioff = voff + vsize
    dst = convert(Ptr{UInt8}, st.transfer_ptr)
    # 4 vertices: position (2 f32), color white (4 f32), uv (0,0)-(1,1).
    xs = (Float32(x), Float32(x + w), Float32(x), Float32(x + w))
    ys = (Float32(y), Float32(y), Float32(y + h), Float32(y + h))
    us = (0.0f0, 1.0f0, 0.0f0, 1.0f0)
    vs_ = (0.0f0, 0.0f0, 1.0f0, 1.0f0)
    for i in 1:4
        base = dst + (voff + (i - 1) * 32)
        unsafe_store!(convert(Ptr{Float32}, base), xs[i])
        unsafe_store!(convert(Ptr{Float32}, base + 4), ys[i])
        for k in (8, 12, 16, 20)
            unsafe_store!(convert(Ptr{Float32}, base + k), 1.0f0)
        end
        unsafe_store!(convert(Ptr{Float32}, base + 24), us[i])
        unsafe_store!(convert(Ptr{Float32}, base + 28), vs_[i])
    end
    # Indices: two triangles (0,1,2), (2,1,3).
    idx = convert(Ptr{Cint}, dst + ioff)
    for (k, v) in ((0, 0), (1, 1), (2, 2), (3, 2), (4, 1), (5, 3))
        unsafe_store!(idx, Cint(v), k + 1)
    end
    st.cursor += vsize + isize
    push!(st.commands, (:tex, vsize, UInt32(6), UInt32(voff), UInt32(ioff),
                        texture))
    return true
end

"""
    gpu_record_scissor!(rect)

Record a scissor change as a draw command (the GPU side of
`SDL_SetRenderClipRect`). The record phase has no render pass, so the change
replays inside the frame-end render pass, in record order around the draws it
wraps (`rect === nothing` restores the full swapchain).
"""
function gpu_record_scissor!(rect)
    st = GPU_STATE[]
    push!(st.commands, (:scissor, rect))
    # The tracked scissor keeps the tuple form (the callers pass SDL_Rect).
    st.scissor = rect isa SDL3.SDL_Rect ?
        (Int(rect.x), Int(rect.y), Int(rect.w), Int(rect.h)) : rect
    return nothing
end

"The GPU side of `SDL_CreateTextureFromSurface` for text: the TTF surface's
pixels upload to a GPU texture through its own command buffer (created once
per text-state change)."
function gpu_texture_from_surface(device, surface)
    # Normalize to ARGB8888: its little-endian byte order (B, G, R, A) matches
    # the B8G8R8A8_UNORM GPU texture's memory order, and it has a known
    # 4-bytes-per-pixel row pitch. (A TTF blended surface is already ARGB8888;
    # loaded images may not be.)
    bgra = try
        SDL3.ConvertSurface(surface, SDL3.SDL_PIXELFORMAT_ARGB8888)
    catch err
        @warn "Rocks: could not convert a surface for GPU upload" exception = err
        C_NULL
    end
    bgra == C_NULL && return C_NULL
    try
        w, h = SDL3.SurfaceWidth(bgra), SDL3.SurfaceHeight(bgra)
        (w <= 0 || h <= 0) && return C_NULL
        tinfo = SDL3.TextureCreateInfo(SDL3.SDL_GPU_TEXTURETYPE_2D,
                                       GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
                                       SDL3.SDL_GPU_TEXTUREUSAGE_SAMPLER, UInt32(w),
                                       UInt32(h), UInt32(1), UInt32(1),
                                       SDL3.SDL_GPU_SAMPLECOUNT_1,
                                       UInt32(0))
        texture = SDL3.CreateGPUTexture(device, tinfo)
        texture == C_NULL && return C_NULL
        SDL3.SetGPUTextureName(device, texture, "text")
        tb = SDL3.CreateGPUTransferBuffer(device, SDL3.TransferBufferCreateInfo(
            SDL3.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, UInt32(w * h * 4), UInt32(0)))
        if tb == C_NULL
            SDL3.ReleaseGPUTexture(device, texture)
            return C_NULL
        end
        dst_ptr = SDL3.MapGPUTransferBuffer(device, tb, false)
        src = convert(Ptr{UInt8}, SDL3.SurfacePixels(bgra))
        dst = convert(Ptr{UInt8}, dst_ptr)
        # Row by row: the surface's pitch may exceed w * 4.
        spitch, dpitch = SDL3.SurfacePitch(bgra), w * 4
        for row in 0:(h - 1)
            unsafe_copyto!(dst + row * dpitch, src + row * spitch, dpitch)
        end
        SDL3.UnmapGPUTransferBuffer(device, tb)
        cmdbuf = SDL3.AcquireGPUCommandBuffer(device)
        copy_pass = SDL3.BeginGPUCopyPass(cmdbuf)
        SDL3.UploadToGPUTexture(copy_pass,
            SDL3.TextureTransferInfo(tb, UInt32(0), UInt32(w), UInt32(h)),
            SDL3.TextureRegion(texture, UInt32(0), UInt32(0), UInt32(0), UInt32(0),
                               UInt32(0), UInt32(w), UInt32(h), UInt32(1)))
        SDL3.EndGPUCopyPass(copy_pass)
        SDL3.SubmitGPUCommandBuffer(cmdbuf)
        SDL3.ReleaseGPUTransferBuffer(device, tb)
        return texture
    finally
        SDL3.DestroySurface(bgra)
    end
end

"The GPU side of `SDL_DestroyTexture` for text textures."
gpu_free_texture(device, texture) = SDL3.ReleaseGPUTexture(device, texture)

"""
    gpu_texture_from_pixels(device, pixels, w, h) -> Ptr{SDL_GPUTexture}

The GPU side of `SDL_UpdateTexture`: raw ARGB8888 pixels (a `Vector{UInt32}`
packed the way SDL_PIXELFORMAT_ARGB8888 stores them, which is the B8G8R8A8
memory order of the texture) upload to a GPU texture through their own
command buffer.
"""
function gpu_texture_from_pixels(device, pixels::AbstractVector{UInt32},
                                 w::Int, h::Int)
    (w <= 0 || h <= 0 || w * h != length(pixels)) && return C_NULL
    tinfo = SDL3.TextureCreateInfo(SDL3.SDL_GPU_TEXTURETYPE_2D,
                                   GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
                                   SDL3.SDL_GPU_TEXTUREUSAGE_SAMPLER, UInt32(w),
                                   UInt32(h), UInt32(1), UInt32(1),
                                   SDL3.SDL_GPU_SAMPLECOUNT_1, UInt32(0))
    texture = SDL3.CreateGPUTexture(device, tinfo)
    texture == C_NULL && return C_NULL
    tb = SDL3.CreateGPUTransferBuffer(device, SDL3.TransferBufferCreateInfo(
        SDL3.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, UInt32(w * h * 4), UInt32(0)))
    if tb == C_NULL
        SDL3.ReleaseGPUTexture(device, texture)
        return C_NULL
    end
    dst = SDL3.MapGPUTransferBuffer(device, tb, false)
    # One copy: the pixels are already in the texture's byte order.
    unsafe_copyto!(convert(Ptr{UInt8}, dst),
                   convert(Ptr{UInt8}, pointer(pixels)), w * h * 4)
    SDL3.UnmapGPUTransferBuffer(device, tb)
    cmdbuf = SDL3.AcquireGPUCommandBuffer(device)
    copy_pass = SDL3.BeginGPUCopyPass(cmdbuf)
    SDL3.UploadToGPUTexture(copy_pass,
        SDL3.TextureTransferInfo(tb, UInt32(0), UInt32(w), UInt32(h)),
        SDL3.TextureRegion(texture, UInt32(0), UInt32(0), UInt32(0), UInt32(0),
                           UInt32(0), UInt32(w), UInt32(h), UInt32(1)))
    SDL3.EndGPUCopyPass(copy_pass)
    SDL3.SubmitGPUCommandBuffer(cmdbuf)
    SDL3.ReleaseGPUTransferBuffer(device, tb)
    return texture
end