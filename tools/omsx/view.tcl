# Interactive run: show the GFX9000 output once the V9990 is producing video,
# and record the session (openMSX reverse) so a crash can be replayed.
#
# env: NES2MSX_OUT (build dir), NES2MSX_CRASH, NES2MSX_BADADDR, NES2MSX_BADBANK,
#      NES2MSX_CURBANK (label addresses from game.lbl). On a crash the replay, a copy of the
#      cartridge and a report go to NES2MSX_OUT/crash-<n>.*; F11 saves the
#      same at any moment.
proc nes2msx_show_v9990 {} {
    if {[catch {set ::videosource GFX9000}]} { after time 0.5 nes2msx_show_v9990 }
}
after time 1 nes2msx_show_v9990

proc nes2msx_hex {addr len} {
    set s ""
    if {$addr + $len > 0x10000} { set len [expr {0x10000 - $addr}] }
    binary scan [debug read_block memory $addr $len] c* bytes
    foreach b $bytes { append s [format "%02X " [expr {$b & 0xFF}]] }
    return $s
}

# Report + replay + cartridge copy as crash-<n>.*, the first unused n.
proc nes2msx_save {why} {
    global env
    set out $env(NES2MSX_OUT)
    set n 1
    while {[file exists "$out/crash-$n.txt"]} { incr n }
    set base "$out/crash-$n"
    set bad $env(NES2MSX_BADADDR)
    set f [open "$base.txt" w]
    puts $f "reason:   $why"
    puts $f [format "time:     %.3f s emulated" [machine_info time]]
    puts $f [format "pc=%04X sp=%04X af=%04X bc=%04X de=%04X hl=%04X" \
        [reg pc] [reg sp] [reg af] [reg bc] [reg de] [reg hl]]
    puts $f "code bank: [debug read memory $env(NES2MSX_CURBANK)]"
    set addr [expr {[debug read memory $bad] | ([debug read memory [expr {$bad + 1}]] << 8)}]
    set bank [debug read memory $env(NES2MSX_BADBANK)]
    puts $f [format "bad_addr: \$%04X, bank %d (NES address of an unknown jump target)" $addr $bank]
    if {$addr != 0} { nes2msx_entry $addr $bank }
    puts $f "stack:    [nes2msx_hex [reg sp] 32]"
    puts $f "NES RAM \$0000: [nes2msx_hex 0xC000 32]"
    close $f
    catch { file copy -force $env(NES2MSX_ROM) "$base.rom" }
    catch { file copy -force "$out/game.lbl" "$base.lbl" }
    if {[catch { reverse savereplay "$base.omr" } err]} {
        message "nes2msxtr: could not save the replay: $err"
    } else {
        message "nes2msxtr: $why - saved $base.omr (+ .txt, .rom, .lbl)"
    }
}

# An unknown computed-jump target: entries.txt makes the next build trace it.
proc nes2msx_entry {addr bank} {
    global env
    set line [format "%s %04x" [expr {$addr >= 0x8000 && $addr < 0xC000 ? [format %x $bank] : "-"}] $addr]
    set file "$env(NES2MSX_OUT)/entries.txt"
    if {[file exists $file]} {
        set f [open $file r]; set old [split [read $f] "\n"]; close $f
        if {[lsearch -exact $old $line] >= 0} return
    }
    set f [open $file a]; puts $f $line; close $f
    message "nes2msxtr: added $line to entries.txt - rebuild to trace it"
}

set ::nes2msx_crashed 0
proc nes2msx_crash {why} {
    if {$::nes2msx_crashed} return
    set ::nes2msx_crashed 1
    nes2msx_save $why
}

if {[info exists env(NES2MSX_OUT)]} {
    reverse start
    bind F11 {nes2msx_save "saved with F11"}
    # Address 0 is the BIOS reset at power-on; arm that check once running.
    after time 3 {
        debug set_bp $env(NES2MSX_CRASH) {} {nes2msx_crash "runtime stop (crash)"}
        debug set_bp 0x0000 {} {nes2msx_crash "jump to \$0000 (bad return or jump)"}
    }
}
