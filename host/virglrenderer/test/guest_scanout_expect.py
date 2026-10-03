#!/usr/bin/env python3
"""Compare a steamac-vm frame dump (PNG, SIGUSR1) with guest_scanout's gradient.

guest_scanout fills a B8G8R8A8 image with B = x, G = y, R = x ^ y (all mod 256) and scans
it out as XRGB8888, so pixel (x, y) of the presented frame must be RGB (x^y, y, x) & 0xff.
Usage: guest_scanout_expect.py FRAME.png [WIDTH HEIGHT]
Exits non-zero on any mismatch. Needs only the Python standard library.
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, hdr = 8, b"", None
    while pos < len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"IDAT":
            idat += chunk
        pos += 12 + length
    width, height, depth, color, _, _, interlace = hdr
    assert depth == 8 and color in (2, 6) and interlace == 0, f"unsupported PNG {hdr}"
    bpp = 3 if color == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for y in range(height):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        rows.append(bytes(line))
        prev = line
    return width, height, bpp, rows


def main():
    path = sys.argv[1]
    width, height, bpp, rows = read_png(path)
    want_w = int(sys.argv[2]) if len(sys.argv) > 2 else width
    want_h = int(sys.argv[3]) if len(sys.argv) > 3 else height
    if (width, height) != (want_w, want_h):
        print(f"frame is {width}x{height}, expected {want_w}x{want_h}")
        return 1
    bad = 0
    first = None
    for y in range(height):
        row = rows[y]
        for x in range(width):
            r, g, b = row[x * bpp:x * bpp + 3]
            if (r, g, b) != ((x ^ y) & 0xFF, y & 0xFF, x & 0xFF):
                bad += 1
                if first is None:
                    first = (x, y, (r, g, b))
    if bad:
        print(f"{bad} of {width * height} pixels differ; first at {first[:2]}: {first[2]}")
        return 1
    print(f"all {width}x{height} pixels match the gradient")
    return 0


if __name__ == "__main__":
    sys.exit(main())
