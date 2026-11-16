#!/usr/bin/env python3
"""Make the app icon from assets/0-nes-to-msx-turbor.png: the artwork left of
the NOTICE panel, without the text lines above and below it (rows ART_Y),
padded to a square with its edge columns, scaled up with nearest neighbour
(pixel art) and down with a box filter.

Writes app/Nes2MsxTr.App/Assets/icon.png (window icon), installer/icon.ico
(Windows) and installer/icon.icns (macOS). Pure Python, no PIL.

usage: make_icon.py [source.png]
"""
import os, struct, sys, zlib

NOTICE_X = 160      # first column of the NOTICE panel (its blue border)
ART_Y = (10, 170)   # rows between "CREATED USING" (2-7) and "CONVERTER TOOL BY" (171-185)


def load(fn):
    d = open(fn, "rb").read()
    p, idat = 8, b""
    while p < len(d):
        n, t = struct.unpack(">I4s", d[p:p + 8])
        c = d[p + 8:p + 8 + n]
        p += 12 + n
        if t == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", c[:10])
            assert bd == 8 and ct in (2, 6), "8-bit RGB/RGBA only"
        elif t == b"IDAT":
            idat += c
    bpp = 3 if ct == 2 else 4
    raw, st = zlib.decompress(idat), w * bpp
    prev, i, px = bytearray(st), 0, []
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + st])
        i += 1 + st
        for x in range(st):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        px.append([tuple(line[x * bpp:x * bpp + 3]) for x in range(w)])
        prev = line
    return px


def png(px):
    h, w = len(px), len(px[0])
    raw = b"".join(b"\0" + bytes(v for p in row for v in (*p, 255)) for row in px)
    chunk = lambda t, c: struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def resize(px, s):
    n = len(px)
    if s >= n:
        return [[px[y * n // s][x * n // s] for x in range(s)] for y in range(s)]
    out = []
    for y in range(s):
        y0, y1 = y * n // s, (y + 1) * n // s
        row = []
        for x in range(s):
            x0, x1 = x * n // s, (x + 1) * n // s
            cells = [px[yy][xx] for yy in range(y0, y1) for xx in range(x0, x1)]
            row.append(tuple(sum(c[k] for c in cells) // len(cells) for k in range(3)))
        out.append(row)
    return out


def square(px):
    art = [row[:NOTICE_X] for row in px[ART_Y[0]:ART_Y[1]]]
    h, w = len(art), NOTICE_X
    assert h >= w
    left = (h - w) // 2
    return [[row[0]] * left + row + [row[-1]] * (h - w - left) for row in art]


def main(src="assets/0-nes-to-msx-turbor.png"):
    sq = square(load(src))
    assert len(sq) == len(sq[0])
    os.makedirs("installer", exist_ok=True)
    open("app/Nes2MsxTr.App/Assets/icon.png", "wb").write(png(resize(sq, 256)))

    sizes = [16, 24, 32, 48, 64, 128, 256]          # PNG entries (Vista and later)
    imgs = [png(resize(sq, s)) for s in sizes]
    off = 6 + 16 * len(sizes)
    ico = struct.pack("<HHH", 0, 1, len(sizes))
    for s, d in zip(sizes, imgs):
        ico += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(d), off)
        off += len(d)
    open("installer/icon.ico", "wb").write(ico + b"".join(imgs))

    body = b""
    for t, s in [(b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128),
                 (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024)]:
        d = png(resize(sq, s))
        body += t + struct.pack(">I", len(d) + 8) + d
    open("installer/icon.icns", "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print("wrote app/Nes2MsxTr.App/Assets/icon.png installer/icon.ico installer/icon.icns")


if __name__ == "__main__":
    main(*sys.argv[1:])
