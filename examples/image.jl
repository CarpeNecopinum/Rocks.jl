# The Picture element: load an image file from a path (or URL) and scale it.
# The example writes a gradient BMP itself so it needs no asset files and no
# third-party image packages.
#
#   julia --project examples/image.jl

using Rocks

const IMG_W, IMG_H = 240, 160

# Write a 24-bit BMP (bottom-up rows, each padded to a multiple of 4 bytes).
# The `do`-block supplies the pixel function, mapping (x, y) to (r, g, b).
function write_bmp(pixel, path, w, h)
    padding = (4 - (3w) % 4) % 4
    row = 3w + padding
    open(path, "w") do io
        write(io, 0x42, 0x4d)                                  # "BM"
        write(io, UInt32(54 + row * h), UInt32(0), UInt32(54)) # file header
        write(io, UInt32(40), Int32(w), Int32(h))              # BITMAPINFOHEADER
        write(io, UInt16(1), UInt16(24), UInt32(0), UInt32(row * h),
              UInt32(2835), UInt32(2835), UInt32(0), UInt32(0))
        for y in h-1:-1:0
            for x in 0:w-1
                r, g, b = pixel(x, y)
                write(io, UInt8(r), UInt8(g), UInt8(b))
            end
            for _ in 1:padding
                write(io, 0x00)
            end
        end
    end
    return path
end

# A vertical/diagonal blue gradient, so the example is self-contained.
img_path = joinpath(tempdir(), "rocks-gradient.bmp")
write_bmp(img_path, IMG_W, IMG_H) do x, y
    r = round(UInt8, 60 + 160 * x / (IMG_W - 1))
    g = round(UInt8, 40 + 140 * y / (IMG_H - 1))
    b = UInt8(200)
    return (r, g, b)
end

function App()
    zoom = @use Observable(1.0)
    w = round(Int, IMG_W * zoom[])
    @rock Window(
        @rock Column(
            @rock Picture(; src = img_path, width = w),
            @rock Label("generated BMP (path), scaled to width ", w;
                        size = 12, color = "#8899aa"),
            @rock Row(
                @rock Button("Smaller";
                             on_press = () -> zoom[] = max(0.5, zoom[] - 0.25)),
                @rock Button("Bigger";
                             on_press = () -> zoom[] = min(2.0, zoom[] + 0.25));
                gap = 8);
            # The props of the enclosing column come after the `;` separator:
            # a `name = value` directly after a comma would be swallowed by
            # the preceding `@rock` call.
            # URLs work too (fetched with Downloads and cached):
            # @rock Picture(; src = "https://example.com/picture.png", width = 240);
            gap = 10);
        title = "Images", width = 420, height = 420,
        padding = 16, gap = 12)
end

if abspath(PROGRAM_FILE) == @__FILE__
    render(App)
end

