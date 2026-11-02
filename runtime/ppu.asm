; NES PPU emulation on the V9990 (P1 mode).
;
; Background: layer A. Each NES tile exists in VRAM in 4 palette variants
; (pattern = bgtable*1024 + palette*256 + tile), so a name-table entry
; carries the attribute palette. Physical nametable k is placed in the
; 64x64 V9990 map twice so the 512x512 roll matches NES mirroring:
;   vertical mirroring:   columns k*32.., rows r and r+30
;   horizontal mirroring: rows k*30+r, columns c and c+32
; Sprites: NES sprite i -> V9990 sprite i, pattern slot i, uploaded on
; change (palette and flips baked in; V9990 sprites cannot flip).
; Palette: NES palette index i -> V9990 palette entry i (sprites use
; palette block 1 = entries 16-31).
;
; I/O handlers take/return the value in L and preserve AF, BC, DE.

ppu_rd_tab:
        dw io_r_open, io_r_open, io_r_2002, io_r_open
        dw io_r_2004, io_r_open, io_r_open, io_r_2007
ppu_wr_tab:
        dw io_w_2000, io_w_2001, io_nop, io_w_2003
        dw io_w_2004, io_w_2005, io_w_2006, io_w_2007

; Background table, sprite size and sprite table take effect in ppu_apply.
io_w_2000:
        push af
        ld a, l
        ld (ppu_ctrl), a
        pop af
        ret

; Latched only: games turn rendering off at the start of their NMI and back
; on at the end, which is invisible on a NES but would blank the top of the
; V9990 picture if the NMI outlasts vblank. isr writes R#8 at vblank.
io_w_2001:
        push af
        ld a, l
        ld (ppu_mask), a
        pop af
        ret

; (ppu_mask) -> V9990 R#8 (display / sprite enable). Interrupts off.
mask_apply:
        ld a, (ppu_mask)
        ld h, $02
        and $18
        jr z, ma_off
        ld h, $82               ; display on
ma_off:
        ld a, (ppu_mask)
        and $10
        jr nz, ma_spr
        set 6, h                ; sprites off
ma_spr:
        ld a, h
        ld c, 8
        jp vreg

; Vblank flag clears on read. Sprite-0 hit is reported from the second read
; of a frame on.
; Sprite-0 polling loops (picked by the translator): waiting for the flag
; to clear sees it clear; waiting for the hit sees it at once, and only that
; starts the split (snapshotting the above-split scroll). Plain reads, often
; just resetting the $2005/$2006 latch, never split the screen.
io_r_2002_s0clr:
        call io_r_2002
        res 6, l
        ret

io_r_2002:
        push af
        ld a, (ppu_status)
        ld l, a
        and $7F
        ld (ppu_status), a
        xor a
        ld (ppu_w), a
        ld a, (s0_state)
        or a
        jr nz, r2002_set
        inc a
        ld (s0_state), a
        res 6, l
        pop af
        ret
r2002_set:
        set 6, l
        pop af
        ret

io_r_2002_s0hit:
        push af
        ld a, 1
        ld (s0_state), a
        pop af
        call io_r_2002
        push af
        ld a, (split_on)
        or a
        jr nz, r2002_done
        ld a, (OAM)
        cp $EF
        jr nc, r2002_done       ; sprite 0 hidden: no split
        ld a, (scroll_x)
        ld (top_sx), a
        ld a, (scroll_y)
        ld (top_sy), a
        ld a, (ppu_ctrl)
        ld (top_ctrl), a
        ld a, 1
        ld (split_on), a
r2002_done:
        pop af
        ret

io_w_2003:
        push af
        ld a, l
        ld (oam_addr), a
        pop af
        ret

io_w_2004:
        push af
        push de
        ld a, (oam_addr)
        ld e, a
        ld d, OAM >> 8
        ld a, l
        ld (de), a
        inc e
        ld a, e
        ld (oam_addr), a
        ld a, 1
        ld (spr_dirty), a
        pop de
        pop af
        ret

io_r_2004:
        push af
        push de
        ld a, (oam_addr)
        ld e, a
        ld d, OAM >> 8
        ld a, (de)
        ld l, a
        pop de
        pop af
        ret

io_w_2005:
        push af
        ld a, (ppu_w)
        xor 1
        ld (ppu_w), a
        ld a, l
        jr z, w2005_y
        ld (scroll_x), a
        pop af
        ret
w2005_y:
        ld (scroll_y), a
        pop af
        ret

io_w_2006:
        push af
        ld a, (ppu_w)
        xor 1
        ld (ppu_w), a
        ld a, l
        jr z, w2006_lo
        and $3F
        ld (ppu_vaddr + 1), a
        pop af
        ret
w2006_lo:
        ld (ppu_vaddr), a
if MMC3
        ld a, 1                 ; mid-frame: moves the picture (irq_one)
        ld (irq_vset), a
endif
        pop af
        ret

io_w_2007:
        push af
        push bc
        push de
        ld a, l
        ld (wr_val), a
        ld hl, (ppu_vaddr)
        call ppu_write
        call vaddr_inc
        pop de
        pop bc
        pop af
        ret

io_r_2007:
        push af
        push bc
        push de
        ld hl, (ppu_vaddr)
        ld a, h
        and $3F
        ld h, a
        cp $3F
        jr nc, r2007_pal
        call ppu_peek
        ld a, (ppu_buf)
        ld h, a
        ld a, l
        ld (ppu_buf), a
        ld l, h
        jr r2007_done
r2007_pal:
        call pal_index
        ld h, PAL_SHADOW >> 8
        ld l, (hl)
r2007_done:
        push hl
        call vaddr_inc
        pop hl
        pop de
        pop bc
        pop af
        ret

vaddr_inc:
        ld hl, (ppu_vaddr)
        ld de, 1
        ld a, (ppu_ctrl)
        and 4
        jr z, vinc_1
        ld e, 32
vinc_1: add hl, de
        ld a, h
        and $3F
        ld h, a
        ld (ppu_vaddr), hl
        ret

; L = palette address low byte -> L = palette index with mirrors folded
pal_index:
        ld a, l
        and $1F
        ld l, a
        and $13
        cp $10
        ret nz
        ld a, l
        and $0F
        ld l, a
        ret

; A = nametable number (0-3) -> A = physical nametable (0-1)
nt_mirror:
        push hl
        ld hl, mir_v
        bit 0, (hl)
        pop hl
        jr nz, ntm_v
        rrca
ntm_v:  and 1
        ret

; HL = PPU address $0000-$3EFF -> L = byte
ppu_peek:
        ld a, h
        cp $20
        jr c, pk_chr
        rrca
        rrca
        and 3
        call nt_mirror
        add a, a
        add a, a
        ld b, a
        ld a, h
        and 3
        add a, b
        add a, NT_SHADOW >> 8
        ld h, a
        ld l, (hl)
        ret
pk_chr:
if MMC3_CHR
        ld a, (chr_remap)       ; banks switched since the last frame: the
        or a                    ; copy must show them now (games read CHR
        jr z, pk_now            ; ROM data through $2007)
        ld a, i
        push af
        di
        push hl
        call chr_remap_do
        pop hl
        pop af
        jp po, pk_now
        ei
pk_now:
endif
        ld a, DSEG_MISC
        call win_map
        ld a, h
        or $80
        ld h, a
        ld l, (hl)
        ret

; A = segment -> page 2 (cached). Preserves HL.
win_map:
        push hl
        ld hl, win_seg
        cp (hl)
        jr z, wm_ok
        ld (hl), a
        out (MAP_P2), a
wm_ok:  pop hl
        ret

; HL = PPU address, (wr_val) = value. Clobbers everything but IX/IY.
ppu_write:
        ld a, h
        and $3F
        ld h, a
        cp $20
if CHR_RAM
        jp c, chr_write
else
        ret c                   ; pattern tables are CHR ROM
endif
        cp $3F
        jr nc, pw_pal
        rrca
        rrca
        and 3
        call nt_mirror
        ld (nt_k), a
        ld a, h
        and 3
        ld h, a
        ld (nt_off), hl
        ld a, (nt_k)
        add a, a
        add a, a
        add a, h
        add a, NT_SHADOW >> 8
        ld d, a
        ld e, l
        ld a, (de)
        ld c, a                 ; old byte
        ld a, (wr_val)
        ld (de), a
        ld a, h
        cp 3
        jp nz, nt_cell
        ld a, l
        cp $C0
        jp c, nt_cell
        ld a, (wr_val)
        xor c
        ret z                   ; attribute byte unchanged
        ld (nt_x), a
        jp nt_attr
pw_pal: call pal_index
        ld h, PAL_SHADOW >> 8
        ld a, (wr_val)
        and $3F
        ld (hl), a
        ld e, l
; A = NES colour, E = palette index: load V9990 palette entry E.
pal_set:
        ld l, a
        ld h, 0
        ld c, l
        ld b, 0
        add hl, hl
        add hl, bc
        ld bc, nes_rgb
        add hl, bc
        ld a, i
        push af
        di
        ld a, 14
        out (V_REGS), a
        ld a, e
        add a, a
        add a, a
        out (V_REGD), a
        ld a, (hl)
        out (V_PAL), a
        inc hl
        ld a, (hl)
        out (V_PAL), a
        inc hl
        ld a, (hl)
        out (V_PAL), a
        pop af
        jp po, $+4
        ei
        ret

if MMC3_CHR
; MMC3 CHR banks: copy each 1K piece whose bank changed into the CHR copy
; in DSEG_MISC and mark its 64 tiles for chr_flush. R0/R1 are 2K banks at
; $0000 ($1000 with $8000 bit 7 set), R2-R5 1K banks at $1000 ($0000).
; CHR ROM stays in the cartridge (1K bank b in ROM bank CHR_BANK0 + b / 16),
; read with page 1 switched to it. Interrupts off.
chr_remap_do:
        xor a
        ld (chr_remap), a
        ld hl, mm_regs
        ld a, (mm_sel)
        rla
        ld de, cr_new
        jr nc, cr_n
        ld de, cr_new + 4
cr_n:   ld b, 2
cr_2k:  ld a, (hl)
        inc hl
        and CHR_MASK & $FE
        ld (de), a
        inc de
        inc a
        ld (de), a
        inc de
        djnz cr_2k
        ld a, (mm_sel)
        rla
        ld de, cr_new + 4
        jr nc, cr_n2
        ld de, cr_new
cr_n2:  ld b, 4
cr_1k:  ld a, (hl)
        inc hl
        and CHR_MASK
        ld (de), a
        inc de
        djnz cr_1k
        ld c, 0                 ; C = slot, B = 0
cr_l:   ld hl, cr_new
        add hl, bc
        ld a, (hl)
        ld hl, chr_map
        add hl, bc
        cp (hl)
        call nz, cr_copy
        inc c
        ld a, c
        cp 8
        jr nz, cr_l
        ret

; A = 1K bank for slot C, HL = its chr_map entry. Preserves BC.
cr_copy:
        ld (hl), a
        push bc
        ld e, a
        rrca
        rrca
        rrca
        rrca
        and $0F
        add a, CHR_BANK0
        ld (cr_sseg), a
        ld a, e
        and 15
        add a, a
        add a, a
        or $40
        ld (cr_shi), a
        ld a, c
        add a, a
        add a, a
        or $80
        ld (cr_dhi), a
        ld a, c
        add a, a
        add a, a
        add a, a
        ld e, a
        ld d, 0
        ld hl, chr_dirty
        add hl, de
        ld b, 8
cr_d:   ld (hl), $FF
        inc hl
        djnz cr_d
        ld a, 1
        ld (chr_any), a
        ld a, DSEG_MISC         ; 1K from the cartridge (page 1) straight
        call win_map            ; into the CHR copy (page 2)
        call cart_in
        ld a, (cr_sseg)
        ld (ASCII16_P1), a
        ld a, (cr_shi)
        ld h, a
        ld l, 0
        ld a, (cr_dhi)
        ld d, a
        ld e, 0
        ld bc, $400
        ldir
        ld b, 1                 ; page 1 back to RAM (the code bank)
        call set_page_ram
        pop bc
        ret

; Page 1 -> the cartridge slot.
cart_in:
        ld a, (cart_s)
        cp $FF
        jr z, ci_p
        add a, a                ; it shares the RAM's expanded slot
        add a, a
        ld e, a
        ld a, ($FFFF)
        cpl
        and $F3
        or e
        ld ($FFFF), a
ci_p:   ld a, (cart_p)
        add a, a
        add a, a
        ld e, a
        in a, (PPI_SLOT)
        and $F3
        or e
        out (PPI_SLOT), a
        ret

cr_new:     defs 8
chr_map:    db $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF   ; 1K bank per slot
cr_sseg:    db 0
cr_shi:     db 0
cr_dhi:     db 0
cart_p:     db 0                ; cartridge slot
cart_s:     db $FF              ; ... its sub-slot, if it shares RAM's slot
endif

if CHR_SHADOW
if CHR_RAM
; CHR RAM write: HL = PPU address < $2000, (wr_val) = value. The byte goes
; to the CHR copy in DSEG_MISC (which $2007 reads use too) and its tile is
; marked for chr_flush.
chr_write:
        ld a, DSEG_MISC
        call win_map
        ld a, h
        or $80
        ld d, a
        ld e, l
        ld a, (wr_val)
        ex de, hl
        cp (hl)
        ret z                   ; unchanged
        ld (hl), a
        ex de, hl
        ld a, l
        rrca
        rrca
        rrca
        rrca
        and 7
        ld b, a                 ; tile & 7
        add hl, hl
        ld e, h                 ; tile >> 3
        ld d, 0
        ld hl, chr_dirty
        add hl, de
        ld a, 1
        inc b
cw_sh:  dec b
        jr z, cw_set
        add a, a
        jr cw_sh
cw_set: or (hl)
        ld (hl), a
        ld a, 1
        ld (chr_any), a
        ret
endif

; Rebuild the tiles written since the last flush (one bit per tile in
; chr_dirty): the 4 palette copies of the background pattern in VRAM, the
; sprite source rows (spr0/spr1) and s0row. Then the sprite pattern cache
; is emptied, so every sprite is uploaded again from the new tiles.
; Interrupts off; clobbers everything but IX/IY.
chr_flush:
        xor a
        ld (chr_any), a
        ld hl, chr_dirty
        ld a, 64
cf_byte:
        ld (cf_left), a
        ld a, (hl)
        or a
        jr z, cf_next
        ld (hl), 0
        push hl
        ld c, a                 ; tiles left in this byte
        ld a, (cf_left)
        neg
        add a, 64
        ld l, a
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl              ; first tile of the byte
        ld b, 8
cf_bit: srl c
        push bc
        push hl
        call c, chr_tile
        pop hl
        pop bc
        inc hl
        djnz cf_bit
        pop hl
cf_next:
        inc hl
        ld a, (cf_left)
        dec a
        jr nz, cf_byte
        ld hl, SC_THI           ; empty the sprite pattern cache
        ld de, SC_THI + 1
        ld bc, $FF
        ld (hl), $FF
        ldir
        ld a, 1
        ld (spr_dirty), a
        ret

; HL = tile 0-511: rebuild it from the CHR copy.
chr_tile:
        ld (ct_t), hl
        ld a, DSEG_MISC
        call win_map
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        set 7, h
        ld de, ct_raw           ; 8 rows x 4 bytes of 2-bit pixels
        ld b, 8
ct_row: push bc
        ld c, (hl)              ; plane 0
        ld a, l
        add a, 8
        ld l, a
        ld b, (hl)              ; plane 1
        sub 7
        ld l, a
        push hl
        ld h, 4
ct_px:  xor a                   ; two pixels: 00 b c 00 b c
        sla b
        rla
        sla c
        rla
        add a, a
        add a, a
        sla b
        rla
        sla c
        rla
        ld (de), a
        inc de
        dec h
        jr nz, ct_px
        pop hl
        pop bc
        djnz ct_row

        ld hl, ct_raw           ; s0row: first row with a pixel set
        ld bc, $0800
ct_s0l: ld a, (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        jr nz, ct_s0f
        inc c
        djnz ct_s0l
        ld c, 0
ct_s0f: ld hl, (ct_t)
        ld de, s0row
        add hl, de
        ld (hl), c

        ld hl, ct_raw           ; mirrored rows for h-flipped sprites
        ld de, ct_raw + 32
        ld b, 8
ct_fl:  push bc
        inc hl
        inc hl
        inc hl
        ld b, 4
ct_fb:  ld a, (hl)
        rrca
        rrca
        rrca
        rrca
        ld (de), a
        inc de
        dec hl
        djnz ct_fb
        ld bc, 5
        add hl, bc
        pop bc
        djnz ct_fl

        ld hl, (ct_t)           ; sprite source: (tile * 2 + hflip) * 32
        ld a, h
        add a, DSEG_SPR0
        call win_map
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        set 7, h
        ex de, hl
        ld hl, ct_raw
        ld bc, 64
        ldir

        ; background: pattern P = table*1024 + palette*256 + tile at
        ; (P / 32) * 1024 + (P % 32) * 4, rows 128 bytes apart
        ld hl, (ct_t)
        ld a, l
        and 31
        add a, a
        add a, a
        ld (ct_lo), a
        ld a, l
        rlca
        rlca
        rlca
        and 7
        add a, a
        add a, a
        bit 0, h
        jr z, ct_t0
        add a, 128
ct_t0:  ld (ct_hi), a
        ld de, ct_raw
        ld c, SPR_LUT >> 8      ; same expansion: pixel v -> palette*4 + v
ct_pal: ld b, 0
ct_bgr: ld a, b
        rrca
        and $80
        ld l, a
        ld a, (ct_lo)
        or l
        ld l, a
        ld a, b
        srl a
        ld h, a
        ld a, (ct_hi)
        add a, h
        ld h, a
        xor a
        call vwaddr
        ld h, c
        ld a, (de)
        inc de
        ld l, a
        ld a, (hl)
        out (V_VRAM), a
        ld a, (de)
        inc de
        ld l, a
        ld a, (hl)
        out (V_VRAM), a
        ld a, (de)
        inc de
        ld l, a
        ld a, (hl)
        out (V_VRAM), a
        ld a, (de)
        inc de
        ld l, a
        ld a, (hl)
        out (V_VRAM), a
        inc b
        ld a, b
        cp 8
        jr nz, ct_bgr
        ex de, hl
        ld de, -32
        add hl, de
        ex de, hl
        ld a, (ct_hi)
        add a, 32
        ld (ct_hi), a
        inc c
        ld a, c
        cp (SPR_LUT >> 8) + 4
        jr nz, ct_pal
        ret

chr_dirty:
        defs 64, 0
ct_raw:
        defs 64, 0
endif

; Rewrite the V9990 entries for cell (nt_k, nt_off), nt_off < $3C0.
nt_cell:
        ld hl, (nt_off)
        ld a, l
        and 31
        ld (nt_c), a
        add hl, hl
        add hl, hl
        add hl, hl
        ld a, h
        ld (nt_r), a
        ld hl, (nt_off)
        ld a, (nt_k)
        add a, a
        add a, a
        add a, h
        add a, NT_SHADOW >> 8
        ld h, a
        ld a, (hl)
        ld (nt_tile), a
        ld a, (nt_r)            ; attribute byte for this cell
        and $1C
        add a, a
        ld l, a
        ld a, (nt_c)
        rrca
        rrca
        and 7
        add a, l
        add a, $C0
        ld l, a
        ld a, (nt_k)
        add a, a
        add a, a
        add a, (NT_SHADOW >> 8) + 3
        ld h, a
        ld c, (hl)
        ld a, (nt_r)            ; quadrant shift 0/2/4/6
        and 2
        add a, a
        ld b, a
        ld a, (nt_c)
        and 2
        or b
        jr z, nc_ns
        ld b, a
nc_sh:  srl c
        djnz nc_sh
nc_ns:  ld a, c
        and 3
        ld b, a
        ld a, (bg_shown)
        or b
        ld (nt_ehi), a          ; pattern bits 12-8: table*4 + palette
        ld a, (mir_v)
        or a
        jr z, nc_hor
        ld a, (nt_k)
        rrca
        rrca
        rrca
        ld b, a
        ld a, (nt_c)
        or b
        ld c, a
        ld a, (nt_r)
        ld b, a
        call nt_emit
        ld a, b
        add a, 30
        ld b, a
        jp nt_emit
nc_hor: ld a, (nt_k)
        or a
        jr z, nc_h0
        ld a, 30
nc_h0:  ld b, a
        ld a, (nt_r)
        add a, b
        ld b, a
        ld a, (nt_c)
        ld c, a
        call nt_emit
        ld a, c
        add a, 32
        ld c, a
        jp nt_emit

; B = map row, C = map column: write (nt_tile, nt_ehi). Preserves BC, DE.
nt_emit:
        ld a, b
        srl a
        or $C0
        ld h, a
        ld a, b
        rrca
        and $80
        ld l, a
        ld a, c
        add a, a
        add a, l
        ld l, a
        ld a, i
        push af
        di
        ld a, $07
        call vwaddr
        ld a, (nt_tile)
        out (V_VRAM), a
        ld a, (nt_ehi)
        out (V_VRAM), a
        pop af
        jp po, $+4
        ei
        ret

; Attribute byte written: refresh those of the 4x4 cells it covers whose
; 2-bit palette changed (nt_x = old XOR new).
nt_attr:
        ld a, (nt_off)
        sub $C0
        ld b, a
        and 7
        add a, a
        add a, a
        ld c, a                 ; first column
        ld a, b
        and $38
        rrca
        ld b, a                 ; first row
        ld d, 4
na_r:   ld a, b
        cp 30
        ret nc
        ld e, 4
        push bc
na_c:   ld a, b                 ; quadrant shift 0/2/4/6 of this cell
        and 2
        add a, a
        ld h, a
        ld a, c
        and 2
        or h
        inc a
        ld h, a
        ld a, (nt_x)
na_sh:  dec h
        jr z, na_tst
        rrca
        jr na_sh
na_tst: and 3
        jr z, na_skip
        ld l, b
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        ld a, l
        or c
        ld l, a
        ld (nt_off), hl
        push bc
        push de
        call nt_cell
        pop de
        pop bc
na_skip:
        inc c
        dec e
        jr nz, na_c
        pop bc
        inc b
        dec d
        jr nz, na_r
        ret

; Rebuild every cell (background pattern table switched).
nt_refresh_all:
        push bc
        push de
        push hl
        xor a
nra_k:  ld (nt_k), a
        ld hl, 0
nra_l:  ld (nt_off), hl
        call nt_cell
        ld hl, (nt_off)
        inc hl
        ld a, h
        cp 3
        jr nz, nra_l
        ld a, l
        cp $C0
        jr nz, nra_l
        ld a, (nt_k)
        inc a
        cp 2
        jr nz, nra_k
        pop hl
        pop de
        pop bc
        ret

; OAM DMA from NES page L.
io_w_4014:
        push af
        push bc
        push de
        ld a, l
        cp $08
        jr nc, dma_slow
        and 7
        add a, NES_RAM >> 8
        ld h, a
        ld l, 0
        ld de, OAM
        ld bc, 256
        ldir
        jr dma_done
dma_slow:
        ld h, a
        ld l, 0
        ld de, OAM
dma_l:  push hl
        call mem_rd
        ld a, l
        ld (de), a
        pop hl
        inc l
        inc e
        jr nz, dma_l
dma_done:
        call spr_update
        pop de
        pop bc
        pop af
        ret

; Convert OAM to V9990 sprites. Clobbers HL; preserves BC, DE, IX, IY.
spr_update:
        push bc
        push de
        push ix
        push iy
        xor a
        ld (spr_dirty), a
        ld a, (spr_ctrl)
        ld (sp_mode), a
        ld c, 4                 ; cache key bits shared by every sprite:
        bit 5, a                ; 8x16 -> bit 2, 8x8 from $1000 -> bit 3
        jr nz, su_kb
        ld c, 0
        bit 3, a
        jr z, su_kb
        ld c, 8
su_kb:  ld a, c
        ld (su_kbase), a
        ld a, i                 ; interrupts stay as they were, except around
        ld a, 0                 ; VRAM address writes: a long upload must not
        jp po, $+4              ; hold off the split line interrupt
        inc a
        ld (su_iff), a
        ld hl, su_stamp
        inc (hl)
        ld c, 1                 ; attribute table at $3FE00, written entry by
                                ; entry; C != 0: VRAM address must be set
        ld hl, OAM
        ld de, SPR_HID          ; DE = hidden flag of the current sprite
        ld b, 64                ; B = sprites left (sprite number = 64 - B)
su_lp:  ld a, (hl)              ; Y
        cp $EF
        jr c, su_show
        ld a, (de)
        or a
        jr z, su_hide
        ld c, 1                 ; already disabled in VRAM: skip it
su_nx:  inc e
        ld a, l
        add a, 4
        ld l, a
        djnz su_lp
        pop iy
        pop ix
        pop de
        pop bc
        ret

su_hide:
        ld a, 1
        ld (de), a
        call su_aw
        xor a
        out (V_VRAM), a
        out (V_VRAM), a
        out (V_VRAM), a
        ld a, $10               ; disabled
        out (V_VRAM), a
        jr su_nx

su_show:
        xor a
        ld (de), a
        push de
        push bc
        inc l
        ld e, (hl)              ; E = tile
        inc l
        ld a, (hl)
        and $C3                 ; flips and palette
        ld c, a
        ld a, (su_kbase)
        or c
        ld c, a                 ; C = key high byte
        bit 2, a
        jr z, su_k8
        bit 0, e                ; 8x16: tile bit 0 picks the table
        jr z, su_k16
        set 3, c
su_k16: res 0, e
su_k8:  push hl
        call su_find            ; -> A = pattern
        pop hl
        pop bc
        pop de
        jr nc, su_nup
        ld c, 1                 ; an upload moved the VRAM address
su_nup: push de
        ld d, a                 ; D = pattern
        push hl
        ld a, e
        sub SPR_HID & $FF
        ld l, a                 ; sprite number
        ld h, SPR_PAT >> 8
        ld (hl), d
        pop hl
        dec l
        dec l
        call su_aw
        ld a, (hl)              ; Y
        sub CROP
        out (V_VRAM), a
        ld a, d
        out (V_VRAM), a
        inc l
        inc l
        ld a, (hl)              ; attributes
        inc l
        and $20                 ; behind background
        or $40                  ; palette block 1
        ld d, a
        ld a, (hl)              ; X
        out (V_VRAM), a
        ld a, d
        out (V_VRAM), a
        dec l
        dec l
        dec l
        pop de
        jr su_nx

; Set the VRAM address to the attribute entry of this sprite (E = its
; hidden-flag address) if a skip or an upload moved it. Clears C.
su_aw:  ld a, c
        or a
        ret z
        ld c, 0
        push hl
        ld a, e
        sub SPR_HID & $FF
        add a, a
        add a, a
        ld l, a
        ld h, $FE
        ld a, $03
        call su_vwaddr
        pop hl
        ret

; vwaddr with interrupts off, then back to spr_update's entry state.
su_vwaddr:
        di
        call vwaddr
        push af
        ld a, (su_iff)
        or a
        jr z, $+3
        ei
        pop af
        ret

; E = tile low byte, C = key high byte (flips and palette in $C3, tile bit 8
; in bit 3, 8x16 in bit 2) -> A = V9990 pattern, uploaded on a miss. Probes
; 8 slots from a hash of the key; a miss takes the first slot not used yet
; in this pass. Carry set if it uploaded. Clobbers BC, DE, HL.
su_find:
        ld a, c
        rlca
        rlca
        rlca
        rlca
        xor e
        ld l, a
        ld d, 8
        ld b, 0                 ; B = 1: free slot found (in sp_free)
sf_l:   ld h, SC_TLO >> 8
        ld a, (hl)
        cp e
        jr nz, sf_no
        inc h
        ld a, (hl)
        cp c
        jr z, sf_hit
sf_no:  ld a, b
        or a
        jr nz, sf_nx
        ld h, SC_STAMP >> 8
        ld a, (su_stamp)
        cp (hl)
        jr z, sf_nx             ; in use by an earlier sprite of this pass
        ld a, l
        ld (sp_free), a
        inc b
sf_nx:  inc l
        dec d
        jr nz, sf_l
        ld a, b
        or a
        jr nz, sf_take
        ld h, SC_STAMP >> 8     ; whole window in use: take the next free slot
        ld a, (su_stamp)
sf_far: cp (hl)
        jr nz, sf_farok
        inc l
        jr sf_far
sf_farok:
        ld a, l
        ld (sp_free), a
sf_take:
        ld a, (sp_free)
        ld l, a
        ld (sp_pat), a
        ld h, SC_TLO >> 8
        ld (hl), e
        inc h
        ld (hl), c
        inc h
        ld a, (su_stamp)
        ld (hl), a
        ld a, e                 ; tile 0-511 and attributes for the upload
        ld (sp_t0), a
        ld a, c
        rrca
        rrca
        rrca
        and 1
        ld (sp_t0 + 1), a
        ld a, c
        and $C3
        ld (sp_attr), a
        call spr_upload
        ld a, (sp_pat)
        scf                     ; carry: uploaded, the VRAM address moved
        ret
sf_hit: inc h                   ; SC_STAMP
        ld a, (su_stamp)
        ld (hl), a
        ld a, l
        or a
        ret

; Upload 16 lines of pattern (sp_pat) for tile (sp_t0) with (sp_attr).
spr_upload:
        ld a, (sp_pat)          ; DE = pattern offset within $20000
        and $F0
        rrca
        ld d, a
        ld a, (sp_pat)
        and $0F
        add a, a
        add a, a
        add a, a
        ld e, a
        xor a
        ld (sp_line), a
spu_line:
        ld a, (sp_line)
        ld b, a
        srl a
        add a, d
        ld h, a
        ld a, b
        rrca
        and $80
        or e
        ld l, a
        ld a, VR_SPRPAT_HI
        call su_vwaddr
        ld a, (sp_mode)
        and $20
        jr nz, spu_tall
        ld a, b
        cp 8
        jr nc, spu_zero
        xor a
        jr spu_src
spu_tall:
        ld a, b
        rrca
        rrca
        rrca
        and 1
        ld c, a
        ld a, (sp_attr)
        rlca
        and 1
        xor c                   ; vertical flip swaps the two tiles
spu_src:
        ld hl, (sp_t0)
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a                 ; tile index 0-511
        ld a, b
        and 7
        ld c, a
        ld a, (sp_attr)
        bit 7, a
        ld a, c
        jr z, spu_nv
        xor 7
spu_nv: add a, a
        add a, a
        ld c, a                 ; row * 4
        ld a, (sp_attr)
        and $40
        rrca
        or c
        ld c, a                 ; + hflip * 32
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl              ; tile * 64
        ld a, l
        or c
        ld l, a
        ld a, h
        rlca
        rlca
        and 3
        add a, DSEG_SPR0
        call win_map
        ld a, h
        and $3F
        or $80
        ld h, a
        ld a, (sp_attr)
        and 3
        add a, SPR_LUT >> 8
        ld c, a
        ld b, 4
spu_b:  ld a, (hl)
        inc hl
        push hl
        ld l, a
        ld h, c
        ld a, (hl)
        out (V_VRAM), a
        pop hl
        djnz spu_b
        jr spu_next
spu_zero:
        xor a
        out (V_VRAM), a
        out (V_VRAM), a
        out (V_VRAM), a
        out (V_VRAM), a
spu_next:
        ld a, (sp_line)
        inc a
        ld (sp_line), a
        cp 16
        jp nz, spu_line
        ret

; ---------------------------------------------------------------------------
; Scroll. Called with interrupts off at the end of each frame's NMI.
; Computes the scroll registers for the next frame. The game's NMI usually
; ends well after vblank, and a mid-frame Y-scroll write would restart the
; picture, so isr writes R#8 and R#17-R#20 at the start of the next frame.
; The pattern tables and sprite size in $2000 are latched too: games often
; write $2000 = 0 at the start of their NMI and restore it at the end, and
; a background table switch rebuilds the whole map, while a sprite update
; in between (OAM DMA) would use the wrong size. They take effect when a
; frame ends with them changed.
ppu_apply:
        ld a, (ppu_ctrl)
        and $28
        ld hl, spr_ctrl
        cp (hl)
        jr z, pa_spr
        ld (hl), a
        ld a, 1
        ld (spr_dirty), a
pa_spr: ld a, (ppu_ctrl)
        and $10
        rrca
        rrca
        ld hl, bg_shown
        cp (hl)
        jr z, pa_bg
        ld (hl), a
        call nt_refresh_all
pa_bg:  ld a, (split_on)
        or a
        jp z, pa_nosplit
        call cur_to_reg         ; below the split: current X, top's Y
        call calc_scroll
        ld hl, vregs
        ld de, bot_regs
        ld bc, 4
        ldir
        ld a, (top_sx)
        ld (reg_sx), a
        ld a, (top_sy)
        ld (reg_sy), a
        ld a, (top_ctrl)
        ld (reg_ctrl), a
        call calc_scroll
        ld a, (vregs)
        ld (bot_regs), a
        ld a, (vregs + 1)
        ld (bot_regs + 1), a
        ld a, (OAM + 1)         ; split line = sprite 0 Y + 2 + first opaque row
        ld l, a
        ld h, 0
        ld a, (ppu_ctrl)
        and 8
        jr z, pa_t0
        inc h
pa_t0:  ld de, s0row
        add hl, de
        ld a, (OAM)
        add a, (hl)
        add a, 2                ; the game's new scroll shows from the line
        sub CROP                ; after the hit
        jr c, pa_allbot
        jr z, pa_allbot
        ; A mid-frame Y-scroll write makes the next line show image line
        ; SCAY, so continue the picture: bottom Y = top Y + split line.
        push af
        ld hl, (bot_regs)
        ld e, a
        ld d, 0
        add hl, de
        ld a, h
        and $1F
        ld h, a
        ld (bot_regs), hl
        pop af
if MMC3
        ld c, a                 ; IRQ splits on screen: leave the line
        ld a, (irq_nact)        ; interrupt to them
        or a
        ld a, c
        ret nz
endif
        ld c, 10
        call vreg
        xor a
        ld c, 11
        call vreg
        ld a, $03
        ld (r9_val), a
        ld c, 9
        jp vreg
pa_allbot:
        ld hl, bot_regs
        ld de, vregs
        ld bc, 4
        ldir
        jr pa_write
pa_nosplit:
        call cur_to_reg
        call calc_scroll
pa_write:
        ld a, $01
        ld (r9_val), a
if MMC3
        ld a, (irq_nact)
        or a
        ret nz
        ld a, $01
endif
        ld c, 9
        jp vreg

cur_to_reg:
        ld a, (scroll_x)
        ld (reg_sx), a
        ld a, (scroll_y)
        ld (reg_sy), a
        ld a, (ppu_ctrl)
        ld (reg_ctrl), a
        ret

; (reg_sx, reg_sy, reg_ctrl) -> vregs = R#17-R#20
calc_scroll:
        ld a, (reg_ctrl)
        and 1
        ld h, a
        ld a, (reg_sx)
        ld l, a
        and 7
        ld (vregs + 2), a
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        ld a, l
        ld (vregs + 3), a
        ld a, (reg_sy)
        ld l, a
        ld h, 0
        ld de, CROP
        add hl, de
        ld a, (mir_v)
        or a
        jr nz, cs_wrapped       ; vertical: nametables 0 and 2 are the same
        ld a, (reg_ctrl)
        and 2
        jr z, cs_y
        ld de, 240
        add hl, de
cs_y:   ld de, 480
        or a
        sbc hl, de
        jr nc, cs_wrapped
        add hl, de
cs_wrapped:
        ld a, l
        ld (vregs), a
        ld a, h
        and $1F
        ld (vregs + 1), a
        ret

write_scroll:
        ld a, 17
        out (V_REGS), a
        ld a, (vregs)
        out (V_REGD), a
        ld a, (vregs + 1)
        out (V_REGD), a
        ld a, (vregs + 2)
        out (V_REGD), a
        ld a, (vregs + 3)
        out (V_REGD), a
        ret
