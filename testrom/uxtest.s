; UxROM + CHR RAM test ROM for the nes2msxtr translator (64K PRG: three
; switchable banks and the fixed one, vertical mirroring). Original code.
;
; Reset runs self-checks: calls from the fixed bank into the same address
; in each bank, reads of the switchable half from fixed and banked code, a
; banked routine calling a fixed helper that calls back into its own bank,
; a JMP (ptr) table inside a bank, a bank switch through an indirect store,
; and CHR RAM written and read back through $2007. testfail = number of the
; first failing check (0 = all passed); results are folded into cks. The
; backdrop turns green on a pass and red on a failure, over a row of tiles
; drawn from CHR RAM and a sprite from the $1000 table.
;
; NMI saves the bank, calls into bank 2, restores the bank and rewrites a
; row of tile 5 each frame until frame 100, so RAM and CHR can be compared
; between implementations.

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
OAMADDR   = $2003
PPUADDR   = $2006
PPUDATA   = $2007
OAMDMA    = $4014

ptr      = $00                  ; 2 bytes
jptr     = $02                  ; 2 bytes, JMP (ptr) in the banks
frame    = $10
testfail = $11
cks      = $12                  ; 2 bytes
res      = $14
nmicnt   = $15
nmibank  = $16
chrsum   = $17

; same layout in every bank; the fixed bank uses bank 0's labels
.macro bankcode id
        .local t0, t1, t2, jt
        .byte id                ; $8000: bank number
.if id = 0
b_entry:
.endif
        lda $8000               ; A = $A0 + bank
        ora #$A0
        rts
.if id = 0
b_table:
.endif
        .byte $10 + id, $20 + id, $30 + id, $40 + id
.if id = 0
b_viafix:
.endif
        jsr fixhelper           ; -> b_back in this bank
        clc
        adc #1
        rts
.if id = 0
b_back:
.endif
        lda b_table + 1         ; constant: this bank's table
        ora #$C0
        rts
.if id = 0
b_jump:
.endif
        asl a                   ; A = case
        tax
        lda jt,x
        sta jptr
        lda jt + 1,x
        sta jptr + 1
        jmp (jptr)
t0:     lda #$50 + id
        rts
t1:     lda #$60 + id
        rts
t2:     lda #$70 + id
        rts
jt:     .word t0, t1, t2
.if id = 0
b_nmi:
.endif
        inc nmicnt
        lda $8000
        sta nmibank
        rts
.endmacro

.segment "HEADER"
        .byte "NES", $1A, 4, 0, $21, $00
        .res 8, 0

.segment "BANK0"
        bankcode 0
.segment "BANK1"
        bankcode 1
.segment "BANK2"
        bankcode 2

.segment "CODE"

reset:
        sei
        cld
        ldx #$FF
        txs
        inx
        stx PPUCTRL
        stx PPUMASK
@vb1:   bit PPUSTATUS
        bpl @vb1
        txa
@clr:   sta $00,x
        sta $0300,x
        inx
        bne @clr
        lda #$F8
@oam:   sta $0200,x
        inx
        bne @oam
@vb2:   bit PPUSTATUS
        bpl @vb2

        jsr tests
        jsr screen

        ldy #1                  ; bank 1 stays mapped while idle
        jsr switch
        lda #$88                ; NMI on, sprites from $1000
        sta PPUCTRL
forever:
        jmp forever

; Y = bank, written over the same value in ROM (no bus conflict)
switch:
        lda banktab,y
        sta banktab,y
        rts
banktab:
        .byte 0, 1, 2, 3

fixhelper:                      ; called from banked code: its bank is mapped
        jsr b_back
        rts

fail:
        lda testfail
        bne @keep
        stx testfail
@keep:  rts

addck:  clc
        adc cks
        sta cks
        lda cks + 1
        adc #0
        sta cks + 1
        rts

; A = result, expected in res; X = check number
check:  cmp res
        beq @ok
        jsr fail
@ok:    jmp addck

tests:
        ldy #0                  ; 1-3: the same address in each bank
        jsr switch
        jsr b_entry
        ldx #$A0
        stx res
        ldx #1
        jsr check
        ldy #1
        jsr switch
        jsr b_entry
        ldx #$A1
        stx res
        ldx #2
        jsr check
        ldy #2
        jsr switch
        jsr b_entry
        ldx #$A2
        stx res
        ldx #3
        jsr check

        ldx #2                  ; 4: fixed code reads the mapped bank
        lda b_table,x           ; (bank 2 still mapped)
        clc
        adc $8000
        ldx #$34
        stx res
        ldx #4
        jsr check

        ldy #1                  ; 5: banked -> fixed -> same bank
        jsr switch
        jsr b_viafix
        ldx #$E2
        stx res
        ldx #5
        jsr check
        ldy #2
        jsr switch
        jsr b_viafix            ; 6: ... in bank 2
        ldx #$E3
        stx res
        ldx #6
        jsr check

        ldy #1                  ; 7: JMP (ptr) table in a bank
        jsr switch
        lda #2
        jsr b_jump
        ldx #$71
        stx res
        ldx #7
        jsr check
        ldy #0
        jsr switch
        lda #1
        jsr b_jump              ; 8: ... the same table address in bank 0
        ldx #$60
        stx res
        ldx #8
        jsr check

        lda #<banktab           ; 9: bank switch through STA (ptr),Y
        sta ptr
        lda #>banktab
        sta ptr + 1
        ldy #2
        lda #2
        sta (ptr),y
        lda $8000
        ldx #2
        stx res
        ldx #9
        jsr check

        ; 10: CHR RAM: upload tiles 0-4 and sprite tile $100, read back
        lda #$00
        sta PPUADDR
        sta PPUADDR
        ldx #0
@up:    lda tiles,x
        sta PPUDATA
        inx
        cpx #80
        bne @up
        lda #$10
        sta PPUADDR
        lda #$00
        sta PPUADDR
        ldx #0
@ups:   lda tiles + 16,x        ; sprite: the solid tile
        sta PPUDATA
        inx
        cpx #16
        bne @ups
        lda #$00
        sta PPUADDR
        lda #$20
        sta PPUADDR
        lda PPUDATA             ; buffered: the first read is stale
        ldx #0
        stx chrsum
@rd:    lda PPUDATA
        cmp tiles + 32,x
        bne @bad
        clc
        adc chrsum
        sta chrsum
        inx
        cpx #48
        bne @rd
        lda #1
        bne @chk
@bad:   lda #0
@chk:   ldx #1
        stx res
        ldx #10
        jsr check
        lda chrsum
        jmp addck

; palette, a row of tiles 1-5 and sprite 0 on them; backdrop by result
screen:
        lda #$3F
        sta PPUADDR
        lda #$00
        sta PPUADDR
        lda #$1A                ; green: pass
        ldx testfail
        beq @pass
        lda #$16                ; red: fail
@pass:  sta PPUDATA
        lda #$0F
        sta PPUDATA
        lda #$20
        sta PPUDATA
        lda #$12
        sta PPUDATA
        lda #$3F
        sta PPUADDR
        lda #$11
        sta PPUADDR
        lda #$27
        sta PPUDATA
        sta PPUDATA
        sta PPUDATA
        lda #$21                ; row 10 of nametable 0
        sta PPUADDR
        lda #$48
        sta PPUADDR
        ldx #0
@row:   txa
        and #3
        clc
        adc #1
        sta PPUDATA
        inx
        cpx #16
        bne @row
        lda #$21                ; tile 5 (rewritten by NMI) twice
        sta PPUADDR
        lda #$88
        sta PPUADDR
        lda #5
        sta PPUDATA
        sta PPUDATA
        lda #79                 ; sprite 0 on the row
        sta $0200
        lda #$00
        sta $0201
        sta $0202
        lda #120
        sta $0203
        lda #0
        sta OAMADDR
        lda #2
        sta OAMDMA
        lda #$1E
        sta PPUMASK
        rts

nmi:
        pha
        txa
        pha
        tya
        pha
        lda frame
        cmp #100
        beq @out
        inc frame
        lda $8000               ; save the bank, use bank 2, restore
        pha
        ldy #2
        jsr switch
        jsr b_nmi
        pla
        tay
        jsr switch
        lda #$00                ; tile 5, row (frame & 7), both planes
        sta PPUADDR
        lda frame
        and #7
        ora #$50
        sta PPUADDR
        lda frame
        sta PPUDATA
        lda #$00
        sta PPUADDR
        lda frame
        and #7
        ora #$58
        sta PPUADDR
        lda frame
        eor #$FF
        sta PPUDATA
        lda #$00                ; scroll 0
        sta PPUADDR
        sta PPUADDR
@out:   pla
        tay
        pla
        tax
        pla
irq:    rti

tiles:  ; 0 blank, 1 solid colour 3, 2 checker, 3 frame, 4 stripes
        .res 16, $00
        .res 16, $FF
        .byte $AA, $55, $AA, $55, $AA, $55, $AA, $55, $FF, $FF, $00, $00, $FF, $FF, $00, $00
        .byte $FF, $81, $81, $81, $81, $81, $81, $FF, $00, $7E, $42, $42, $42, $42, $7E, $00
        .byte $F0, $F0, $F0, $F0, $0F, $0F, $0F, $0F, $00, $00, $FF, $FF, $00, $00, $FF, $FF

.segment "VECTORS"
        .word nmi, reset, irq
