# Break on given addresses; log registers, stack and slot/mapper state, then exit.
set out $env(NES2MSX_OUT)
set throttle off
set log [open "$out/debug.txt" w]
proc hexdump {addr len} {
    set s ""
    binary scan [debug read_block memory $addr $len] c* bytes
    foreach b $bytes { append s [format "%02X " [expr {$b & 0xFF}]] }
    return $s
}
proc report {tag} {
    global log out
    puts $log "== $tag pc=[format %04X [reg pc]] sp=[format %04X [reg sp]] af=[format %04X [reg af]] bc=[format %04X [reg bc]] de=[format %04X [reg de]] hl=[format %04X [reg hl]]"
    set sp [reg sp]
    set n [expr {0x10000 - $sp}]; if {$n > 24} {set n 24}
    puts $log "stack: [hexdump $sp $n]"
    puts $log "below: [hexdump 0xFFB0 0x40]"
    puts $log "A8=[format %02X [debug read ioports 0xA8]] mapper=[debug read {Main RAM regs} 0] [debug read {Main RAM regs} 1] [debug read {Main RAM regs} 2] [debug read {Main RAM regs} 3]"
    puts $log "0000: [hexdump 0 8]  0038: [hexdump 0x38 4]  0100: [hexdump 0x100 16]"
    flush $log
}
foreach a $env(NES2MSX_BP) {
    debug set_bp $a 1 "report bp_$a; close \$log; exit"
}
after time $env(NES2MSX_SECS) { report timeout; close $log; exit }
