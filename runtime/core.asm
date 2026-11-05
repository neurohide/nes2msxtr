; nes2msxtr runtime core (runs from page-3 RAM).

; ---------------------------------------------------------------------------
; Second-stage boot. BIOS is still in page 0 and the cartridge in page 1;
; boot_init has switched to the R800 already.
boot2:
        di
        call v9990_detect
        jp nz, no_v9990
if SPLASH
        call splash_show
endif

        call ram_find           ; the memory mapper to run from
        jp c, no_ram
if MMC3_CHR
        in a, (PPI_SLOT)        ; the cartridge (page 1 now): CHR ROM is read
        rrca                    ; from it when banks switch
        rrca
        and 3
        ld (cart_p), a
        ld hl, p3_slot
        cp (hl)
        jr nz, boot_cart        ; another primary slot: its expander stays put
        ld a, (p3_slot + 1)
        cp $FF
        jr z, boot_cart
        ld a, ($FFFF)
        cpl
        rrca
        rrca
        and 3
        ld (cart_s), a
boot_cart:
endif

        ld b, 2                 ; page 2 -> RAM, copy ROM banks into segments
        call set_page_ram
        ld b, 0
boot_copy:
        ld a, b
        inc a
        ld (ASCII16_P1), a
        ld a, b
        add a, SEG_BASE
        out (MAP_P2), a
        push bc
        ld hl, $4000
        ld de, $8000
        ld bc, $4000
        ldir
        pop bc
        inc b
        ld a, b
        cp NSEGS
        jr nz, boot_copy

        call v9990_init         ; also uploads the BG patterns from ROM
        call psg_init
        xor a                   ; MSX VDP: display and interrupts off
        out ($99), a
        ld a, $81
        out ($99), a
        xor a
        out ($99), a
        ld a, $80
        out ($99), a
        in a, ($99)

        ld hl, NES_RAM          ; clear NES RAM, PPU and APU state
        ld de, NES_RAM + 1
        ld bc, RUNTIME - NES_RAM - 1
        ld (hl), 0
        ldir
        call boot_init_state

        ; pages 0 and 1 -> RAM (code bank 0), page 2 -> PRG data
        ld a, SEG_BASE
        out (MAP_P0), a
        inc a
        out (MAP_P1), a
        ld b, 0
        call set_page_ram
        ld b, 1
        call set_page_ram
        ld a, DSEG_PRG0
        ld (win_seg), a
        out (MAP_P2), a

        ld sp, STACK_TOP
        im 1
        ld bc, 0                ; X = 0, B = 0 invariant
        ld de, 0
        xor a
        ld (cur_bank), a
        ld a, RESET_BANK
        call set_bank
        ei
        jp go_reset

; Initial state after the RAM clear.
boot_init_state:
        ld hl, SC_THI           ; empty sprite pattern cache ($FF is no key)
        ld de, SC_THI + 1
        ld bc, $FF
        ld (hl), $FF
        ldir
        ld hl, SC_STAMP
        ld de, SC_STAMP + 1
        ld bc, $FF
        ld (hl), 0
        ldir
        ld hl, spr_lut_src      ; sprite palette expansion tables
        ld de, SPR_LUT
        ld bc, $400
        ldir
        ld hl, NES_RAM + $1FD   ; 6502 S = $FD, I set, as after a NES reset
        ld (s6_ptr), hl
        ld hl, BSTK_TOP
        ld (bstk), hl
        ld a, 4
        ld (p_id), a
        ld a, $01
        ld (r9_val), a
        ld a, MIRROR_V
        ld (mir_v), a
        ld a, 8                 ; no idle point seen yet
        ld (idle_age), a
        ld a, $B8
        ld (psg_mix), a
        ld a, $80
        ld (pad_shift), a
        ld a, 1                 ; pulse 1 negates in ones' complement
        ld (APU + $20 + 6), a
        ret

; B = page (0-2): select the memory mapper ram_find chose there.
set_page_ram:
        ld hl, (map_slot)

; B = page (0-2), L = primary slot, H = sub-slot ($FF: not expanded). The
; sub-slot register at $FFFF is only reachable for page 3's own primary
; slot; ram_find only picks such slots. Preserves HL, B.
set_page_slot:
        ld a, b
        add a, a
        ld c, a                 ; shift = 2 * page
        ld a, 3
        call shl_c
        cpl
        ld e, a                 ; keep mask
        ld a, h
        cp $FF
        jr z, sps_p
        call shl_c
        ld d, a
        ld a, ($FFFF)
        cpl
        and e
        or d
        ld ($FFFF), a
sps_p:  ld a, l
        call shl_c
        ld d, a
        in a, (PPI_SLOT)
        and e
        or d
        out (PPI_SLOT), a
        ret

; Find the memory mapper to run from: page 3's own when it has the
; RAM_SEGS segments the game needs (segments 0..SEG_BASE-1 stay the
; system's), else the largest other one that has them, a RAM expansion.
; Slots behind another primary slot's expander can't be switched from page
; 3 and aren't looked at. Carry: none is big enough.
ram_find:
        in a, (PPI_SLOT)
        rlca
        rlca
        and 3
        ld l, a
        ld h, $FF
        call exp_of
        jr z, rf_p3
        ld a, ($FFFF)
        cpl
        rlca
        rlca
        and 3
        ld h, a
rf_p3:  ld (p3_slot), hl
        ld (map_slot), hl
        call rf_size
        cp RAM_SEGS
        ret nc                  ; enough in the machine's own RAM
        xor a
        ld (rf_best), a
        ld l, 0
rf_pl:  ld a, l
        call exp_of
        jr nz, rf_ex
        ld a, (p3_slot)
        cp l
        jr z, rf_np             ; page 3's, done
        ld h, $FF
        call rf_try
        jr rf_np
rf_ex:  ld a, (p3_slot)
        cp l
        jr nz, rf_np
        ld h, 0
rf_sl:  ld a, (p3_slot + 1)
        cp h
        call nz, rf_try
        inc h
        ld a, h
        cp 4
        jr nz, rf_sl
rf_np:  inc l
        ld a, l
        cp 4
        jr nz, rf_pl
        ld a, (rf_best)
        cp RAM_SEGS
        ret
; HL = slot: keep it if its mapper is the largest so far
rf_try: call rf_size
        ld e, a
        ld a, (rf_best)
        cp e
        ret nc
        ld a, e
        ld (rf_best), a
        ld (map_slot), hl
        ret

; A = primary slot -> NZ if expanded. Preserves HL.
exp_of: push hl
        ld e, a
        ld d, 0
        ld hl, EXPTBL
        add hl, de
        ld a, (hl)
        pop hl
        and $80
        ret

; HL = slot -> A = memory mapper segments seen at page 2 there (0: no RAM),
; at most 255: a marker in byte 0 of each segment, written from the top so
; mirrored segments keep the lowest number. Only byte 0 of a segment is
; touched ($C000 in page 3: NES RAM, cleared later). Preserves HL.
rf_size:
        ld b, 2
        call set_page_slot
        ld b, 0
rfs_w:  dec b
        ld a, b
        out (MAP_P2), a
        ld ($8000), a
        or a
        jr nz, rfs_w
rfs_r:  ld a, b
        out (MAP_P2), a
        ld a, ($8000)
        cp b
        jr nz, rfs_end
        inc b
        jr nz, rfs_r
        dec b
rfs_end:
        ld a, b
        ret

map_slot:   dw 0                ; memory mapper slot: primary, sub ($FF: none)
p3_slot:    dw 0                ; page 3's slot
rf_best:    db 0

; A <<= C (C may be 0)
shl_c:
        inc c
        dec c
        ret z
        push bc
        ld b, c
shl_c_l:
        add a, a
        djnz shl_c_l
        pop bc
        ret

no_v9990:
        ld hl, msg_no_v9990
nv_l:   ld a, (hl)
        or a
        jr z, nv_halt
        call CHPUT
        inc hl
        jr nv_l
nv_halt:
        ei
        jr nv_halt
msg_no_v9990:
        db "This cartridge needs a V9990", 13, 10
        db "(GFX9000) at I/O port $60.", 13, 10, 0
no_ram:
        ld hl, msg_no_ram       ; in tables.asm: the size needed
        jr nv_l

; ---------------------------------------------------------------------------
; V9990

; Z set when a V9990 answers at port $60.
v9990_detect:
        ld a, $07
        ld hl, $FFF0
        call vwaddr
        ld a, $A5
        out (V_VRAM), a
        ld a, 3
        out (V_REGS), a
        ld a, $F0
        out (V_REGD), a
        ld a, $FF
        out (V_REGD), a
        ld a, $07
        out (V_REGD), a
        in a, (V_VRAM)
        cp $A5
        ret

; Set VRAM write address: A = bits 18-16, HL = bits 15-0. Interrupts off.
vwaddr:
        push af
        xor a
        out (V_REGS), a
        ld a, l
        out (V_REGD), a
        ld a, h
        out (V_REGD), a
        pop af
        out (V_REGD), a
        ret

; Write V9990 register: A = value, register number in C. Interrupts off.
vreg:
        push af
        ld a, c
        out (V_REGS), a
        pop af
        out (V_REGD), a
        ret

; Fill VRAM: A = bits 18-16, HL = addr, DE = count, value in (vfill_val)
vfill:
        call vwaddr
vfill_l:
        ld a, (vfill_val)
        out (V_VRAM), a
        dec de
        ld a, d
        or e
        jr nz, vfill_l
        ret
vfill_val:
        db 0

v9990_init:
        xor a
        out (V_SYS), a          ; XTAL clock, no reset
        ld hl, v9990_regs
        call vreg_list
        xor a
        ld (vfill_val), a
        ld a, VR_SPRPAT_HI      ; sprite patterns $20000-$27FFF (all 256: the
        ld hl, $0000            ; right half of each stays transparent)
        ld de, $8000
        call vfill
        ld a, $07               ; name tables A and B
        ld hl, $C000
        ld de, $4000
        call vfill
        ld a, $04               ; layer B pattern 0
        ld hl, $0000
        ld de, $0400
        call vfill
        ld a, $03               ; sprite attribute table: all disabled
        ld hl, $FE00
        call vwaddr
        ld b, 128
vi_sat: xor a
        out (V_VRAM), a
        out (V_VRAM), a
        out (V_VRAM), a
        ld a, $10
        out (V_VRAM), a
        djnz vi_sat
        ld a, 14                ; palette: all black
        out (V_REGS), a
        xor a
        out (V_REGD), a
        ld b, 192
vi_pal: out (V_PAL), a
        djnz vi_pal

        xor a                   ; background patterns from ROM -> $00000
        ld hl, 0
        call vwaddr
        ld a, BG_BANK
vi_bg:  ld (ASCII16_P1), a
        push af
        ld hl, $4000
        ld c, V_VRAM
        ld d, 64
vi_bgl: ld b, 0
        otir
        dec d
        jr nz, vi_bgl
        pop af
        inc a
        cp BG_BANK + 4
        jr nz, vi_bg
        ld a, $07               ; clear any pending interrupt flags
        out (V_INT), a
        ret

; Write the register, value pairs at HL ($FF ends).
vreg_list:
        ld a, (hl)
        cp $FF
        ret z
        inc hl
        ld c, a
        ld a, (hl)
        inc hl
        call vreg
        jr vreg_list

if SPLASH
; Boot picture from ROM (SPLASH_BANK, 2 banks: B1 bitmap, then palette at
; $6A00 of the second) shown for 3 seconds. v9990_init sets P1 mode again.
splash_show:
        xor a
        out (V_SYS), a
        ld hl, splash_regs
        call vreg_list
        xor a                   ; 212 lines x 128 bytes -> $00000
        ld hl, 0
        call vwaddr
        ld a, SPLASH_BANK
        ld (ASCII16_P1), a
        ld hl, $4000
        ld c, V_VRAM
        ld d, 64
ss_a:   ld b, 0
        otir
        dec d
        jr nz, ss_a
        ld a, SPLASH_BANK + 1
        ld (ASCII16_P1), a
        ld hl, $4000
        ld d, $2A
ss_b:   ld b, 0
        otir
        dec d
        jr nz, ss_b
        ld a, 14                ; palette 0-15
        out (V_REGS), a
        xor a
        out (V_REGD), a
        ld b, 48
        ld c, V_PAL
        otir
        ld a, $C2               ; display on, no cursors
        ld c, 8
        call vreg
        ld hl, 180              ; 3 s of frames
ss_w0:  in a, (V_STAT)          ; end of the vertical retrace
        and $40
        jr nz, ss_w0
ss_w1:  in a, (V_STAT)          ; start of the next one
        and $40
        jr z, ss_w1
        dec hl
        ld a, h
        or l
        jr nz, ss_w0
        ld a, $02               ; display off
        ld c, 8
        jp vreg

splash_regs:
        db 8, $02               ; display off while loading
        db 6, $81               ; B1: bitmap, 256 wide, 4 bpp
        db 7, $00               ; NTSC, non-interlaced
        db 9, $00               ; no interrupts
        db 13, $00              ; palette 0-15
        db 15, $00              ; backdrop = colour 0
        db 17, 0, 18, 0, 19, 0, 20, 0
        db $FF
endif

; register, value pairs; $FF ends
v9990_regs:
        db 6, $05               ; P1 mode
        db 7, $00               ; NTSC, non-interlaced
        db 8, $02               ; display off until the game enables it
        db 9, $01               ; vertical interrupt on
        db 13, $00              ; palette mode, layer A/B offset 0
        db 15, $00              ; backdrop = palette 0
        db 16, $00
        db 17, 0, 18, 0, 19, 0, 20, 0, 21, 0, 22, 0, 23, 0, 24, 0
        db 25, $08              ; sprite patterns at $20000
        db 27, $00, 28, $00
        db $FF

; ---------------------------------------------------------------------------
; Code banks

; A = bank. Maps it into pages 0-1.
set_bank:
        ld (cur_bank), a
        add a, a
        add a, SEG_BASE
        out (MAP_P0), a
        inc a
        out (MAP_P1), a
        ret

; Far jump from translated code: 6502 A/F are in AF', A = bank, HL = target.
; The routine now continues in another bank, so a plain return frame (one
; that returns into the bank being left) is routed through xret.
far_jump:
        di                      ; fc_tgt / fj_bank must survive the NMI
        ld (fc_tgt), hl
        ld (fj_bank), a
        ld hl, 0
        add hl, sp
        ld a, l
        cp STACK_TOP & $FF
        jr nz, fj_frame
        ld a, h
        cp STACK_TOP >> 8
        jr z, fj_go             ; top level: no return frame
fj_frame:
        ld a, (hl)
        cp xret & $FF
        jr nz, fj_plain
        inc hl
        ld a, (hl)
        cp xret >> 8
        jr z, fj_go             ; already returns through xret
fj_plain:
        ld hl, (bstk)
        dec hl
        ld a, (cur_bank)
        ld (hl), a
        ld (bstk), hl
        ld hl, xret
        push hl
fj_go:  ld a, (fj_bank)
        call set_bank
        ld hl, (fc_tgt)
        ex af, af'
        ei                      ; game code always runs with interrupts on
        jp (hl)

; Multi-bank calls. A call within a bank is a plain CALL and RTS is a plain
; RET. A call into another bank goes through far_call, which keeps the
; caller's bank on the bank stack (bstk, one byte per frame, growing down
; from BSTK_TOP) and returns through xret, so the frame is [return][xret].
; far_call, far_jump, dyn_jump and drop_frame use fixed scratch variables
; that the NMI's own calls would overwrite, so they run with interrupts off.

; A = target bank, HL = target, return address on the stack; 6502 A/F in AF'.
far_call:
        di
        ld (fc_tgt), hl
        ld hl, (bstk)
        dec hl
        push af
        ld a, (cur_bank)
        ld (hl), a
        ld (bstk), hl
        pop af
        call set_bank
        ld hl, xret
        push hl
        ld hl, (fc_tgt)
        ex af, af'
        ei
        jp (hl)

; The callee returned: back to the caller's bank and return address.
xret:   ex af, af'
        ld hl, (bstk)
        ld a, (hl)
        inc hl
        ld (bstk), hl
        call set_bank
        ex af, af'
        ret

; PLA/PLA that drops the current return frame. If it was a cross-bank
; frame and the frame below returns into the caller's bank, that frame now
; needs the bank restored: the bank stack entry is kept and xret pushed.
drop_frame:
        di
        ex af, af'
        pop hl                  ; our own return address
        ld (fc_tgt), hl
        pop hl                  ; the frame
        ld a, h
        cp xret >> 8
        jr nz, df_done
        ld a, l
        cp xret & $FF
        jr nz, df_done
        pop hl                  ; cross-bank frame: drop its return address
        pop hl                  ; look at the frame below
        push hl
        ld a, h
        cp xret >> 8
        jr nz, df_plain
        ld a, l
        cp xret & $FF
        jr z, df_pop            ; below is cross-bank too: describes itself
df_plain:
        ld hl, (bstk)
        ld a, (cur_bank)
        cp (hl)
        jr z, df_pop            ; same bank: a plain RET will do
        ld hl, xret
        push hl
        jr df_done
df_pop: ld hl, (bstk)
        inc hl
        ld (bstk), hl
df_done:
        ld hl, (fc_tgt)
        ex af, af'
        ei
        jp (hl)

; An NMI handler that pulls its interrupt frame and RTS returns from the
; routine it interrupted, a loop waiting for the NMI. nmi_rts (that RTS,
; A = the handler's A) only notes it and returns to the isr; the wait loop,
; which the translator turns into a jump to spin_wait, then returns from
; its routine with that A. Carry is the interrupted code's.
nmi_rts:
        ld (unw_a), a
        ld a, 1
        ld (unw_pend), a
        ret
spin_wait:
        call idle_poll
        ld a, (unw_pend)
        inc a
        dec a
        jr z, spin_wait
        ld a, 0
        ld (unw_pend), a
        ld (poll_seen), a       ; leaves the wait
        ld a, (unw_a)
        ld d, a
        ret

; Idle points of the main loop: small loops that wait for the NMI (polling
; a RAM byte), as the translator marks them; idle_end is where they exit.
; A vblank while the main loop is busy (slower than the NES's) would run
; the NMI on a half-built frame: sprite buffer, CHR bank shadows, scroll.
; The isr holds it back instead (up to 8 frames), and it runs here, when
; the main loop waits, like a NES lag frame. Preserve all registers.
idle_poll:
        push af
        xor a
        ld (idle_age), a
        ld a, (nmi_pend)
        or a
        jr nz, nmi_late
        ld a, 1
        jr ie_st
idle_end:
        push af
        xor a
ie_st:  ld (poll_seen), a
        pop af
        ret

; The held-back NMIs, one per vblank missed, from the main loop (AF
; pushed): an isr frame like the vblank one, so int_run finds the
; interrupted registers.
nmi_late:
        ld a, 1
        ld (poll_seen), a
        pop af
        push af
        push bc
        push de
        push hl
        ex af, af'
        push af
        ex af, af'
        push ix
        push iy
        ld a, (win_seg)
        push af
        di
        ld (isr_sp), sp
nl_l:   call isr_nmi
        ld hl, nmi_pend
        dec (hl)
        jr nz, nl_l
        jp isr_exit

; JMP / JSR into NES RAM, HL = address: code the game built there, like a
; sound driver's STA $40xx / RTS. Only STA / STX / STY abs and RTS are
; run; anything else stops (bad_addr = where).
ram_jump:
        push af
        ld a, h
        and 7
        or $C0
        ld h, a
rj_op:  ld a, (hl)
        cp $60
        jr z, rj_rts
        cp $8C
        jr z, rj_sty
        cp $8E
        jr z, rj_stx
        cp $8D
        jr nz, rj_bad
        pop af
        push af
        jr rj_st
rj_stx: ld a, c
        jr rj_st
rj_sty: ld a, e
rj_st:  ld (wr_val), a
        inc hl
        ld a, (hl)
        inc hl
        push hl
        ld h, (hl)
        ld l, a
        call mem_wr_v
        pop hl
        inc hl
        jr rj_op
rj_rts: pop af
if FAITHFUL
        ld hl, s6_ptr
        inc (hl)
        inc (hl)
endif
        ret
rj_bad: ld a, h
        and 7
        ld h, a
        ld (bad_addr), hl
        jp crash

; JMP (ind) with a runtime target: HL = NES address.
dyn_jump:
        di                      ; dj_key must survive the NMI (far_jump: ei)
        ex af, af'
        call dyn_find
        jp far_jump

; JSR from the fixed bank into $8000-$BFFF: the routine of the bank mapped
; there now. HL = NES address; 6502 A/F are live.
dyn_call:
        di
        ex af, af'
        call dyn_find
        jp far_call

; HL = NES address -> A = code bank, HL = Z80 address. The lookup table
; (dyn.asm, in segment DSEG_DYN) groups entries by the low byte of the NES
; address and dyn_bkt holds where each group starts. An entry is the high
; byte, the switchable bank it was traced in (0 outside $8000-$BFFF; MMC3:
; the 8K bank of the slot the address is in), the
; Z80 address and the code bank. Preserves BC, DE. Interrupts off.
dyn_find:
        push bc
        push de
        ld (dj_key), hl
        ld e, 0                 ; E = bank key
        ld a, h
        and $C0
        cp $80
        jr nz, df_fixed
        ld a, (nes_bank)
if MMC3
        bit 5, h
        jr z, df_s0
        ld a, (nes_bank1)
df_s0:
endif
        ld e, a
df_fixed:
        ld d, h                 ; D = high byte
        ld a, (win_seg)
        push af
        ld a, DSEG_DYN
        ld (win_seg), a
        out (MAP_P2), a
        ld h, 0
        add hl, hl
        ld bc, dyn_bkt
        add hl, bc
        ld c, (hl)
        inc hl
        ld b, (hl)
        inc hl
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        push hl
        ld h, b
        ld l, c                 ; HL = first entry
        pop bc                  ; BC = end of the group
dj_l:   ld a, l
        cp c
        jr nz, dj_cmp
        ld a, h
        cp b
        jr z, dj_miss
dj_cmp: ld a, (hl)
        inc hl
        cp d
        jr nz, dj_nx
        ld a, (hl)
        cp e
        jr z, dj_hit
dj_nx:  inc hl
        inc hl
        inc hl
        inc hl
        jr dj_l
dj_hit: inc hl
        ld c, (hl)
        inc hl
        ld b, (hl)
        inc hl
        ld a, (hl)
dj_hit2: ld h, b       ; (softmiss.tcl resumes here)
        ld l, c
        ld (dj_key), a
        pop af
        ld (win_seg), a
        out (MAP_P2), a
        ld a, (dj_key)
        pop de
        pop bc
        ret
dj_miss:
        pop af
        ld (win_seg), a
        out (MAP_P2), a
        ld a, e
        ld (bad_bank), a
        ld hl, (dj_key)
        ld (bad_addr), hl
        jp crash

; RTS with two bytes pushed by the routine itself (PHA/PHA/RTS dispatch):
; pull the address and jump to it + 1.
rts_jump:
        ex af, af'
        push de
        ld hl, (s6_ptr)
        inc l
        ld e, (hl)
        inc l
        ld d, (hl)
        ld (s6_ptr), hl
        inc de
        ex de, hl
        pop de
        ex af, af'
        jp dyn_jump

; PHP: push N (D bit 7), V, B, I/D, Z (D = 0) and C as a 6502 status byte.
php_rt:
        push af
        ld l, 0
        rl l                    ; carry -> bit 0
        ld a, d
        or a
        jr nz, php_nz
        set 1, l
php_nz: bit 7, a
        jr z, php_pos
        set 7, l
php_pos:
        ld a, (vflag)
        or a
        jr z, php_nov
        set 6, l
php_nov:
        ld a, (p_id)
        or l
        or $30
        ld hl, (s6_ptr)
        dec l
        ld (s6_ptr), hl
        inc l
        ld (hl), a
        pop af
        ret

if MMC1
; BRK: counts the software interrupt (HL clobbered, A and flags kept).
brk_mark:
        ld hl, brk_n
        inc (hl)
        ld hl, brk_ctx
        push af
        ld a, (in_nmi)
        ld (hl), a
        pop af
        ret

; RTI. The one that ends a BRK handler (started from the same NMI state)
; jumps to the PC it pulls, which the handler may have moved on. Any other
; RTI (the NMI's) returns through the Z80 stack.
rti_rt:
        push af
        ld a, (brk_n)
        or a
        jr z, rti_ret
        ld a, (brk_ctx)
        ld hl, in_nmi
        cp (hl)
        jr nz, rti_ret
        ld hl, brk_n
        dec (hl)
        pop af
        call plp_rt             ; P (flags, A kept)
        push af
        push de
        ld hl, (s6_ptr)
        inc l
        ld e, (hl)
        inc l
        ld d, (hl)
        ld (s6_ptr), hl
        ex de, hl
        pop de
        pop af
        jp dyn_jump
rti_ret:
        pop af
        ld hl, s6_ptr
        inc (hl)
        inc (hl)
        inc (hl)
        ret
endif

; PLP: pull a 6502 status byte into carry, D (N/Z), vflag and p_id.
; Preserves A.
plp_rt:
        push af
        ld hl, (s6_ptr)
        inc l
        ld a, (hl)
        ld (s6_ptr), hl
        ld l, a
        and $0C
        ld (p_id), a
        ld a, l
        and $40
        ld (vflag), a
        ld d, 1
        bit 7, l
        jr z, plp_pos
        ld d, $80
plp_pos:
        bit 1, l
        jr z, plp_nz
        ld d, 0
plp_nz: pop af
        rr l                    ; bit 0 -> carry
        ret

; Unrecoverable: backdrop red, halt. bad_addr holds the NES address.
crash:
        di
        ld a, 14
        out (V_REGS), a
        xor a
        out (V_REGD), a
        ld a, 31
        out (V_PAL), a
        xor a
        out (V_PAL), a
        out (V_PAL), a
        ld a, $82
        ld c, 8
        call vreg
crash_l:
        halt
        jr crash_l

; ---------------------------------------------------------------------------
; Memory access helpers for addresses only known at run time.

; HL = NES address $8000-$FFFF -> L = byte. Preserves AF, BC, DE.
if MMC3
; MMC3: 8K banks R6 at $8000, R7 at $A000 (segment DSEG_PRG0 + bank / 2,
; upper half of the window if the bank is odd), the last 16K fixed.
rom_rd:
        ex af, af'
        bit 6, h
        jr nz, rr_fix
        bit 5, h
        jr nz, rr_s1
        ld a, h
        and $1F
rr_h0:  or $80                  ; operand: window half of R6's bank
        ld h, a
rr_s0:  ld a, DSEG_PRG0         ; operand: segment of R6's bank
        jr rr_cur
rr_s1:  ld a, h
        and $1F
rr_h1:  or $A0                  ; R7
        ld h, a
rr_g1:  ld a, DSEG_PRG0
        jr rr_cur
rr_fix: ld a, h
        and $3F
        or $80
        ld h, a
        ld a, DSEG_PRG1
rr_cur: cp 0                    ; operand is win_seg
        jr nz, rr_map
rr_ok:  ld l, (hl)
        ex af, af'
        ret
rr_map: ld (win_seg), a
        out (MAP_P2), a
        jr rr_ok
win_seg:    equ rr_cur + 1
prg_lo:     equ rr_s0 + 1
else
rom_rd:
        ex af, af'
        bit 6, h
        ld a, DSEG_PRG1         ; $C000-$FFFF
        jr nz, rr_cur
rr_lo:  ld a, DSEG_PRG0         ; $8000-$BFFF: operand is prg_lo
rr_cur: cp 0                    ; operand is win_seg
        jr nz, rr_map
rr_ok:  ld a, h
        and $3F
        or $80
        ld h, a
        ld l, (hl)
        ex af, af'
        ret
rr_map: ld (win_seg), a
        out (MAP_P2), a
        jr rr_ok
; The page-2 segment is kept as the operand of the compare above, so the
; hottest path (ROM reads) checks it without a memory access.
win_seg:    equ rr_cur + 1
; The segment of the bank mapped at $8000-$BFFF (UxROM: set by mapper_w)
prg_lo:     equ rr_lo + 1
endif

; HL = page-2 window address of PRG half 0 ($8000-$BFFF, the bank mapped
; there) / 1 -> L = byte. Preserves AF, BC, DE. For tables whose half the
; translator already knows.
rom_rd0:
        ex af, af'
        ld a, (win_seg)
rr0_cp: cp DSEG_PRG0            ; operand: copy of prg_lo
        jr nz, rr0_map
rr0_ok: ld l, (hl)
        ex af, af'
        ret
rr0_map:
        ld a, (prg_lo)
        ld (win_seg), a
        out (MAP_P2), a
        jr rr0_ok
rom_rd1:
        ex af, af'
        ld a, (win_seg)
        cp DSEG_PRG1
        jr nz, rr1_map
rr1_ok: ld l, (hl)
        ex af, af'
        ret
rr1_map:
        ld a, DSEG_PRG1
        ld (win_seg), a
        out (MAP_P2), a
        jr rr1_ok

; Write to ROM, L = value. UxROM: select the bank at $8000-$BFFF (the
; game avoids bus conflicts by writing the value the ROM holds there).
; Preserves AF, BC, DE.
mapper_w:
if UXROM + MMC1
        push af
        ld a, i                 ; atomic, as mm_8001
        jp pe, $+5              ; NMOS bug: an interrupt at LD A,I reads as DI
        ld a, i
        push af
        di
        ld a, l
        and PRG_MASK
        ld (nes_bank), a
        add a, DSEG_PRG0
        ld (prg_lo), a
        ld (rr0_cp + 1), a
        pop af
        jp po, mw_di
        ei
mw_di:  pop af
endif
        ret

if MMC1
; MMC1 serial port: H = NES address high byte, L = value. Bit 7 resets
; the shift register; the 5th write loads the register H selects. Only
; PRG mode 3 (16K at $8000, the last bank fixed) and CHR RAM / one 8K CHR
; ROM bank. Preserves AF, BC, DE.
m1_wr:
        push af
        ld a, i                 ; atomic, as mapper_w
        jp pe, $+5              ; NMOS bug: an interrupt at LD A,I reads as DI
        ld a, i
        push af
        di
        bit 7, l
        jr nz, m1_rst
        rr l                    ; bit 0 in at the top, 5 writes: bits 7-3
        ld a, (m1_sr)
        rra
        ld (m1_sr), a
        ld a, (m1_cnt)
        inc a
        ld (m1_cnt), a
        cp 5
        jr nz, m1_done
        ld a, (m1_sr)
        rrca
        rrca
        rrca
        and $1F
        ld l, a                 ; L = register value
        ld a, h                 ; address bits 14-13: the register
        rlca
        rlca
        rlca
        and 3
        jr z, m1_ctrl
        dec a
        jr z, m1_chr0
        dec a
        call nz, mapper_w       ; $E000: PRG bank ($C000: CHR bank 1, unused)
m1_rst: xor a
        ld (m1_cnt), a
        ld (m1_sr), a
m1_done:
        pop af
        jp po, m1_di
        ei
m1_di:  pop af
        ret
; Control: mirroring (one-screen modes are not supported). It applies
; to $2007 at once; the V9990 map is rebuilt at vblank.
m1_ctrl:
        ld a, l
        and 3
        cp 2
        jr c, m1_rst
        xor 3                   ; 2 vertical -> 1, 3 horizontal -> 0
        ld hl, mir_v
        cp (hl)
        jr z, m1_rst
        ld (hl), a
        ld a, 1
        ld (mir_dirty), a
        jr m1_rst
; CHR bank 0: on SOROM / SXROM also the PRG RAM bank
m1_chr0:
if WRAM_MASK
        ld a, l
        rrca
        rrca
if WRAM_SHIFT - 2
        rrca
endif
        and WRAM_MASK
        call wram_bank
endif
        jr m1_rst

m1_sr:      db 0                ; shift register (bits 7-3 after 5 writes)
m1_cnt:     db 0                ; writes so far
endif

if WRAM
; HL = NES address $6000-$7FFF -> L = byte of the PRG RAM bank mapped
; there. Preserves AF, BC, DE.
wram_rd:
        ex af, af'
        ld a, h
wr_hi:  xor $E0                 ; operand: $E0 / $C0, the bank's window half
        ld h, a
        ld a, (win_seg)
wr_sg:  cp DSEG_WRAM            ; operand: the bank's segment
        jr nz, wr_map
wr_ok:  ld l, (hl)
        ex af, af'
        ret
wr_map: ld a, (wr_sg + 1)
        ld (win_seg), a
        out (MAP_P2), a
        jr wr_ok

; HL = NES address $6000-$7FFF, value in A / C (X) / E (Y). Preserves
; AF, BC, DE.
wram_wa:
        push af
        jr ww_go
wram_wc:
        push af
        ld a, c
        jr ww_go
wram_we:
        push af
        ld a, e
ww_go:  push de
        ld e, a
        ld a, h
ww_hi:  xor $E0                 ; operand: as wr_hi
        ld h, a
        ld a, (win_seg)
ww_sg:  cp DSEG_WRAM            ; operand: as wr_sg
        jr nz, ww_map
ww_ok:  ld (hl), e
        pop de
        pop af
        ret
ww_map: ld a, (ww_sg + 1)
        ld (win_seg), a
        out (MAP_P2), a
        jr ww_ok

; A = 8K PRG RAM bank -> mapped at $6000-$7FFF. Clobbers AF, HL.
wram_bank:
        ld h, $E0
        srl a
        jr nc, wb_even
        ld h, $C0
wb_even:
        add a, DSEG_WRAM
        ld (wr_sg + 1), a
        ld (ww_sg + 1), a
        ld a, h
        ld (wr_hi + 1), a
        ld (ww_hi + 1), a
        ret
endif

if MMC3
; MMC3 register writes, L = value. Preserves AF, BC, DE.
mm_8000:
        push af
        ld a, (mm_sel)
        xor l
        ld a, l
        ld (mm_sel), a
        jp p, mm_pop            ; CHR inversion unchanged
        ld a, 1
        ld (chr_remap), a
mm_pop: pop af
mm_ret: ret

mm_8001:
        push af
        push de
        push hl
        ld a, i                 ; atomic: an interrupt must not see the bank
        jp pe, $+5              ; NMOS bug: an interrupt at LD A,I reads as DI
        ld a, i
        push af                 ; half switched (nes_bank1 vs rom_rd)
        di
        ld e, l                 ; E = value
        ld a, (mm_sel)
        and 7
        ld d, a                 ; D = register
        ld hl, mm_regs
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld a, d
        cp 6
        jr c, m1_chr
        ld (hl), e
        ld a, e
        and PRG_MASK
        bit 0, d
        jr nz, m1_r7
        ld (nes_bank), a
        call m1_seg
        ld (rr_s0 + 1), a
        ld a, e
        ld (rr_h0 + 1), a
        jr m1_done
m1_r7:  ld (nes_bank1), a
        call m1_seg
        ld (rr_g1 + 1), a
        ld a, e
        ld (rr_h1 + 1), a
        jr m1_done
m1_chr:
        ld (hl), e
if MMC3_CHR
        ld a, 1
        ld (chr_remap), a
endif
m1_done:
        pop af
        jp po, m1_di
        ei
m1_di:  pop hl
        pop de
        pop af
        ret
; A = 8K bank -> A = segment, E = window half ($80 / $A0)
m1_seg: ld e, $80
        srl a
        jr nc, m1_even
        ld e, $A0
m1_even:
        add a, DSEG_PRG0
        ret

; Mirroring applies to $2007 at once; the V9990 map is rebuilt at vblank.
mm_a000:
        push af
        push hl
        ld a, l
        and 1
        xor 1                   ; 1: vertical
        ld hl, mir_v
        cp (hl)
        jr z, ma_same
        ld (hl), a
        ld a, 1
        ld (mir_dirty), a
ma_same:
        pop hl
        pop af
        ret
mm_c000:
        push af
        ld a, l
        ld (irq_latch), a
        pop af
        ret
mm_c001:
        push af
        ld a, 1
        ld (irq_reload), a
        pop af
        ret
mm_e000:
        push af
        xor a
        ld (irq_en), a
        pop af
        ret
mm_e001:
        push af
        ld a, 1
        ld (irq_en), a
        pop af
        ret

; HL = NES address $8000-$FFFF, (wr_val) = value: the register it selects.
mapper_wa:
        push af
        push de
        ld a, h                 ; (address bits 14-13) * 2 + bit 0
        rlca
        rlca
        rlca
        and 3
        add a, a
        bit 0, l
        jr z, mwa_e
        inc a
mwa_e:  add a, a
        ld e, a
        ld d, 0
        ld hl, mm_tab
        add hl, de
        ld e, (hl)
        inc hl
        ld d, (hl)
        ex de, hl
        pop de
        pop af
        push hl                 ; -> handler with L = value
        ld hl, (wr_val)
        ret
mm_tab: dw mm_8000, mm_8001, mm_a000, mm_ret, mm_c000, mm_c001, mm_e000, mm_e001

mm_sel:     db 0                ; last $8000 write
mm_regs:    db 0, 2, 4, 5, 6, 7, 0, 1   ; R0-R7
irq_latch:  db 0
irq_reload: db 0
irq_en:     db 0
endif

; HL = any NES address -> L = byte. Preserves AF, BC, DE.
mem_rd:
        bit 7, h
        jp nz, rom_rd
        push af
        ld a, h
        cp $20
        jr nc, mr_io
        and $07
        or $C0
        ld h, a
        ld l, (hl)
        pop af
        ret
mr_io:
if WRAM
        cp $60
        jr nc, mr_wram
endif
        call io_rd_handler
        pop af
        jp (hl)
if WRAM
mr_wram:
        pop af
        jp wram_rd
endif

; HL = any NES address, A = value. Preserves AF, BC, DE.
mem_wr_a:
        ld (wr_val), a
; HL = any NES address, value in (wr_val).
mem_wr_v:
        bit 7, h
        jr nz, mw_rom
        push af
        ld a, h
        cp $20
        jr nc, mw_io
        and $07
        or $C0
        ld h, a
        ld a, (wr_val)
        ld (hl), a
        pop af
        ret
mw_io:
if WRAM
        cp $60
        jr nc, mw_wram
endif
        call io_wr_handler
        pop af
        push hl
        ld hl, (wr_val)
        ret                     ; -> handler with L = value
if WRAM
mw_wram:
        ld a, (wr_val)
        call wram_wa
        pop af
        ret
endif
if MMC3
mw_rom: jp mapper_wa
endif
if MMC1
mw_rom: push af
        ld a, (wr_val)
        ld l, a
        pop af
        jp m1_wr
endif
if 1 - MMC3 - MMC1
mw_rom: ld hl, (wr_val)
        jp mapper_w
endif

; HL = NES I/O address -> HL = read handler. Clobbers A.
io_rd_handler:
        ld a, h
        cp $40
        jr nc, ird_apu
        ld a, l
        and 7
        add a, a
        ld hl, ppu_rd_tab
        jr io_tab
ird_apu:
        jr nz, io_rd_none
        ld a, l
        cp $18
        jr nc, io_rd_none
        add a, a
        ld hl, apu_rd_tab
        jr io_tab
io_rd_none:
        ld hl, io_r_zero
        ret

; HL = NES I/O address -> HL = write handler. Clobbers A.
io_wr_handler:
        ld a, h
        cp $40
        jr nc, iwr_apu
        ld a, l
        and 7
        add a, a
        ld hl, ppu_wr_tab
        jr io_tab
iwr_apu:
        jr nz, io_wr_none
        ld a, l
        cp $18
        jr nc, io_wr_none
        add a, a
        ld hl, apu_wr_tab
        jr io_tab
io_wr_none:
        ld hl, io_nop
        ret

; HL = table, A = offset -> HL = word at table + A
io_tab:
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ret

io_nop:
        ret
io_r_zero:
        ld l, 0
        ret
io_r_open:
        ld l, $40
        ret

; ---------------------------------------------------------------------------
; Interrupt handler (IM 1, via $0038 in every code bank).
isr:
        push af
        push bc
        push de
        push hl
        ex af, af'
        push af
        ex af, af'
        push ix
        push iy
        ld a, (win_seg)
        push af
        out (MAP_P2), a         ; interrupted between setting win_seg and the
                                ; port (always in that order): match them now
        in a, (V_INT)
        out (V_INT), a          ; acknowledge
        push af
        bit 1, a
        call nz, isr_line
        pop af
        bit 0, a
        jp z, isr_exit

        ld hl, frame_cnt
        inc (hl)
        ld a, (ppu_status)
        or $80
        ld (ppu_status), a
        call mask_apply         ; display enable and top-of-frame scroll from
        call write_scroll       ; the last ppu_apply, even if the NMI is skipped
if MMC3
        call irq_start          ; this frame's IRQ splits
endif
        ld a, (in_nmi)
        or a
if DEFER_DMA
        jr nz, isr_busy         ; the NMI still running keeps its split state
else
        jr nz, isr_apu          ; the NMI still running keeps its split state
endif
        ld (s0_state), a
        ld (split_on), a
        ld (isr_sp), sp         ; int_run finds the interrupted registers here
if MMC3 + MMC1
        ld a, (mir_dirty)       ; the mapper changed the mirroring: rebuild the map
        or a
        jr z, isr_mir
        xor a
        ld (mir_dirty), a
        call nt_refresh_all
isr_mir:
endif
if MMC3_CHR
        ld a, (chr_remap)       ; CHR banks switched since the last frame
        or a
        call nz, chr_remap_do
endif
if CHR_SHADOW
        ld a, (chr_any)         ; tiles written since the last frame
        or a
        call nz, chr_flush
endif
        ld a, (spr_dirty)
        or a
        call nz, spr_update
if DEFER_DMA
        ld hl, idle_age         ; only while the game waits at idle points
        ld a, (hl)              ; (not on screens that wait some other way)
        cp 8
        jr nc, isr_now
        inc (hl)
        ld a, (ppu_ctrl)
        bit 7, a
        jr z, isr_now
        ld a, (poll_seen)       ; main loop busy: the NMI waits for its idle
        or a                    ; point (idle_poll), up to 8 frames in a row
        jr nz, isr_now
        ld a, (dma_skips)
        cp 8
        jr nc, isr_now
        inc a
        ld (dma_skips), a
        ld hl, nmi_pend
        inc (hl)
        jr isr_apu
isr_now:
        xor a
        ld (dma_skips), a
        ld a, (nmi_pend)        ; held ones the idle point didn't run
        inc a
        ld (nmi_pend), a
isr_nl: call isr_nmi
        ld hl, nmi_pend
        dec (hl)
        jr nz, isr_nl
        jr isr_apu
endif
        call isr_nmi
        jr isr_apu
if DEFER_DMA
isr_busy:
        ld hl, nmi_pend         ; this vblank's NMI runs after it (up to 2)
        ld a, (hl)
        cp 2
        jr nc, isr_apu
        inc (hl)
endif
isr_apu:
        call apu_frame          ; after the NMI, so it gets the most frame time
isr_exit:
        pop af
        ld hl, win_seg
        cp (hl)
        jr z, isr_same
        ld (hl), a
        out (MAP_P2), a
isr_same:
        pop iy
        pop ix
        ex af, af'
        pop af
        ex af, af'
        pop hl
        pop de
        pop bc
        pop af
        ei
        ret

; The NMI (if enabled), then the next frame's scroll and scanline IRQs.
isr_nmi:
        ld a, (ppu_ctrl)
        bit 7, a
        jr z, isr_nonmi
        ld a, 1
        ld (in_nmi), a
        ld hl, call_nmi
        call int_run
nmi_done:
        xor a
        ld (in_nmi), a
isr_nonmi:
        call ppu_apply
if MMC3
        ld a, 1                 ; the scanline IRQs of the coming frame
        ld (in_nmi), a
        call irq_frame
        xor a
        ld (in_nmi), a
endif
        ret

; Run a 6502 interrupt handler as an interrupt of the code the vblank isr
; interrupted: HL = its call stub (call_nmi / call_irq). Its frame (PC
; unknown, P) goes on the 6502 stack, where RTI pulls it again, and I is
; set; the handler sees the interrupted A/X/Y and flags, and runs with
; interrupts enabled.
int_run:
        ld (ir_call + 1), hl
        ld hl, (s6_ptr)
        ld (hl), 0
        dec l
        ld (hl), 0
        dec l
        ld a, (p_id)
        push af
        or $20
        ld (hl), a
        dec l
        ld (s6_ptr), hl
        pop af
        push af
        or 4
        ld (p_id), a
        ld hl, (isr_sp)         ; reload DE, C, AF saved on isr entry
        ld de, 10
        add hl, de
        ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        ld c, (hl)
        ld b, 0                 ; B = 0 invariant for translated code
        inc hl
        inc hl
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        push hl
        pop af
        ld hl, (wr_val)         ; the interrupted code may be mid-write
        push hl
if MMC3
        ; and between its $8000 and $8001 writes: handlers that switch banks
        ; without restoring $8000 rely on the NES main loop being idle when
        ; they run, which a slower main loop isn't
        ld hl, (mm_sel)
        push hl
endif
        ei
ir_call:
        call 0
        di
if MMC3
        pop hl
        ld a, (mm_sel)
        xor l
        ld a, l
        ld (mm_sel), a
        jp p, ir_sel
        ld a, 1                 ; CHR inversion back
        ld (chr_remap), a
ir_sel:
endif
        pop hl
        ld (wr_val), hl
        pop af
        ld (p_id), a
        ret
isr_sp: dw 0                    ; SP in the vblank isr after its pushes

if MMC3
; MMC3 scanline IRQ. There is no raster timing to count lines with, so the
; vblank isr runs the counter over the coming frame's lines 0-239 right
; after the NMI (irq_frame), calling the game's IRQ handler at each line
; where it reaches 0. What the handler did to the scroll is recorded as a
; split (line, R#17-R#20) for that frame, which irq_start and isr_line
; then show with V9990 line interrupts, like ppu_apply's top-of-frame
; scroll. Entry: V9990 line, 1 if Y changed (a $2006 write) else 0, R#17-20.
irq_start:
        xor a
        ld (irq_k), a
        ld a, (in_nmi)          ; the list is being rebuilt (a held-back NMI
        or a                    ; running late): show the last one again
        jr nz, is_old
        ld a, (irq_n)
        ld (irq_nact), a
        or a
        jr nz, is_on
        ld a, (r9_val)          ; none: ppu_apply's choice
        ld c, 9
        jp vreg
is_on:  ld hl, irq_nxt
        ld de, irq_act
        ld bc, 4 * 6
        ldir
is_old: ld a, (irq_nact)
        or a
        ret z
        ld a, (irq_act)
        ld c, 10
        call vreg
        xor a
        ld c, 11
        call vreg
        ld a, $03
        ld c, 9
        jp vreg

; Line interrupt with IRQ splits: the next one's scroll.
il_irq: ld a, (irq_k)
        ld b, a
        add a, a
        add a, b
        add a, a
        ld hl, irq_act + 1
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld a, (hl)              ; mode
        inc hl
        or a
        jr z, il_x
        ld a, 17
        out (V_REGS), a
        ld a, (hl)
        out (V_REGD), a
        inc hl
        ld a, (hl)
        out (V_REGD), a
        inc hl
        jr il_x2
il_x:   inc hl
        inc hl
        ld a, 19
        out (V_REGS), a
il_x2:  ld a, (hl)
        out (V_REGD), a
        inc hl
        ld a, (hl)
        out (V_REGD), a
        inc hl
        ld a, (irq_k)
        inc a
        ld (irq_k), a
        ld b, a
        ld a, (irq_nact)
        cp b
        jr z, il_last
        ld a, (hl)              ; next entry's line
        ld c, 10
        jp vreg
il_last:
        ld a, $01
        ld c, 9
        jp vreg

; Run the counter over lines 0-239 (clocked while rendering is on: the
; pre-render line, then each line), calling the IRQ handler where it hits
; 0 with IRQs enabled.
irq_frame:
        xor a
        ld (irq_n), a
        ld a, (ppu_mask)
        and $18
        ret z
        ld a, (p_id)            ; the interrupted code masks IRQs
        and 4
        ret nz
        ld hl, irq_reload       ; pre-render line
        ld a, (irq_cnt)
        or a
        jr z, if_rl
        ld a, (hl)
        or a
        jr nz, if_rl
        ld a, (irq_cnt)
        dec a
        ld (irq_cnt), a
        jr if_go
if_rl:  ld (hl), 0
        ld a, (irq_latch)
        ld (irq_cnt), a
if_go:  ld hl, -1               ; HL = line of the last clock
if_l:   ld a, (irq_cnt)
        or a
        ret z                   ; latch 0: not emulated
        ld e, a
        ld d, 0
        add hl, de              ; the line where it reaches 0
        ld a, h
        or a
        jr nz, if_over
        ld a, l
        cp 240
        jr nc, if_over
        xor a
        ld (irq_cnt), a
        ld a, (irq_en)
        or a
        jr z, if_noirq
        ld a, l
        ld (irq_line), a
        push hl
        call irq_one
        pop hl
if_noirq:
        inc hl                  ; next line's clock reloads it
        ld a, l
        cp 240
        ret nc
        xor a
        ld (irq_reload), a
        ld a, (irq_latch)
        ld (irq_cnt), a
        jr if_l
if_over:
        ld de, -239             ; still counting at the end of the frame
        add hl, de
        ld a, l
        ld (irq_cnt), a
        ret

; The IRQ at NES line irq_line: run the handler, record its split for the
; line after.
irq_one:
        xor a
        ld (irq_vset), a
        ld hl, call_irq
        call int_run
        ld a, (irq_n)
        cp 4
        ret nc
        ld a, (irq_line)        ; the line interrupt one line early, as
        dec a                   ; the scroll write lands a line late
        sub CROP
        ret c
        ret z
        cp 211
        ret nc
        ld b, a                 ; V9990 line
        ld a, (irq_n)
        ld c, a
        add a, a
        add a, c
        add a, a
        ld hl, irq_nxt
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld (hl), b
        inc hl
        push hl
        ld hl, vregs            ; calc_scroll's output is ppu_apply's
        ld de, irq_sv
        ld bc, 4
        ldir
        ld a, (irq_vset)
        or a
        jr nz, io_v
        call cur_to_reg         ; only X: $2005 / $2000 from this handler
        call calc_scroll
        ld c, 0
        jr io_st
io_v:   ld hl, (ppu_vaddr)      ; $2006 set coarse X/Y, fine Y, nametable
        ld a, l
        and 31
        add a, a
        add a, a
        add a, a
        ld b, a
        ld a, (scroll_x)        ; fine X from $2005
        and 7
        or b
        ld (reg_sx), a
        ld a, l
        rlca
        rlca
        rlca
        and 7
        ld b, a
        ld a, h
        and 3
        rlca
        rlca
        rlca
        or b                    ; coarse Y
        add a, a
        add a, a
        add a, a
        ld b, a
        ld a, h
        rrca
        rrca
        rrca
        rrca
        and 7                   ; fine Y
        or b
        ld (reg_sy), a
        ld a, h
        rrca
        rrca
        and 3
        ld (reg_ctrl), a
        call calc_scroll
        ld hl, (vregs)          ; mid-frame SCAY: no crop, and the V9990 shows
        ld de, -CROP - 2        ; it 2 lines further on
        add hl, de
        bit 7, h
        jr z, io_pos
        ld de, 480
        ld a, (mir_v)
        or a
        jr z, io_h
        ld de, 240
io_h:   add hl, de
io_pos: ld a, h
        and $1F
        ld h, a
        ld (vregs), hl
        ld c, 1
io_st:  pop hl
        ld (hl), c
        inc hl
        ex de, hl
        ld hl, vregs
        ld bc, 4
        ldir
        ld hl, irq_sv
        ld de, vregs
        ld bc, 4
        ldir
        ld hl, irq_n
        inc (hl)
        ret

irq_cnt:    db 0                ; the MMC3 counter
irq_n:      db 0                ; splits recorded for the coming frame
irq_nact:   db 0                ; splits of this frame
irq_k:      db 0                ; next one to show
irq_line:   db 0
irq_vset:   db 0                ; $2006 written by this IRQ handler
irq_act:    defs 4 * 6
irq_nxt:    defs 4 * 6
irq_sv:     defs 4
endif

; Split-screen line interrupt: switch to the below-split scroll.
isr_line:
if MMC3
        ld a, (irq_nact)
        or a
        jp nz, il_irq
endif
        ld a, 17
        out (V_REGS), a
        ld hl, bot_regs
        ld a, (hl)
        out (V_REGD), a
        inc hl
        ld a, (hl)
        out (V_REGD), a
        inc hl
        ld a, (hl)
        out (V_REGD), a
        inc hl
        ld a, (hl)
        out (V_REGD), a
        ret
