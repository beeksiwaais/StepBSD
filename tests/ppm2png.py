"""Convert a qemu screendump (binary PPM) to PNG and decide whether it shows
the X desktop or still the text console.

usage: python3 -I ppm2png.py in.ppm out.png

Exit 1 when the picture looks like a text console: mostly black, or only a
handful of colours (vt(4) draws 16).
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


w, h, rgb = read_ppm(sys.argv[1])
write_png(sys.argv[2], w, h, rgb)

pixels = [rgb[i:i + 3] for i in range(0, len(rgb), 3)]
black = sum(1 for p in pixels if max(p) < 16) / len(pixels)
colours = len(set(pixels))
print(f"screenshot {w}x{h}: {black:.0%} black, {colours} colours -> {sys.argv[2]}")
if black > 0.6 or colours < 24:
    print("FAIL: the screen still looks like the text console")
    sys.exit(1)
print("OK: the screen shows a graphical desktop")
