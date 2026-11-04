#!/usr/bin/env python3
"""nes2msxtr: statically recompile an NROM, UxROM, MMC1 or MMC3 NES game into an MSX
turboR cartridge (ASCII16 megaROM) that renders on a V9990 (GFX9000).

usage: nes2msxtr.py game.nes out_dir [--crop N] [--bank-kb N] [--pad-kb N] [--splash PNG]

Only use this on games you have the rights to port.
"""
import argparse, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.join(os.path.dirname(HERE), "runtime")
sys.path.insert(0, HERE)
import nestrace

RAMB = 0xC000
SEG_BASE = 4                    # first mapper segment we use (0-3: system)
NZ_OPS = {"LDA", "LDX", "LDY", "ADC", "SBC", "AND", "ORA", "EOR", "CMP", "CPX", "CPY",
          "BIT", "INC", "DEC", "ASL", "LSR", "ROL", "ROR", "TAX", "TAY", "TXA", "TYA",
          "TSX", "INX", "INY", "DEX", "DEY", "PLA", "PLP"}
PPU_R = {2: "io_r_2002", 4: "io_r_2004", 7: "io_r_2007"}
PPU_W = {0: "io_w_2000", 1: "io_w_2001", 2: "io_nop", 3: "io_w_2003", 4: "io_w_2004",
         5: "io_w_2005", 6: "io_w_2006", 7: "io_w_2007"}

def lbl(a): return f"n_{a:04x}"     # banked addresses get 5 digits

def io_read_handler(a):
    if 0x2000 <= a < 0x4000: return PPU_R.get(a & 7, "io_r_open")
    return {0x4015: "io_r_4015", 0x4016: "io_r_4016", 0x4017: "io_r_open"}.get(a, "io_r_zero")

MMC3_W = ["mm_8000", "mm_8001", "mm_a000", None, "mm_c000", "mm_c001", "mm_e000", "mm_e001"]

def io_write_handler(a):
    if 0x2000 <= a < 0x4000: return PPU_W[a & 7]
    if a == 0x4014: return "io_w_4014"
    if a == 0x4016: return "io_w_4016"
    if 0x4000 <= a <= 0x4015: return f"apu_w_{a - 0x4000:02x}"
    return "io_nop"


NZ_READ = {"BEQ", "BNE", "BMI", "BPL", "PHP"}
NZ_WRITE = NZ_OPS
C_READ = {"ADC", "SBC", "ROL", "ROR", "BCC", "BCS", "PHP"}
C_WRITE = {"CLC", "SEC", "ADC", "SBC", "CMP", "CPX", "CPY", "ASL", "LSR", "ROL", "ROR", "PLP"}

def flag_liveness(P):
    """-> (nz_dead, c_dead): instructions whose N/Z or carry result no path
    reads before it is overwritten. Calls, returns, computed jumps and code
    with unknown successors count as reading both flags."""
    code = P.code
    succ, opaque = {}, set()
    for a, (n, m, mode, arg) in code.items():
        s = []
        if m in ("RTS", "RTI", "BRK") or (m == "JMP" and mode == "ind") or m == "JSR" or a in P.dispatch:
            opaque.add(a)
        if m == "JMP" and mode == "abs": s = [P.mem.at(a, arg)]
        elif mode == "rel":
            s = [nestrace.branch_target(a, arg)] + ([] if a in P.nofall else [nestrace.nxt(a, n)])
        elif m not in nestrace.ENDS_FLOW and not (m == "JSR" and P.mem.at(a, arg) in P.engines):
            s = [nestrace.nxt(a, n)]
        if any(t not in code for t in s): opaque.add(a)
        succ[a] = [t for t in s if t in code]

    def solve(reads, writes):
        live_in = {a: False for a in code}
        changed = True
        while changed:
            changed = False
            for a in sorted(code, reverse=True):
                m = code[a][1]
                out = any(live_in[t] for t in succ[a])
                v = a in opaque or m in reads or (out and m not in writes)
                if v != live_in[a]:
                    live_in[a] = v; changed = True
        return {a for a in code if code[a][1] in writes and a not in opaque
                and not any(live_in[t] for t in succ[a])}, live_in
    nz_dead, nz_live = solve(NZ_READ, NZ_WRITE)
    c_dead, _ = solve(C_READ, C_WRITE)
    return nz_dead, c_dead, nz_live, succ


class Translator:
    def __init__(self, P, multibank, wram=False):
        self.P = P
        self.mem = P.mem
        self.multi = multibank
        self.wram = wram                # PRG RAM at $6000-$7FFF
        self.warn = list(P.warnings)
        self.v_used = any(d[1] in ("BVC", "BVS") for d in P.code.values())
        self.engine_body = set()
        for e in P.engines | P.inline:
            a = e
            while a in P.code:
                self.engine_body.add(a)
                n, m, mode, _ = P.code[a]
                if m == "JMP": break
                a = nestrace.nxt(a, n)
        # addresses with incoming control flow (flags are unknown there)
        self.entries = set(P.labels)
        # TSX reads the real stack: JSR/RTS then also keep 6502 return
        # addresses in the page-1 stack, not just on the Z80 stack
        self.faithful = any(d[1] == "TSX" for d in P.code.values())
        self.nz_dead, self.c_dead, self.nz_live, self.succ = flag_liveness(P)
        # an NMI handler that pulls its interrupt frame and the bytes below
        # it, then RTS, returns from the routine it interrupted (a wait
        # loop): that RTS becomes nmi_rts and self-loops spin_wait
        self.unwind = {a for a in P.nmi_body if P.code[a][1] == "RTS" and P.depth.get(a, 0) <= -3}
        self.polls, self.poll_exits = self.idle_loops()

    POLL_OPS = {"LDA", "LDX", "LDY", "CMP", "CPX", "CPY", "BIT", "AND"}

    def idle_loops(self):
        """Heads of the main loop's waits for the NMI: a backward branch over
        at most 4 instructions that only read RAM, like LDA frame / CMP #2 /
        BCC back. Translated code calls idle_poll there
        and idle_end where the loop falls through (see io_w_4014).
        -> (heads, exits)"""
        code, heads, exits = self.P.code, set(), set()
        for a, (n, m, mode, arg) in code.items():
            if a in self.P.nmi_body: continue
            if mode != "rel": continue
            t = nestrace.branch_target(a, arg)
            if t is None or t > a or t not in code: continue
            b, k, ok = t, 0, True
            while b != a and ok:
                bn, bm, bmode, barg = code.get(b, (0, None, None, None))
                ok = bm in self.POLL_OPS and (bmode in ("imm", "zp") or (bmode == "abs" and barg < 0x800))
                k += 1; b = nestrace.nxt(b, bn)
                ok = ok and k <= 4 and b in code
            if ok and t != a:
                heads.add(t)
                if a not in self.P.nofall: exits.add(nestrace.nxt(a, n))
        return heads, exits - heads

    # -- operand addressing -------------------------------------------------
    def addr(self, mode, arg):
        """-> (lines, kind, value). kinds: imm, ram_abs (MSX addr),
        ram_hl, rom_hl, wram_hl, io (NES addr), gen_hl (HL = NES address)."""
        X = ["ex af,af'"]
        if mode == "imm": return [], "imm", arg
        if mode == "zp": return [], "ram_abs", RAMB + arg
        if mode in ("zpx", "zpy"):
            r = "c" if mode == "zpx" else "e"
            return X + [f"ld a,{r}", f"add a,{arg}", "ld l,a", f"ld h,{RAMB >> 8}"] + X, "ram_hl", None
        if mode == "abs":
            if arg < 0x2000: return [], "ram_abs", RAMB + (arg & 0x7FF)
            if arg < 0x4020: return [], "io", arg
            if arg >= 0x8000: return [f"ld hl,{arg}"], "rom_hl", arg
            if arg >= 0x6000 and self.wram: return [f"ld hl,{arg}"], "wram_hl", arg
            self.warn.append(f"access to ${arg:04X} (no device there)")
            return [f"ld hl,{arg}"], "gen_hl", arg
        if mode in ("abx", "aby"):
            base = arg
            wrap = []
            if base < 0x2000 and (base & 0x7FF) + 0xFF < 0x800:
                b, kind = RAMB + (base & 0x7FF), "ram_hl"
            elif base < 0x2000:         # may cross into a RAM mirror: wrap at 2K
                b, kind = RAMB + (base & 0x7FF), "ram_hl"
                wrap = ["and $C7", "ld h,a"]   # A = H after the add
            elif base >= 0x8000 and base + 0xFF <= 0xFFFF:
                b, kind = base, "rom_hl"
            elif self.wram and base >= 0x6000 and base + 0xFF < 0x8000:
                b, kind = base, "wram_hl"
            else:
                b, kind = base, "gen_hl"
            if b & 0xFF == 0 and not wrap and kind != "gen_hl":
                # page-aligned table: the index is the low byte, no add needed
                return [f"ld l,{'c' if mode == 'abx' else 'e'}", f"ld h,{b >> 8}"], kind, None
            if mode == "abx":
                if wrap: return X + [f"ld hl,{b}", "add hl,bc", "ld a,h"] + wrap + X, kind, None
                return X + [f"ld hl,{b}", "add hl,bc"] + X, kind, None
            return X + ["ld a,e", f"add a,{b & 0xFF}", "ld l,a", f"adc a,{b >> 8}", "sub l", "ld h,a"] + wrap + X, kind, None
        if mode == "izx":
            return X + ["ld a,c", f"add a,{arg}", "ld l,a", f"ld h,{RAMB >> 8}",
                        "ld a,(hl)", "inc l", "ld h,(hl)", "ld l,a"] + X, "gen_hl", None
        if mode == "izy":
            if arg == 0xFF:
                ptr = ["ld a,($c0ff)", "ld l,a", "ld a,($c000)", "ld h,a"]
            else:
                ptr = [f"ld hl,({RAMB + arg})"]
            return X + ptr + ["ld a,e", "add a,l", "ld l,a", "adc a,h", "sub l", "ld h,a"] + X, "gen_hl", None
        raise ValueError(mode)

    def read(self, mode, arg):
        """-> (lines, src operand string usable as Z80 r/(hl)/n)."""
        lines, kind, v = self.addr(mode, arg)
        if kind == "imm": return lines, str(v)
        if kind == "ram_abs": return [f"ld hl,{v}"], "(hl)"
        if kind == "ram_hl": return lines, "(hl)"
        if kind == "rom_hl":
            if mode == "abs":
                # a ROM address is a constant, unless it is in the
                # switchable half and this is fixed-bank code
                v = self.mem.at(self.cur, arg)
                if v is not None: return [], str(self.mem.rd(v))
                return lines + ["call rom_rd"], "l"
            if arg & 0xC000 == (arg + 0xFF) & 0xC000 and not (self.mem.mmc3 and arg < 0xC000):
                # table within one 16K half: window address known now
                # (rom_rd0 reads the bank mapped in the switchable half)
                half = 1 if arg & 0x4000 else 0
                wb = (arg & 0x3FFF) | 0x8000
                return self.addr(mode, wb)[0] + [f"call rom_rd{half}"], "l"
            return lines + ["call rom_rd"], "l"
        if kind == "io": return [f"call {self.io_rd(v)}"], "l"
        if kind == "wram_hl": return lines + ["call wram_rd"], "l"
        return lines + ["call mem_rd"], "l"

    def io_rd(self, v):
        """Read handler for I/O address v at the current instruction.

        There is no raster timing, so a sprite-0 polling loop on $2002
        (LDA/AND #$40/BNE|BEQ self, or BIT/BVS|BVC self) gets a handler
        that ends it: waiting for the flag to clear sees it clear, waiting
        for the hit sees the hit.
        """
        h = io_read_handler(v)
        if h != "io_r_2002": return h
        code, a = self.P.code, self.cur
        n, m, _, _ = code[a]
        b = a + n
        if m == "LDA" and code.get(b, (0, None, None, None))[1:] == ("AND", "imm", 0x40):
            b += 2
            clr, hit = "BNE", "BEQ"
        elif m == "BIT":
            clr, hit = "BVS", "BVC"
        else:
            return h
        if b not in code: return h
        _, m2, mode2, arg2 = code[b]
        if mode2 != "rel" or nestrace.branch_target(b, arg2) != a: return h
        return {clr: "io_r_2002_s0clr", hit: "io_r_2002_s0hit"}.get(m2, h)

    def jump(self, t):
        """JMP to NES address t from the current instruction"""
        v = self.mem.at(self.cur, t)
        if v == self.cur and self.unwind: return ["jp spin_wait"]
        if t < 0x2000 and (t & 0x7FF) in self.P.ramcode: return [("JP", self.P.ramcode[t & 0x7FF])]
        if t < 0x2000: return [f"ld hl,{t & 0x7FF}", "jp ram_jump"]      # code built in RAM
        if v is not None: return [("JP", v)]
        return [f"ld hl,{t}", "jp dyn_jump"]     # into the bank mapped now

    # page-1 6502 stack, S in (s6_ptr). Pushes move S first so an NMI
    # arriving mid-sequence never lands on a live byte.
    @staticmethod
    def push_bytes(vals):
        """vals: Z80 operands, pushed in order (first = deepest)."""
        L = ["ld hl,(s6_ptr)"] + ["dec l"] * len(vals) + ["ld (s6_ptr),hl"]
        for v in reversed(vals): L += ["inc l", f"ld (hl),{v}"]
        return L

    @staticmethod
    def pull_a(k=1):
        """Pull k bytes; A = the last one."""
        return ["ld hl,(s6_ptr)"] + ["inc l"] * k + ["ld a,(hl)", "ld (s6_ptr),hl", "ld d,a"]

    def vcap(self):
        if not self.v_used: return []
        return ["push af", "push af", "pop hl", "ld a,l", "and 4", "ld (vflag),a", "pop af"]

    def cmp_fuses(self, a):
        """CMP at a is followed by an N/Z branch (not a jump target) and no
        path after that branch reads N/Z."""
        n = self.P.code[a][0]
        b = a + n
        d = self.P.code.get(b)
        if d is None or d[1] not in ("BEQ", "BNE", "BMI", "BPL") or b in self.entries:
            return False
        if b not in self.succ or len(self.succ[b]) != (1 if b in self.P.nofall else 2):
            return False
        return not any(self.nz_live[t] for t in self.succ[b])

    # -- BIT: which of N / Z do later branches look at? ------------------------
    def bit_needs(self, a):
        need = set()
        n = self.P.code[a][0]
        a += n
        for _ in range(16):
            if a not in self.P.code: break
            n, m, mode, arg = self.P.code[a]
            if m in ("BMI", "BPL"): need.add("N")
            elif m in ("BEQ", "BNE"): need.add("Z")
            if m in NZ_OPS or m in ("JMP", "JSR", "RTS", "RTI"): break
            a += n
        return need

    def ret_lines(self, a, m, d):
        """RTS / RTI at a, reached at stack depth d"""
        if a in self.unwind:
            return ["; leaves the routine the NMI interrupted"] + \
                ((["ld hl,s6_ptr", "inc (hl)", "inc (hl)"]) if self.faithful else []) + ["jp nmi_rts"]
        if m == "RTS" and d == 2:
            # PHA/PHA/RTS: jump to the pushed address + 1
            if a not in self.P.dispatch:
                self.warn.append(f"${a:04X}: RTS dispatch with unknown targets (resolved at run time)")
            return ["jp rts_jump"]
        if m == "RTS" and (d > 0 or d % 2):     # -2k: k return frames dropped
            self.warn.append(f"${a:04X}: RTS at stack depth {d} not supported")
        if m == "RTI" and self.mem.mmc1: return ["jp rti_rt"]
        if m == "RTI": return ["ld hl,s6_ptr", "inc (hl)", "inc (hl)", "inc (hl)", "ret"]
        return (["ld hl,s6_ptr", "inc (hl)", "inc (hl)"] if self.faithful else []) + ["ret"]

    def rts_depth(self, a):
        """Stack depth the RTS at a is translated for: 2 when it dispatches
        (PHA/PHA/RTS), even if a plain return also jumps to it."""
        return 2 if a in self.P.dispatch else self.P.depth.get(a, 0)

    def rts_edge(self, a, t):
        """A branch at a to the RTS at t reaching it at another stack depth
        than the one t is translated for (one RTS shared by a return and a
        PHA/PHA/RTS dispatch): its own return code, else None."""
        d = self.P.depth.get(a)
        if d is None or self.P.code.get(t, (0, ""))[1] != "RTS" or t in self.unwind \
                or self.rts_depth(t) == d:
            return None
        return self.ret_lines(t, "RTS", d)

    # -- one instruction ---------------------------------------------------------
    def insn(self, a):
        """-> (list of lines / pseudo-ops, falls_through)"""
        n, m, mode, arg = self.P.code[a]
        self.cur = a
        L = []
        zs = self.zs
        self.zs = False
        def nz(r="a"):
            if a not in self.nz_dead: L.append(f"ld d,{r}")

        if m in ("LDA", "LDX", "LDY"):
            dst = {"LDA": "a", "LDX": "c", "LDY": "e"}[m]
            lines, kind, v = self.addr(mode, arg)
            if kind == "ram_abs" and dst == "a":
                L += [f"ld a,({v})"]
            else:
                lines, src = self.read(mode, arg)
                L += lines + [f"ld {dst},{src}"]
            nz(dst)
        elif m == "ADC":
            lines, src = self.read(mode, arg)
            L += lines + [f"adc a,{src}"] + self.vcap(); nz(); self.zs = not self.v_used
        elif m == "SBC":
            lines, src = self.read(mode, arg)
            L += lines + ["ccf", f"sbc a,{src}", "ccf"] + self.vcap(); nz(); self.zs = not self.v_used
        elif m in ("AND", "ORA", "EOR"):
            op = {"AND": "and", "ORA": "or", "EOR": "xor"}[m]
            lines, src = self.read(mode, arg)
            if a in self.c_dead:        # carry not read afterwards: no need to keep it
                L += lines + [f"{op} {src}"]; nz()
            else:
                L += lines + ["push af", f"{op} {src}", "ld d,a", "pop af", "ld a,d"]
        elif m in ("CMP", "CPX", "CPY") and self.cmp_fuses(a):
            # only the next branch looks at the result: Z80 flags are enough
            lines, src = self.read(mode, arg)
            if m == "CMP": L += lines + [f"cp {src}"]
            else: L += lines + ["ld d,a", f"ld a,{'c' if m == 'CPX' else 'e'}", f"cp {src}", "ld a,d"]
            if a not in self.c_dead: L.append("ccf")
            self.zs = True
        elif m in ("CMP", "CPX", "CPY"):
            lines, src = self.read(mode, arg)
            reg = {"CMP": None, "CPX": "c", "CPY": "e"}[m]
            L += lines + ["ld d,a"] + ([f"ld a,{reg}"] if reg else []) + \
                 [f"sub {src}", "ccf", "ld l,a", "ld a,d", "ld d,l"]
            self.zs = True
        elif m == "BIT":
            lines, kind, v = self.addr(mode, arg)
            if kind == "ram_abs": L += [f"ld hl,{v}", "ld l,(hl)"]
            elif kind == "io": L += [f"call {self.io_rd(v)}"]
            elif kind == "rom_hl": L += lines + ["call rom_rd"]
            elif kind == "wram_hl": L += lines + ["call wram_rd"]
            else: L += lines + ["call mem_rd"]
            need = self.bit_needs(a)
            if need == {"N", "Z"}:
                self.warn.append(f"${a:04X}: BIT result used for both N and Z; only Z kept")
            inner = []
            if "N" in need and "Z" not in need: L.append("ld d,l")
            else: inner += ["and l", "ld d,a"]
            if self.v_used: inner += ["ld a,l", "and $40", "ld (vflag),a"]
            if inner: L += ["push af"] + inner + ["pop af"]
        elif m in ("STA", "STX", "STY"):
            reg = {"STA": "a", "STX": "c", "STY": "e"}[m]
            lines, kind, v = self.addr(mode, arg)
            if kind == "ram_abs":
                L += [f"ld ({v}),a"] if reg == "a" else [f"ld hl,{v}", f"ld (hl),{reg}"]
            elif kind == "ram_hl": L += lines + [f"ld (hl),{reg}"]
            elif kind == "wram_hl": L += lines + [f"call wram_w{reg}"]
            elif kind == "io": L += [f"ld l,{reg}", f"call {io_write_handler(v)}"]
            elif kind == "rom_hl" and self.mem.mmc1:      # indexed: the base's register
                L += [f"ld h,{arg >> 8}", f"ld l,{reg}", "call m1_wr"]
            elif kind == "rom_hl" and self.mem.mmc3:
                if mode == "abs":
                    h = MMC3_W[(arg >> 12 & 6) | (arg & 1)]
                    L += [f"ld l,{reg}", f"call {h}"] if h else [f"; MMC3 ${arg:04X} ignored"]
                else:
                    L += (["ld (wr_val),a"] if reg == "a" else ["push af", f"ld a,{reg}", "ld (wr_val),a", "pop af"]) \
                         + lines + ["call mapper_wa"]
            elif kind == "rom_hl" and self.mem.ux: L += [f"ld l,{reg}", "call mapper_w"]
            elif kind == "rom_hl": L += [f"; write to ROM ${arg:04X} ignored"]
            elif reg == "a": L += lines + ["call mem_wr_a"]
            else:
                L += ["push af", f"ld a,{reg}", "ld (wr_val),a", "pop af"] + lines + ["call mem_wr_v"]
        elif m in ("INC", "DEC", "ASL", "LSR", "ROL", "ROR"):
            op = {"INC": "inc", "DEC": "dec", "ASL": "sla", "LSR": "srl", "ROL": "rl", "ROR": "rr"}[m]
            if mode == "acc":
                L += ["add a,a" if m == "ASL" else f"{op} a"]; nz()
            else:
                lines, kind, v = self.addr(mode, arg)
                if kind in ("ram_abs", "ram_hl"):
                    L += ([f"ld hl,{v}"] if kind == "ram_abs" else lines) + [f"{op} (hl)"]
                    if a not in self.nz_dead: L.append("ld d,(hl)")
                else:
                    if kind == "io": lines = [f"ld hl,{v}"]
                    L += lines + ["push hl", "call mem_rd", f"{op} l", "ld d,l",
                                  "ld (wr_val),hl", "pop hl", "call mem_wr_v"]
            self.zs = True
        elif m in ("TAX", "TAY", "TXA", "TYA"):
            src, dst = {"TAX": ("a", "c"), "TAY": ("a", "e"), "TXA": ("c", "a"), "TYA": ("e", "a")}[m]
            L += [f"ld {dst},{src}"]; nz(dst)
        elif m in ("INX", "DEX", "INY", "DEY"):
            r = "c" if m[2] == "X" else "e"
            L += [f"{'inc' if m[0] == 'I' else 'dec'} {r}"]; nz(r); self.zs = True
        elif m == "TSX": L += ["ld hl,(s6_ptr)", "ld c,l"]; nz("c")
        elif m == "TXS":
            L += ["ld hl,s6_ptr", "ld (hl),c"]
            if self.P.depth.get(a, 0) != 0 and a not in self.P.txs_restore:
                self.warn.append(f"${a:04X}: TXS inside a routine; Z80 return frames are not moved")
        elif m == "CLC": L += ["scf", "ccf"]
        elif m == "SEC": L += ["scf"]
        elif m == "CLV": L += ["push af", "xor a", "ld (vflag),a", "pop af"]
        elif m in ("CLI", "SEI", "CLD", "SED"):
            L += ["ld hl,p_id", f"{'set' if m[:2] == 'SE' else 'res'} {2 if m[2] == 'I' else 3},(hl)"]
        elif m == "NOP": pass
        elif m == "PHA": L += self.push_bytes(["a"])
        elif m == "PHP": L += ["call php_rt"]
        elif m == "PLP": L += ["call plp_rt"]
        elif m == "PLA":
            d = self.P.depth.get(a, 0)
            if a not in self.engine_body and d <= 0 and a not in self.P.nmi_body:
                nxt = nestrace.nxt(a, 1)
                if self.P.code.get(nxt, (0, ""))[1] == "PLA" and d % 2 == 0:
                    L += ["; PLA/PLA: drop the return frame"]
                    if self.faithful: L += self.pull_a(2)
                    L += ["call drop_frame" if self.multi else "pop hl"]
                    self.skip_next = True
                    return L, True
                if not self.faithful:
                    self.warn.append(f"${a:04X}: PLA pops a return address byte; not supported")
            L += self.pull_a()
        elif mode == "rel":
            t = nestrace.branch_target(a, arg)
            if m in ("BVC", "BVS"):
                L += ["ld hl,vflag", "inc (hl)", "dec (hl)",
                      ("JPCC", "z" if m == "BVC" else "nz", t)]
            else:
                cc = {"BCC": "nc", "BCS": "c", "BEQ": "z", "BNE": "nz", "BMI": "m", "BPL": "p"}[m]
                if cc not in ("c", "nc"):
                    if not zs: L += ["inc d", "dec d"]
                    self.zs = True
                elif zs:
                    self.zs = True
                edge = self.rts_edge(a, t)
                if edge:
                    inv = {"z": "nz", "nz": "z", "c": "nc", "nc": "c", "m": "p", "p": "m"}[cc]
                    L += [f"jp {inv},$+{3 + sum(zsize(x) for x in edge)}"] + edge
                else:
                    L.append(f"jp {cc},spin_wait" if t == a and self.unwind else ("JPCC", cc, t))
        elif m == "JMP":
            if mode == "abs":
                edge = self.rts_edge(a, self.mem.at(a, arg))
                L += edge if edge else self.jump(arg); return L, False
            if arg < 0x2000:
                p = RAMB + (arg & 0x7FF)
                if arg & 0xFF == 0xFF:
                    L += ["ex af,af'", f"ld a,({p})", "ld l,a", f"ld a,({p - 0xFF})", "ld h,a", "ex af,af'"]
                else:
                    L += [f"ld hl,({p})"]
                L += ["jp dyn_jump"]
            elif arg >= 0x8000 and self.mem.at(a, arg) is not None:
                L += self.jump(self.mem.rw(self.mem.at(a, arg)))
            elif 0x6000 <= arg < 0x8000 and self.wram:        # pointer in PRG RAM
                L += [f"ld hl,{arg + 1}", "call wram_rd", "ld b,l", f"ld hl,{arg}", "call wram_rd", "ld h,b", "ld b,0", "jp dyn_jump"]
            else:
                self.warn.append(f"${a:04X}: JMP (${arg:04X}) through I/O space")
                L += ["jp crash"]
            return L, False
        elif m == "JSR":
            ret = (a + 2) & 0xFFFF
            t = self.mem.at(a, arg)
            if t is not None and (t in self.P.engines or t in self.P.inline):
                L += self.push_bytes([ret >> 8, ret & 0xFF]) + [("JP", t)]
                return L, False
            if self.faithful: L += self.push_bytes([ret >> 8, ret & 0xFF])
            # fixed bank into the switchable half: whatever bank is mapped
            if arg < 0x2000 and (arg & 0x7FF) in self.P.ramcode: L += [("CALL", self.P.ramcode[arg & 0x7FF])]
            elif arg < 0x2000: L += [f"ld hl,{arg & 0x7FF}", "call ram_jump"]   # code built in RAM
            else: L += [("CALL", t)] if t is not None else [f"ld hl,{arg}", "call dyn_call"]
        elif m in ("RTS", "RTI"):
            L += self.ret_lines(a, m, self.rts_depth(a) if m == "RTS" else self.P.depth.get(a, 0))
            return L, False
        elif m == "BRK" and self.mem.mmc1:
            # software interrupt: PCH PCL P frame (PC+2), through the IRQ vector. Its RTI (rti_rt)
            # jumps to the PC it pulls: the handler steps it over the data after the BRK.
            ret = (a + 2) & 0xFFFF
            L += self.push_bytes([ret >> 8, ret & 0xFF]) + ["call php_rt", "call brk_mark"]
            t = self.mem.at(a, self.P.vectors["IRQ"])
            L += [("JP", t)] if t is not None else [f"ld hl,{self.P.vectors['IRQ']}", "jp dyn_jump"]
            return L, False
        elif m == "BRK":
            self.warn.append(f"${a:04X}: BRK"); L += ["jp crash"]; return L, False
        else:
            raise RuntimeError(f"unhandled {m}")
        return L, True

    def translate(self):
        """-> list of (addr, lines, falls_through) in address order"""
        out = []
        self.zs = False
        self.skip_next = False
        prev_end = None
        order = sorted(self.P.code)
        after = dict(zip(order, order[1:] + [None]))
        for a in order:
            if self.skip_next:
                self.skip_next = False
                out.append((a, [], True))
                continue
            if a in self.entries or a != prev_end: self.zs = False
            lines, ft = self.insn(a)
            if a in self.polls: lines = ["call idle_poll"] + lines
            elif a in self.poll_exits: lines = ["call idle_end"] + lines
            n = self.P.code[a][0]
            if a in self.P.skips:       # BIT skip trick: continue past its operand
                lines, ft = lines + [("JP", nestrace.nxt(a, n))], False
            elif ft and a not in self.P.nofall and nestrace.nxt(a, n) != after[a]:
                # the next instruction isn't next in address order: into the
                # other 8K slot, or overlapping code (2-byte NOP tricks)
                lines, ft = lines + [("JP", nestrace.nxt(a, n))], False
            out.append((a, lines, ft))
            prev_end = nestrace.nxt(a, self.P.code[a][0])
        return out


# -- sizes / packing -----------------------------------------------------------
REG8 = {"a", "b", "c", "d", "e", "h", "l", "(hl)"}

def zsize(ins):
    if isinstance(ins, tuple):
        return 3
    if ins.startswith(";") or ins.endswith(":"): return 0
    m, _, ops = ins.partition(" ")
    ops = ops.replace(" ", "")
    if m in ("call", "jp"): return 1 if ops == "(hl)" else 3
    if m in ("ret", "ccf", "scf", "ex", "push", "pop", "inc", "dec", "di", "ei", "halt", "nop"): return 1
    if m in ("sla", "srl", "rl", "rr", "bit", "set", "res"): return 2
    if m in ("add", "adc", "sub", "sbc", "and", "or", "xor", "cp"):
        if ops in ("hl,bc", "hl,de", "hl,hl"): return 1
        last = ops.split(",")[-1]
        return 1 if last in REG8 else 2
    if m == "ld":
        dst, src = ops.split(",", 1)
        if dst in ("hl", "bc", "de", "sp"): return 3
        if dst.startswith("(") and dst != "(hl)": return 3
        if src.startswith("(") and src != "(hl)": return 3
        if src in REG8: return 1
        return 2
    raise ValueError(ins)

FAR_JP = 9          # ex af,af' / ld a,n / ld hl,nn / jp far_jump
FAR_CALL = 3 + 9    # call stub / stub: ex af,af' / ld a,n / ld hl,nn / jp far_call

def item_size(it, multi):
    s = sum(zsize(x) for x in it[1])
    if multi:
        s += sum(FAR_CALL if isinstance(x, tuple) and x[0] == "CALL" else
                 FAR_JP + 3 if isinstance(x, tuple) else 0 for x in it[1])
    return s

def pack(items, cap, multi):
    """items: (addr, lines, ft) -> list of banks, each a list of items"""
    banks, cur, size = [], [], 0
    for it in items:
        s = item_size(it, multi)
        if cur and size + s + FAR_JP > cap:
            banks.append(cur); cur, size = [], 0
        cur.append(it); size += s
    if cur: banks.append(cur)
    return banks

CLONE_MAX = 600     # bytes: largest routine copied into a calling bank
CLONE_MAX_HOT = 3000    # ... when the profile measured its calls

def plan_clones(banks, cap, profile=None):
    """bank -> set of addresses of other banks' code to copy into it.

    Each bank gets its own copy of small routines it calls or jumps to in
    another bank (the code a target reaches without following calls), so
    those transfers and their returns don't switch banks. Routines that the
    profile ({(bank, NES target): count}, from `make profile`) measured as
    hot come first, then the smallest with the most call sites, while the
    bank has room.
    """
    profile = profile or {}
    bank_of = {a: i for i, b in enumerate(banks) for a, _, _ in b}
    order = [it for b in banks for it in b]
    idx = {it[0]: i for i, it in enumerate(order)}

    def body(t, limit=CLONE_MAX):
        seen, work, size = set(), [t], 0
        while work:
            a = work.pop()
            if a in seen or a not in idx: continue
            seen.add(a); it = order[idx[a]]
            size += item_size(it, True) + 3
            if size > limit: return None, 0
            work += [x[-1] for x in it[1] if isinstance(x, tuple) and x[0] in ("JP", "JPCC")]
            if it[2] and idx[a] + 1 < len(order): work.append(order[idx[a] + 1][0])
        return seen, size

    used = [sum(item_size(it, True) for it in b) + FAR_JP for b in banks]
    clones = {bi: set() for bi in range(len(banks))}
    # rounds: calls made from copies added in one round are candidates in
    # the next (a copied routine that calls another bank). Measured routines
    # get all their rounds before any unmeasured one is considered.
    for only_hot in ([True] * 6 if profile else []) + [False] * 4:
        calls = {}
        for bi, b in enumerate(banks):
            here = [it[1] for it in b] + [order[idx[a]][1] for a in clones[bi]]
            for lines in here:
                for x in lines:
                    if isinstance(x, tuple) and x[0] in ("CALL", "JP"):
                        t = x[-1]
                        if bank_of.get(t, bi) != bi and t not in clones[bi]:
                            calls[(bi, t)] = calls.get((bi, t), 0) + 1
        cands = []
        for (bi, t), n in calls.items():
            seen, size = body(t, CLONE_MAX_HOT if (bi, t) in profile else CLONE_MAX)
            if not seen: continue
            # measured weight: the edge itself, or a measured edge that only
            # exists from a copy of this routine (its own cross-bank calls)
            inner = [x[-1] for a in seen for x in order[idx[a]][1]
                     if isinstance(x, tuple) and x[0] in ("CALL", "JP")]
            hot = max([profile.get((bi, t), 0)] + [profile.get((bi, u), 0) for u in inner])
            if only_hot and not hot: continue
            cands.append(((-hot / size, size / n), bi, seen))   # calls saved per byte
        added = False
        for _, bi, seen in sorted(cands, key=lambda c: c[0]):
            new = {a for a in seen if bank_of[a] != bi} - clones[bi]
            size = sum(item_size(order[idx[a]], True) + 3 for a in new)
            if new and used[bi] + size <= cap:
                clones[bi] |= new; used[bi] += size; added = True
        if not added and not only_hot: break
    return clones

def emit_banks(banks, multi, cap=None, profile=None):
    bank_of = {a: i for i, b in enumerate(banks) for a, _, _ in b}
    order = [it for b in banks for it in b]
    idx = {it[0]: i for i, it in enumerate(order)}
    clones = plan_clones(banks, cap, profile) if multi and cap else {}
    files, nstub, missing = [], 0, set()
    for bi, items in enumerate(banks):
        out = ["        org $0000", "        jp crash", "        defs $0038 - $, 0",
               "        jp isr", "        defs $0100 - $, 0"]
        stubs = []
        mine = clones.get(bi, set())
        def local(t):
            """label of t in this bank, or None if it lives in another bank"""
            if bank_of.get(t) == bi: return lbl(t)
            if t in mine: return f"c{bi}_{t:04x}"
            return None
        def far(t):
            if t not in bank_of:        # not traced as code: stops at run time
                missing.add(t)
                return [f"ld hl,{t & 0xFFFF}", "jp dyn_jump"]
            return ["ex af,af'", f"ld a,{bank_of[t]}", f"ld hl,{lbl(t)}", "jp far_jump"]
        def emit(label, lines):
            nonlocal nstub, stubs, out
            out.append(f"{label}:")
            for x in lines:
                if isinstance(x, str):
                    out.append("        " + x)
                    continue
                kind, *rest = x
                if kind == "JP":
                    t = rest[0]
                    if local(t): out.append(f"        jp {local(t)}")
                    else: out += ["        " + y for y in far(t)]
                elif kind == "JPCC":
                    cc, t = rest
                    if local(t): out.append(f"        jp {cc},{local(t)}")
                    else:
                        nstub += 1
                        out.append(f"        jp {cc},stub_{nstub}")
                        stubs += [f"stub_{nstub}:"] + ["        " + y for y in far(t)]
                elif kind == "CALL":
                    t = rest[0]
                    if t not in bank_of:
                        missing.add(t)
                        out += [f"        ld hl,{t & 0xFFFF}", "        call dyn_call"]
                    elif not multi:
                        out.append(f"        call {lbl(t)}")
                    elif local(t):
                        out.append(f"        call {local(t)}")
                    else:
                        nstub += 1
                        out.append(f"        call stub_{nstub}")
                        stubs += [f"stub_{nstub}:"] + ["        " + y for y in far(t)[:-1]] + ["        jp far_call"]
        for k, (a, lines, ft) in enumerate(items):
            emit(lbl(a), lines)
            # fall-through into the next bank
            if k == len(items) - 1 and ft and bi + 1 < len(banks):
                nxt = banks[bi + 1][0][0]
                out += ["        " + y for y in (["jp " + local(nxt)] if local(nxt) else far(nxt))]
        # copies of other banks' routines; fall-through becomes a jump
        for a in sorted(mine):
            _, lines, ft = order[idx[a]]
            emit(f"c{bi}_{a:04x}", lines)
            if ft:
                nxt = order[idx[a] + 1][0]
                out += ["        " + y for y in (["jp " + local(nxt)] if local(nxt) else far(nxt))]
        out += stubs
        out.append("        defs $8000 - $, $ff")
        files.append("\n".join(out) + "\n")
    return files, bank_of, sorted(missing)


# -- graphics / tables -----------------------------------------------------------
def nes_palette():
    lo = [-0.12, 0.00, 0.31, 0.72]
    hi = [0.40, 0.68, 1.00, 1.00]
    out = []
    for n in range(64):
        hue, lvl = n & 15, n >> 4
        if hue >= 14: out.append((0, 0, 0)); continue
        l, h = lo[lvl], hi[lvl]
        if hue == 0: l = h
        if hue == 13: h = l
        y, sat = (l + h) / 2, (h - l) / 2 if hue not in (0, 13) else 0
        ang = math.radians(193 - hue * 30)
        i, q = sat * math.cos(ang), sat * math.sin(ang)
        rgb = (y + 0.956 * i + 0.621 * q, y - 0.272 * i - 0.647 * q, y - 1.106 * i + 1.703 * q)
        out.append(tuple(max(0, min(31, round(c * 31))) for c in rgb))
    return out

def tile_rows(chr_, t):
    off = t * 16
    if off + 16 > len(chr_):
        return [[0] * 8 for _ in range(8)]
    b = chr_[off: off + 16]
    return [[((b[y] >> (7 - x)) & 1) | (((b[y + 8] >> (7 - x)) & 1) << 1) for x in range(8)]
            for y in range(8)]

def bg_vram(chr_):
    """64K: pattern P = table*1024 + pal*256 + tile, V9990 P1 layout."""
    v = bytearray(0x10000)
    for t in range(2):
        for tile in range(256):
            rows = tile_rows(chr_, t * 256 + tile)
            for p in range(4):
                P = t * 1024 + p * 256 + tile
                base = (P // 32) * 1024 + (P % 32) * 4
                for y, r in enumerate(rows):
                    px = [(p * 4 + c) if c else 0 for c in r]
                    for k in range(4):
                        v[base + y * 128 + k] = px[2 * k] << 4 | px[2 * k + 1]
    return bytes(v)

def spr_src(chr_):
    """32K: tile T (0-511), hflip h -> 8 rows x 4 bytes of raw 2-bit pixels."""
    v = bytearray(0x8000)
    for T in range(512):
        rows = tile_rows(chr_, T)
        for h in range(2):
            for y, r in enumerate(rows):
                px = r[::-1] if h else r
                for k in range(4):
                    v[(T * 2 + h) * 32 + y * 4 + k] = px[2 * k] << 4 | px[2 * k + 1]
    return bytes(v)

def read_png(path):
    """Indexed-colour PNG -> (width, height, rows of palette indices, [(r, g, b)])."""
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n": sys.exit(f"{path}: not a PNG file")
    p, idat, pal = 8, b"", []
    while p < len(d):
        n, t = int.from_bytes(d[p:p + 4], "big"), d[p + 4:p + 8]
        c = d[p + 8:p + 8 + n]
        if t == b"IHDR": w, h, depth, ctype, _, _, lace = c[:4], c[4:8], c[8], c[9], c[10], c[11], c[12]
        elif t == b"PLTE": pal = [tuple(c[i:i + 3]) for i in range(0, n, 3)]
        elif t == b"IDAT": idat += c
        p += 12 + n
    w, h = int.from_bytes(w, "big"), int.from_bytes(h, "big")
    if ctype != 3 or lace: sys.exit(f"{path}: must be an indexed-colour, non-interlaced PNG")
    import zlib
    raw, stride, bpp = zlib.decompress(idat), (w * depth + 7) // 8, max(1, depth // 8)
    rows, prev, k = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[k], bytearray(raw[k + 1:k + 1 + stride]); k += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, cc = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - cc), abs(a - cc), abs(a + b - 2 * cc)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else cc)) & 255
        prev = line
        rows.append([(line[x * depth // 8] >> (8 - depth - x * depth % 8)) & ((1 << depth) - 1) for x in range(w)])
    return w, h, rows, pal

def splash_bin(path):
    """32K, two ROM banks: the boot picture for V9990 B1 mode (256 wide, 4 bpp).
    $0000: 212 lines x 128 bytes, the picture centred on colour 0;
    $6A00: 16 palette entries, 5-bit R, G, B."""
    w, h, rows, pal = read_png(path)
    if w != 256 or h > 212 or len(pal) > 16 or max(map(max, rows)) > 15:
        sys.exit(f"{path}: the boot picture must be 256 pixels wide, at most 212 high, 16 colours")
    top, bg = (212 - h) // 2, 0
    rows = [[bg] * 256] * top + rows + [[bg] * 256] * (212 - h - top)
    v = bytearray(r[x] << 4 | r[x + 1] for r in rows for x in range(0, 256, 2))
    pal = (pal + [(0, 0, 0)] * 16)[:16]
    v += bytes(c >> 3 for rgb in pal for c in rgb)
    return bytes(v) + b"\xff" * (0x8000 - len(v))

def db_lines(data, per=16):
    return ["        db " + ",".join(str(x) for x in data[i:i + per]) for i in range(0, len(data), per)]


def read_profile(path):
    """profile.txt from tools/profile.py: 'count bank target' per line."""
    prof = {}
    if path and os.path.exists(path):
        for line in open(path):
            f = line.split()
            if len(f) == 3 and not line.startswith("#"):
                prof[(int(f[1]), int(f[2], 16))] = int(f[0])
    return prof

def read_entries(path, mem):
    """entries.txt: 'bank address' per line (hex; bank '-' outside the
    switchable half, MMC3: the 8K bank), computed-jump targets seen only at
    run time. Written
    by make run / make discover when a lookup misses."""
    out = []
    if path and os.path.exists(path):
        for line in open(path):
            f = line.split()
            if len(f) != 2 or line.startswith("#"): continue
            a = int(f[1], 16)
            if mem.slot(a) is not None:
                if f[0] == "-": continue
                a = mem.banked(a, int(f[0], 16))
            out.append(a)
    return out

def build(rom_path, out_dir, crop, bank_kb, pad_kb=0, splash=None):
    rom = open(rom_path, "rb").read()
    if rom[:4] != b"NES\x1a": sys.exit("not an iNES file")
    mapper = (rom[6] >> 4) | (rom[7] & 0xF0)
    kind = {0: "nrom", 1: "mmc1", 2: "uxrom", 4: "mmc3"}.get(mapper)
    if kind is None: sys.exit(f"mapper {mapper} not supported (NROM, UxROM, MMC1 and MMC3 only)")
    ux, mmc3 = kind != "nrom", kind == "mmc3"
    prg_n, chr_n = rom[4], rom[5]
    if kind != "mmc3" and chr_n > 1: sys.exit("multiple CHR banks not supported")
    if kind == "mmc1" and prg_n > 16: sys.exit("MMC1 with more than 256K PRG (SUROM) not supported")
    if ux and (prg_n < 2 or prg_n & (prg_n - 1)): sys.exit(f"{kind} with {prg_n} PRG banks not supported")
    if not ux and prg_n not in (1, 2): sys.exit(f"NROM with {prg_n} PRG banks")
    if chr_n & (chr_n - 1): sys.exit(f"{chr_n} CHR banks not supported")
    chr_ram = chr_n == 0
    mmc3_chr = mmc3 and not chr_ram         # CHR ROM switched in 1K / 2K pieces
    trainer = 512 if rom[6] & 4 else 0
    prg_off = 16 + trainer
    prg = rom[prg_off: prg_off + prg_n * 0x4000]
    chr_off = prg_off + prg_n * 0x4000
    chr_rom = rom[chr_off: chr_off + chr_n * 0x2000]
    chr_ = bytes(0x2000) if chr_ram or mmc3_chr else chr_rom[:0x2000]
    if len(chr_) < 0x2000:
        chr_ = chr_ + bytes(0x2000 - len(chr_))
        print(f"warning: CHR data is only {len(chr_)} bytes; padded with zeros", file=sys.stderr)
    mirror_v = rom[6] & 1
    # PRG RAM at $6000-$7FFF: NES 2.0 gives its size; otherwise 8K on
    # MMC1 / MMC3 boards and with a battery. MMC1 (SOROM / SXROM) selects
    # 8K banks with CHR register 0 bits 3 / 3-2.
    if rom[7] & 0x0C == 0x08:
        wram = sum(64 << n for n in (rom[10] & 15, rom[10] >> 4) if n)
    else:
        wram = 0x2000 if kind in ("mmc1", "mmc3") or rom[6] & 2 else 0
    wram_banks = min(4 if kind == "mmc1" else 1, max(1, wram // 0x2000)) if wram else 0

    extra = read_entries(os.path.join(out_dir, "entries.txt"), nestrace.Mem(prg, kind))
    P = nestrace.trace(prg, kind, extra)
    cap = bank_kb * 1024 - 0x100
    items = None
    for multi in ((True,) if bank_kb < 32 or ux else (False, True)):
        T = Translator(P, multi, wram_banks > 0)
        items = T.translate()
        # multi-bank: leave room in each bank for copies of hot routines
        banks = pack(items, cap - cap // 10 if multi else 0x7F00, multi)
        if len(banks) == 1 or multi: break
    profile = read_profile(os.path.join(out_dir, "profile.txt"))
    files, bank_of, missing = emit_banks(banks, multi, cap, profile)
    T.warn += [f"jump to ${t:04X}, which was not traced as code (stops there at run time)" for t in missing]

    # logical segments: code banks (2 each), then data
    segs = []
    for i in range(len(banks)): segs += [f"bank{i}:lo", f"bank{i}:hi"]
    def add(name): segs.append(name); return SEG_BASE + len(segs) - 1
    # PRG: one segment per 16K bank; DSEG_PRG1 is the one at $C000
    d_prg0 = add("prg0")
    for i in range(1, prg_n): add(f"prg{i}")
    d_prg1 = d_prg0 + prg_n - 1
    d_spr0 = add("spr0"); add("spr1")
    d_misc = add("misc")
    for i in range((pad_kb + 15) // 16): add("pad")     # testing: more RAM
    d_wram = 0
    for i in range((wram_banks + 1) // 2):
        k = add("wram")
        d_wram = d_wram or k
    # computed-jump lookup (runtime dyn_find): every address a computed
    # jump, a call or a fixed-bank jump into the switchable half can reach
    nmi, reset = P.vectors["NMI"], P.vectors["RESET"]
    dyn = {t for tg in P.tables.values() for t in tg} | {t for tg in P.dispatch.values() for t in tg} \
        | set(P.calls) | {nmi, reset} | P.extra | P.pushed | set(P.inline_cont.values())
    for site, bk in P.xbank.items():
        dyn |= {P.mem.banked(P.code[site][3], b) for b in bk or ()}
    dyn = [t for t in dyn if t in bank_of]
    key = lambda a: (a & 0xFF, (a >> 8) & 0xFF, max(0, P.mem.bank(a)) if a & 0xFFFF >= 0x8000 else 0)
    dyn.sort(key=key)
    dyn_size = 2 * 257 + 5 * len(dyn)
    d_dyn, dyn_org = (d_misc, 0xA000) if dyn_size <= 0x2000 else (add("dyn"), 0x8000)
    if dyn_size > 0x4000: sys.exit(f"{len(dyn)} computed-jump targets: lookup table too large")
    nsegs = len(segs)               # copied into mapper RAM at boot
    # MMC3 CHR ROM: only in the cartridge (ROM bank = segment - SEG_BASE + 1),
    # read from there when banks switch
    chr_bank0 = 1 + nsegs
    for i in range(len(chr_rom) // 0x4000 if mmc3_chr else 0): segs.append(f"chr{i}")
    bg_bank = 1 + len(segs)
    ram_k = (SEG_BASE + nsegs) * 16
    if SEG_BASE + nsegs > 255:
        sys.exit(f"needs {ram_k}K of mapper RAM; at most 4080K is supported")

    os.makedirs(out_dir, exist_ok=True)
    w = lambda name, data: open(os.path.join(out_dir, name), "wb" if isinstance(data, bytes) else "w").write(data)
    for i in range(prg_n): w(f"prg{i}.bin", prg[i * 0x4000: (i + 1) * 0x4000])
    sp = spr_src(chr_)
    w("spr0.bin", sp[:0x4000]); w("spr1.bin", sp[0x4000:])
    w("chr.bin", chr_)
    for i in range(len(chr_rom) // 0x4000 if mmc3_chr else 0): w(f"chr{i}.bin", chr_rom[i * 0x4000: (i + 1) * 0x4000])
    w("bg.bin", bg_vram(chr_))
    if splash: w("splash.bin", splash_bin(splash))
    for i, f in enumerate(files): w(f"bank{i}.asm", f)

    # sorted by low byte; dyn_bkt[b] = first entry with low byte >= b.
    # Entry: high byte, switchable bank (0 outside $8000-$BFFF), Z80
    # address, code bank.
    firsts, k = [], 0
    for bkt in range(257):
        while k < len(dyn) and dyn[k] & 0xFF < bkt: k += 1
        firsts.append(k)
    t = ["; generated by nes2msxtr.py: computed-jump lookup", f"        org ${dyn_org:04X}", "dyn_bkt:"]
    t += [f"        dw dyn_tab + {5 * f}" for f in firsts]
    t += ["dyn_tab:"]
    t += [f"        db {key(a)[1]}, {key(a)[2]}\n        dw {lbl(a)}\n        db {bank_of[a]}" for a in dyn]
    t += [f"        defs ${dyn_org + 0x2000 if d_dyn == d_misc else 0xC000:04X} - $, $ff"]
    w("dyn.asm", "\n".join(t) + "\n")

    if reset not in bank_of:
        sys.exit(f"RESET vector ${reset:04X} was not traced as code — the ROM may be corrupt or use an unsupported feature")
    if nmi not in bank_of:
        sys.exit(f"NMI vector ${nmi:04X} was not traced as code — the ROM may be corrupt or use an unsupported feature")
    w("config.asm", "\n".join([
        f"CROP: equ {crop}", f"MIRROR_V: equ {mirror_v}", f"SEG_BASE: equ {SEG_BASE}",
        f"NSEGS: equ {nsegs}", f"BG_BANK: equ {bg_bank}", f"DSEG_PRG0: equ {d_prg0}",
        f"DSEG_PRG1: equ {d_prg1}", f"DSEG_SPR0: equ {d_spr0}", f"DSEG_MISC: equ {d_misc}",
        f"DSEG_DYN: equ {d_dyn}", f"UXROM: equ {int(kind == 'uxrom')}", f"MMC3: equ {int(mmc3)}",
        f"MMC1: equ {int(kind == 'mmc1')}", f"WRAM: equ {int(wram_banks > 0)}",
        f"DSEG_WRAM: equ {d_wram}", f"WRAM_MASK: equ {max(1, wram_banks) - 1}",
        f"WRAM_SHIFT: equ {3 if wram_banks == 2 else 2}",
        f"PRG_MASK: equ {len(prg) // P.mem.unit - 1}",
        f"CHR_RAM: equ {int(chr_ram)}", f"MMC3_CHR: equ {int(mmc3_chr)}",
        f"CHR_SHADOW: equ {int(chr_ram or mmc3_chr)}", f"CHR_BANK0: equ {chr_bank0}",
        f"CHR_MASK: equ {max(1, len(chr_rom) // 0x400) - 1}", f"FAITHFUL: equ {int(T.faithful)}",
        f"RAM_SEGS: equ {SEG_BASE + nsegs}", f"DEFER_DMA: equ {int(bool(T.polls))}",
        f"RESET_BANK: equ {bank_of[reset]}", f"SPLASH: equ {int(bool(splash))}",
        f"SPLASH_BANK: equ {bg_bank + 4}", ""]))

    # page-3 tables
    pal = nes_palette()
    s0 = []
    for T_ in range(512):
        rows = tile_rows(chr_, T_)
        s0.append(next((y for y, r in enumerate(rows) if any(r)), 0))
    lut = []
    for p in range(4):
        for b in range(256):
            hi_, lo_ = b >> 4, b & 15
            f = lambda v: ((p * 4 + (v & 3)) & 15) if v else 0
            lut.append(f(hi_) << 4 | f(lo_))
    t = ["; generated by nes2msxtr.py", "go_reset:", f"        jp {lbl(reset)}"]
    irq = P.vectors["IRQ"] if mmc3 and P.vectors["IRQ"] in bank_of else None
    for name, v in (("call_nmi", nmi), ("call_irq", irq)):
        if v is None: t += [f"{name}:", "        ret"]
        elif multi:
            # a cross-bank call; keeps the interrupted A/F/DE for the handler
            t += [f"{name}:", "        ex af,af'", f"        ld a,{bank_of[v]}", f"        ld hl,{lbl(v)}",
                  "        jp far_call"]
        else:
            t += [f"{name}:", f"        jp {lbl(v)}"]
    t += ["lentab:"] + db_lines([10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
                                 12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30])
    t += ["voltab:"] + db_lines([0, 7, 9, 10, 11, 11, 12, 12, 13, 13, 14, 14, 14, 15, 15, 15])
    t += ["noisetab:"] + db_lines([1, 1, 1, 2, 4, 6, 8, 10, 13, 16, 24, 31, 31, 31, 31, 31])
    t += ["nes_rgb:"] + db_lines([c for rgb in pal for c in rgb], 15)
    t += ["msg_no_ram:", f'        db "This cartridge needs {ram_k}K of", 13, 10',
          '        db "RAM in one memory mapper.", 13, 10, 0']
    t += ["s0row:"] + db_lines(s0)
    t += ["spr_lut_src:"] + db_lines(lut)
    w("tables.asm", "\n".join(t) + "\n")

    main = [f'        include "config.asm"', f'        include "{RUNTIME}/defs.asm"',
            "        org $4000", f'        include "{RUNTIME}/boot.asm"', "blob_src:",
            "        org RUNTIME", "blob_start:"]
    main += [f'        include "{RUNTIME}/{f}"' for f in ("core.asm", "ppu.asm", "apu.asm", "input.asm")]
    main += ['        include "tables.asm"', "blob_end:",
             "        org blob_src + (blob_end - blob_start)", "        defs $8000 - $, $ff"]
    main += [f'        include "bank{i}.asm"' for i in range(len(banks))]
    for s in segs[2 * len(banks):]:
        if s == "misc":
            main += ['        org $8000', '        incbin "chr.bin"']
            main += ['        include "dyn.asm"' if d_dyn == d_misc else '        defs $C000 - $, $ff']
        elif s == "dyn": main.append('        include "dyn.asm"')
        elif s == "pad": main.append('        defs $4000, $ff')
        elif s == "wram": main.append('        defs $4000, 0')
        else: main.append(f'        incbin "{s}.bin"')
    main.append('        incbin "bg.bin"')
    if splash: main.append('        incbin "splash.bin"')
    w("main.asm", "\n".join(main) + "\n")

    r = subprocess.run(["z80asm", "-o", "game.rom", "--label=game.lbl", "main.asm"],
                       cwd=out_dir, capture_output=True, text=True)
    if r.returncode != 0 or r.stderr.strip():
        sys.exit("z80asm failed:\n" + r.stderr)
    data = bytearray(open(os.path.join(out_dir, "game.rom"), "rb").read())
    size = 1 << max(17, (len(data) - 1).bit_length())
    data += b"\xff" * (size - len(data))
    labels = dict(l.split(":\tequ ") for l in open(os.path.join(out_dir, "game.lbl")).read().splitlines() if ":\tequ " in l)
    blob_end = int(labels["blob_end"].lstrip("$"), 16)
    if blob_end > 0xFB00:
        sys.exit(f"runtime blob ends at ${blob_end:04X}, past $FB00 (sprite cache)")
    name = os.path.splitext(os.path.basename(rom_path))[0] + ".rom"
    open(os.path.join(out_dir, name), "wb").write(data)
    os.remove(os.path.join(out_dir, "game.rom"))

    T.warn = sorted(set(T.warn))
    if getattr(P, "mode1", None):
        T.warn.append("MMC3 PRG mode 1 ($8000 bit 6) selected at " + ", ".join(f"${a:04X}" for a in sorted(P.mode1))
                      + "; only mode 0 is supported")
    if getattr(P, "m1mode", None):
        T.warn.append("MMC1 PRG mode other than 3 selected at " + ", ".join(f"${a:04X}" for a in sorted(P.m1mode))
                      + "; only mode 3 (16K at $8000, last bank fixed) is supported")
    report = [f"input: {rom_path}", f"{ {'nrom': 'NROM', 'uxrom': 'UxROM', 'mmc1': 'MMC1', 'mmc3': 'MMC3'}[kind]}, PRG {len(prg) // 1024}K, "
              f"{'CHR RAM' if chr_ram else f'CHR ROM {len(chr_rom) // 1024}K'}, mirroring {'vertical' if mirror_v else 'horizontal'}"
              + (f", PRG RAM {wram_banks * 8}K" if wram_banks else ""),
              f"6502 instructions: {len(P.code)}, jump tables: {len(P.tables)}, dispatchers: {len(P.engines)}, "
              f"computed-jump sites: {len(P.dispatch)}, lookup entries: {len(dyn)}",
              f"stack: {'faithful (TSX used: JSR return addresses kept in page 1)' if T.faithful else 'data only in page 1'}",
              f"code banks: {len(banks)} ({'multi-bank' if multi else 'single bank'})"
              + (f", hot copies from profile.txt ({len(profile)} edges)" if multi and profile else ""),
              f"entry points from entries.txt: {len(P.extra)}",
              f"mapper segments used: {SEG_BASE}..{SEG_BASE + nsegs - 1} ({ram_k}K RAM needed"
              + (", more than the turboR's 512K: runs from a RAM expansion (memory mapper)" if ram_k > 512 else "") + ")",
              f"runtime blob: ${0xD700:04X}-${blob_end:04X}", f"cartridge: {name}, {size // 1024}K ASCII16",
              f"warnings ({len(T.warn)}):"] + ["  " + x for x in T.warn]
    w("report.txt", "\n".join(report) + "\n")
    print("\n".join(report))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("out")
    ap.add_argument("--crop", type=int, default=16, help="NES lines hidden at the top (212 of 240 shown)")
    ap.add_argument("--bank-kb", type=int, default=32, help="code bank size (forces multi-bank when small)")
    ap.add_argument("--pad-kb", type=int, default=0, help="unused RAM to add (testing RAM expansions)")
    ap.add_argument("--splash", default=os.path.join(os.path.dirname(HERE), "assets", "0-nes-to-msx-turbor.png"),
                    help="picture shown for 3 s at boot (256 wide, up to 212 high, 16-colour PNG; '' for none)")
    a = ap.parse_args()
    build(a.rom, a.out, a.crop, a.bank_kb, a.pad_kb, a.splash)
