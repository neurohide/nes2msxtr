#!/bin/sh
# usage: profile.sh game.rom out_dir seconds  -- plays the cartridge in openMSX
# (FS-A1GT + GFX9000) and records cross-bank calls in out_dir/profile_raw.txt.
ROM="$1"; OUT="$2"; SECS="${3:-40}"
if [ -z "$OPENMSX" ]; then     # the macOS app, else openmsx on the PATH
    OPENMSX=/Applications/openMSX.app/Contents/MacOS/openmsx
    [ -x "$OPENMSX" ] || OPENMSX=openmsx
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
lbl() { grep "^$1:" "$OUT/game.lbl" | sed 's/.*\$/0x/'; }
rm -f "$OUT/profile_raw.txt"
NES2MSX_OUT="$(cd "$OUT" && pwd)" NES2MSX_SECS="$SECS" NES2MSX_FC="$(lbl far_call)" \
NES2MSX_CURBANK="$(lbl cur_bank)" \
    "$OPENMSX" -machine Panasonic_FS-A1GT -ext gfx9000 -carta "$ROM" -romtype ASCII16 \
    -script "$HERE/profile.tcl" > "$OUT/omsx_profile.log" 2>&1 &
PID=$!
i=0
while kill -0 $PID 2>/dev/null && [ $i -lt 900 ]; do sleep 1; i=$((i+1)); done
kill $PID 2>/dev/null
[ -s "$OUT/profile_raw.txt" ] || { echo "profiling run produced no data (see $OUT/omsx_profile.log)"; exit 1; }
