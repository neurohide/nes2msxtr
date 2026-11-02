#!/usr/bin/env python3
"""Reference 6502 + minimal NES bus, used to produce expected RAM states.

The PPU/APU are stubs with the same observable semantics the MSX runtime
implements (vblank flag always set, sprite-0 hit toggles on after the first
$2002 read of a frame, controller reads 0), so a frame-by-frame run of a
game's RESET + NMI handlers is deterministic and comparable. PPU memory is
kept so $2007 reads (and CHR RAM) behave. NROM, UxROM and MMC3 (PRG mode 0,
CHR banks, $A000 mirroring; the scanline IRQ is run after each NMI over
lines 0-239 the way the MSX runtime does, while rendering is on and I clear).

usage: ref6502.py game.nes frames out_ram.bin [out_chr.bin]
"""
import sys

class NES:
    def __init__(self, rom):
        assert rom[:4] == b"NES\x1a"
        prg_banks = rom[4]
        self.prg = rom[16:16 + prg_banks * 0x4000]
        self.prg_mask = len(self.prg) - 1
        mapper = rom[6] >> 4 | rom[7] & 0xF0
        self.ux, self.mmc3 = mapper == 2, mapper == 4
        self.bank = 0
        self.sel, self.regs = 0, [0, 2, 4, 5, 6, 7, 0, 1]
        self.latch = self.cnt = self.reload = self.irq_en = self.mask = 0
        self.chr_rom = rom[16 + prg_banks * 0x4000:][:rom[5] * 0x2000] if self.mmc3 else b""
        self.ram = bytearray(0x800)
        self.s0 = 0
        self.ppu_writes = 0
        chr_ = rom[16 + len(self.prg): 16 + len(self.prg) + 0x2000] if rom[5] else b""
        self.vram = bytearray(chr_.ljust(0x4000, b"\0"))
        self.vmirror = rom[6] & 1
        self.ctrl = self.w = self.vaddr = self.buf = 0

    def prg_rd(self, a):
        if self.mmc3:
            n, sl = len(self.prg) // 0x2000, (a >> 13) & 3
            b = [self.regs[6], self.regs[7], n - 2, n - 1][sl] % n
            return self.prg[b * 0x2000 + (a & 0x1FFF)]
        if not self.ux: return self.prg[(a - 0x8000) & self.prg_mask]
        if a >= 0xC000: return self.prg[len(self.prg) - 0x10000 + a]
        return self.prg[self.bank * 0x4000 + a - 0x8000]

    def chr_bank(self, a):
        """MMC3: 1K CHR ROM bank at PPU address a < $2000"""
        k = (a >> 10) ^ (4 if self.sel & 0x80 else 0)
        b = (self.regs[k >> 1] & 0xFE) | (k & 1) if k < 4 else self.regs[k - 2]
        return b % (len(self.chr_rom) // 0x400)

    def chr_view(self):
        if not self.chr_rom: return bytes(self.vram[:0x2000])
        return bytes(self.chr_rom[self.chr_bank(a) * 0x400 + (a & 0x3FF)] for a in range(0x2000))

    def vidx(self, a):
        a &= 0x3FFF
        if 0x2000 <= a < 0x3F00:
            k = (a >> 10) & 3
            k = k & 1 if self.vmirror else k >> 1
            return 0x2000 + k * 0x400 + (a & 0x3FF)
        if a >= 0x3F00:
            a &= 0x1F
            return 0x3F00 + (a & 0x0F if a & 0x13 == 0x10 else a)
        return a

    def rd(self, a):
        if a < 0x2000: return self.ram[a & 0x7FF]
        if a >= 0x8000: return self.prg_rd(a)
        if a & 0xE007 == 0x2002:
            v = 0x80 | (0x40 if self.s0 else 0)
            self.s0 = 1
            self.w = 0
            return v
        if a & 0xE007 == 0x2007:
            i = self.vidx(self.vaddr)
            if i >= 0x3F00: v = self.vram[i]
            elif i < 0x2000 and self.chr_rom:
                v, self.buf = self.buf, self.chr_rom[self.chr_bank(i) * 0x400 + (i & 0x3FF)]
            else: v, self.buf = self.buf, self.vram[i]
            self.vaddr = (self.vaddr + (32 if self.ctrl & 4 else 1)) & 0x3FFF
            return v
        if a in (0x4016, 0x4017): return 0x40
        return 0

    def wr(self, a, v):
        if a < 0x2000: self.ram[a & 0x7FF] = v
        elif a >= 0x8000 and self.mmc3:
            r = a & 0xE001
            if r == 0x8000: self.sel = v
            elif r == 0x8001: self.regs[self.sel & 7] = v
            elif r == 0xA000: self.vmirror = 0 if v & 1 else 1
            elif r == 0xC000: self.latch = v
            elif r == 0xC001: self.reload = 1
            elif r == 0xE000: self.irq_en = 0
            elif r == 0xE001: self.irq_en = 1
        elif a >= 0x8000:
            if self.ux: self.bank = (v & self.prg_rd(a)) & (len(self.prg) // 0x4000 - 1)
        elif a == 0x4014:
            page = v << 8
            self.oam = bytes(self.rd(page + i) for i in range(256))
        elif a & 0xE007 == 0x2000: self.ctrl = v
        elif a & 0xE007 == 0x2001: self.mask = v
        elif a & 0xE007 == 0x2006:
            self.w ^= 1
            self.vaddr = (v & 0x3F) << 8 | self.vaddr & 0xFF if self.w else self.vaddr & 0x3F00 | v
        elif a & 0xE007 == 0x2007:
            i = self.vidx(self.vaddr)
            self.vram[i] = v & 0x3F if i >= 0x3F00 else v
            self.vaddr = (self.vaddr + (32 if self.ctrl & 4 else 1)) & 0x3FFF
        elif a & 0xE007 == 0x2005: self.w ^= 1
        else: self.ppu_writes += 1

class CPU:
    def __init__(self, bus):
        self.b = bus
        self.a = self.x = self.y = 0
        self.sp = 0xFD
        self.c = self.z = self.i = self.d = self.v = self.n = 0
        self.pc = self.rw(0xFFFC)

    def rw(self, a): return self.b.rd(a) | self.b.rd((a + 1) & 0xFFFF) << 8
    def rwzp(self, a): return self.b.rd(a & 0xFF) | self.b.rd((a + 1) & 0xFF) << 8
    def push(self, v): self.b.wr(0x100 | self.sp, v); self.sp = (self.sp - 1) & 0xFF
    def pop(self): self.sp = (self.sp + 1) & 0xFF; return self.b.rd(0x100 | self.sp)
    def p(self, brk=1):
        return (self.n << 7 | self.v << 6 | 0x20 | brk << 4 | self.d << 3 |
                self.i << 2 | self.z << 1 | self.c)
    def setp(self, v):
        self.n, self.v, self.d, self.i, self.z, self.c = (v >> 7) & 1, (v >> 6) & 1, (v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1
    def nz(self, v): self.n = v >> 7; self.z = int(v == 0); return v

    def nmi(self, vec=0xFFFA):
        self.push(self.pc >> 8); self.push(self.pc & 0xFF); self.push(self.p(0))
        self.i = 1
        self.pc = self.rw(vec)

    def fetch(self):
        v = self.b.rd(self.pc); self.pc = (self.pc + 1) & 0xFFFF; return v

    def addr(self, mode):
        if mode == "imm": a = self.pc; self.pc += 1; return a
        if mode == "zp": return self.fetch()
        if mode == "zpx": return (self.fetch() + self.x) & 0xFF
        if mode == "zpy": return (self.fetch() + self.y) & 0xFF
        if mode == "abs": lo = self.fetch(); return lo | self.fetch() << 8
        if mode == "abx": lo = self.fetch(); return ((lo | self.fetch() << 8) + self.x) & 0xFFFF
        if mode == "aby": lo = self.fetch(); return ((lo | self.fetch() << 8) + self.y) & 0xFFFF
        if mode == "izx": return self.rwzp(self.fetch() + self.x)
        if mode == "izy": return (self.rwzp(self.fetch()) + self.y) & 0xFFFF
        raise ValueError(mode)

    def adc(self, m):
        r = self.a + m + self.c
        self.v = int(((self.a ^ r) & (m ^ r) & 0x80) != 0)
        self.c = int(r > 0xFF)
        self.a = self.nz(r & 0xFF)

    def cmp(self, r, m):
        self.c = int(r >= m); self.nz((r - m) & 0xFF)

    def step(self):
        op = self.fetch()
        m, mode = OPS[op]
        if m in ("LDA", "LDX", "LDY", "ADC", "SBC", "AND", "ORA", "EOR", "CMP", "CPX", "CPY", "BIT"):
            v = self.b.rd(self.addr(mode))
            if m == "LDA": self.a = self.nz(v)
            elif m == "LDX": self.x = self.nz(v)
            elif m == "LDY": self.y = self.nz(v)
            elif m == "ADC": self.adc(v)
            elif m == "SBC": self.adc(v ^ 0xFF)
            elif m == "AND": self.a = self.nz(self.a & v)
            elif m == "ORA": self.a = self.nz(self.a | v)
            elif m == "EOR": self.a = self.nz(self.a ^ v)
            elif m == "CMP": self.cmp(self.a, v)
            elif m == "CPX": self.cmp(self.x, v)
            elif m == "CPY": self.cmp(self.y, v)
            elif m == "BIT":
                self.z = int((self.a & v) == 0); self.n = v >> 7; self.v = (v >> 6) & 1
        elif m in ("STA", "STX", "STY"):
            self.b.wr(self.addr(mode), {"STA": self.a, "STX": self.x, "STY": self.y}[m])
        elif m in ("ASL", "LSR", "ROL", "ROR", "INC", "DEC"):
            if mode == "acc": v = self.a
            else: a = self.addr(mode); v = self.b.rd(a)
            if m == "ASL": self.c = v >> 7; v = (v << 1) & 0xFF
            elif m == "LSR": self.c = v & 1; v >>= 1
            elif m == "ROL": c = self.c; self.c = v >> 7; v = ((v << 1) | c) & 0xFF
            elif m == "ROR": c = self.c; self.c = v & 1; v = (v >> 1) | (c << 7)
            elif m == "INC": v = (v + 1) & 0xFF
            elif m == "DEC": v = (v - 1) & 0xFF
            self.nz(v)
            if mode == "acc": self.a = v
            else: self.b.wr(a, v)
        elif mode == "rel":
            off = self.fetch()
            cond = {"BPL": not self.n, "BMI": self.n, "BVC": not self.v, "BVS": self.v,
                    "BCC": not self.c, "BCS": self.c, "BNE": not self.z, "BEQ": self.z}[m]
            if cond: self.pc = (self.pc + (off - 256 if off > 127 else off)) & 0xFFFF
        elif m == "JMP":
            if mode == "abs": self.pc = self.addr("abs")
            else:
                p = self.addr("abs")
                self.pc = self.b.rd(p) | self.b.rd((p & 0xFF00) | ((p + 1) & 0xFF)) << 8
        elif m == "JSR":
            t = self.addr("abs"); r = (self.pc - 1) & 0xFFFF
            self.push(r >> 8); self.push(r & 0xFF); self.pc = t
        elif m == "RTS": lo = self.pop(); self.pc = ((self.pop() << 8 | lo) + 1) & 0xFFFF
        elif m == "RTI": self.setp(self.pop()); lo = self.pop(); self.pc = self.pop() << 8 | lo
        elif m == "PHA": self.push(self.a)
        elif m == "PHP": self.push(self.p())
        elif m == "PLA": self.a = self.nz(self.pop())
        elif m == "PLP": self.setp(self.pop())
        elif m == "TAX": self.x = self.nz(self.a)
        elif m == "TAY": self.y = self.nz(self.a)
        elif m == "TXA": self.a = self.nz(self.x)
        elif m == "TYA": self.a = self.nz(self.y)
        elif m == "TSX": self.x = self.nz(self.sp)
        elif m == "TXS": self.sp = self.x
        elif m == "INX": self.x = self.nz((self.x + 1) & 0xFF)
        elif m == "INY": self.y = self.nz((self.y + 1) & 0xFF)
        elif m == "DEX": self.x = self.nz((self.x - 1) & 0xFF)
        elif m == "DEY": self.y = self.nz((self.y - 1) & 0xFF)
        elif m == "CLC": self.c = 0
        elif m == "SEC": self.c = 1
        elif m == "CLI": self.i = 0
        elif m == "SEI": self.i = 1
        elif m == "CLD": self.d = 0
        elif m == "SED": self.d = 1
        elif m == "CLV": self.v = 0
        elif m == "NOP":
            if mode == "imm": self.pc = (self.pc + 1) & 0xFFFF   # 2-byte NOP
        else: raise RuntimeError(f"unhandled {m} at {self.pc - 1:04X}")

def _ops():
    import os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from nestrace import OPS
    return OPS
OPS = _ops()

def run(rom, frames, max_steps=2_000_000):
    bus = NES(rom); cpu = CPU(bus)
    # RESET until the main loop settles into a tight cycle
    seen = {}
    for i in range(max_steps):
        pc = cpu.pc
        cpu.step()
        if cpu.pc == pc or (pc in seen and i - seen[pc] < 8 and bus.rd(pc) == 0x4C):
            break
        seen[pc] = i
    else:
        raise RuntimeError("RESET did not reach an idle loop")
    idle = cpu.pc

    def interrupt(vec, what):
        sp = cpu.sp
        cpu.nmi(vec)
        for _ in range(max_steps):
            cpu.step()
            if cpu.pc == idle and cpu.sp == sp: return
        raise RuntimeError(f"{what} did not return")

    for f in range(frames):
        bus.s0 = 0
        interrupt(0xFFFA, f"NMI {f}")
        if bus.mmc3 and bus.mask & 0x18 and not cpu.i:
            irq_frame(bus, lambda: interrupt(0xFFFE, f"IRQ in frame {f}"))
    return bus, cpu

def irq_frame(bus, irq):
    """The MMC3 counter over the pre-render line and lines 0-239, as the
    runtime's irq_frame: an IRQ where it reaches 0, reloading on the next
    line."""
    if bus.cnt == 0 or bus.reload: bus.cnt, bus.reload = bus.latch, 0
    else: bus.cnt -= 1
    line = -1
    while bus.cnt:
        line += bus.cnt
        if line >= 240:
            bus.cnt = line - 239
            return
        bus.cnt = 0
        if bus.irq_en: irq()
        line += 1
        if line >= 240: return
        bus.reload, bus.cnt = 0, bus.latch

if __name__ == "__main__":
    rom = open(sys.argv[1], "rb").read()
    bus, cpu = run(rom, int(sys.argv[2]))
    open(sys.argv[3], "wb").write(bus.ram)
    if len(sys.argv) > 4: open(sys.argv[4], "wb").write(bus.chr_view())
    print(f"idle loop at ${cpu.pc:04X}; RAM written to {sys.argv[3]}")
