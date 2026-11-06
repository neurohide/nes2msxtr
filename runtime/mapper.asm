; ---------------------------------------------------------------------------
; Mapper: PRG/CHR bank switching, PRG RAM banking, and (MMC3) the scanline
; IRQ. Split out of core.asm so mapper logic for NROM/UxROM/MMC1/MMC3 lives
; in one place.

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
