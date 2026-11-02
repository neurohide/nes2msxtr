; Stack and computed-jump test ROM for the nes2msxtr translator (NROM-128).
; Original code.
;
; Reset runs self-checks of stack idioms: PHA/PHA/RTS dispatch through split
; and word tables, JMP (ptr) through a table, TSX stack inspection, TSX/TXS
; save and restore, PHP/PLP status bytes, return-frame drops and an inline
; jump-table engine. testfail = number of the first failing check (0 = all
; passed); every result is folded into cks. The backdrop turns green on a
; pass and red on a failure.
;
; NMI runs an RTS-trick dispatch on the frame number and inspects its own
; stack frame, until frame 200, so RAM can be compared between
; implementations.

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
PPUADDR   = $2006
PPUDATA   = $2007

ptr      = $00                  ; 2 bytes
eptr     = $02                  ; 2 bytes, used by engine
frame    = $10
testfail = $11
cks      = $12                  ; 2 bytes
acc      = $14
save     = $15
res      = $16
retlo    = $17
rethi    = $18
nmiacc   = $19
nmipeek  = $1A
nmis     = $1B
sbefore  = $1C

.segment "HEADER"
        .byte "NES", $1A, 1, 1, $01, $00
        .res 8, 0

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
        sta $0200,x
        sta $0300,x
        inx
        bne @clr
@vb2:   bit PPUSTATUS
        bpl @vb2

        jsr tests

        lda #$3F                ; backdrop: green = pass, red = fail
        sta PPUADDR
        lda #$00
        sta PPUADDR
        lda #$1A
        ldx testfail
        beq @pass
        lda #$16
@pass:  sta PPUDATA
        lda #$08
        sta PPUMASK
        lda #$80
        sta PPUCTRL
forever:
        jmp forever

; ---------------------------------------------------------------------------
fail:
        lda testfail
        bne @keep
        stx testfail
@keep:  rts

addck:  clc
        adc cks
        sta cks
        lda cks+1
        adc #0
        sta cks+1
        rts

tests:
        lda #0                  ; 1: PHA/PHA/RTS through split lo/hi tables
        sta acc
        ldx #3
@l1:    jsr dispatch_split
        dex
        bpl @l1
        lda acc
        ldx #1
        cmp #$0F
        beq @t2
        jsr fail
@t2:    jsr addck

        lda #0                  ; 2: PHA/PHA/RTS through a word table
        sta acc
        lda #2
@l2:    sta save
        jsr dispatch_word
        lda save
        sec
        sbc #1
        bcs @l2
        lda acc
        ldx #2
        cmp #$60
        beq @t3
        jsr fail
@t3:    jsr addck

        lda #0                  ; 3: JMP (ptr) through a word table
        jsr jmp_ind
        lda #1
        jsr jmp_ind
        lda res
        ldx #3
        cmp #$33
        beq @t4
        jsr fail
@t4:    jsr addck

        lda #$5A                ; 4: TSX + $0100,X reads pushed bytes
        pha
        lda #$A5
        pha
        tsx
        lda $0102,x
        cmp #$5A
        bne @f4
        lda $0101,x
        cmp #$A5
        beq @ok4
@f4:    ldx #4
        jsr fail
@ok4:   pla
        pla
        jsr addck

        jsr peek_ret            ; 5: the return address JSR pushed
ret5:   lda retlo
        ldx #5
        cmp #<(ret5 - 1)
        bne @f5
        lda rethi
        cmp #>(ret5 - 1)
        beq @t6
@f5:    jsr fail
@t6:    lda retlo
        jsr addck

        lda #$77                ; 6: TSX/TXS save and restore
        pha
        tsx
        stx save
        lda #1
        pha
        pha
        pha
        ldx save
        txs
        pla
        ldx #6
        cmp #$77
        beq @t7
        jsr fail
@t7:    jsr addck

        sec                     ; 7: PHP pushes N V 1 B D I Z C
        clv
        lda #$80
        php
        pla
        ldx #7
        cmp #$B5
        beq @t8
        jsr fail
@t8:    jsr addck

        ldx #8                  ; 8: PLP sets V, Z, C from the stack
        lda #$43
        pha
        plp
        bcc @f8
        bne @f8
        bvc @f8
        lda #$80                ; ... and N, with C clear
        pha
        plp
        bpl @f8
        bcc @t9
@f8:    jsr fail
@t9:    lda #8
        jsr addck

        ldx #9                  ; 9: PHP/PLP round trip of Z and C
        lda #0
        sec
        php
        lda #5
        clc
        plp
        bne @f9
        bcs @t10
@f9:    jsr fail
@t10:   lda #9
        jsr addck

        tsx                     ; 10: PLA/PLA return-frame drop keeps S
        stx sbefore
        jsr drop_outer
        tsx
        txa
        ldx #10
        cmp sbefore
        beq @t11
        jsr fail
@t11:   jsr addck

        lda #0                  ; 11: inline jump-table engine
        sta res
        jsr call_engine
        lda res
        ldx #11
        cmp #$3C
        beq @t12
        jsr fail
@t12:   jsr addck
        rts

; X = 0..3 -> h0..h3 via PHA/PHA/RTS
dispatch_split:
        lda split_hi,x
        pha
        lda split_lo,x
        pha
        rts
split_lo:
        .lobytes h0 - 1, h1 - 1, h2 - 1, h3 - 1
split_hi:
        .hibytes h0 - 1, h1 - 1, h2 - 1, h3 - 1

h0:     lda acc
        ora #$01
        sta acc
        rts
h1:     lda acc
        ora #$02
        sta acc
        rts
h2:     lda acc
        ora #$04
        sta acc
        rts
h3:     lda acc
        ora #$08
        sta acc
        rts

; A = 0..2 -> w0..w2 via PHA/PHA/RTS
dispatch_word:
        asl a
        tay
        lda word_tab + 1,y
        pha
        lda word_tab,y
        pha
        rts
word_tab:
        .word w0 - 1, w1 - 1, w2 - 1
        .byte $FF, $FF, $00, $13        ; not addresses: the table ends here

w0:     lda #$10
        bne wadd
w1:     lda #$20
        bne wadd
w2:     lda #$30
wadd:   clc
        adc acc
        sta acc
        rts

; A = 0..1 -> j0..j1 via JMP (ptr)
jmp_ind:
        asl a
        tax
        lda jtab,x
        sta ptr
        lda jtab + 1,x
        sta ptr + 1
        jmp (ptr)
jtab:   .word j0, j1
        .byte "JT"

j0:     lda #$11
        sta res
        rts
j1:     lda res
        ora #$22
        sta res
        rts

peek_ret:
        tsx
        lda $0101,x
        sta retlo
        lda $0102,x
        sta rethi
        rts

drop_outer:
        jsr drop_inner
        lda #$EE                ; skipped: drop_inner returns past us
        sta res
        rts
drop_inner:
        pla
        pla
        rts

call_engine:
        lda #1
        jsr engine
        .word e0, e1
e0:     lda #$C3
        sta res
        rts
e1:     lda #$3C
        sta res
        rts

; A = index into the .word list that follows the JSR
engine:
        asl a
        tay
        pla
        sta eptr
        pla
        sta eptr + 1
        iny
        lda (eptr),y
        sta ptr
        iny
        lda (eptr),y
        sta ptr + 1
        jmp (ptr)

; ---------------------------------------------------------------------------
nmi:
        pha
        txa
        pha
        tya
        pha
        lda frame
        cmp #200
        beq @out
        inc frame
        tsx                     ; A pushed first sits just above the 2 others
        lda $0103,x
        sta nmipeek
        stx nmis
        lda frame
        and #3
        tax
        jsr nmi_dispatch
@out:   pla
        tay
        pla
        tax
        pla
        rti

nmi_dispatch:
        lda nmi_hi,x
        pha
        lda nmi_lo,x
        pha
        rts
nmi_lo: .lobytes n0 - 1, n1 - 1, n2 - 1, n3 - 1
nmi_hi: .hibytes n0 - 1, n1 - 1, n2 - 1, n3 - 1

n0:     inc nmiacc
        rts
n1:     lda nmiacc
        clc
        adc #3
        sta nmiacc
        rts
n2:     asl nmiacc
        rts
n3:     lsr nmiacc
        rts

irq:    rti

.segment "VECTORS"
        .word nmi, reset, irq

.segment "CHR"
        .incbin "testrom.chr"
