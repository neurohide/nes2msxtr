# Who jumps to a bad address? Replay a crash and log the last dyn_find calls
# (NES target HL, Z80 caller), then the 6502 stack, when HL == env(WHO_ADDR)
# or the runtime stops (NES2MSX_CRASH).
# env: NES2MSX_REPLAY, WHO_FIND (dyn_find address), WHO_ADDR, WHO_S6 (s6_ptr label), WHO_BANK (nes_bank label), WHO_IL (il label: log the interpreter PC), WHO_WADDR + WHO_WCOND (watch one address, with a condition on $wp_last_value), WHO_TMIN (notes only after this emulated time), WHO_BELOW (note only while s6 low byte is below this) + WHO_NFIRST (keep the first N notes), WHO_DUMPAT (dump the rings at this emulated time), WHO_WFIRST (keep the first N watch hits, not the last 12), WHO_WVAL (log writes of this value to the 6502 stack page), WHO_CURBANK, WHO_NOTE ("name addr ..." extra breakpoints noted in the ring)
set throttle off
proc nes2msx_hex {addr len} {
    set s ""
    if {$addr + $len > 0x10000} { set len [expr {0x10000 - $addr}] }
    binary scan [debug read_block memory $addr $len] c* bytes
    foreach b $bytes { append s [format "%02X " [expr {$b & 0xFF}]] }
    return $s
}
set ring {}
set iring {}
proc ilhit {} {
    global iring
    lappend iring [format %04X [reg iy]]
    if {[llength $iring] > 40} { set iring [lrange $iring 1 end] }
}
proc hit {} {
    global ring iring env
    set hl [expr {[reg hl]}]
    set caller [expr {[debug read memory [reg sp]] | ([debug read memory [expr {[reg sp] + 1}]] << 8)}]
    lappend ring [format "target=%04X caller_z80=%04X nes_bank=%d z80=%s s6=%02X: %s" $hl $caller [debug read memory $env(WHO_BANK)] [nes2msx_hex [expr {[reg sp] + 2}] 8] [debug read memory $env(WHO_S6)] [nes2msx_hex [expr {[debug read memory $env(WHO_S6)] | ([debug read memory [expr {$env(WHO_S6)+1}]] << 8)}] 10]]
    if {[llength $ring] > 40} { set ring [lrange $ring 1 end] }
    if {$hl == $env(WHO_ADDR)} dump
}
proc dump {} {
    global ring iring env
    if 1 {
        puts stderr "whomiss: last dyn_find calls (oldest first):"
        foreach r $ring { puts stderr "  $r" }
        set s6 [debug read memory $env(WHO_S6)]
        foreach w $::wring { puts stderr $w }
        foreach w $::nring { puts stderr $w }
        puts stderr "  interpreter PCs (oldest first): $iring"
        puts stderr [format "  6502 SP=\$%02X A=%02X X=%02X Y=%02X" $s6 [expr {[reg a]}] [expr {[reg c]}] [expr {[reg e]}]]
        puts stderr "  6502 stack: [nes2msx_hex [expr {0xC100 + $s6}] 16]"
        puts stderr "  z80 stack: [nes2msx_hex [reg sp] 24]"
        puts stderr "  NES RAM 0000: [nes2msx_hex 0xC000 16]"
        puts stderr "  NES RAM 0160: [nes2msx_hex 0xC160 32]"
        exit
    }
}
set ::nring {}
proc note {what} {
    global env
    set s6 [expr {[debug read memory $env(WHO_S6)] | ([debug read memory [expr {$env(WHO_S6) + 1}]] << 8)}]
    if {[info exists env(WHO_TMIN)] && [machine_info time] < $env(WHO_TMIN)} return
    if {[info exists env(WHO_BELOW)] && ($s6 & 0xFF) >= $env(WHO_BELOW)} return
    if {[info exists env(WHO_NFIRST)] && [llength $::nring] >= $env(WHO_NFIRST)} return
    set e ""
    if {[info exists env(WHO_ENG)]} { set e " eng_s6: [nes2msx_hex $env(WHO_ENG) 18]" }
    lappend ::nring [format "  %s t=%.2f sp=%04X s6_ptr=%04X z80stack: %s%s" $what [machine_info time] [reg sp] $s6 [nes2msx_hex [reg sp] 8] $e]
    if {[llength $::nring] > 2000} { set ::nring [lrange $::nring 1 end] }
}
if {[info exists env(WHO_NOTE)]} {
    foreach {n a} $env(WHO_NOTE) { debug set_bp $a {} "note $n" }
}
debug set_bp $env(WHO_FIND) {} hit
if {[info exists env(WHO_IL)]} { debug set_bp $env(WHO_IL) {} ilhit }
debug set_bp $env(NES2MSX_CRASH) {} dump
set ::wring {}
proc wnote {} {
    global env
    if {[info exists env(WHO_WFIRST)] && [llength $::wring] >= $env(WHO_WFIRST)} return
    lappend ::wring [format "  WRITE %04X<-%02X pc=%04X cur_bank=%d s6=%02X z80: %s" $::wp_last_address $::wp_last_value [reg pc] [debug read memory $env(WHO_CURBANK)] [debug read memory $env(WHO_S6)] [nes2msx_hex [reg sp] 8]]
    if {![info exists env(WHO_WFIRST)] && [llength $::wring] > 12} { set ::wring [lrange $::wring 1 end] }
}
if {[info exists env(WHO_WADDR)]} {
    debug set_watchpoint write_mem $env(WHO_WADDR) $env(WHO_WCOND) wnote
}
if {[info exists env(WHO_WVAL)]} {
    debug set_watchpoint write_mem {0xC100 0xC1FF} "\$::wp_last_value == $env(WHO_WVAL)" wnote
}
if {[info exists env(WHO_SAMPLE)]} {
    proc sample {} {
        global env
        puts stderr [format "sample t=%.1f s6=%02X" [machine_info time] [debug read memory $env(WHO_S6)]]
        after time $env(WHO_SAMPLE) sample
    }
    after time $env(WHO_SAMPLE) sample
}
if {[info exists env(WHO_DUMPAT)]} { after time $env(WHO_DUMPAT) dump }
# a replay (NES2MSX_REPLAY), else a live scripted run (run.tcl: NES2MSX_PLAY, NES2MSX_SECS)
if {[info exists env(NES2MSX_REPLAY)]} {
    reverse loadreplay $env(NES2MSX_REPLAY)
    after time 600 { puts stderr "replay: target never seen"; exit }
} else {
    source [file join [file dirname [info script]] run.tcl]
}
