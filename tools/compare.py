#!/usr/bin/env python3
"""Compare NES RAM from the MSX run with the reference 6502 run.

usage: compare.py ref_ram.bin msx_ram.bin [ref_chr.bin v9990_vram.bin]
With CHR (from ref6502.py) and a V9990 VRAM dump, the background patterns
are compared too: CHR RAM tiles as the runtime rebuilt them.
The stack page ($0100-$01FF) is skipped. NMI frames hold the interrupted
PC, which translated code doesn't know. Unless the game uses TSX, JSR return
addresses live only on the Z80 stack.
"""
import sys

ref = open(sys.argv[1], "rb").read()
msx = open(sys.argv[2], "rb").read()
diffs = [a for a in range(0x800) if ref[a] != msx[a] and not 0x100 <= a < 0x200]
for a in diffs[:32]:
    print(f"  ${a:04X}: ref {ref[a]:02X}  msx {msx[a]:02X}")
print(f"{len(diffs)} differing bytes" if diffs else "RAM matches the reference")
bad = 0
if len(sys.argv) > 4:
    sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
    from nes2msxtr import bg_vram
    want = bg_vram(open(sys.argv[3], "rb").read())
    got = open(sys.argv[4], "rb").read()[:0x10000]
    bad = sum(1 for i in range(0x10000) if want[i] != got[i])
    print(f"background patterns: {bad} differing VRAM bytes" if bad else "background patterns match the CHR")
sys.exit(1 if diffs or bad else 0)
