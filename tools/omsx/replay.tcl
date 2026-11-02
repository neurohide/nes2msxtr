# Replay a recorded session headless (make replay REPLAY=...): runs it at full
# speed and reports where the runtime stopped, or that it didn't.
# env: NES2MSX_REPLAY, NES2MSX_OUT, NES2MSX_CRASH, NES2MSX_BADADDR, NES2MSX_CURBANK
set throttle off
source [file join [file dirname [info script]] view.tcl]
proc nes2msx_crash {why} {
    if {$::nes2msx_crashed} return
    set ::nes2msx_crashed 1
    global env
    set bad $env(NES2MSX_BADADDR)
    puts stderr "replay: $why"
    puts stderr [format "  time %.3f s, pc=%04X sp=%04X bank=%d bad_addr=\$%04X" [machine_info time] \
        [reg pc] [reg sp] [debug read memory $env(NES2MSX_CURBANK)] \
        [expr {[debug read memory $bad] | ([debug read memory [expr {$bad + 1}]] << 8)}]]
    puts stderr "  stack: [nes2msx_hex [reg sp] 32]"
    exit
}
reverse loadreplay $env(NES2MSX_REPLAY)
debug set_bp $env(NES2MSX_CRASH) {} {nes2msx_crash "runtime stop (crash)"}
after time 1 { debug set_bp 0x0000 {} {nes2msx_crash "jump to \$0000 (bad return or jump)"} }
# The end of the recording, read once: after it openMSX records live again.
set ::nes2msx_end [dict get [reverse status] end]
after time [expr {$::nes2msx_end + 2}] {
    puts stderr [format "replay: reached the end (%.1f s) without a crash" $::nes2msx_end]
    exit
}
