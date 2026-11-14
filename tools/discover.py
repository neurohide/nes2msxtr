#!/usr/bin/env python3
"""Find computed-jump targets the tracer missed by running the game.

Builds the game, runs it headless in openMSX (the attract mode, then
scripted play: Start, run right, jump, fire), and when the runtime stopped
on an unknown jump target (bad_addr), adds it to entries.txt and repeats,
until both runs get through without one. Targets that only real play
reaches are added the same way by make run when the game stops on them.

DISCOVER_PLAY=2 in the environment presses Start every 4 s up to 40 s
before playing (games with an intro and menus; see tools/omsx/run.tcl).
DISCOVER_POKES in the environment adds more play runs, one per ';'-separated
set of NES RAM pokes ("addr=val,..." hex, kept at those values), e.g. for
Contra infinite lives on each level: "32=09,30=00;32=09,30=01;...".

usage: discover.py game.nes out_dir [seconds] [rounds]
"""
import os, re, subprocess, sys

rom, out = sys.argv[1], sys.argv[2]
secs = sys.argv[3] if len(sys.argv) > 3 else "90"
rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 30
here = os.path.dirname(os.path.abspath(__file__))
name = os.path.splitext(os.path.basename(rom))[0]

# runs: the attract mode, plain play, then play with each set of pokes
mode = os.environ.get("DISCOVER_PLAY") or "1"
runs = [("0", ""), (mode, "")] + [(mode, p) for p in os.environ.get("DISCOVER_POKES", "").split(";") if p]
path = os.path.join(out, "entries.txt")
for r in range(rounds):
    b = subprocess.run([sys.executable, os.path.join(here, "nes2msxtr.py"), rom, out],
                       capture_output=True, text=True)
    if b.returncode: sys.exit(b.stdout + b.stderr)
    lbl = {m.group(1): int(m.group(2), 16) for m in
           re.finditer(r"^(\w+):\s+equ \$([0-9a-f]+)", open(os.path.join(out, "game.lbl")).read(), re.M)}
    # all runs in parallel, each dumping into its own dir; every unknown target found is added
    procs = []
    for i, (play, poke) in enumerate(runs):
        d = os.path.join(out, f".discover{i}")
        procs.append((d, play, poke, subprocess.Popen(
            [os.path.join(here, "omsx", "run.sh"), os.path.join(out, name + ".rom"), d, secs],
            stdout=subprocess.DEVNULL, env=dict(os.environ, NES2MSX_PLAY=play, NES2MSX_POKE=poke))))
    old = open(path).read().split("\n") if os.path.exists(path) else []
    new = []
    for d, play, poke, p in procs:
        p.wait()
        v = open(os.path.join(d, "msx_vars.bin"), "rb").read()
        addr = v[lbl["bad_addr"] - 0xD100] | v[lbl["bad_addr"] - 0xD100 + 1] << 8
        if not addr: continue
        bank = v[lbl["bad_bank"] - 0xD100]
        line = f"{bank:x} {addr:04x}" if 0x8000 <= addr < 0xC000 else f"- {addr:04x}"
        if line in old: sys.exit(f"round {r + 1}: ${addr:04X} (bank {bank}) is in entries.txt and still unknown")
        if line not in new: new.append(line)
    if not new:
        print(f"round {r + 1}: {secs} s of {len(runs)} runs without an unknown jump target")
        break
    open(path, "a").write("".join(l + "\n" for l in new))
    print(f"round {r + 1}: added {', '.join(new)}")
