"""Convert a qemu screendump (binary PPM) to PNG and decide whether it shows
the X desktop or still the text console.

usage: python3 -I ppm2png.py [--menubar] in.ppm out.png

Exit 1 when the picture looks like a text console: mostly black, or only a
handful of colours (vt(4) draws 16). With --menubar, also exit 1 unless the
desktop session's menu bar is up: Menu draws a light grey bar across the
top of the screen, where the login window shows its blue wallpaper.
"""
import struct
import sys
import zlib


def read_ppm(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6" or int(fields[3]) != 255:
        sys.exit("not an 8-bit binary PPM")
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos + 1:pos + 1 + w * h * 3]


def write_png(path, w, h, rgb):
    def chunk(kind, body):
        c = kind + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c))
    rows = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


args = sys.argv[1:]
menubar = args[:1] == ["--menubar"]
if menubar:
    args = args[1:]
w, h, rgb = read_ppm(args[0])
write_png(args[1], w, h, rgb)

pixels = [rgb[i:i + 3] for i in range(0, len(rgb), 3)]
black = sum(1 for p in pixels if max(p) < 16) / len(pixels)
colours = len(set(pixels))
print(f"screenshot {w}x{h}: {black:.0%} black, {colours} colours -> {args[1]}")
if black > 0.6 or colours < 24:
    print("FAIL: the screen still looks like the text console")
    sys.exit(1)
print("OK: the screen is graphical")
if menubar:
    # Rows 2-17: inside the bar, clear of its edges. The bar is a light grey
    # gradient; the login window's wallpaper there is a saturated blue.
    strip = [rgb[(y * w + x) * 3:(y * w + x) * 3 + 3] for y in range(2, 18) for x in range(w)]
    light = sum(1 for p in strip if min(p) >= 150 and max(p) - min(p) <= 16) / len(strip)
    print(f"top strip: {light:.0%} light grey")
    if light < 0.5:
        print("FAIL: no menu bar: the desktop session did not start")
        sys.exit(1)
    print("OK: the desktop session's menu bar is up")
