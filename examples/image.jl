# The Image element: load a graphics file from a path (or URL) and scale it.
# The example generates a gradient BMP with SDL so it needs no asset files.
#
#   julia --project examples/image.jl

using Rocks
using SimpleDirectMediaLayer.LibSDL2
import Rocks: Text

const IMG_W, IMG_H = 240, 160

# Generate a gradient BMP so the example is self-contained.
function make_image(path)
    surface = SDL_CreateRGBSurfaceWithFormat(0, IMG_W, IMG_H, 24, SDL_PIXELFORMAT_RGB24)
    pixels = Ptr{UInt8}(unsafe_load(surface).pixels)
    for y in 0:IMG_H-1, x in 0:IMG_W-1
        offset = (y * IMG_W + x) * 3
        unsafe_store!(pixels, round(UInt8, 60 + 160 * x / (IMG_W - 1)), offset + 1)
        unsafe_store!(pixels, round(UInt8, 40 + 140 * y / (IMG_H - 1)), offset + 2)
        unsafe_store!(pixels, UInt8(180), offset + 3)
    end
    rw = SDL_RWFromFile(path, "wb")
    @assert SDL_SaveBMP_RW(surface, rw, 1) == 0 # frees the RWops
    SDL_FreeSurface(surface)
    return path
end

img_path = joinpath(tempdir(), "rocks-gradient.bmp")
make_image(img_path)

function App()
    zoom = @use Observable(1.0)
    w = round(Int, IMG_W * zoom[])
    @rock Window(
        @rock Column(
            @rock Image(; src = img_path, width = w),
            @rock Text("generated BMP (path), scaled to width ", w;
                       size = 12, color = "#8899aa"),
            @rock Row(
                @rock Button("Smaller";
                             on_press = () -> zoom[] = max(0.5, zoom[] - 0.25)),
                @rock Button("Bigger";
                             on_press = () -> zoom[] = min(2.0, zoom[] + 0.25));
                gap = 8);
            # URLs work too (fetched with Downloads and cached):
            # @rock Image(; src = "https://example.com/picture.png", width = 240);
            gap = 10);
        title = "Image", width = 420, height = 440,
        padding = 16, gap = 12)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end
