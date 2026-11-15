#!/usr/bin/env python3
"""Zip nes2msxtr itself (tools, runtime, testrom, docs, app, Makefile, deps
scripts) for itch.io. Carries no NES ROMs: sourcerom/, build/ and dist/
are left out; sourcerom/ and published/ go in empty.

usage: package_tool.py [version]
"""
import os, sys, zipfile

PATHS = ["tools", "runtime", "testrom", "docs", "samples", "assets", "app",
         "Makefile", "README.md", "LICENSE"]
SKIP_EXT = (".pyc", ".nes", ".rom")
SKIP_DIR = {"__pycache__", "bin", "obj"}
EMPTY_DIRS = ["sourcerom", "published"]     # for the user's ROMs and the converted cartridges

def main(version="dev"):
    os.makedirs("dist", exist_ok=True)
    zpath = os.path.join("dist", f"nes2msxtr-{version}.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for d in EMPTY_DIRS:
            zi = zipfile.ZipInfo(d + "/")
            zi.external_attr = (0o40755 << 16) | 0x10      # a directory, rwxr-xr-x
            z.writestr(zi, "")
        for base in PATHS:
            if os.path.isfile(base):
                z.write(base, base)
                continue
            for root, dirs, files in os.walk(base):
                dirs[:] = [d for d in dirs if d not in SKIP_DIR]
                for f in files:
                    if f.endswith(SKIP_EXT):
                        continue
                    p = os.path.join(root, f)
                    z.write(p, p)
    print(f"wrote {zpath}")

if __name__ == "__main__":
    main(*sys.argv[1:])
