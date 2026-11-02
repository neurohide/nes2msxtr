#!/bin/sh
# usage: run.sh game.rom out_dir seconds  -- boots the cartridge on an emulated
# Panasonic FS-A1GT (MSX turboR) with a GFX9000, dumps RAM/VRAM and a screenshot.
# NES2MSX_PLAY=1 in the environment plays it (Start, run right, jump, fire;
# 2: Start every 4 s up to 40 s first, for games with an intro and menus);
# NES2MSX_POKE="32=09,30=02" keeps NES RAM bytes at those values (hex).
ROM="$1"; OUT="$2"; SECS="${3:-12}"
if [ -z "$OPENMSX" ]; then     # the macOS app, else openmsx on the PATH
    OPENMSX=/Applications/openMSX.app/Contents/MacOS/openmsx
    [ -x "$OPENMSX" ] || OPENMSX=openmsx
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/ramext.sh"
mkdir -p "$OUT"
NES2MSX_OUT="$(cd "$OUT" && pwd)" NES2MSX_SECS="$SECS" "$OPENMSX" -machine Panasonic_FS-A1GT \
    -ext gfx9000 -carta "$ROM" -romtype ASCII16 $RAMEXT -script "$HERE/run.tcl" > "$OUT/omsx.log" 2>&1 &
PID=$!
i=0
while kill -0 $PID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i+1)); done
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
grep -i -E "warning|error" "$OUT/omsx.log"
exit 0
