# The Image element: load a graphics file from a path (or URL) and scale it.
# The example generates a gradient BMP with SDL so it needs no asset files.
#
#   julia --project examples/image.jl

using Rocks
import SDL3 # qualified: SDL3 exports a `Window` type alias, Rocks a component
import Rocks: Text

const IMG_W, IMG_H = 240, 160

# Generate a gradient BMP so the example is self-contained.
function make_image(path)
    surface = SDL3.CreateSurface(IMG_W, IMG_H, SDL3.SDL_PIXELFORMAT_RGB24)
    for y in 0:IMG_H-1, x in 0:IMG_W-1
        r = round(UInt8, 60 + 160 * x / (IMG_W - 1))
        g = round(UInt8, 40 + 140 * y / (IMG_H - 1))
        SDL3.WriteSurfacePixel(surface, x, y, r, g, UInt8(180), 255)
    end
    SDL3.SaveBMP(surface, path)
    SDL3.DestroySurface(surface)
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
