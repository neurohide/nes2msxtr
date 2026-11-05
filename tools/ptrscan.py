#!/usr/bin/env python3
"""Static fallback for computed jumps the tracer missed: scan PRG for
pointer tables and keep the targets that look like code.

Candidates: runs of >= RUN words (or split lo / hi byte tables) whose
values point into ROM, also value + 1 (RTS-trick tables). A target is kept
when a linear decode from it reaches RTS / RTI / JMP within 64
instructions with only official opcodes, in-ROM jumps and in-range
branches. UxROM / MMC1 layout only (16K banks, last one fixed at $C000).

usage: ptrscan.py game.nes [entries.txt]   (prints 'bank addr' lines;
with entries.txt, appends the new ones)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nestrace import OPS, MODES

RUN = 3

def main(rom_path, out=None):
    rom = open(rom_path, "rb").read()
    n = rom[4]
    prg = rom[16 + (512 if rom[6] & 4 else 0):][:n * 0x4000]
    banks = [prg[i * 0x4000:(i + 1) * 0x4000] for i in range(n)]
    fixed = banks[-1]

    def rd(b, a):                  # bank b mapped at $8000, fixed at $C000
        if a >= 0xC000: return fixed[a - 0xC000]
        if a >= 0x8000: return banks[b][a - 0x8000]
        return None

    def code_ok(b, t):
        a = t
        for _ in range(64):
            o = rd(b, a)
            if o is None or o not in OPS: return False
            m, mode = OPS[o]
            k = MODES[mode]
            if a + k > 0x10000 or rd(b, a + k - 1) is None: return False
            if mode == "rel":
                d = rd(b, a + 1)
                if not 0x8000 <= a + 2 + (d - 256 if d > 127 else d) < 0x10000: return False
            elif m in ("JMP", "JSR") and mode == "abs":
                if rd(b, a + 1) | rd(b, a + 2) << 8 < 0x8000: return False
            if m in ("RTS", "RTI") or (m == "JMP" and mode in ("abs", "ind")): return True
            a += k
        return False

    # operands of indexed loads: a table the code indexes is named there
    refs = set()
    for b in range(n):
        for src, base in ((banks[b], 0x8000), (fixed, 0xC000)):
            if b < n - 1 or src is fixed:
                for i in range(len(src) - 2):
                    if src[i] in (0xBD, 0xB9, 0xBC, 0xBE, 0xFD, 0xF9):
                        refs.add(src[i + 1] | src[i + 2] << 8)

    def near(lo, hi):              # a referenced address in [lo, hi]
        return any(lo <= r <= hi for r in refs)

    cands = set()                  # (bank, target)
    for b in range(n):
        d = banks[b]
        for src, base in ((d, 0x8000), (fixed, 0xC000)):
            if src is fixed and b != n - 1: continue
            # word tables, both alignments
            for start in range(2):
                run = []
                for i in range(start, len(src) - 1, 2):
                    v = src[i] | src[i + 1] << 8
                    if v >= 0x8000: run.append(v)
                    else:
                        if len(run) >= RUN and near(base + i - 2 * len(run) - 1, base + i):
                            cands |= {(b, x) for x in run} | {(b, x + 1) for x in run}
                        run = []
            # split tables: lo[o + i], hi[o + L + i]; both bases referenced
            for o in range(len(src)):
                if base + o not in refs and base + o - 1 not in refs: continue
                for L in range(RUN, 0x100):
                    run = 0
                    while o + run + L < len(src) and src[o + run + L] >= 0x80 and run < 0x100: run += 1
                    if run >= RUN and (base + o + L in refs or base + o + L - 1 in refs):
                        for i in range(run):
                            v = src[o + i] | src[o + i + L] << 8
                            cands |= {(b, v), (b, v + 1)}
    good = sorted((b, t) for b, t in cands if 0x8000 <= t < 0x10000 and code_ok(b, t))
    return good

if __name__ == "__main__":
    g = main(sys.argv[1])
    print(len(g), "targets")
