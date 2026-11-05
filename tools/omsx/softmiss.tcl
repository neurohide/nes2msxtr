# Soft-miss discovery: replay a recording (or play live with view.sh's inputs)
# and, instead of stopping at an unknown computed-jump target, log it
# ("bank addr", hex) to NES2MSX_OUT/softmiss.txt and make the jump a no-op
# RTS, so one run collects every target it reaches. Run via softmiss.sh.
# env as replay.tcl, plus NES2MSX_MISS (dj_miss), NES2MSX_HIT2 (dj_hit2),
# NES2MSX_NOP (a bare ret), NES2MSX_DJKEY (word).
set throttle off
source [file join [file dirname [info script]] view.tcl]
global env
set ::sm_seen {}
set ::sm_log [open [file join $env(NES2MSX_OUT) softmiss.txt] w]
proc sm_miss {} {
    global env
    set k $env(NES2MSX_DJKEY)
    set a [expr {[debug read memory $k] | ([debug read memory [expr {$k + 1}]] << 8)}]
    set b [reg E]
    set line [format "%x %04x" [expr {$a >= 0x8000 && $a < 0xC000 ? $b : 0}] $a]
    if {$a < 0x8000 || $a >= 0xC000} {set line [format "- %04x" $a]}
    if {[lsearch -exact $::sm_seen $line] < 0} {
        lappend ::sm_seen $line
        puts $::sm_log $line; flush $::sm_log
    }
    reg BC $env(NES2MSX_NOP)
    reg A [debug read memory $env(NES2MSX_CURBANK)]
    reg PC $env(NES2MSX_HIT2)
}
reverse loadreplay $env(NES2MSX_REPLAY)
debug set_bp $env(NES2MSX_MISS) {} {sm_miss}
set ::nes2msx_end [dict get [reverse status] end]
after time [expr {$::nes2msx_end + 2}] {
    puts stderr [format "softmiss: replay done (%.1f s), [llength $::sm_seen] targets" $::nes2msx_end]
    close $::sm_log
    exit
}
