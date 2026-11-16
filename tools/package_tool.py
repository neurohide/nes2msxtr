#!/usr/bin/env python3
"""Zip nes2msxtr itself (tools, runtime, testrom, docs, app, Makefile, deps
scripts) for itch.io. Carries no NES ROMs: sourcerom/, build/ and dist/
are left out; sourcerom/ and published/ go in empty.

usage: package_tool.py [version]
       package_tool.py --dir DEST     copy the same files into DEST (installers)
"""
import os, shutil, sys, zipfile

PATHS = ["tools", "runtime", "testrom", "docs", "samples", "assets", "app", "installer",
         "Makefile", "README.md", "LICENSE"]
SKIP_EXT = (".pyc", ".nes", ".rom")
SKIP_DIR = {"__pycache__", "bin", "obj"}
EMPTY_DIRS = ["sourcerom", "published"]     # for the user's ROMs and the converted cartridges

def files():
    for base in PATHS:
        if os.path.isfile(base):
            yield base
            continue
        for root, dirs, fs in os.walk(base):
            dirs[:] = [d for d in dirs if d not in SKIP_DIR]
            for f in fs:
                if not f.endswith(SKIP_EXT):
                    yield os.path.join(root, f)

def to_dir(dest):
    for d in EMPTY_DIRS:
        os.makedirs(os.path.join(dest, d), exist_ok=True)
    for p in files():
        os.makedirs(os.path.join(dest, os.path.dirname(p)), exist_ok=True)
        shutil.copy2(p, os.path.join(dest, p))
    print(f"copied the project into {dest}")

def main(version="dev"):
    os.makedirs("dist", exist_ok=True)
    zpath = os.path.join("dist", f"nes2msxtr-{version}.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for d in EMPTY_DIRS:
            zi = zipfile.ZipInfo(d + "/")
            zi.external_attr = (0o40755 << 16) | 0x10      # a directory, rwxr-xr-x
            z.writestr(zi, "")
        for p in files():
            z.write(p, p)
    print(f"wrote {zpath}")

if __name__ == "__main__":
    if sys.argv[1:2] == ["--dir"]:
        to_dir(sys.argv[2])
    else:
        main(*sys.argv[1:])
