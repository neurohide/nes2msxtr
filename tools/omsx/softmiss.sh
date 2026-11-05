#!/bin/sh
# usage: softmiss.sh game.rom out_dir replay.omr -- replay without stopping at
# unknown jump targets; the targets go to out_dir/softmiss.txt
ROM="$1"; OUT="$2"; REPLAY="$3"
[ -z "$OPENMSX" ] && { OPENMSX=/Applications/openMSX.app/Contents/MacOS/openmsx; [ -x "$OPENMSX" ] || OPENMSX=openmsx; }
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/ramext.sh"
LBL="$OUT/game.lbl"
lbl() { grep "^$1:" "$LBL" | sed 's/.*\$/0x/'; }
export NES2MSX_OUT="$(cd "$OUT" && pwd)" NES2MSX_ROM="$(cd "$(dirname "$ROM")" && pwd)/$(basename "$ROM")"
export NES2MSX_CRASH="$(lbl crash)" NES2MSX_BADADDR="$(lbl bad_addr)" NES2MSX_CURBANK="$(lbl cur_bank)" NES2MSX_BADBANK="$(lbl bad_bank)"
export NES2MSX_MISS="$(lbl dj_miss)" NES2MSX_HIT2="$(lbl dj_hit2)" NES2MSX_NOP="$(lbl io_nop)" NES2MSX_DJKEY="$(lbl dj_key)"
export NES2MSX_REPLAY="$(cd "$(dirname "$REPLAY")" && pwd)/$(basename "$REPLAY")"
"$OPENMSX" -machine Panasonic_FS-A1GT -ext gfx9000 -carta "$ROM" -romtype ASCII16 $RAMEXT \
    -script "$HERE/softmiss.tcl" 2>&1 | grep -E '^softmiss|rror'
