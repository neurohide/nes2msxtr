# openMSX profiling driver: plays the cartridge with scripted input and
# counts every cross-bank call (caller bank, target bank, target). Jumps are
# left out: most are jump-table dispatches, which a copy can't shorten.
# env: NES2MSX_OUT (output dir), NES2MSX_SECS (emulated seconds),
#      NES2MSX_FC (far_call address), NES2MSX_CURBANK (cur_bank address)
set out $env(NES2MSX_OUT)
set secs $env(NES2MSX_SECS)
set throttle off
array set ::hits {}
proc hit {} {
    set k "[debug read memory $::curbank] [reg a] [reg hl]"
    if {[info exists ::hits($k)]} { incr ::hits($k) } else { set ::hits($k) 1 }
}
set ::curbank $env(NES2MSX_CURBANK)
# Input: Start after boot, then run right and jump now and then.
after time 8.0 { keymatrixdown 7 0x80 }
after time 8.3 { keymatrixup 7 0x80 }
after time 11.0 { keymatrixdown 8 0x80 }
for {set t 11.5} {$t < $secs} {set t [expr {$t + 0.9}]} {
    after time $t { keymatrixdown 5 0x80 }
    after time [expr {$t + 0.45}] { keymatrixup 5 0x80 }
}
after time 8.0 {
    debug set_bp $env(NES2MSX_FC) {} hit
}
after time $secs {
    set f [open "$out/profile_raw.txt" w]
    foreach k [array names ::hits] { puts $f "$::hits($k) $k" }
    close $f
    exit
}
