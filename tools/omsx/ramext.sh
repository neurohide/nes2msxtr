# Sourced by run.sh / view.sh with ROM set: when the build's report says the
# game needs more mapper RAM than the FS-A1GT's 512K, RAMEXT adds the
# smallest openMSX memory mapper cartridge that holds it (the runtime finds
# it at boot and runs from it).
RAMEXT=""
REPORT="$(dirname "$ROM")/report.txt"
if [ -f "$REPORT" ]; then
    NEED=$(sed -n 's/.*(\([0-9]*\)K RAM needed.*/\1/p' "$REPORT" | head -1)
    if [ -n "$NEED" ] && [ "$NEED" -gt 512 ]; then
        for k in 1 2 4; do
            if [ "$NEED" -le $((k * 1024)) ]; then RAMEXT="-ext ram${k}mb"; break; fi
        done
    fi
fi
