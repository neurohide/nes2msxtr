## 1. Install the dependencies (Windows)

nes2msxtr runs under WSL (Windows Subsystem for Linux) — the build uses
`make` and shell scripts.

1. In a Command Prompt or PowerShell, inside the unzipped folder:
   ```
   tools\deps.cmd
   ```
   First run installs WSL + Ubuntu (admin rights needed; restart Windows
   if asked, finish the Ubuntu username/password prompt), then run
   `tools\deps.cmd` again. Second run installs `make`, `python3`,
   `z80asm`, `cc65` and openMSX inside WSL with apt.
2. Copy your FS-A1GT system ROM dumps into
   `~/.openMSX/share/systemroms/` **inside WSL** (copyrighted, so the
   script can't fetch them). `tools\deps.cmd -Check` reports if openMSX
   can't find them.
3. From here on, prefix commands with `wsl`, run from the project folder,
   e.g. `wsl make ROM=mygame`. openMSX opens through WSLg.

## 2. Generate a ROM from an NES file

1. Copy your ROM into `sourcerom/`, e.g. `sourcerom/mygame.nes`.
   If the file name has spaces, it's recommended to link it under a short
   name without spaces and use that name from then on:
   ```
   wsl ln -sfn "Bubble Bobble (USA).nes" sourcerom/bubblebobble.nes
   ```
2. Build:
   ```
   wsl make ROM=mygame
   ```
   Writes `build/mygame/mygame.rom` and `build/mygame/report.txt`
   (mapper, RAM needed, code banks, warnings).

## 3. Simple case: mapper 0 (NROM), happy path

NROM has one fixed 32K bank, no bank switching — nothing to discover.

```
wsl make ROM=mygame        # build/mygame/mygame.rom, report.txt
wsl make run ROM=mygame    # play it in openMSX
```

`report.txt` should read `warnings (0):`. That's the whole pipeline for
this case — no `entries.txt`, no crash handling needed.

### Controls

NES controller 1 works with either the MSX keyboard or joystick port 1:

| NES control | Keyboard | Joystick 1 |
|---|---|---|
| D-pad | Cursor keys | Stick |
| A | Z or SPACE | Trigger A |
| B | X | Trigger B |
| Start | RETURN | — |
| Select | SELECT (F7 in openMSX) or TAB | — |

## 4. Other mappers (UxROM / MMC1 / MMC3): finding missed jump targets

These bank-switch code at run time. The tracer follows the reset/NMI/IRQ
vectors statically and usually resolves which bank is mapped at each
call, but some targets are only reachable at run time (a jump table built
from game state, a computed jump after a bank swap it couldn't follow).
`report.txt` lists these as warnings, e.g.:

```
$E1F4: bank mapped at this call into $8000-$BFFF not known; not traced
```

### 4.1 `make discover`: headless, fills `entries.txt`

```
wsl make discover ROM=mygame
```

Plays the attract mode / menus headless in openMSX and writes any missed
computed-jump target it reaches to `build/mygame/entries.txt` (`bank
addr` in hex, or `- addr` for the fixed bank). Rebuild to pick them up:

```
wsl make ROM=mygame
```

Knobs:
- `DISCOVER_PLAY=2` — presses Start every few seconds, for an intro/menu
  to get through before real play starts.
- `DISCOVER_SECS=120` — plays longer.
- `DISCOVER_POKES="32=09,30=00;32=09,30=01"` — holds NES RAM bytes
  (lives, stage, …) across separate play runs, to reach content normal
  play wouldn't in one pass.

Headless play won't reach everything (specific levels, real input) —
that's what step 4.2 is for.

### 4.2 A real crash in openMSX: capture it, add the entry

An untraced target the cartridge actually jumps to stops it with a red
screen rather than crashing silently.

1. Play for real:
   ```
   wsl make run ROM=mygame
   ```
2. On a crash (or pressing F11 yourself) it saves three files next to the
   build: `build/mygame/crash-N.rom` (the cartridge at that point),
   `crash-N.omr` (the input recording), `crash-N.txt` (the bank/address
   it stopped on). Read it:
   ```
   wsl cat build/mygame/crash-N.txt
   ```
3. `make run` already added that bank/address line to
   `build/mygame/entries.txt` for you (the whole point of stopping there
   instead of corrupting the run). Confirm it's there, or add it by hand
   as `bank addr` (hex), or `- addr` if the crash was in the fixed bank.
4. Rebuild:
   ```
   wsl make ROM=mygame
   ```

### 4.3 `make replay`: check the fix without playing again

```
wsl make replay ROM=mygame REPLAY=build/mygame/crash-N.omr
```

Replays the exact saved input headless against the *rebuilt* cartridge
and reports whether it still stops on a crash. Repeat for every
`crash-N.omr` collected — a fix for one target can't be assumed to fix
another.

Once `build/mygame/entries.txt` is stable (`make run`/`replay` go through
cleanly), copy it to `samples/mygame.entries.txt` so later builds of the
same ROM start from it instead of rediscovering the same targets.

### 4.4 Other warnings in `report.txt`, and what to do about them

- `jump to $XXXX, which was not traced as code (stops there at run
  time)` / `bank mapped at this call ... not known; not traced` — the
  common case; fixed by 4.1-4.3 above.
- `invalid opcode $XX at $XXXX (path from $XXXX)` — the tracer followed a
  path into data (often a jump table it misread as code, or an untraced
  bank switch landing it in the wrong bank). Check the "path from"
  address: it's usually the same root cause as the bank warnings above,
  not a real illegal instruction — add the right bank/address to
  `entries.txt` rather than treating it as a dead end.
- `overlapping instruction at $XXXX` — a byte was reached decoded two
  different ways (as the middle of one instruction, and the start of
  another). Downstream of the same mistraced-jump-table or wrong-bank
  issue above; resolving the warning above it usually clears this one.
- `inconsistent stack depth at $XXXX (A vs B)` — the tracer's call/return
  balance disagreed between two paths reaching that address (e.g. an
  RTS-trick dispatcher or a routine entered both via `JSR` and via a
  fallthrough). If it's inside a region you've already pinned down with
  `entries.txt`, it's usually harmless; if the cartridge misbehaves near
  that address at run time, it's worth checking that address in
  `build/mygame/game.lbl` against the NES disassembly, since it points
  at a real ambiguity in how that code is reached.
- `RTS dispatch with unknown targets (resolved at run time)` — an
  RTS-trick jump table (`PHA`/`PHA`/`RTS`) the tracer recognized but
  couldn't enumerate statically; the runtime resolves it live, so this is
  informational, not a bug — crashes from it are reported and fixed the
  same way as any other "not traced" target (4.2-4.3).

If none of the above gets a game running after a few discover/crash/
replay passes, that's a sign it's hitting an actual limit — check
[docs/TECHNICAL.md](TECHNICAL.md)'s Limits section (mapper coverage, the
DMC channel, MMC3 PRG mode 1, etc.) before assuming it's a missing
entry.
