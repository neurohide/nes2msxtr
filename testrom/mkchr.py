#!/usr/bin/env python3
"""Builds testrom.chr: original tiles for the translator test ROM.

Pattern table 0 (BG): blank, solid, brick, block, dots, a 3x5 font.
Pattern table 1 (sprites): a 2x2-tile robot and a marker tile for sprite 0.
"""
import sys

def tile(rows):
    """rows: 8 strings of 8 chars '0'-'3' -> 16 bytes of NES 2bpp."""
    lo = bytearray(8); hi = bytearray(8)
    for y, r in enumerate(rows):
        for x, c in enumerate(r.ljust(8, "0")):
            v = int(c)
            lo[y] |= (v & 1) << (7 - x)
            hi[y] |= (v >> 1) << (7 - x)
    return bytes(lo + hi)

FONT = {  # 3x5 glyphs, '#' = on
 "0":"### # # # # # ###","1":" #  #  #  #  # ","2":"###  #####  ###","3":"###  ####  ####",
 "4":"# ## ####  #  #","5":"####  ###  ####","6":"####  #### ####","7":"###  #  #  #  #",
 "8":"#### ##### ####","9":"#### ####  ####","A":" # # ##### ## #","B":"## # ### # ### ",
 "C":"####  #  #  ###","D":"## # ## ## ### ","E":"####  ####  ###","F":"####  ####  #  ",
 "G":"####  # ## ####","K":"# ## ### # ## #","M":"# #### ## ## ##","N":"#### ## ## ## #",
 "O":"### ## ## ## ###","P":"### #####  #  ","R":"### #### # ## #","S":"####  ###  ####",
 "T":"### #  #  #  # ","U":"# ## ## ## #####","X":"# ## # # # ## #","Y":"# ## # #  #  # ",
 ":":"    #     #    ","-":"      ###      ",
}
def glyph(ch):
    g = FONT[ch].ljust(15)
    rows = ["00000000"]
    for y in range(5):
        r = "0"
        for x in range(3):
            r += ("33" if g[y * 3 + x] == "#" else "00")
        rows.append(r.ljust(8, "0"))
    rows += ["00000000", "00000000"]
    return tile(rows)

FONT_ORDER = "0123456789ABCDEFGKMNOPRSTUXY:-"   # tile $10 + index

bg = [bytes(16)] * 256
bg[1] = tile(["11111111"] * 8)
bg[2] = tile(["22222223", "22222223", "33333333", "22232222",
              "22232222", "33333333", "22222223", "22222223"])
bg[3] = tile(["13333331", "31111113", "31222213", "31211213",
              "31211213", "31222213", "31111113", "13333331"])
bg[4] = tile(["00000000", "01000100", "00000000", "00010001",
              "00000000", "01000100", "00000000", "00010001"])
for i, ch in enumerate(FONT_ORDER):
    bg[0x10 + i] = glyph(ch)

sp = [bytes(16)] * 256
# robot, 16x16 as 4 tiles: original design (antenna, visor, body, treads)
robot = [
 "0000000330000000", "0000000110000000", "0003333333333000", "0031111111111300",
 "0031222222221300", "0031233223321300", "0031222222221300", "0003333333333000",
 "0000311111130000", "0003111331113000", "0031113113111300", "0031111111111300",
 "0003333333333000", "0032323003232300", "0033333003333300", "0000000000000000",
]
def sub(r0, c0): return tile([robot[r0 + y][c0:c0 + 8] for y in range(8)])
sp[0], sp[1], sp[2], sp[3] = sub(0, 0), sub(0, 8), sub(8, 0), sub(8, 8)
sp[4] = tile(["00000000"] * 6 + ["11111111", "11111111"])   # sprite-0 marker

open(sys.argv[1], "wb").write(b"".join(bg) + b"".join(sp))
