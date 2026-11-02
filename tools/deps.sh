#!/bin/sh
# usage: tools/deps.sh [--check]
# Installs what nes2msxtr needs, with Homebrew (macOS) or apt (Debian/Ubuntu):
#   python3   the translator and test tools
#   make      runs the build (missing on a fresh Ubuntu / WSL)
#   z80asm    assembles the cartridge
#   cc65      assembles the bundled test ROMs (make test)
#   openmsx   plays the cartridge (make run / test / discover / profile)
# then checks that openMSX can start a Panasonic FS-A1GT with a GFX9000.
# The FS-A1GT system ROMs are copyrighted and are not installed: copy your own
# dumps into ~/.openMSX/share/systemroms/ (see the openMSX setup guide).
# --check only reports what is missing.
CHECK=0
[ "$1" = "--check" ] && CHECK=1

# command -> package (same names in Homebrew and apt)
TOOLS="python3:python3 make:make z80asm:z80asm ca65:cc65 ld65:cc65"
MISSING=""
for t in $TOOLS; do
    cmd=${t%%:*}; pkg=${t#*:}
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "found    $cmd"
    else
        echo "missing  $cmd (package $pkg)"
        case " $MISSING " in *" $pkg "*) ;; *) MISSING="$MISSING $pkg" ;; esac
    fi
done

OPENMSX="${OPENMSX:-}"
if [ -z "$OPENMSX" ]; then
    OPENMSX=/Applications/openMSX.app/Contents/MacOS/openmsx
    [ -x "$OPENMSX" ] || OPENMSX=openmsx
fi
if command -v "$OPENMSX" >/dev/null 2>&1; then
    echo "found    openmsx ($OPENMSX)"
else
    echo "missing  openmsx (package openmsx)"
    MISSING="$MISSING openmsx"
fi

if [ -n "$MISSING" ] && [ $CHECK = 0 ]; then
    if command -v brew >/dev/null 2>&1; then
        echo "installing:$MISSING"
        brew install $MISSING || exit 1
    elif command -v apt-get >/dev/null 2>&1; then
        echo "installing:$MISSING"
        sudo apt-get update && sudo apt-get install -y $MISSING || exit 1
    else
        echo "no Homebrew or apt found: install$MISSING by hand"
        exit 1
    fi
    command -v "$OPENMSX" >/dev/null 2>&1 || OPENMSX=openmsx
    MISSING=""
fi

# openMSX: the machine the scripts boot, with its system ROMs
STATUS=0
[ -n "$MISSING" ] && STATUS=1
if command -v "$OPENMSX" >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    echo "exit" > "$TMP/exit.tcl"
    if "$OPENMSX" -machine Panasonic_FS-A1GT -ext gfx9000 -script "$TMP/exit.tcl" > "$TMP/log" 2>&1; then
        echo "found    FS-A1GT system ROMs and GFX9000 in openMSX"
    else
        echo "missing  FS-A1GT system ROMs: openMSX said"
        sed 's/^/           /' "$TMP/log" | head -5
        echo "         copy your own FS-A1GT ROM dumps into ~/.openMSX/share/systemroms/"
        STATUS=1
    fi
    rm -rf "$TMP"
fi

[ $STATUS = 0 ] && echo "all dependencies found"
exit $STATUS
