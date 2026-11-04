"""Recursive-descent 6502 tracer for NROM, UxROM, MMC1 and MMC3 images.

Addresses: NROM code has plain 16-bit addresses. On UxROM, MMC1 (PRG mode
3, banked like UxROM) and MMC3 the
fixed last 16K ($C000-$FFFF) keeps plain addresses too, and code in the
switchable half is at the banked address (bank + 1) << 16 | addr (see
Mem), so the same NES address traced in two banks is two different
instructions. The switchable half is one 16K slot on UxROM and two 8K
slots ($8000, $A000: R6, R7) on MMC3, which stays in PRG mode 0. Calls
into a slot whose bank the caller doesn't fix are traced in every bank
the bank analysis (_bank_flow) finds mapped there at that call.

trace(prg, kind, extra) -> Program with (extra: more entry points, e.g.
targets of computed jumps that were only seen at run time):
  code      addr -> (len, mnemonic, mode, operand)
  labels    set of addresses that need a label (branch/jump/call targets)
  calls     JSR targets
  engines   dispatcher routines (pop return address, JMP (ind) through the
            inline .word table that follows each JSR to them)
  inline    routines that pop their return address, read the zero-terminated
            data that follows each JSR to them and JMP (ptr) past it
  inline_cont  JSR site -> where such a call continues (after the data)
  tables    JSR-site -> [case addresses]
  pushed    return addresses (+ 1) pushed by hand with LDA #imm / PHA
  dispatch  site -> [targets] for computed jumps found by pattern:
            PHA/PHA/RTS through address tables (RTS-trick) and JMP (ptr)
            after the pointer was loaded from a table
  depth     addr -> stack depth (bytes) relative to the current return frame
  xbank     site -> banks mapped in the slot it calls or jumps into, when
            that isn't its own (None: not known)
  nmi_body  code of the NMI handler itself (not the routines it calls)
  mem       the Mem of the image
  warnings  list of strings
"""

MODES = {"imp": 1, "acc": 1, "imm": 2, "zp": 2, "zpx": 2, "zpy": 2, "izx": 2, "izy": 2,
         "rel": 2, "abs": 3, "abx": 3, "aby": 3, "ind": 3}
OPS = {}
for _m, _codes in {
 "ADC": [(0x69, "imm"), (0x65, "zp"), (0x75, "zpx"), (0x6D, "abs"), (0x7D, "abx"), (0x79, "aby"), (0x61, "izx"), (0x71, "izy")],
 "AND": [(0x29, "imm"), (0x25, "zp"), (0x35, "zpx"), (0x2D, "abs"), (0x3D, "abx"), (0x39, "aby"), (0x21, "izx"), (0x31, "izy")],
 "ASL": [(0x0A, "acc"), (0x06, "zp"), (0x16, "zpx"), (0x0E, "abs"), (0x1E, "abx")],
 "BIT": [(0x24, "zp"), (0x2C, "abs")],
 "BPL": [(0x10, "rel")], "BMI": [(0x30, "rel")], "BVC": [(0x50, "rel")], "BVS": [(0x70, "rel")],
 "BCC": [(0x90, "rel")], "BCS": [(0xB0, "rel")], "BNE": [(0xD0, "rel")], "BEQ": [(0xF0, "rel")],
 "BRK": [(0x00, "imp")],
 "CMP": [(0xC9, "imm"), (0xC5, "zp"), (0xD5, "zpx"), (0xCD, "abs"), (0xDD, "abx"), (0xD9, "aby"), (0xC1, "izx"), (0xD1, "izy")],
 "CPX": [(0xE0, "imm"), (0xE4, "zp"), (0xEC, "abs")], "CPY": [(0xC0, "imm"), (0xC4, "zp"), (0xCC, "abs")],
 "DEC": [(0xC6, "zp"), (0xD6, "zpx"), (0xCE, "abs"), (0xDE, "abx")],
 "EOR": [(0x49, "imm"), (0x45, "zp"), (0x55, "zpx"), (0x4D, "abs"), (0x5D, "abx"), (0x59, "aby"), (0x41, "izx"), (0x51, "izy")],
 "CLC": [(0x18, "imp")], "SEC": [(0x38, "imp")], "CLI": [(0x58, "imp")], "SEI": [(0x78, "imp")],
 "CLV": [(0xB8, "imp")], "CLD": [(0xD8, "imp")], "SED": [(0xF8, "imp")],
 "INC": [(0xE6, "zp"), (0xF6, "zpx"), (0xEE, "abs"), (0xFE, "abx")],
 "JMP": [(0x4C, "abs"), (0x6C, "ind")], "JSR": [(0x20, "abs")],
 "LDA": [(0xA9, "imm"), (0xA5, "zp"), (0xB5, "zpx"), (0xAD, "abs"), (0xBD, "abx"), (0xB9, "aby"), (0xA1, "izx"), (0xB1, "izy")],
 "LDX": [(0xA2, "imm"), (0xA6, "zp"), (0xB6, "zpy"), (0xAE, "abs"), (0xBE, "aby")],
 "LDY": [(0xA0, "imm"), (0xA4, "zp"), (0xB4, "zpx"), (0xAC, "abs"), (0xBC, "abx")],
 "LSR": [(0x4A, "acc"), (0x46, "zp"), (0x56, "zpx"), (0x4E, "abs"), (0x5E, "abx")],
 "NOP": [(0xEA, "imp")],
 "ORA": [(0x09, "imm"), (0x05, "zp"), (0x15, "zpx"), (0x0D, "abs"), (0x1D, "abx"), (0x19, "aby"), (0x01, "izx"), (0x11, "izy")],
 "TAX": [(0xAA, "imp")], "TXA": [(0x8A, "imp")], "DEX": [(0xCA, "imp")], "INX": [(0xE8, "imp")],
 "TAY": [(0xA8, "imp")], "TYA": [(0x98, "imp")], "DEY": [(0x88, "imp")], "INY": [(0xC8, "imp")],
 "ROL": [(0x2A, "acc"), (0x26, "zp"), (0x36, "zpx"), (0x2E, "abs"), (0x3E, "abx")],
 "ROR": [(0x6A, "acc"), (0x66, "zp"), (0x76, "zpx"), (0x6E, "abs"), (0x7E, "abx")],
 "RTI": [(0x40, "imp")], "RTS": [(0x60, "imp")],
 "SBC": [(0xE9, "imm"), (0xE5, "zp"), (0xF5, "zpx"), (0xED, "abs"), (0xFD, "abx"), (0xF9, "aby"), (0xE1, "izx"), (0xF1, "izy")],
 "STA": [(0x85, "zp"), (0x95, "zpx"), (0x8D, "abs"), (0x9D, "abx"), (0x99, "aby"), (0x81, "izx"), (0x91, "izy")],
 "TXS": [(0x9A, "imp")], "TSX": [(0xBA, "imp")], "PHA": [(0x48, "imp")], "PLA": [(0x68, "imp")],
 "PHP": [(0x08, "imp")], "PLP": [(0x28, "imp")],
 "STX": [(0x86, "zp"), (0x96, "zpy"), (0x8E, "abs")], "STY": [(0x84, "zp"), (0x94, "zpx"), (0x8C, "abs")],
}.items():
    for _c, _mode in _codes:
        OPS[_c] = (_m, _mode)
# unofficial: 2-byte NOPs (used to skip the next byte, like the BIT trick)
# and the SBC #imm duplicate. Only decoded where a branch jumps over just
# their opcode byte, or right after another of them, so data doesn't turn
# into code
UNOFFICIAL = (0x80, 0x82, 0x89, 0xC2, 0xE2, 0xEB)
for _c in UNOFFICIAL[:-1]: OPS[_c] = ("NOP", "imm")
OPS[0xEB] = ("SBC", "imm")
SKIPS = ("BIT", "NOP")      # may hide the next instruction in their operand

ENDS_FLOW = ("RTS", "RTI", "BRK", "JMP")
OPPOSITE = {"BCC": "BCS", "BCS": "BCC", "BEQ": "BNE", "BNE": "BEQ",
            "BPL": "BMI", "BMI": "BPL", "BVC": "BVS", "BVS": "BVC"}


class Program:
    pass


_SLOT = 0x4000      # switchable slot size: 16K (UxROM) or 8K (MMC3); set by trace()
WTAG = 0x100        # bank tag of code in PRG RAM: WTAG << 16 | address


def canon(a):
    """A banked address that ran past $BFFF is in the fixed bank."""
    return a & 0xFFFF if (a & 0xFFFF) >= 0xC000 else a


def nxt(a, n):
    """Address n bytes after instruction a. Banked code running from the
    $8000 slot into the $A000 one (MMC3) is assumed to continue in the
    next 8K bank, as with banks mapped in pairs."""
    t = canon(a + n)
    if t >> 16 and (t & 0xFFFF) // _SLOT != (a & 0xFFFF) // _SLOT:
        t += 0x10000
    return t


def branch_target(a, arg):
    t = canon((a & ~0xFFFF) | ((a + 2 + (arg - 256 if arg > 127 else arg)) & 0xFFFF))
    if t >> 16 and (t & 0xFFFF) // _SLOT != (a & 0xFFFF) // _SLOT:
        t += 0x10000 if t & 0xFFFF > a & 0xFFFF else -0x10000
    return t


class Mem:
    """The PRG image as seen through NROM, UxROM (16K banks, the last one
    fixed at $C000; MMC1 too) or MMC3 (8K banks in two slots, the last 16K
    fixed). kind: "nrom", "uxrom", "mmc1" or "mmc3"."""
    def __init__(self, prg, kind):
        self.prg, self.kind = prg, kind
        self.ux = kind != "nrom"        # has a switchable half
        self.mmc3 = kind == "mmc3"
        self.mmc1 = kind == "mmc1"
        self.unit = 0x2000 if self.mmc3 else 0x4000
        self.nslots = 2 if self.mmc3 else 1
        self.nbanks = len(prg) // self.unit
        # code the game copies from PRG into PRG RAM and runs there:
        # (RAM address, PRG address it came from, length)
        self.wram_code = None

    def slot(self, t):
        """switchable slot of 16-bit address t, or None"""
        if not self.ux or not 0x8000 <= t < 0xC000: return None
        return (t - 0x8000) // self.unit

    def off(self, a):
        """address -> offset in prg, or None outside ROM / a plain
        switchable-half address (bank unknown)."""
        n = a & 0xFFFF
        if a >> 16 == WTAG and self.wram_code:
            dst, src, ln = self.wram_code
            return self.off(src + n - dst) if dst <= n < dst + ln else None
        if n < 0x8000: return None
        if not self.ux: return (n - 0x8000) & (len(self.prg) - 1)
        if n >= 0xC000: return len(self.prg) - 0x10000 + n
        b = (a >> 16) - 1
        return None if b < 0 else b * self.unit + (n & (self.unit - 1))

    def inrom(self, a): return self.off(a) is not None
    def rd(self, a): return self.prg[self.off(a)]
    def rw(self, a): return self.rd(a) | self.rd(canon(a + 1)) << 8

    def at(self, site, t):
        """16-bit address t as code at site sees it, or None when it is in
        a switchable slot other than site's own."""
        if self.wram_code and 0x6000 <= t < 0x8000: return WTAG << 16 | t
        sl = self.slot(t)
        if sl is None: return t
        return (site & ~0xFFFF) | t if site >> 16 and self.slot(site & 0xFFFF) == sl else None

    @staticmethod
    def bank(a): return (a >> 16) - 1       # -1: fixed bank / NROM

    @staticmethod
    def banked(t, b): return (b + 1) << 16 | t


def trace(prg, kind="nrom", extra=()):
    """prg: NROM 16K/32K image mapped at $8000 (16K is mirrored), or a
    UxROM / MMC3 image."""
    global _SLOT
    mem = Mem(prg, kind)
    _SLOT = mem.unit
    uxrom = mem.ux
    rd, rw, inrom = mem.rd, mem.rw, mem.inrom

    def decode(a):
        o = rd(a)
        if o not in OPS: return None
        m, mode = OPS[o]
        n = MODES[mode]
        if (a & 0xFFFF) + n - 1 > 0xFFFF or not inrom(canon(a + n - 1)): return None
        arg = rd(canon(a + 1)) if n == 2 else rw(canon(a + 1)) if n == 3 else None
        return n, m, mode, arg

    P = Program()
    P.mem = mem
    P.xbank, P.dbank = {}, {}
    P.ramcode = {}      # NES RAM address -> the ROM code copied there

    def targets(site, t):
        """JSR/JMP operand t at site -> addresses to trace"""
        if t < 0x2000:
            v = P.ramcode.get(t & 0x7FF)
            return [v] if v is not None else []
        v = mem.at(site, t)
        if v is not None: return [v] if inrom(v) else []
        return [mem.banked(t, b) for b in sorted(P.xbank.get(site) or ())]
    P.vectors = {"NMI": rw(0xFFFA), "RESET": rw(0xFFFC), "IRQ": rw(0xFFFE)}

    # Recover zeroed vectors: scan for the SEI; CLD reset prologue
    if P.vectors["RESET"] == 0 or not inrom(P.vectors["RESET"]):
        for a in range(0xC000 if uxrom else 0x8000, 0x10000):
            if rd(a) == 0x78 and rd((a + 1) & 0xFFFF) == 0xD8:  # SEI; CLD
                P.vectors["RESET"] = a; break
    if P.vectors["NMI"] == 0 or not inrom(P.vectors["NMI"]):
        # find RTI-terminated routines that look like an NMI handler
        P.vectors["NMI"] = P.vectors["RESET"]  # fallback: same as RESET

    P.engines, P.tables = set(), {}
    P.inline, P.inline_cont = set(), {}

    def data_end(site):
        """the address after the zero byte that ends the data after JSR site"""
        for k in range(3, 259):
            b = canon(site + k)
            if not inrom(b): return None
            if rd(b) == 0: return canon(b + 1)
        return None

    def run(entries):
        code, labels, calls, warns = {}, set(), set(), []
        P.inline_cont = {}
        soft = set()     # reached by falling through a skip's operand
        unoff = set()    # where an unofficial opcode may be decoded
        nofall = set()   # branches that are always taken
        skips = set()    # BIT instructions that hide the next instruction
        work = list(entries)
        while work:
            a = start = work.pop()
            imm = prev = None
            after_skip = False
            while inrom(a) and a not in code:
                d = decode(a) if rd(a) not in UNOFFICIAL or a in unoff else None
                if d is None:
                    warns.append(f"invalid opcode ${rd(a):02X} at ${a:04X} (path from ${start:04X})"); break
                n, m, mode, arg = d
                # LDA #0 / .byte $2C / LDA #1: a BIT (or a 2-byte NOP) whose
                # operand is the next instruction, used to skip it. Kept as
                # code; skips are collected below and the translator jumps
                # past them.
                inner = [canon(a + i) for i in range(1, n) if canon(a + i) in code]
                if m not in SKIPS and any(code[x][1] not in SKIPS and x not in soft for x in inner):
                    warns.append(f"overlapping instruction at ${a:04X}"); break
                code[a] = d
                if after_skip: soft.add(a)
                after_skip = m in SKIPS
                if rd(a) in UNOFFICIAL: unoff.add(nxt(a, n))
                if mode == "rel" and branch_target(a, arg) == nxt(a, 3): unoff.add(nxt(a, 2))
                if mode == "rel":
                    t = branch_target(a, arg); labels.add(t); work.append(t)
                elif m in ("JMP", "JSR") and mode == "abs":
                    for t in targets(a, arg):
                        labels.add(t); work.append(t)
                        if m == "JSR": calls.add(t)
                if m in ENDS_FLOW: break
                # LDx #imm followed by a branch on Z/N is unconditional
                if mode == "rel" and imm is not None and (
                        (m == "BNE" and imm) or (m == "BEQ" and not imm) or
                        (m == "BPL" and imm < 0x80) or (m == "BMI" and imm >= 0x80)):
                    nofall.add(a); break
                # BCC x / BCS y (or any opposite pair) never falls through
                if mode == "rel" and prev == OPPOSITE[m]: nofall.add(a); break
                prev = m if mode == "rel" else None
                imm = arg if (mode == "imm" and m in ("LDA", "LDX", "LDY")) else None
                if m == "JSR" and mem.at(a, arg) in P.inline:
                    c = data_end(a)
                    if c is not None:
                        P.inline_cont[a] = c; labels.add(c); work.append(c)
                    break
                a = nxt(a, n)
                if m == "JSR" and mem.at(a, arg) in P.engines: break   # inline table follows
        # found in either order: the BIT first, or the hidden instruction first
        for a, (n, m, _, _) in code.items():
            hidden = [canon(a + i) for i in range(1, n) if canon(a + i) in code]
            if not hidden: continue
            if m in SKIPS: skips.add(a); labels.add(a + n)
            elif any(code[x][1] not in SKIPS and x not in soft for x in hidden):
                warns.append(f"overlapping instruction at ${a:04X}")
        P.nofall, P.skips = nofall, skips
        return code, labels, calls, warns

    def is_engine(code, t):
        a, pla = t, 0
        for _ in range(24):
            if a not in code: return False
            n, m, mode, arg = code[a]
            if m == "PLA": pla += 1
            if m == "JMP" and mode == "ind": return pla >= 2
            if m in ENDS_FLOW: return False
            a = nxt(a, n)
        return False

    def is_inline(code, t):
        """PLA / STA p / PLA / STA p+1 (in either order), then a JMP (p)"""
        seq, a = [], t
        for _ in range(4):
            if a not in code: return False
            seq.append(code[a]); a = nxt(a, code[a][0])
        if [x[1:3] for x in seq] != [("PLA", "imp"), ("STA", "zp")] * 2 or abs(seq[1][3] - seq[3][3]) != 1:
            return False
        p = min(seq[1][3], seq[3][3])
        seen, work = set(), [t]
        while work and len(seen) < 64:
            a = work.pop()
            if a in seen or a not in code: continue
            seen.add(a)
            n, m, mode, arg = code[a]
            if m == "JMP" and mode == "ind" and arg == p: return True
            if mode == "rel": work.append(branch_target(a, arg))
            if m == "JMP" and mode == "abs" and mem.at(a, arg) is not None: work.append(mem.at(a, arg))
            if m not in ENDS_FLOW: work.append(nxt(a, n))
        return False

    roots = [P.vectors["NMI"], P.vectors["RESET"]]
    if (mem.mmc3 or mem.mmc1) and inrom(P.vectors["IRQ"]): roots.append(P.vectors["IRQ"])   # scanline IRQ / BRK
    P.roots = roots
    entries = roots + [a for a in extra if inrom(a)]
    P.extra = set(entries[len(roots):])
    P.dispatch = {}
    P.pushed = set()
    while True:
        extra = [w for tg in P.tables.values() for w in tg]
        extra += [w for tg in P.dispatch.values() for w in tg]
        code, labels, calls, warns = run(entries + extra + sorted(P.pushed))
        # LDA #>ret / PHA / LDA #<ret / PHA: a return address pushed by hand
        # (JMP (ptr) as a call); the RTS that pulls it goes to ret + 1
        pushed = set()
        for a, d in code.items():
            seq, b = [], a
            for _ in range(4):
                if b not in code: break
                seq.append(code[b]); b = nxt(b, code[b][0])
            if len(seq) == 4 and [x[1:3] for x in seq] == [("LDA", "imm"), ("PHA", "imp")] * 2:
                v = mem.at(a, ((seq[0][3] << 8 | seq[2][3]) + 1) & 0xFFFF)
                if v is not None and inrom(v): pushed.add(v)
        ramcode = _ram_copies(code, mem)
        engines = P.engines | {t for t in calls if is_engine(code, t)}
        inline = P.inline | {t for t in calls if t not in engines and is_inline(code, t)}
        tables = {}
        for c in sorted(a for a, d in code.items() if d[1] == "JSR" and mem.at(a, d[3]) in engines):
            t, tg = nxt(c, 3), []
            while (t & 0xFFFF) <= 0xFFF9 and inrom(t):
                if tg and t in code: break
                w = mem.at(c, rw(t))
                if w is None or not inrom(w) or c + 3 <= w < t + 2: break
                if tg and any(t <= x < t + 2 for x in tg): break
                tg.append(w); t = canon(t + 2)
            tables[c] = tg
        dispatch = _find_dispatch(code, engines, decode, mem, P.dbank)
        # targets only accumulate: once traced, code can make a later walk
        # stop earlier, which must not drop what it found before
        for site, tg in P.dispatch.items():
            if site in code:
                dispatch[site] = tg + [t for t in dispatch.get(site, []) if t not in tg]
        xbank = _bank_flow(P, code, engines, tables, dispatch) if uxrom else {}
        dbank = P.dbank_new if uxrom else {}
        wram = _wram_copy(code, mem, P.izy_bank) if uxrom else None
        # bank sets only grow between rounds; "unknown" only if never known
        for new, old in ((xbank, P.xbank), (dbank, P.dbank)):
            for site, bk in old.items():
                if site not in code: continue
                n = new.get(site)
                new[site] = bk if n is None else n if bk is None else n | bk
        if engines == P.engines and tables == P.tables and dispatch == P.dispatch \
                and xbank == P.xbank and dbank == P.dbank and pushed <= P.pushed \
                and ramcode == P.ramcode and inline == P.inline and (mem.wram_code or wram) == mem.wram_code: break
        P.engines, P.tables, P.dispatch, P.xbank, P.dbank = engines, tables, dispatch, xbank, dbank
        P.pushed |= pushed
        P.ramcode, P.inline = ramcode, inline
        mem.wram_code = mem.wram_code or wram      # once found, kept

    for tg in P.tables.values(): labels.update(tg)
    for tg in P.dispatch.values(): labels.update(tg)
    labels.update(P.pushed)
    labels.update(entries)
    P.code, P.labels, P.calls, P.warnings = code, labels, calls, warns
    P.rd, P.rw = rd, rw
    for site, bk in sorted(P.xbank.items()):
        if bk is None:
            warns.append(f"${site:04X}: bank mapped at this call into $8000-$BFFF not known; not traced")
    # the NMI handler's own code: the translator treats its pulls below the
    # interrupt frame as leaving the interrupted routine (see nes2msxtr)
    P.nmi_body, work = set(), [P.vectors["NMI"]]
    while work:
        a = work.pop()
        while a in code and a not in P.nmi_body:
            P.nmi_body.add(a)
            n, m, mode, arg = code[a]
            if mode == "rel": work.append(branch_target(a, arg))
            if m == "JMP" and mode == "abs" and mem.at(a, arg) is not None: work.append(mem.at(a, arg))
            if m in ENDS_FLOW or a in P.nofall or (m == "JSR" and mem.at(a, arg) in P.engines): break
            a = nxt(a, n)
    _stack_depth(P)
    return P


def _ram_copies(code, mem):
    """RAM address -> ROM address, for code a game copies into RAM and
    calls there right away (like a timing loop): a LDA rom,X / STA ram,X
    (or ,Y) copy loop shortly before a JSR / JMP into what it copied."""
    copies = []
    for a, (n, m, mode, arg) in code.items():
        if m != "LDA" or mode not in ("abx", "aby"): continue
        d = code.get(nxt(a, n))
        if d is None or d[1] != "STA" or d[2] not in (("zpx", "abx") if mode == "abx" else ("aby",)) \
                or d[3] >= 0x800:
            continue
        src = mem.at(a, arg)
        if src is not None and mem.inrom(src): copies.append((a, d[3], src))
    out = {}
    for a, (n, m, mode, arg) in code.items():
        if m not in ("JSR", "JMP") or mode != "abs" or arg >= 0x2000: continue
        t = arg & 0x7FF
        near = [(t - dst, src) for c, dst, src in copies
                if 0 <= t - dst < 0x100 and c >> 16 == a >> 16 and 0 < a - c < 0x40]
        if near:
            k, src = min(near)
            v = canon(src + k)
            if mem.inrom(v): out[t] = v
    return out


def _wram_copy(code, mem, izy_bank):
    """LDA (p),Y / STA (q),Y right after q is set to a PRG RAM address and p
    to a PRG one: the game copies PRG into PRG RAM (to run it there).
    -> (RAM address, PRG address it came from, length) or None."""
    pred = {}
    for a, (n, m, mode, arg) in code.items():
        if m not in ENDS_FLOW: pred[nxt(a, n)] = a
    for a, (n, m, mode, arg) in sorted(code.items()):
        if m != "LDA" or mode != "izy": continue
        d = code.get(nxt(a, n))
        if d is None or d[1:3] != ("STA", "izy"): continue
        seq, b = [], a
        while b in pred and len(seq) < 16:
            b = pred[b]; seq.append(b)
            if code[b][1] == "JSR": break
        A = X = None
        zp = {}
        for b in reversed(seq):
            _, m2, mode2, arg2 = code[b]
            if m2 == "LDA": A = arg2 if mode2 == "imm" else None
            elif m2 == "LDX": X = arg2 if mode2 == "imm" else None
            elif m2 == "STA" and mode2 == "zp": zp[arg2] = A
            elif m2 in ("JSR", "TXA", "TYA", "PLA") or m2 in _A_WRITERS: A = None
        v = [zp.get(x & 0xFF) for x in (d[3], d[3] + 1, arg, arg + 1)]
        if None in v: continue
        dst, src = v[0] | v[1] << 8, v[2] | v[3] << 8
        if not (0x6000 <= dst < 0x8000 and src >= 0x8000): continue
        sl = mem.slot(src)
        if sl is not None:
            bk = izy_bank.get(a)
            if not bk or len(bk) != 1 or next(iter(bk))[sl] is None: continue
            src = mem.banked(src, next(iter(bk))[sl])
        return dst, src, min(0x8000 - dst, (X or 0x20) * 0x100, 0x10000 - (src & 0xFFFF))
    return None


# A-register effects for the dispatch pattern scan
_KEEPS_A = {"TAX", "TAY", "LDX", "LDY", "STX", "STY", "INX", "INY", "DEX", "DEY", "CMP",
            "CPX", "CPY", "BIT", "CLC", "SEC", "CLV", "CLI", "SEI", "CLD", "SED", "NOP",
            "INC", "DEC", "TSX", "TXS"}


def _find_dispatch(code, engines, decode, mem, dbank={}):
    """site -> targets for RTS-trick dispatch and JMP (ptr) through tables.

    Scans the straight-line code before each RTS / JMP (ind) and tracks where
    A came from (LDA table,X/Y or LDA #imm) through PHA and STA. The table is
    then walked entry by entry while each target looks like code.
    Two-level tables are found too: a pointer loaded from a table into zp,
    then LDA (zp),Y / INY / LDA (zp),Y into the jump pointer. Every table
    the first level points to is walked.
    UxROM / MMC3: tables and targets in a switchable slot other than the
    site's own are walked in each bank the bank analysis found mapped at
    the site (dbank), or, when that isn't known, in every bank, keeping the
    banks where the walk finds most targets that look like code.
    """
    rd, inrom = mem.rd, mem.inrom
    covered = {}
    for a, d in sorted(code.items(), key=lambda x: x[1][1] in SKIPS):
        for i in range(d[0]): covered.setdefault(canon(a + i), a)
    pred = {}
    for a, (n, m, mode, arg) in code.items():
        if m not in ENDS_FLOW and not (m == "JSR" and mem.at(a, arg) in engines):
            pred[nxt(a, n)] = a

    def plausible(t):
        if t is None or not inrom(t) or covered.get(t, t) != t: return False
        a = t
        for _ in range(32):
            if a in code: return True
            if not inrom(a): return False
            d = decode(a)
            if d is None or d[1] == "BRK": return False
            if any(canon(a + i) in covered for i in range(d[0])): return False   # runs into code
            n, m, mode, arg = d
            if m in ("JMP", "JSR") and mode == "abs" and mem.at(a, arg) is not None \
                    and not inrom(mem.at(a, arg)): return False
            if m in ENDS_FLOW: return True
            a = nxt(a, n)
        return True

    def banks(site):
        """-> [(view, banks)]: how code at site sees 16-bit addresses"""
        if not mem.ux or site not in dbank: return [(lambda t: mem.at(site, t), None)]
        bk = dbank[site]
        if bk is None:
            n = mem.nbanks
            bk = [(b,) for b in range(n - 1)] if not mem.mmc3 else \
                [(b, None) for b in range(n)] + [(None, b) for b in range(n)]
        def view(t, tp):
            v = mem.at(site, t)
            if v is not None: return v
            b = tp[mem.slot(t)]
            return None if b is None else mem.banked(t, b)
        return [((lambda t, tp=tp: view(t, tp)), tp) for tp in sorted(bk, key=lambda tp: tuple(-1 if x is None else x for x in tp))]

    def per_bank(site, walk):
        found = [walk(view) for view, _ in banks(site)]
        if mem.ux and site in dbank and dbank[site] is None:
            best = max(map(len, found), default=0)
            found = [f for f in found if len(f) >= max(4, best // 2)]
        out = []
        for f in found: out += [t for t in f if t not in out]
        return out

    def entries(lo, hi, plus, site):
        return per_bank(site, lambda view: entries1(lo, hi, plus, site, view))

    def entries1(lo, hi, plus, site, view):
        if lo is None or hi is None: return []
        if lo[0] == "imm" and hi[0] == "imm":
            t = view(((hi[1] << 8 | lo[1]) + plus) & 0xFFFF)
            return [t] if plausible(t) else []
        stride, limit = 1, 256
        if lo[0] == "tbl" and hi[0] == "tbl":
            if hi[1] == lo[1] + 1: stride, limit = 2, 128
            elif hi[1] != lo[1]: limit = min(256, abs(hi[1] - lo[1]))
        out = []
        for i in range(limit):
            la = lo[1] + i * stride if lo[0] == "tbl" else None
            ha = hi[1] + i * stride if hi[0] == "tbl" else None
            locs = [x for x in (la, ha) if x is not None]
            if not all(inrom(x) for x in locs) or any(x in covered for x in locs): break
            t = ((rd(ha) if ha is not None else hi[1]) << 8 | (rd(la) if la is not None else lo[1]))
            t = view((t + plus) & 0xFFFF)
            if not plausible(t): break
            out.append(t)
        return out

    def entries2(lo, hi, site):
        return per_bank(site, lambda view: entries21(lo, hi, site, view))

    def entries21(lo, hi, site, view):
        """lo/hi: ("ptr", lo table, hi table, Y offset) -> targets"""
        _, L, H, k = lo
        if hi[1:3] != (L, H) or hi[3] != k + 1: return []
        stride, limit = (2, 128) if H == L + 1 else (1, 256)
        out = []
        for i in range(limit):
            la, ha = L + i * stride, H + i * stride
            if not (inrom(la) and inrom(ha)): break
            if la in covered or ha in covered:
                if i == 0: continue     # entry 0 may share bytes with code
                break
            q = rd(ha) << 8 | rd(la)             # 16-bit: may sit just below ROM
            if not any(view((q + j) & 0xFFFF) is not None and inrom(view((q + j) & 0xFFFF))
                       for j in range(0, 10, 2)):
                if i == 0: continue     # a null entry 0 is common
                break
            got = 0
            for j in range(0, 256, 2):
                a0, a1 = view((q + j + k) & 0xFFFF), view((q + j + k + 1) & 0xFFFF)
                if a0 is None or a1 is None or not (inrom(a0) and inrom(a1)):
                    if got or j >= 8: break
                    continue
                if a0 in covered or a1 in covered: break
                t = view(rd(a1) << 8 | rd(a0))
                if not plausible(t):
                    if got or j >= 8 or (t is not None and inrom(t)): break
                    continue            # unused entries (outside ROM) before the first
                got += 1
                if t not in out: out.append(t)
        return out

    found = {}
    for site, (n, m, mode, arg) in code.items():
        if not (m == "RTS" or (m == "JMP" and mode == "ind" and arg < 0x800)): continue
        seq, a = [], site
        while a in pred and len(seq) < 16:
            a = pred[a]; seq.append(a)
        A, stack, stores, yoff = None, [], {}, None
        for a in reversed(seq):
            _, m2, mode2, arg2 = code[a]
            if m2 == "LDA" and mode2 == "izy":
                lo, hi = stores.get(arg2), stores.get((arg2 + 1) & 0xFF)
                A = ("ptr", lo[1], hi[1], yoff) if lo and hi and lo[0] == hi[0] == "tbl" \
                    and yoff is not None else None
            elif m2 == "LDA":
                tb = mem.at(a, arg2) if mode2 in ("abx", "aby") else None
                A = ("tbl", tb) if tb is not None and inrom(tb) else \
                    ("imm", arg2) if mode2 == "imm" else None
            elif m2 in ("TAY", "LDY"): yoff = 0
            elif m2 == "INY": yoff = None if yoff is None else yoff + 1
            elif m2 == "DEY": yoff = None
            if m2 == "STA" and mode2 in ("zp", "abs"): stores[arg2] = A
            elif m2 in ("PHA", "PHP"): stack.append(A if m2 == "PHA" else None)
            elif m2 in ("LDA", "TAY", "LDY", "INY", "DEY", "STA"): pass
            elif m2 in ("PLA", "PLP"):
                v = stack.pop() if stack else None
                if m2 == "PLA": A = v
            elif m2 == "JSR": A = None      # a called routine leaves the stack as it was
            elif m2 not in _KEEPS_A and mode2 != "rel": A = None
        if m == "RTS":
            if len(stack) < 2: continue
            tg = entries(stack[-1], stack[-2], 1, site)
        else:
            lo, hi = stores.get(arg), stores.get(arg + 1)
            if lo and hi and lo[0] == hi[0] == "ptr": tg = entries2(lo, hi, site)
            else: tg = entries(lo, hi, 0, site)
        if tg: found[site] = tg
    return found


_A_WRITERS = {"ADC", "SBC", "AND", "ORA", "EOR", "PLA"}


def _bank_flow(P, code, engines, tables, dispatch):
    """UxROM / MMC3: site -> frozenset of the banks that can be mapped in
    the slot it calls or jumps into (when that isn't its own slot), or None
    when that isn't known.

    Abstract interpretation from the vectors. The state is (A, X, Y, banks,
    RAM): a constant or None per register, the set of bank tuples (one bank
    per switchable slot, None in a tuple: that slot unknown; the set None:
    nothing known) that may be mapped, and the constants held by the few
    RAM bytes that the code leading to a bank switch loads. RAM also holds
    "sel" (the last MMC3 $8000 write) and "stk" (the bytes the routine
    pushed, so TSX / LDA $0101+k,X reads a caller's PHA). UxROM: a store to
    ROM selects bank value & (banks - 1), with the bus conflict applied when
    the ROM byte is known. MMC3: a $8001 store after selecting R6 / R7 sets
    that slot. A routine that switches banks or calls into another slot
    (itself or through its calls) is analysed once per entry state, so a
    switch routine like LDA bank_table,Y / STA bank_table,Y sees its
    caller's LDY #n; other routines are analysed with the registers
    unknown, and keep the caller's value of each register they never
    write. Banked code always runs with its own bank mapped.
    """
    mem = P.mem
    rd, nb = mem.rd, mem.nbanks

    # RAM worth tracking: loads in the few instructions leading to a store
    # to ROM, walking back through fall-through, branches, jumps and calls
    preds = {}
    for a, (n, m, mode, arg) in code.items():
        succ = []
        if mode == "rel":
            succ.append(branch_target(a, arg))
        if m in ("JMP", "JSR") and mode == "abs" and mem.at(a, arg) is not None:
            succ.append(mem.at(a, arg))
        if m not in ENDS_FLOW and m != "JSR" and a not in P.nofall:
            succ.append(nxt(a, n))
        if m == "JSR":      # the code after the call follows the code before it
            succ.append(P.inline_cont.get(a, nxt(a, n)))
        for t in succ: preds.setdefault(t, []).append(a)
    tracked, seen = set(), set()
    work = [(a, 0) for a, (n, m, mode, arg) in code.items()
            if m in ("STA", "STX", "STY") and mode in ("abs", "abx", "aby") and arg >= 0x8000]
    while work:
        a, d = work.pop()
        if a in seen or d > 4: continue
        seen.add(a)
        n, m, mode, arg = code[a]
        if m in ("LDA", "LDX", "LDY") and (mode == "zp" or (mode == "abs" and arg < 0x2000)):
            tracked.add(arg & 0x7FF)
        work += [(b, d + 1) for b in preds.get(a, ())]
    tracked |= {"sel", "stk", "sr"}

    # per routine entry: (switches banks or calls into the switchable half,
    # registers written), through everything it calls
    def uses(a):
        """registers (0 A, 1 X, 2 Y) an instruction reads, and writes"""
        n, m, mode, arg = code[a]
        u = {1} if mode in ("zpx", "abx", "izx") else {2} if mode in ("zpy", "aby", "izy") else set()
        d = set()
        if m in ("STA", "PHA", "CMP", "BIT", "TAX", "TAY") or m in ("ADC", "SBC", "AND", "ORA", "EOR") \
                or mode == "acc": u.add(0)
        if m in ("STX", "CPX", "TXA", "TXS", "INX", "DEX"): u.add(1)
        if m in ("STY", "CPY", "TYA", "INY", "DEY"): u.add(2)
        if m in ("LDA", "TXA", "TYA", "PLA", "ADC", "SBC", "AND", "ORA", "EOR") or mode == "acc": d.add(0)
        if m in ("LDX", "TAX", "TSX", "INX", "DEX"): d.add(1)
        if m in ("LDY", "TAY", "INY", "DEY"): d.add(2)
        return u, d

    def body(e):
        seen, work, calls = set(), [e], set()
        direct, regs = False, set()
        while work:
            a = work.pop()
            if a in seen or a not in code: continue
            seen.add(a)
            n, m, mode, arg = code[a]
            if m in ("STA", "STX", "STY") and mode in ("abs", "abx", "aby") and arg >= 0x8000:
                direct = True
            if m in ("LDA", "TXA", "TYA", "PLA", "ADC", "SBC", "AND", "ORA", "EOR") or mode == "acc":
                regs.add(0)
            if m in ("LDX", "TAX", "TSX", "INX", "DEX"): regs.add(1)
            if m in ("LDY", "TAY", "INY", "DEY"): regs.add(2)
            if mode == "rel": work.append(branch_target(a, arg))
            if m in ("JMP", "JSR") and mode == "abs":
                v = mem.at(a, arg)
                if v is None: direct = True
                elif m == "JSR": calls.add(v)
                else: work.append(v)
            if m == "JMP" and mode == "ind": regs |= {0, 1, 2}
            if m == "JSR" and mem.at(a, arg) in engines: calls.update(tables.get(a, []))
            elif a in dispatch: calls.update(dispatch[a])
            if m not in ENDS_FLOW and a not in P.nofall and not (m == "JSR" and mem.at(a, arg) in engines):
                work.append(P.inline_cont.get(a, nxt(a, n)))
        return direct, regs, calls, seen

    summ = {}
    work = list(P.roots)
    while work:
        e = work.pop()
        if e in summ: continue
        summ[e] = body(e)
        work += [c for c in summ[e][2] if c not in summ]
    rel = {e: d for e, (d, _, _, _) in summ.items()}
    wr = {e: set(r) for e, (_, r, _, _) in summ.items()}
    changed = True
    while changed:
        changed = False
        for e, (_, _, calls, _) in summ.items():
            r = rel[e] or any(rel.get(c, True) for c in calls)
            w = wr[e].union(*[wr.get(c, {0, 1, 2}) for c in calls])
            if r != rel[e] or w != wr[e]:
                rel[e], wr[e] = r, w; changed = True
    # registers whose value at an instruction can still be read (a call
    # reads what its callee reads, a computed jump reads everything)
    succ, pred = {}, {}
    for a, (n, m, mode, arg) in code.items():
        t = []
        if mode == "rel": t.append(branch_target(a, arg))
        if m == "JMP" and mode == "abs" and mem.at(a, arg) is not None: t.append(mem.at(a, arg))
        if m not in ENDS_FLOW and a not in P.nofall and not (m == "JSR" and mem.at(a, arg) in engines):
            t.append(P.inline_cont.get(a, nxt(a, n)))
        succ[a] = [x for x in t if x in code]
        for x in succ[a]: pred.setdefault(x, []).append(a)
        if m == "JSR" and mem.at(a, arg) in code: pred.setdefault(mem.at(a, arg), []).append(a)
    live = {a: set() for a in code}
    work = list(code)
    while work:
        a = work.pop()
        n, m, mode, arg = code[a]
        u, d = uses(a)
        if m == "JSR":
            v = mem.at(a, arg)
            u = u | (live.get(v, {0, 1, 2}) if v in code and v not in engines else {0, 1, 2})
        if (m == "JMP" and mode == "ind") or a in dispatch: u = {0, 1, 2}
        v = u | (set().union(*[live[t] for t in succ[a]]) - d)
        if v != live[a]:
            live[a] = v; work += pred.get(a, [])
    livein = {e: live.get(e, {0, 1, 2}) for e in summ}

    xbank, dbank, memo, active, ncontexts = {}, {}, {}, set(), {}
    nsl = mem.nslots
    P.mode1 = set()         # MMC3 $8000 writes selecting PRG mode 1
    P.izy_bank = {}
    P.m1mode = set()        # MMC1 control writes selecting a PRG mode other than 3

    def proj(bk, sl):
        """banks that may be in slot sl, or None"""
        if bk is None or any(tp[sl] is None for tp in bk): return None
        return frozenset(tp[sl] for tp in bk)

    def setb(bk, sl, b):
        """slot sl now holds bank b (None: unknown)"""
        base = {(None,) * nsl} if bk is None else bk
        return frozenset(tp[:sl] + (b,) + tp[sl + 1:] for tp in base)

    def fixb(bk, sl, b):
        """keep the tuples where slot sl can hold bank b. MMC3: an unknown
        other slot is assumed to hold the other half of b's 16K pair (as
        games that switch 16K at a time map them)."""
        r = None
        if bk is not None:
            r = frozenset(tp[:sl] + (b,) + tp[sl + 1:] for tp in bk if tp[sl] in (b, None))
        if not r: r = setb(None, sl, b)
        if nsl == 2:
            r = frozenset((tp[1] & ~1, tp[1]) if tp[0] is None and tp[1] is not None and tp[1] & 1 else
                          (tp[0], tp[0] | 1) if tp[1] is None and tp[0] is not None and not tp[0] & 1 else tp
                          for tp in r)
        return r

    def join(s, t):
        if s is None: return t
        if t is None: return s
        r = tuple(x if x == y else None for x, y in zip(s[:3], t[:3]))
        bk = None if s[3] is None or t[3] is None else s[3] | t[3]
        return r + (bk, s[4] & t[4])

    def havoc(s): return (None, None, None, s[3], s[4])

    def setm(s, addr, v):
        if addr not in tracked: return s
        if addr not in ("stk", "sr") and not isinstance(v, int): v = None
        ms = frozenset((k, x) for k, x in s[4] if k != addr)
        return s[:4] + ((ms | {(addr, v)}) if v is not None else ms,)

    def getm(s, addr): return next((x for k, x in s[4] if k == addr), None)

    def ram_addr(mode, arg, s):
        idx = s[1] if mode in ("zpx", "abx") else s[2] if mode in ("zpy", "aby") else 0
        if not isinstance(idx, int): return None
        if mode in ("zp", "zpx", "zpy"): return (arg + idx) & 0xFF
        if mode in ("abs", "abx", "aby") and arg + idx < 0x2000: return (arg + idx) & 0x7FF
        return None

    def rom_addr(site, mode, arg, s):
        idx = s[1] if mode == "abx" else s[2] if mode == "aby" else 0 if mode == "abs" else None
        if not isinstance(idx, int) or not 0x8000 <= arg + idx <= 0xFFFF: return None
        t = arg + idx
        v = mem.at(site, t)
        if v is None:
            bk = proj(s[3], mem.slot(t))
            if bk is not None and len(bk) == 1: v = mem.banked(t, next(iter(bk)))
        return v if v is not None and mem.inrom(v) else None

    def note(site, bk):
        old = xbank.get(site, frozenset())
        xbank[site] = None if bk is None or old is None else old | bk

    def call(site, t, s):
        """-> state after calling NES address t from site (None: no return)"""
        v = mem.at(site, t)
        if v is not None:
            if v not in code: return havoc(s)
            # a routine that never switches banks: analysed once for any
            # registers and banks, which it leaves as they were
            sw = rel.get(v, True)
            keep = livein.get(v, {0, 1, 2}) if sw else set()
            r = routine(v, tuple(s[i] if i in keep else None for i in range(3)) + (s[3] if sw else None, s[4]))
            if r is None: return None
            w = wr.get(v, {0, 1, 2})
            r = tuple(r[i] if r[i] is not None or i in w else s[i] for i in range(3)) + (r[3] if sw else s[3], r[4])
            return setm(r, "stk", getm(s, "stk"))
        sl = mem.slot(t)
        bks = proj(s[3], sl)
        note(site, bks)
        if bks is None: return havoc(s)
        out = None
        for b in sorted(bks):
            v = mem.banked(t, b)
            if v in code:
                r = routine(v, s[:3] + (fixb(s[3], sl, b), s[4]))
                if r is not None: out = join(out, setm(r, "stk", getm(s, "stk")))
        return out

    def routine(entry, s):
        if entry not in code: return havoc(s)      # traced in the next round
        if entry >> 16 and mem.slot(entry & 0xFFFF) is not None:
            s = s[:3] + (fixb(s[3], mem.slot(entry & 0xFFFF), mem.bank(entry)), s[4])
        s = setm(s, "stk", ())
        key = (entry, s)
        if key in memo: return memo[key]
        if key in active: return havoc(s)
        k = ncontexts.get(entry, 0)
        if k >= 24 and s[4] != frozenset({("stk", ())}):
            return routine(entry, s[:4] + (frozenset(),))
        # then a routine that switches banks itself (like SetPRG with the
        # bank in A, called from everywhere) without the banks on entry
        sl = mem.slot(entry & 0xFFFF) if entry >> 16 else None
        if k >= 36 and summ.get(entry, (False,))[0] \
                and s[3] != (None if sl is None else fixb(None, sl, mem.bank(entry))):
            return routine(entry, s[:3] + (None, s[4]))
        if k >= 48 and s[:3] != (None, None, None):
            return routine(entry, havoc(s))
        ncontexts[entry] = k + 1
        active.add(key)
        exit_, state, work = None, {entry: s}, [entry]
        while work:
            a = work.pop()
            succ, ex = step(a, state[a])
            exit_ = join(exit_, ex)
            for t, s2 in succ:
                if t not in code:
                    exit_ = join(exit_, havoc(s2)); continue
                old = state.get(t)
                new = s2 if old is None else join(old, s2)
                if new != old:
                    state[t] = new; work.append(t)
        active.discard(key)
        memo[key] = exit_
        return exit_

    def each(tg, s):
        out = None
        for t in tg: out = join(out, routine(t, havoc(s)))
        return out

    def num(v): return v if isinstance(v, int) else None

    def step(a, s):
        """-> ([(successor, state)], exit state or None)"""
        n, m, mode, arg = code[a]
        A, X, Y, bk, ms = s
        if (not a >> 16 or mem.mmc3) and (m == "JMP" and mode == "ind" or m == "RTS"):
            old = dbank.get(a, frozenset())     # banks mapped at a computed jump
            dbank[a] = None if bk is None or old is None else old | bk
        if m == "LDA" and mode == "izy":        # copy loops (see _wram_copy)
            old = P.izy_bank.get(a, frozenset())
            P.izy_bank[a] = None if bk is None or old is None else old | bk
        fall = nxt(a, n)
        stk = getm(s, "stk")
        if m in ("LDA", "LDX", "LDY"):
            if mode == "imm": v = arg
            elif mode == "abx" and isinstance(X, tuple) and 0x100 <= arg < 0x200:
                i = X[1] - (arg - 0x100)        # TSX / LDA $0100+k,X: a pushed byte
                v = stk[i] if stk is not None and 0 <= i < len(stk) else None
            else:
                r = ram_addr(mode, arg, s)
                if r is not None: v = getm(s, r)
                else:
                    ra = rom_addr(a, mode, arg, s)
                    v = rd(ra) if ra is not None else None
            s = ((v, X, Y) if m == "LDA" else (A, v, Y) if m == "LDX" else (A, X, v)) + (bk, ms)
        elif m in ("STA", "STX", "STY"):
            v = num(A if m == "STA" else X if m == "STX" else Y)
            if mode in ("abs", "abx", "aby") and arg >= 0x8000:
                if mem.mmc3:
                    reg = arg & 0xE001
                    if reg == 0x8000:
                        if v is not None and v & 0x40: P.mode1.add(a)
                        s = setm(s, "sel", v)
                    elif reg == 0x8001:
                        sel = getm(s, "sel")
                        if sel is None: s = (A, X, Y, None, ms)
                        elif sel & 7 >= 6:
                            s = (A, X, Y, setb(bk, (sel & 7) - 6, None if v is None else v & (nb - 1)), ms)
                elif mem.mmc1:
                    # serial port: 5 writes of bit 0, bit 7 resets. "sr" =
                    # (bits so far or None, count); unknown: a fresh sequence
                    bits, cnt = getm(s, "sr") or (0, 0)
                    if v is not None and v & 0x80:
                        bits, cnt = 0, 0
                    else:
                        bits = None if bits is None or v is None else bits | (v & 1) << cnt
                        cnt += 1
                    if cnt == 5:
                        reg = (arg >> 13) & 3
                        if reg == 3:
                            s = (A, X, Y, setb(None, 0, None if bits is None else bits & (nb - 1)), ms)
                        elif reg == 0 and bits is not None and bits & 0x0C != 0x0C:
                            P.m1mode.add(a)
                        bits, cnt = 0, 0
                    s = setm(s, "sr", (bits, cnt))
                else:
                    if v is not None:
                        ra = rom_addr(a, mode, arg, s)
                        if ra is not None: v &= rd(ra)
                    s = (A, X, Y, setb(None, 0, None if v is None else v & (nb - 1)), ms)
            else:
                r = ram_addr(mode, arg, s)
                if r is not None: s = setm(s, r, v)
        elif m in ("TAX", "TAY", "TXA", "TYA"):
            src = {"TAX": A, "TAY": A, "TXA": num(X), "TYA": Y}[m]
            s = ((A, src, Y) if m == "TAX" else (A, X, src) if m == "TAY" else (src, X, Y)) + (bk, ms)
        elif m in ("INX", "DEX"):
            s = (A, None if num(X) is None else (X + (1 if m == "INX" else -1)) & 0xFF, Y, bk, ms)
        elif m in ("INY", "DEY"):
            s = (A, X, None if Y is None else (Y + (1 if m == "INY" else -1)) & 0xFF, bk, ms)
        elif m in ("PHA", "PHP"):
            if stk is not None: s = setm(s, "stk", stk + (A if m == "PHA" else None,))
        elif m in ("PLA", "PLP"):
            v = stk[-1] if stk else None
            s = setm(s, "stk", stk[:-1] if stk else None)
            if m == "PLA": s = (v,) + s[1:]
        elif m in ("AND", "ORA", "EOR") and mode == "imm" and A is not None:
            s = ({"AND": A & arg, "ORA": A | arg, "EOR": A ^ arg}[m], X, Y, bk, ms)
        elif m in ("ASL", "LSR") and mode == "acc" and A is not None:
            s = ((A << 1) & 0xFF if m == "ASL" else A >> 1, X, Y, bk, ms)
        elif m in _A_WRITERS or (mode == "acc"):
            s = (None, X, Y, bk, ms)
        elif m == "TSX":
            s = (A, ("S", len(stk)) if stk is not None else None, Y, bk, ms)
        elif m in ("INC", "DEC", "ASL", "LSR", "ROL", "ROR"):
            r = ram_addr(mode, arg, s)
            if r is not None: s = setm(s, r, None)

        if mode == "rel":
            return [(branch_target(a, arg), s)] + ([] if a in P.nofall else [(fall, s)]), None
        if m == "JSR":
            if mem.at(a, arg) in engines:
                return [], each(tables.get(a, []), s)
            r = call(a, arg, s)
            return ([(P.inline_cont.get(a, fall), r)] if r is not None else []), None
        if m == "JMP":
            if a in dispatch: return [], each(dispatch[a], s)
            t = arg
            if mode == "ind":
                p = mem.at(a, arg) if arg >= 0x8000 else None
                if p is None or not mem.inrom(p): return [], havoc(s)
                t = mem.rw(p)
            v = mem.at(a, t)
            if v is not None: return [(v, s)], None
            return [], call(a, t, s)         # tail call into another slot
        if m == "RTS":
            return [], (each(dispatch[a], s) if a in dispatch else s)
        if m in ("RTI", "BRK"): return [], None
        return [(fall, s)], None

    import sys
    sys.setrecursionlimit(max(sys.getrecursionlimit(), 20000))
    for v in P.roots:
        if v in code: routine(v, (None, None, None, None, frozenset()))
    P.dbank_new = dbank
    return xbank


def _stack_depth(P):
    """Depth (bytes pushed since the current routine was entered) per address.

    A PLA at depth <= 0 pops the routine's own return address; two of them in
    a row outside a dispatcher is the 'drop return frame' idiom.
    TXS after TSX in the same flow restores the depth TSX saw (P.txs_restore).
    """
    code = P.code
    depth, P.txs_restore = {}, set()
    work = [(r, 0, None) for r in P.roots]
    work += [(t, 0, None) for t in P.calls]
    work += [(t, 0, None) for t in sorted(P.extra)]     # entered by calls found at run time
    mem = P.mem
    while work:
        a, d, sx = work.pop()
        while a in code:
            if a in depth:
                if depth[a] != d:
                    P.warnings.append(f"inconsistent stack depth at ${a:04X} ({depth[a]} vs {d})")
                break
            depth[a] = d
            n, m, mode, arg = code[a]
            if m in ("PHA", "PHP"): d += 1
            elif m in ("PLA", "PLP"): d -= 1
            elif m == "TSX": sx = d
            elif m == "TXS" and sx is not None: d = sx; P.txs_restore.add(a)
            if mode == "rel": work.append((branch_target(a, arg), d, sx))
            if m == "JMP" and mode == "abs":
                v = mem.at(a, arg)
                tg = [v] if v is not None else [mem.banked(arg, b) for b in P.xbank.get(a) or ()]
                work += [(t, d, sx) for t in tg]
            if a in P.dispatch:
                # RTS-trick: the two pushed bytes are consumed by the jump
                work += [(t, d - 2 if m == "RTS" else d, None) for t in P.dispatch[a]]
            if m in ENDS_FLOW or a in P.nofall: break
            if m == "JSR" and mem.at(a, arg) in P.engines:
                # cases run at the dispatch site's depth (the engine pops its own return)
                work += [(t, d, None) for t in P.tables.get(a, [])]
                break
            if a in P.inline_cont:
                work.append((P.inline_cont[a], d, sx))
                break
            a = nxt(a, n)
    P.depth = depth
