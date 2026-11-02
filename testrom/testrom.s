; Translator test ROM (NROM-128, vertical mirroring). Original code.
;
; Reset runs a CPU self-test (result + checksum shown in the status bar),
; draws two nametables, then all game logic runs in NMI: sprite-0 split
; status bar, scrolling playfield, a robot driven by the pad (or a built-in
; demo when no button is held), a jump-table state machine and APU sounds.
; After 200 frames the logic freezes so RAM can be compared between
; implementations.

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
OAMADDR   = $2003
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007
OAMDMA    = $4014
APUSTATUS = $4015
JOY1      = $4016
JOY2      = $4017

CTRL_BASE = $88                 ; NMI on, sprites from $1000, BG from $0000

ptr      = $00                  ; 2 bytes
jt_ptr   = $04                  ; 2 bytes, used by jump_engine
jt_dest  = $06                  ; 2 bytes
tmp      = $08
tmp2     = $09
row      = $0A
col      = $0B
nt       = $0C
frame    = $10
done     = $11
state    = $12
pad      = $13
padprev  = $14
px       = $15
py       = $16
vy       = $17
scrollx  = $18
scrollhi = $19
facing   = $1A
cks      = $1C                  ; 2 bytes
testfail = $1E
sndtimer = $1F
GROUND_Y = $B7

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
        stx $4010
@vb1:   bit PPUSTATUS
        bpl @vb1
        txa
@clr:   sta $00,x
        sta $0300,x
        sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $0700,x
        inx
        bne @clr
        lda #$F8
@oam:   sta $0200,x
        inx
        bne @oam
@vb2:   bit PPUSTATUS
        bpl @vb2

        jsr cpu_test
        jsr load_palettes
        jsr draw_nametables
        jsr draw_status

        lda #$60
        sta px
        lda #GROUND_Y
        sta py
        lda #$0F
        sta APUSTATUS

        lda #CTRL_BASE
        sta PPUCTRL
        lda #$1E
        sta PPUMASK
forever:
        jmp forever

; ---------------------------------------------------------------------------
; CPU self-test. Sets testfail to the number of the first failing check
; (0 = all passed) and folds every intermediate result into cks.
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

cpu_test:
        ldx #1                  ; 1: ADC overflow
        clc
        lda #$50
        adc #$50
        bvc @f1
        bcs @f1
        bpl @f1
        cmp #$A0
        beq @t2
@f1:    jsr fail
@t2:    jsr addck
        ldx #2                  ; 2: SBC borrow + overflow
        sec
        lda #$50
        sbc #$B0
        bcs @f2
        bvc @f2
        cmp #$A0
        beq @t3
@f2:    jsr fail
@t3:    jsr addck
        ldx #3                  ; 3: ASL into carry, zero result
        lda #$80
        asl a
        bcc @f3
        bne @f3
        lda #$01
        clc
        ror a
        bcc @f3
        bne @f3
        sec
        lda #$40
        rol a
        bcs @f3
        cmp #$81
        beq @t4
@f3:    jsr fail
@t4:    jsr addck
        ldx #4                  ; 4: compares
        lda #$10
        cmp #$20
        bcs @f4
        bpl @f4
        beq @f4
        ldy #$05
        cpy #$05
        bne @f4
        bcc @f4
        ldx #$03
        cpx #$04
        ldx #4
        bcs @f4
        jmp @t5
@f4:    jsr fail
@t5:    ldx #5                  ; 5: BIT flags (N/V, then Z)
        lda #$01
        bit bitval
        bvc @f5
        bpl @f5
        lda #$01
        bit bitval
        bne @f5
        lda #$40
        bit bitval
        beq @f5
        jmp @t6
@f5:    jsr fail
@t6:    ldx #6                  ; 6: INC/DEC memory wrap
        lda #$FF
        sta tmp
        inc tmp
        bne @f6
        dec tmp
        bpl @f6
        lda tmp
        jsr addck
        jmp @t7
@f6:    jsr fail
@t7:    ldx #$10                ; 7: zero-page,X wraps within page 0
        lda #$5A
        sta $F8,x
        ldx #7
        lda $08
        cmp #$5A
        bne @f7
        ldy #$10
        ldx $F8,y               ; zp,Y also wraps
        ldx #7
        cpx #7
        bne @f7
        jmp @t8
@f7:    jsr fail
@t8:    ldx #8                  ; 8: (zp),Y across a page, (zp,X)
        lda #$F0
        sta ptr
        lda #$02
        sta ptr+1
        ldy #$20
        lda #$C3
        sta (ptr),y             ; writes $0310
        lda $0310
        cmp #$C3
        bne @f8
        lda #$10
        sta $20
        lda #$03
        sta $21
        ldx #$20
        lda ($00,x)             ; reads $0310 via ($20)
        ldx #8
        cmp #$C3
        bne @f8
        lda #<sqtab
        sta ptr
        lda #>sqtab
        sta ptr+1
        ldy #9
        lda (ptr),y             ; ROM read through a pointer
        cmp #81
        bne @f8
        jsr addck
        jmp @t9
@f8:    jsr fail
@t9:    ldx #9                  ; 9: PHP/PLP keeps carry, PHA/PLA
        sec
        php
        clc
        plp
        bcc @f9
        lda #$77
        pha
        lda #$00
        pla
        cmp #$77
        bne @f9
        jmp @t10
@f9:    jsr fail
@t10:   lda #0                  ; 10: PLA/PLA return-address drop
        sta tmp
        jsr drop_outer
        ldx #10
        lda tmp
        cmp #1
        beq @t11
        jsr fail
@t11:   jsr dispatch_test       ; 11: jump-table dispatch
        ldx #11
        lda tmp
        cmp #$33
        beq @t12
        jsr fail
@t12:   ldx #12                 ; 12: LSR/ROR memory, abs,Y table read
        lda #$03
        sta tmp
        lsr tmp
        bcc @f12
        ror tmp
        bcc @f12
        lda tmp
        cmp #$80
        bne @f12
        ldy #4
        lda sqtab,y
        cmp #16
        bne @f12
        jsr addck
        jmp @t13
@f12:   jsr fail
@t13:   ldx #0                  ; 13: 256-iteration loop checksum
        lda #0
        sta tmp
        sta tmp2
@l13:   txa
        clc
        adc tmp
        sta tmp
        lda tmp2
        adc #0
        sta tmp2
        dex
        bne @l13
        lda tmp
        jsr addck
        lda tmp2
        jsr addck
        ldy #0                  ; DEY wraps to $FF
        dey
        cpy #$FF
        beq @done
        ldx #13
        jsr fail
@done:  rts

drop_outer:
        jsr drop_inner
        lda #2                  ; must be skipped
        sta tmp
        rts
drop_inner:
        lda #1
        sta tmp
        pla
        pla
        rts

dispatch_test:
        lda #2
        jsr jump_engine
        .word case0, case1, case2
case0:  lda #$11
        sta tmp
        rts
case1:  lda #$22
        sta tmp
        rts
case2:  lda #$33
        sta tmp
        rts

; A = index; the word table follows the JSR.
jump_engine:
        asl a
        tay
        pla
        sta jt_ptr
        pla
        sta jt_ptr+1
        iny
        lda (jt_ptr),y
        sta jt_dest
        iny
        lda (jt_ptr),y
        sta jt_dest+1
        jmp (jt_dest)

; ---------------------------------------------------------------------------
load_palettes:
        lda #$3F
        sta PPUADDR
        lda #$00
        sta PPUADDR
        ldx #0
@l:     lda palettes,x
        sta PPUDATA
        inx
        cpx #32
        bne @l
        rts

; Tile for (row, col + nt*32), returned in A.
tile_at:
        lda row
        cmp #5
        bcc @blank
        beq @bar
        cmp #24
        beq @grass
        bcs @brick
        lda col
        ora nt                  ; nt is 0 or 32
        tay
        lda (ptr),y             ; pillar height, ptr -> heights
        sta tmp
        lda #24
        sec
        sbc tmp
        cmp row
        beq @block
        bcc @block
        lda row
        cmp #9
        beq @cloud
        cmp #10
        bne @blank
@cloud: lda col
        and #7
        cmp #2
        beq @dots
        cmp #3
        beq @dots
@blank: lda #0
        rts
@bar:   lda #1
        rts
@grass:
@block: lda #3
        rts
@brick: lda #2
        rts
@dots:  lda #4
        rts

draw_nametables:
        lda #<heights
        sta ptr
        lda #>heights
        sta ptr+1
        lda #0
        sta nt
@ntl:   lda nt
        lsr a
        lsr a
        lsr a                   ; 0 or 4
        ora #$20
        sta PPUADDR
        lda #0
        sta PPUADDR
        sta row
@rowl:  lda #0
        sta col
@coll:  jsr tile_at
        sta PPUDATA
        inc col
        lda col
        cmp #32
        bne @coll
        inc row
        lda row
        cmp #30
        bne @rowl
        ldx #0                  ; attribute table
@attr:  lda attrs,x
        sta PPUDATA
        inx
        cpx #64
        bne @attr
        lda nt
        clc
        adc #32
        sta nt
        cmp #64
        bne @ntl
        rts

; "CPU OK hhhh" / "CPU NG nn" on row 3, "FRAME" label on row 4.
draw_status:
        lda #$20
        sta PPUADDR
        lda #$64
        sta PPUADDR
        ldx #0
@t:     lda txt_cpu,x
        sta PPUDATA
        inx
        cpx #4
        bne @t
        lda testfail
        bne @ng
        lda #$24                ; O
        sta PPUDATA
        lda #$21                ; K
        sta PPUDATA
        lda #0
        sta PPUDATA
        lda cks+1
        jsr puthex
        lda cks
        jsr puthex
        jmp @frame
@ng:    lda #$23                ; N
        sta PPUDATA
        lda #$20                ; G
        sta PPUDATA
        lda #0
        sta PPUDATA
        lda testfail
        jsr puthex
@frame: lda #$20
        sta PPUADDR
        lda #$84
        sta PPUADDR
        ldx #0
@f:     lda txt_frame,x
        sta PPUDATA
        inx
        cpx #6
        bne @f
        rts

puthex: pha
        lsr a
        lsr a
        lsr a
        lsr a
        ora #$10
        sta PPUDATA
        pla
        and #$0F
        ora #$10
        sta PPUDATA
        rts

; ---------------------------------------------------------------------------
nmi:
        pha
        txa
        pha
        tya
        pha
        lda #0
        sta OAMADDR
        lda #$02
        sta OAMDMA
        lda #$20                ; frame counter after "FRAME:"
        sta PPUADDR
        lda #$8A
        sta PPUADDR
        lda frame
        jsr puthex
        lda #0                  ; status bar: no scroll
        sta PPUSCROLL
        sta PPUSCROLL
        lda #CTRL_BASE
        sta PPUCTRL
@w0:    bit PPUSTATUS           ; wait for sprite-0 hit to clear, then set
        bvs @w0
@w1:    bit PPUSTATUS
        bvc @w1
        lda scrollx
        sta PPUSCROLL
        lda #0
        sta PPUSCROLL
        lda scrollhi
        ora #CTRL_BASE
        sta PPUCTRL

        lda done
        bne nmi_out
        jsr read_pad
        lda state
        jsr jump_engine
        .word st_walk, st_air
nmi_after:
        jsr sound
        jsr build_oam
        inc frame
        lda frame
        cmp #200
        bne nmi_out
        inc done
nmi_out:
        pla
        tay
        pla
        tax
        pla
        rti

read_pad:
        lda pad
        sta padprev
        lda #1
        sta JOY1
        lda #0
        sta JOY1
        ldx #8
@b:     lda JOY1
        lsr a
        rol pad
        dex
        bne @b
        lda pad                 ; bits: A B Sel Start U D L R (A = bit 7)
        bne @r
        lda frame               ; demo input when nothing is held
        and #$40
        bne @left
        lda #$01                ; right
        bne @jump
@left:  lda #$02
@jump:  sta pad
        lda frame
        and #$1F
        cmp #5
        bne @r
        lda pad
        ora #$80
        sta pad
@r:     rts

; Walking: horizontal movement, A starts a jump.
st_walk:
        jsr move_x
        lda pad
        bpl @nojump
        lda padprev
        bmi @nojump
        lda #$FA                ; vy = -6
        sta vy
        lda #1
        sta state
        lda #$85                ; pulse 1: duty 2, envelope period 5
        sta $4000
        lda #$A3                ; sweep up
        sta $4001
        lda #$C0
        sta $4002
        lda #$28
        sta $4003
@nojump:
        jmp nmi_after

; Airborne: gravity every other frame, land on the ground line.
st_air:
        jsr move_x
        lda py
        clc
        adc vy
        sta py
        lda frame
        and #1
        bne @nog
        inc vy
@nog:   lda vy
        bmi @up
        lda py
        cmp #GROUND_Y
        bcc @up
        lda #GROUND_Y
        sta py
        lda #0
        sta state
        lda #$04                ; noise thump on landing
        sta $400C
        lda #$0A
        sta $400E
        lda #$18
        sta $400F
@up:    jmp nmi_after


move_x:
        lda pad
        lsr a                   ; right -> carry
        bcc @notr
        lda #0
        sta facing
        lda px
        cmp #$80
        bcs @scroll
        inc px
        rts
@scroll:
        inc scrollx
        bne @r
        lda scrollhi
        eor #1
        sta scrollhi
@r:     rts
@notr:  lsr a                   ; left -> carry
        bcc @r
        lda #$40
        sta facing
        lda px
        cmp #9
        bcc @r
        dec px
        rts

; Triangle plays a two-note pattern; length/linear counters stop it.
sound:
        inc sndtimer
        lda sndtimer
        and #$1F
        bne @r
        lda #$C0
        sta $4008
        lda sndtimer
        and #$20
        beq @lo
        lda #$A9
        bne @set
@lo:    lda #$FD
@set:   sta $400A
        lda #$08
        sta $400B
@r:     rts

; OAM: sprite 0 marker under the status bar, robot as 2x2 sprites.
build_oam:
        lda #39
        sta $0200
        lda #4
        sta $0201
        lda #0
        sta $0202
        lda #8
        sta $0203
        ldx #0                  ; 4 robot parts, from robot_parts
        ldy #4
@p:     lda py
        clc
        adc robot_parts,x       ; dy
        sta $0200,y
        lda robot_parts+1,x     ; tile
        bit facing
        bvc @nof
        eor #1                  ; mirrored: swap left/right tiles
@nof:   sta $0201,y
        lda facing
        ora #1                  ; palette 1
        sta $0202,y
        lda px
        clc
        adc robot_parts+2,x     ; dx
        sta $0203,y
        inx
        inx
        inx
        iny
        iny
        iny
        iny
        cpy #20
        bne @p
        rts

; ---------------------------------------------------------------------------
robot_parts:                    ; dy, tile, dx
        .byte 0, 0, 0,  0, 1, 8,  8, 2, 0,  8, 3, 8
bitval: .byte $C0
sqtab:  .byte 0, 1, 4, 9, 16, 25, 36, 49, 64, 81
txt_cpu:   .byte $1C, $25, $29, $00            ; "CPU "
txt_frame: .byte $1F, $26, $1A, $22, $1E, $2C  ; "FRAME:"
palettes:
        .byte $21, $30, $10, $00,  $21, $27, $17, $07
        .byte $21, $2A, $1A, $0A,  $21, $30, $16, $06
        .byte $21, $30, $00, $0F,  $21, $30, $11, $0F
        .byte $21, $28, $16, $0F,  $21, $30, $2A, $0F
heights:
        .byte 0,0,0,2,2,0,0,0, 0,4,4,4,0,0,0,1, 0,0,3,0,0,0,0,0, 6,6,0,0,0,2,0,0
        .byte 0,0,0,1,1,1,0,0, 0,0,5,0,0,0,0,0, 2,3,4,5,0,0,0,0, 0,0,0,0,3,3,0,0
attrs:
        .byte $00,$00,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$00,$00,$00,$00,$00
        .byte $AA,$AA,$AA,$AA,$AA,$AA,$AA,$AA
        .byte $AA,$AA,$AA,$AA,$AA,$AA,$AA,$AA
        .byte $AA,$AA,$AA,$AA,$AA,$AA,$AA,$AA
        .byte $AA,$AA,$AA,$AA,$AA,$AA,$AA,$AA
        .byte $55,$55,$55,$55,$55,$55,$55,$55
        .byte $55,$55,$55,$55,$55,$55,$55,$55

.segment "VECTORS"
        .word nmi, reset, reset

.segment "CHR"
        .incbin "testrom.chr"
