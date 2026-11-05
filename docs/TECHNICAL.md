# nes2msxtr: technical notes

Statically recompiles an NROM (mapper 0), MMC1 (mapper 1), UxROM (mapper 2) or MMC3 (mapper 4) NES game into an **MSX turboR cartridge**
(ASCII16 megaROM) that draws on a **V9990 / GFX9000** and plays through the PSG.
Use it only on games you have the rights to port.

> **Disclaimer:** a non-profit, fan-made, unofficial project, NOT affiliated
> with, authorized or endorsed by Nintendo Co., Ltd., Konami Group Corporation,
> Arc System Works Co., Ltd. or their affiliates. All trademarks, game titles
> and related assets belong to their owners. nes2msxtr is MIT-licensed (see
> [LICENSE](../LICENSE)); the license does not cover game images or the
> cartridges built from them.

```
make ROM=game               # -> build/game/game.rom + build/game/report.txt
make run ROM=path/to/game.nes  # boot it in openMSX (FS-A1GT + GFX9000); a crash
                               # (or F11) saves build/<game>/crash-<n>.omr + .rom/.lbl/.txt
make replay ROM=path/to/game.nes REPLAY=build/game/crash-1.omr
                               # play that session back headless, report the stop
make profile ROM=path/to/game.nes  # play it headless, rebuild with hot routines
                               # copied into the banks that call them (2-3 runs)
make discover ROM=path/to/game.nes # run it headless (attract mode, then scripted
                               # play) and add computed-jump targets the tracer
                               # missed to build/game/entries.txt
make discover ROM=contra DISCOVER_POKES="32=09,30=00;32=09,30=01;..."
                               # ... plus one play run per set of NES RAM bytes
                               # held fixed (here Contra: $32 lives, $30 level),
                               # so scripted play reaches every level
make discover ROM=doubledragonii DISCOVER_PLAY=2 DISCOVER_POKES="432=09;432=09,422=01;432=09,422=02"
                               # scripted play that presses Start every 4 s
                               # up to 40 s first (intro and menus), unpauses
                               # when the sprites stand still, and walks up and
                               # down too; here Double Dragon II with infinite
                               # lives ($0432) on each difficulty ($0422)
make test                      # end-to-end check with the bundled test ROMs
```

Needs Python 3, `z80asm`, and cc65 plus openMSX for the tests. `make run` and the
tests expect the FS-A1GT system ROM in openMSX.

## How it works

| Stage | File |
|---|---|
| Trace code vs. data from the vectors; find jump-table dispatchers, computed-jump tables, stack depth and (UxROM, MMC3) the bank mapped at each call into a switchable slot | `tools/nestrace.py` |
| Translate every 6502 instruction to Z80/R800, pack into 32K code banks | `tools/nes2msxtr.py` |
| Runtime: boot, interrupts, banking, PPU/APU/pad emulation (page-3 RAM) | `runtime/*.asm` |
| Reference 6502 + RAM comparison for testing | `tools/ref6502.py`, `tools/compare.py` |
| openMSX driver (dumps RAM, V9990 state, PSG, screenshot) | `tools/omsx/` |

**Register mapping:** A→A, X→C (B is always 0), Y→E. D holds the last N/Z result,
the Z80 carry is the 6502 carry, and V is a memory flag that is only computed when
the game ever branches on it. NES RAM sits at `$C000`. ROM data is read through a
16K window in page 2, and I/O goes to runtime handlers.

**Stack:**
- `PHA`/`PLA`/`PHP`/`PLP` use a real 6502 stack in NES page 1, with S kept by
  the runtime. `PHP` pushes a real status byte (N V 1 B D I Z C).
- Return addresses live on the Z80 stack. If the game uses `TSX`, `JSR` also
  writes the 6502 return address into page 1, so stack peeking sees what it
  would on a NES. The report says which mode was chosen.
- The NMI pushes a 3-byte frame. Its PC bytes are zero, because the
  interrupted 6502 PC isn't known.

**Computed jumps:**
- The tracer finds jump-table dispatchers that pop their return address
  (`JSR` + inline `.word` list).
- It also scans the code before every `RTS` and `JMP (ptr)` for where the
  pushed or stored bytes came from: `LDA table,X/Y` or `LDA #imm`. Split lo/hi
  tables and word tables are both recognised.
- Each table is walked entry by entry while the target still looks like code.
  The walk stops at an invalid opcode, `BRK`, an address outside ROM, or bytes
  already traced as code.
- At run time `PHA`/`PHA`/`RTS` and `JMP (ptr)` look the address up in that
  list. An address that was never found stops the machine with a red backdrop,
  and the NES address is left in `bad_addr`.

**UxROM:**
- Code in the switchable half (`$8000-$BFFF`) is traced once per bank it can
  run in, under the address `(bank + 1) << 16 | addr`, so the same NES address
  in two banks becomes two separate routines (labels `n_1xxxx`, `n_2xxxx`, ...).
  The fixed bank keeps plain addresses.
- To find which bank a fixed-bank `JSR`/`JMP $8xxx` reaches, the tracer
  follows constants through the code from the vectors: registers, the set of
  banks that may be mapped, and the few RAM bytes that bank-switching code
  loads. A store to ROM selects a bank. A switch routine like
  `LDA tbl,Y / STA tbl,Y` is analysed once for each caller's `LDY #n`.
- At run time, a store to ROM goes to `mapper_w`, which maps the PRG
  segment. A fixed-bank call into the switchable half looks up the address
  and the bank mapped now (`dyn_call`). Banked code reads its own bank's
  constants directly.
- Computed-jump tables are recognised two levels deep: a pointer from a
  table, then `LDA (ptr),Y / INY / LDA (ptr),Y` into the jump pointer. Seen
  from the fixed bank, such tables are walked in the bank the analysis
  found. When that isn't known, they are walked in each bank and the banks
  where they hold code are kept.
- What the tracer still misses (say, a table pointer kept in RAM per level)
  stops the game with the address and bank. `make run` (on a stop) and
  `make discover` add it to `build/<game>/entries.txt`, which the next build
  reads as extra entry points.

**MMC3:**
- The switchable half is two 8K slots, `$8000` (R6) and `$A000` (R7); the
  last 16K stays fixed (PRG mode 0; mode 1 is reported, not supported).
  Banked code is traced per 8K bank, and the bank analysis keeps a tuple of
  the banks in both slots, so code at `$8000` calling into `$A000` (and
  fixed code calling either) gets the right bank. Where the other slot isn't
  known, it is assumed to hold the other half of a 16K pair, as games that
  switch 16K at a time map them.
- The analysis also tracks the last `$8000` write and the bytes a routine
  pushed, so a switch routine that reads its caller's `PHA` back with
  `TSX / LDA $0102,X` still resolves.
- CHR ROM is switched in 1K / 2K pieces (R0-R5, `$8000` bit 7 swaps the
  halves). It stays in the cartridge: when banks change, the pieces that
  changed are copied into the CHR copy and rebuilt like CHR RAM tiles, at the
  next frame or at once when the game reads CHR through `$2007` (games keep
  compressed data there).
- `$A000` mirroring applies at once; the V9990 map is rebuilt at the next
  frame.
- Scanline IRQ: there is no raster timing to count lines with, so after each
  NMI the runtime runs the counter over lines 0-239 and calls the game's IRQ
  handler at each line where it reaches 0 (while rendering is on and I is
  clear). The scroll each handler leaves (`$2005` / `$2000`, or a `$2006`
  write that moves the picture) is recorded and shown in the next frame with
  V9990 line interrupts, like the top-of-frame scroll.
- Interrupt handlers run with the `$8000` select value saved and restored
  around them: handlers that switch banks without restoring it rely on the
  NES main loop being idle when they run, which a slower one isn't.
- Other idioms seen in MMC3 games: a 2-byte `NOP` (`$80`) used to skip a
  byte like the `BIT` trick, a return address pushed by hand before
  `JMP (ptr)` (the pushed address + 1 is traced), `STA abs / RTS` code built
  in RAM (`ram_jump` runs it), and an NMI handler that pulls its own frame
  and returns from the wait loop it interrupted (`nmi_rts` / `spin_wait`).

**CHR RAM:** a `$2007` write to `$0000-$1FFF` goes to a CHR copy (in the misc
segment, which `$2007` reads use too) and marks the tile dirty. At the start
of each frame the dirty tiles are rebuilt: the 4 palette copies of the
background pattern in VRAM, the sprite source rows and `s0row`. The sprite
pattern cache is then emptied.

**Memory at run time** (everything but MMC3 CHR ROM is copied into mapper
RAM at boot). At boot the runtime looks for memory mappers in the slots it
can switch to (any primary slot, or a sub-slot of page 3's own slot) and
counts their segments. It runs from the machine's own RAM when the game fits
there (the report says how much it needs), else from the largest RAM
expansion that holds it; with none, it says how much RAM is needed. `make
run` and the tests add an openMSX `ram1mb` / `ram2mb` / `ram4mb` cartridge
to slot B when the report asks for more than 512K. A RAM expansion behind a
slot expander in another slot isn't used.
- `$0000-$7FFF`: a code bank
- `$8000-$BFFF`: a data window (PRG banks, sprite tiles, CHR, the
  computed-jump lookup table)
- `$C000-$FFFF`: NES RAM, PPU/APU state, the runtime and the stack

**Graphics (V9990 P1 mode):**
- Each NES background tile is stored 4 times, once per palette. A name-table entry
  therefore picks tile and attribute palette together.
- NES sprite *i* becomes V9990 sprite *i*. V9990 sprites can't flip, so each
  (tile, flip, palette, size) combination gets its own pattern from a 256-entry
  cache. A sprite only uploads a pattern on a cache miss, so games that shuffle
  sprite slots every frame don't re-upload anything.
- Sprite-0 splits use the V9990 line interrupt. `$2002` polling loops that wait
  for the sprite-0 flag to clear or to be set are recognised by the translator
  and end at once, since there is no raster timing. Only such a loop starts a
  split: other `$2002` reads (latch resets, vblank waits) leave the screen
  whole.
- `$2001` and the scroll are latched and written to the V9990 at the start of
  the next frame, so an NMI that runs past vblank doesn't blank or tear the top
  of the picture. The pattern-table and sprite-size bits of `$2000` are
  latched too, and take effect when a frame ends with them changed. Games
  often write `$2000 = 0` at the start of their NMI, and a background-table
  switch rebuilds the whole map.
- 212 of the 240 NES lines are shown. `--crop` sets how many lines are hidden at
  the top (default 16).

**Lag frames:** a game whose main loop waits for the NMI in a small loop
polling RAM (`LDA frame / CMP #2 / BCC back`, as the translator marks them)
builds its sprite buffer, CHR bank shadows and scroll during the frame and
expects the NMI to find them finished. When the translated main loop is
still busy at vblank, the NMI is held back (up to 8 frames) and run when the
main loop reaches its wait, once per vblank missed, like a NES lag frame:
the game slows down instead of showing half-built sprites. This only applies
while the game is actually using such a wait (one seen in the last 8
frames).

**Sound:**
- Pulse 1 → PSG A, pulse 2 → PSG B, triangle → PSG C. Noise is mixed into C.
- Envelopes, length counters, sweep and the linear counter are emulated at 60 Hz.
  The PSG runs at the NES CPU clock, so periods map exactly.

**Controller:**
- D-pad: cursor keys or joystick 1.
- A: Z, SPACE or trigger A. B: X or trigger B.
- Start: RETURN. Select: SELECT.

## Status

Verified on an emulated Panasonic FS-A1GT (R800 mode) with a GFX9000, using three
original test ROMs:
- `testrom`: ALU flags, `BIT`, zero-page wrap, `(zp),Y`/`(zp,X)`, return-address
  drops, jump-table dispatch, the sprite-0 split, scrolling, sprites and the APU.
- `stacktest`: `PHA`/`PHA`/`RTS` through split and word tables (also inside the
  NMI), `JMP (ptr)` tables, `TSX` reads of pushed bytes and of `JSR` return
  addresses, `TSX`/`TXS` save and restore, `PHP`/`PLP` status bytes, return-frame
  drops with a faithful stack, and an inline jump-table engine. It shows a green
  backdrop when every check passes and red otherwise.
- `uxtest` (UxROM, CHR RAM): calls from the fixed bank into the same address
  in each bank, reads of the switchable half from fixed and banked code, a
  banked routine calling back into its own bank through a fixed helper, a
  `JMP (ptr)` table inside a bank, a bank switch through `STA (ptr),Y`, CHR
  RAM written and read back through `$2007`, and an NMI that saves, switches
  and restores the bank. Its background patterns, as rebuilt from CHR RAM,
  are compared with the reference CHR too.
- `mmc3test` (MMC3, 32K CHR ROM): the same addresses in different banks of
  each slot, paired and not, a call from `$8000` code into whatever `$A000`
  holds, fixed code reading both slots, a `JMP (ptr)` table in a bank, the
  2-byte `NOP` skip, a return address pushed by hand, code built in RAM, CHR
  banks read through `$2007` with and without inversion, `$A000` mirroring,
  and two scanline IRQs per frame. The reference 6502 runs the IRQ counter
  the same way.
- `uxtest` again, padded with `--pad-kb 600` to need 816K: it runs from a
  1MB RAM expansion.

After 200 frames the NES RAM of each ROM matches the reference 6502 byte for
byte. Page 1 is excluded, because NMI frames hold the PC. Each ROM passes as one
code bank and when forced into 2K banks (`--bank-kb 2`).

## Limits

These are reported in `report.txt` where detectable:

- NROM, MMC1, UxROM and MMC3 only. No other mappers, no battery saves, no MMC3 PRG mode 1. MMC1: PRG mode 3 only (16K banks, last fixed, like UxROM), up to 256K PRG; the 5-write serial port is followed by the tracer and emulated by the runtime.
- MMC3: the IRQ handler runs right after the NMI rather than at its line,
  and a split shows from the next frame on. IRQs masked by I are dropped for
  that frame. CHR banks switched mid-frame are not shown per line.
- UxROM: banked code is assumed to run with its own bank mapped (code that
  switches the bank under itself isn't followed). Bus conflicts are not
  emulated; games write the value the ROM holds anyway.
- CHR RAM tiles written during a frame show from the next frame on.
- No DMC channel. Noise and triangle share PSG channel C.
- Raster effects other than one sprite-0 split or MMC3 IRQ splits aren't
  emulated.
- Horizontal mirroring: vertical scrolling wraps at 512 lines instead of 480,
  which can show 4 blank rows at the wrap.
- `BIT` results used for both N and Z keep only Z. So does `PLP` of a status
  byte with both N and Z set.
- Computed jumps are found by pattern. Targets built some other way (arithmetic
  on the address, a pointer copied from RAM, a table index computed elsewhere)
  are missing from the lookup list and stop the game at run time. The report
  says `RTS dispatch with unknown targets` for the `RTS` case.
- Not supported:
  - Routines that read inline data after their `JSR` and return past it.
  - `TXS` to an unrelated value inside a routine. Z80 return frames don't move;
    the report warns about it.
- Multi-bank code: a call within a bank is a plain `CALL`/`RET`; a call into
  another bank keeps the caller's bank on a small bank stack. Each bank also
  gets copies of routines it calls in other banks, so those calls don't
  switch banks. Without a profile the copies are picked statically; `make
  profile` plays the game in openMSX (Start, then run right and jump),
  records which cross-bank calls are hot in `build/<game>/profile.txt`, and
  rebuilds with those routines copied first. Profiles of successive runs are
  merged.
- RAM: about 160K for a small game. Each extra 32K code bank needs 32K more. A1ST
  (256K) fits about 4 code banks, A1GT (512K) about 12. More runs from a RAM
  expansion (up to 4080K, in one memory mapper).
- R800 speed hasn't been profiled on real hardware yet. If a game's NMI runs past a
  frame, that frame is skipped.
