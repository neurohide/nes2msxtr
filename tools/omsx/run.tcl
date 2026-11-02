# openMSX test driver: run, then dump NES RAM / V9990 state and a screenshot.
# env: NES2MSX_OUT (output dir), NES2MSX_SECS (emulated seconds before dump),
#      NES2MSX_PLAY (1: press Start, then run right, jump and fire; 2: press
#      Start every 4 s up to 40 s, for games with an intro and menus, then
#      walk right (now and then up or down too, for paths that turn) and
#      fire, pressing Start again when the sprites stand still for 3 s: a
#      press that paused the game),
#      NES2MSX_POKE ("addr=val,..." hex: NES RAM bytes kept at those values,
#      e.g. lives or the level number, so scripted play gets further)
set out $env(NES2MSX_OUT)
set secs $env(NES2MSX_SECS)
set throttle off
if {[info exists env(NES2MSX_POKE)] && $env(NES2MSX_POKE) ne ""} {
    set ::nes2msx_pokes {}
    foreach p [split $env(NES2MSX_POKE) ","] {
        lassign [split $p "="] a v
        lappend ::nes2msx_pokes [expr {0xC000 + ([scan $a %x] & 0x7FF)}] [scan $v %x]
    }
    proc nes2msx_poke {} {
        foreach {a v} $::nes2msx_pokes { debug write memory $a $v }
        after time 0.1 nes2msx_poke
    }
    after time 1 nes2msx_poke
}
if {[info exists env(NES2MSX_PLAY)] && $env(NES2MSX_PLAY) == 2} {
    for {set t 8.0} {$t <= 40} {set t [expr {$t + 4}]} {
        after time $t { keymatrixdown 7 0x80 }
        after time [expr {$t + 0.3}] { keymatrixup 7 0x80 }
    }
    after time 44.0 { keymatrixdown 8 0x80 }
    for {set t 44.5} {$t < $secs} {set t [expr {$t + 0.7}]} {
        after time $t { keymatrixdown 5 0x20 }
        after time [expr {$t + 0.2}] { keymatrixup 5 0x20 }
    }
    # paths that turn: up for 1.5 s every 6 s, down every 12 s
    for {set t 47.0} {$t < $secs} {set t [expr {$t + 6}]} {
        set k [expr {int($t) % 12 == 5 ? 0x40 : 0x20}]
        after time $t "keymatrixdown 8 $k"
        after time [expr {$t + 1.5}] "keymatrixup 8 $k"
    }
    # a Start press that landed in the game paused it: when the sprites
    # stop moving for 3 s, press Start once more
    set ::nes2msx_still 0
    set ::nes2msx_sig ""
    proc nes2msx_unpause {} {
        set pos {}
        foreach {y t a x} [split [debug read_block memory 0xD000 256] ""] {
            if {[scan $y %c] < 0xEF} { lappend pos "[scan $y %c],[scan $x %c]" }
        }
        set sig [lsort $pos]
        if {$sig eq $::nes2msx_sig} { incr ::nes2msx_still } else { set ::nes2msx_still 0 }
        set ::nes2msx_sig $sig
        if {$::nes2msx_still >= 3} {
            set ::nes2msx_still 0
            keymatrixdown 7 0x80
            after time 0.3 { keymatrixup 7 0x80 }
        }
        after time 1 nes2msx_unpause
    }
    after time 46 nes2msx_unpause
} elseif {[info exists env(NES2MSX_PLAY)] && $env(NES2MSX_PLAY)} {
    foreach t {8.0 9.5} {
        after time $t { keymatrixdown 7 0x80 }
        after time [expr {$t + 0.3}] { keymatrixup 7 0x80 }
    }
    after time 12.0 { keymatrixdown 8 0x80 }
    for {set t 12.5} {$t < $secs} {set t [expr {$t + 0.9}]} {
        after time $t { keymatrixdown 5 0x80 }
        after time [expr {$t + 0.45}] { keymatrixup 5 0x80 }
        after time [expr {$t + 0.2}] { keymatrixdown 5 0x20 }
        after time [expr {$t + 0.4}] { keymatrixup 5 0x20 }
    }
}
proc dumpblk {debuggable addr len file} {
    set f [open $file w]
    fconfigure $f -translation binary
    puts -nonewline $f [debug read_block $debuggable $addr $len]
    close $f
}
after time $secs {
    dumpblk memory 0xC000 0x800 "$out/msx_ram.bin"
    dumpblk memory 0xD100 0x100 "$out/msx_vars.bin"
    dumpblk {PSG regs} 0 16 "$out/psg_regs.bin"
    set f [open "$out/cpu.txt" w]
    puts $f "pc=[reg pc] sp=[reg sp] a=[reg a] bc=[reg bc] de=[reg de] hl=[reg hl]"
    puts $f "debuggables: [debug list]"
    close $f
    dumpblk {Sunrise GFX9000 VRAM} 0 0x80000 "$out/v9990_vram.bin"
    catch { dumpblk {Main RAM} 0 [debug size {Main RAM}] "$out/mapper_ram.bin" }
    dumpblk {Sunrise GFX9000 palette} 0 [debug size {Sunrise GFX9000 palette}] "$out/v9990_pal.bin"
    dumpblk {Sunrise GFX9000 regs} 0 [debug size {Sunrise GFX9000 regs}] "$out/v9990_regs.bin"
    set f [open "$out/video.txt" w]
    catch { puts $f "videosource values: [set videosource]" } e1
    puts $f "set: [catch {set videosource GFX9000} e2] $e2"
    puts $f "now: [set videosource]"
    close $f
    after time 0.2 {
        catch { screenshot "$out/screen.png" }
        exit
    }
}
