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
import hashlib, os, re, subprocess, sys

rom, out = sys.argv[1], sys.argv[2]
secs = sys.argv[3] if len(sys.argv) > 3 else "90"
rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 30
here = os.path.dirname(os.path.abspath(__file__))
name = os.path.splitext(os.path.basename(rom))[0]

# runs: the attract mode, plain play, then play with each set of pokes
mode = os.environ.get("DISCOVER_PLAY") or "1"
runs = [("0", ""), (mode, "")] + [(mode, p) for p in os.environ.get("DISCOVER_POKES", "").split(";") if p]
signature = hashlib.sha1(open(rom, "rb").read()).hexdigest()
path = os.path.join(out, f"entries.{signature}.txt")


faults = []


def unknown_target(d, lbl, play, poke):
    dump = os.path.join(d, "msx_vars.bin")
    if not os.path.isfile(dump):
        log = os.path.join(d, "omsx.log")
        detail = open(log).read().strip() if os.path.isfile(log) else "no emulator log"
        raise RuntimeError(f"{d}: emulator produced no msx_vars.bin ({detail})")
    v = open(dump, "rb").read()
    i = lbl.get("bad_addr", -1) - 0xD100
    j = lbl.get("bad_bank", -1) - 0xD100
    if i < 0 or i + 1 >= len(v) or j < 0 or j >= len(v):
        raise RuntimeError(f"{d}: bad_addr/bad_bank labels are outside the {len(v)}-byte dump")
    addr = v[i] | v[i + 1] << 8
    cpu_path = os.path.join(d, "cpu.txt")
    crashed = False
    if os.path.isfile(cpu_path) and "crash" in lbl and "crash_l" in lbl:
        pc = re.search(r"\bpc=(\d+)\b", open(cpu_path).read())
        crashed = bool(pc and lbl["crash"] <= int(pc.group(1)) <= lbl["crash_l"] + 2)
    if not addr and crashed:
        # a RET with no frame left (a PLA/PLA dropped one too many): not a
        # missing entry, so nothing to add; reported once the round is done
        faults.append(f"{d}: runtime jumped to $0000 (unbalanced return frames, e.g. PLA/PLA drop_frame); "
                      "replay the crash (make replay) and check the last dyn_jump / drop_frame targets")
        return None
    if not addr:
        return None
    bank = v[j]
    line = f"{bank:x} {addr:04x}" if 0x8000 <= addr < 0xC000 else f"- {addr:04x}"
    return line, bank, addr


for r in range(rounds):
    build = [sys.executable, os.path.join(here, "nes2msxtr.py"), rom, out, "--no-interp"]
    if "DISCOVER_SPLASH" in os.environ:
        build += ["--splash", os.environ["DISCOVER_SPLASH"]]
    b = subprocess.run(build, capture_output=True, text=True)
    if b.returncode: sys.exit(b.stdout + b.stderr)
    # an entry that makes the tracer overlap an instruction points into the
    # middle of code: a wrong return or stack imbalance, not missing code
    ov = {int(m, 16) for m in re.findall(r"overlapping instruction at \$([0-9A-Fa-f]+)", b.stdout + b.stderr)}
    if ov and os.path.exists(path):
        lines = open(path).read().split("\n")
        bad = [l for l in lines if len(l.split()) == 2 and any(abs(int(l.split()[1], 16) - o) <= 3 for o in ov)]
        if bad:
            open(path, "w").write("".join(l + "\n" for l in lines if l and l not in bad))
            sys.exit(f"round {r + 1}: entries {', '.join(bad)} overlap traced code (${', $'.join(f'{o:04X}' for o in sorted(ov))}); "
                     "removed them: the game reached them through a wrong return address, not missing code")
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
        try:
            result = unknown_target(d, lbl, play, poke)
        except RuntimeError as e:
            sys.exit(f"round {r + 1}: {e}")
        if result is None: continue
        line, bank, addr = result
        if line in old:
            sys.exit(f"round {r + 1}: {d} ({'play' if play else 'attract'}{', pokes ' + poke if poke else ''}) "
                     f"still misses ${addr:04X} (bank {bank}); {line} is already in entries.txt")
        if line not in new: new.append(line)
    if not new and faults: sys.exit(f"round {r + 1}: " + "; ".join(faults))
    if not new:
        print(f"round {r + 1}: {secs} s of {len(runs)} runs without an unknown jump target")
        break
    open(path, "a").write("".join(l + "\n" for l in new))
    print(f"round {r + 1}: added {', '.join(new)}")
    if faults: print("warning: " + "; ".join(faults)); faults.clear()
