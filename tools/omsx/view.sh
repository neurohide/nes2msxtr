#!/bin/sh
# usage: view.sh game.rom out_dir [replay.omr]  -- runs the cartridge in openMSX
# (FS-A1GT + GFX9000) with crash recording; with a replay, plays it back
# headless and reports where it stopped.
ROM="$1"; OUT="$2"; REPLAY="$3"
OPENMSX="${OPENMSX:-/Applications/openMSX.app/Contents/MacOS/openmsx}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/ramext.sh"
# labels of the cartridge being run: the copy saved with a replay, if any
LBL="$OUT/game.lbl"
[ -n "$REPLAY" ] && [ -f "${REPLAY%.omr}.lbl" ] && LBL="${REPLAY%.omr}.lbl"
lbl() { grep "^$1:" "$LBL" | sed 's/.*\$/0x/'; }
export NES2MSX_OUT="$(cd "$OUT" && pwd)" NES2MSX_ROM="$(cd "$(dirname "$ROM")" && pwd)/$(basename "$ROM")"
export NES2MSX_CRASH="$(lbl crash)" NES2MSX_BADADDR="$(lbl bad_addr)" NES2MSX_CURBANK="$(lbl cur_bank)"
export NES2MSX_BADBANK="$(lbl bad_bank)"
if [ -z "$REPLAY" ]; then
    exec "$OPENMSX" -machine Panasonic_FS-A1GT -ext gfx9000 -carta "$ROM" -romtype ASCII16 $RAMEXT \
        -script "$HERE/view.tcl"
fi
export NES2MSX_REPLAY="$(cd "$(dirname "$REPLAY")" && pwd)/$(basename "$REPLAY")"
"$OPENMSX" -machine Panasonic_FS-A1GT -ext gfx9000 -carta "$ROM" -romtype ASCII16 $RAMEXT \
    -script "$HERE/replay.tcl" 2>&1 | grep -E '^replay|^  |rror'
