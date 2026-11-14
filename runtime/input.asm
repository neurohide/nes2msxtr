; NES controller 1 from the MSX keyboard and joystick port 1.
;
;   NES      keyboard            joystick
;   A        Z or SPACE          trigger A
;   B        X                   trigger B
;   Select   SELECT or TAB
;   Start    RETURN
;   D-pad    cursor keys         stick

; A = buttons, 1 = pressed: bit0 A, 1 B, 2 Select, 3 Start,
; 4 Up, 5 Down, 6 Left, 7 Right. Preserves BC, DE.
read_pad:
        push bc
        ld c, 0
        ld a, 8
        call key_row
        bit 0, b
        jr z, $+4
        set 0, c
        bit 5, b
        jr z, $+4
        set 4, c
        bit 6, b
        jr z, $+4
        set 5, c
        bit 4, b
        jr z, $+4
        set 6, c
        bit 7, b
        jr z, $+4
        set 7, c
        ld a, 5
        call key_row
        bit 7, b
        jr z, $+4
        set 0, c
        bit 5, b
        jr z, $+4
        set 1, c
        ld a, 7
        call key_row
        bit 7, b
        jr z, $+4
        set 3, c
        bit 6, b
        jr z, $+4
        set 2, c
        bit 3, b                ; TAB too: openMSX puts SELECT on F7, a media key on Macs
        jr z, $+4
        set 2, c
        ld a, 15                ; joystick port 1, pins 6/7 high
        out (PSG_REG), a
        in a, (PSG_RD)
        and $80
        or $3F
        out (PSG_WR), a
        ld a, 14
        out (PSG_REG), a
        in a, (PSG_RD)
        cpl
        ld b, a
        bit 0, b
        jr z, $+4
        set 4, c
        bit 1, b
        jr z, $+4
        set 5, c
        bit 2, b
        jr z, $+4
        set 6, c
        bit 3, b
        jr z, $+4
        set 7, c
        bit 4, b
        jr z, $+4
        set 0, c
        bit 5, b
        jr z, $+4
        set 1, c
        ld a, c
        pop bc
        ret

; A = keyboard row -> B = pressed keys (1 = down)
key_row:
        ld b, a
        in a, (PPI_ROW)
        and $F0
        or b
        out (PPI_ROW), a
        in a, (PPI_KEYS)
        cpl
        ld b, a
        ret

io_w_4016:
        push af
        bit 0, l
        jr z, w4016_low
        ld a, 1
        ld (pad_strobe), a
        jr w4016_done
w4016_low:
        ld a, (pad_strobe)
        or a
        jr z, w4016_done
        xor a
        ld (pad_strobe), a
        call read_pad
        ld (pad_shift), a
w4016_done:
        pop af
        ret

; While strobing, bit 0 follows A live. Otherwise read the latched buttons
; serially: bit 0 = next button, $40 = open bus; 1s after 8 reads.
io_r_4016:
        push af
        ld a, (pad_strobe)
        or a
        jr z, r4016_shift
        call read_pad
        and 1
        or $40
        ld l, a
        pop af
        ret
r4016_shift:
        ld a, (pad_shift)
        scf
        rra
        ld (pad_shift), a
        ld a, $40
        adc a, 0
        ld l, a
        pop af
        ret
