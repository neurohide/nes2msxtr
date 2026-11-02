#!/usr/bin/env python3
"""Turn profile_raw.txt (cross-bank calls counted in openMSX: count,
caller bank, target bank, Z80 target) into profile.txt: count, caller bank,
NES target address. nes2msxtr.py reads profile.txt to choose which routines
to copy into the banks that use them. An existing profile.txt is merged in.

usage: profile.py out_dir
"""
import bisect, collections, glob, os, re, sys

out = sys.argv[1]
addr = {}
for line in open(os.path.join(out, "game.lbl")):
    m = re.match(r"(n_([0-9a-f]{4,5})):\s+equ \$([0-9a-f]+)", line)
    if m: addr[m.group(1)] = (int(m.group(3), 16), int(m.group(2), 16))
labels = {}
for f in glob.glob(os.path.join(out, "bank*.asm")):
    b = int(re.search(r"bank(\d+)\.asm$", f).group(1))
    names = re.findall(r"^(n_[0-9a-f]{4,5}):", open(f).read(), re.M)
    labels[b] = sorted(addr[n] for n in names if n in addr)

# A call only shows up while it crosses banks, and each build copies other
# routines, so profiles of successive builds are merged (largest count).
counts = collections.Counter()
prof = os.path.join(out, "profile.txt")
old = collections.Counter()
if os.path.exists(prof):
    for line in open(prof):
        f = line.split()
        if len(f) == 3 and not line.startswith("#"):
            old[(int(f[1]), int(f[2], 16))] = int(f[0])
for line in open(os.path.join(out, "profile_raw.txt")):
    n, caller, bank, z80 = map(int, line.split())
    lab = labels.get(bank, [])
    i = bisect.bisect_right([z for z, _ in lab], z80) - 1
    if i >= 0 and lab[i][0] == z80:     # calls land on a routine's label
        counts[(caller, lab[i][1])] += n
for k, n in old.items():
    counts[k] = max(counts[k], n)
with open(prof, "w") as f:
    f.write("# count caller-bank NES-target (from make profile)\n")
    for (caller, t), n in counts.most_common():
        f.write(f"{n} {caller} {t:04x}\n")
print(f"profile.txt: {len(counts)} cross-bank edges, {sum(counts.values())} calls")
