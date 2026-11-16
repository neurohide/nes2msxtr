; 6502 interpreter: the last code bank (INTERP_BANK). dyn_find sends a jump or
; call to an address with no translated code here (a miss) instead of
; stopping: the original bytes are run one instruction at a time, until the
; flow reaches translated code again. Slow, but correct where the tracer
; found no entry. tools/nes2msxtr.py puts the preamble ($0000-$00FF), the
; opcode table at $0200 and the instruction stubs at the marked line.
;
; Registers as in translated code: A, carry, D = last N/Z result, C = X,
; E = Y, B = 0, (vflag), (p_id), s6_ptr. IY = the 6502 PC. HL is scratch
; (mem_rd / mem_wr_v take the address in it); the shadow set is scratch too.

; Entered through far_jump / far_call; bad_addr = the address that missed.
interp_entry:
        ld iy, (bad_addr)

; Next instruction.
il:     push iy
        pop hl
        inc iy
        call mem_rd             ; L = opcode
        push af
        ld h, 0
        add hl, hl
        inc h                   ; the table is at $0200
        inc h
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        pop af
        jp (hl)

; PC (IY) changed by a jump or a taken branch: translated code starts there?
ij:     push iy
        pop hl
        di
        ex af, af'
        call dyn_find           ; A = bank, HL = Z80 address
        cp INTERP_BANK
        jr z, ij_stay
        jp far_jump
ij_stay: ex af, af'
        ei
        jp il

        defs $0200 - $, $ff     ; the opcode table is at $0200

;@TABLE@

; ---------------------------------------------------------------------------
; Addressing modes -> HL = effective address. AF (carry) is preserved.

; L = next byte of the program
fetch:  push iy
        pop hl
        inc iy
        jp mem_rd

am_imm:  push iy
        pop hl
        inc iy
        ret
am_zp:   call fetch
        ld h, 0
        ret
am_zpx:  call fetch
        push af
        ld a, l
        add a, c
        ld l, a
        ld h, 0
        pop af
        ret
am_zpy:  call fetch
        push af
        ld a, l
        add a, e
        ld l, a
        ld h, 0
        pop af
        ret
am_abs:  push iy
        pop hl
        inc iy
        inc iy
        jr rdw
am_abx:  call am_abs
        push af
        ld b, 0
        add hl, bc
        pop af
        ret
am_aby:  call am_abs
        push af
        push de
        ld d, 0
        add hl, de
        pop de
        pop af
        ret
am_izx:  call fetch
        push af
        ld a, l
        add a, c
        ld l, a
        pop af
        ld h, 0
        jr rdwz
am_izy:  call fetch
        ld h, 0
        call rdwz
        push af
        push de
        ld d, 0
        add hl, de
        pop de
        pop af
        ret

; HL = address -> HL = the word there
rdw:    push af
        push hl
        call mem_rd
        ld a, l
        pop hl
        inc hl
        call mem_rd
        ld h, l
        ld l, a
        pop af
        ret
; ... in page 0 (the pointer wraps in it, like JMP ($xxFF))
rdwz:   push af
        push hl
        call mem_rd
        ld a, l
        pop hl
        inc l
        call mem_rd
        ld h, l
        ld l, a
        pop af
        ret

; ---------------------------------------------------------------------------
; Reads: HL = address.
x_lda:  call mem_rd
        ld a, l
        ld d, a
        jp il
x_ldx:  call mem_rd
        ld c, l
        ld d, l
        jp il
x_ldy:  call mem_rd
        ld e, l
        ld d, l
        jp il
x_and:  call mem_rd
        push af
        and l
        ld d, a
        pop af
        ld a, d
        jp il
x_ora:  call mem_rd
        push af
        or l
        ld d, a
        pop af
        ld a, d
        jp il
x_eor:  call mem_rd
        push af
        xor l
        ld d, a
        pop af
        ld a, d
        jp il
x_adc:  call mem_rd
        adc a, l
        jr adc_v
x_sbc:  call mem_rd
        ccf
        sbc a, l
        ccf
; V from the Z80 overflow flag; the carry goes on unchanged
adc_v:  ld d, a
        push af
        ld a, 0
        jp po, adc_nv
        ld a, $40
adc_nv: ld (vflag), a
        pop af
        jp il
x_cmp:  call mem_rd
        ld d, a
        sub l
        jr cmp_e
x_cpx:  call mem_rd
        ld d, a
        ld a, c
        sub l
        jr cmp_e
x_cpy:  call mem_rd
        ld d, a
        ld a, e
        sub l
cmp_e:  ccf
        ld l, a
        ld a, d
        ld d, l
        jp il
; Z from A & operand, V and N from the operand (N is lost if the AND is 0)
x_bit:  call mem_rd
        push af
        and l
        ld d, a
        jr z, bit_z
        ld a, l
        and $80
        or d
        ld d, a
bit_z:  ld a, l
        and $40
        ld (vflag), a
        pop af
        jp il

; Writes: HL = address.
x_sta:  ld (wr_val), a
        call mem_wr_v
        jp il
x_stx:  push af
        ld a, c
        ld (wr_val), a
        pop af
        call mem_wr_v
        jp il
x_sty:  push af
        ld a, e
        ld (wr_val), a
        pop af
        call mem_wr_v
        jp il

; Read-modify-write: HL = address.
x_asl:  push hl
        call mem_rd
        sla l
        jr rmw_w
x_lsr:  push hl
        call mem_rd
        srl l
        jr rmw_w
x_rol:  push hl
        call mem_rd
        rl l
        jr rmw_w
x_ror:  push hl
        call mem_rd
        rr l
        jr rmw_w
x_inc:  push hl
        call mem_rd
        inc l
        jr rmw_w
x_dec:  push hl
        call mem_rd
        dec l
rmw_w:  ld d, l
        push af
        ld a, l
        ld (wr_val), a
        pop af
        pop hl
        call mem_wr_v
        jp il

; Accumulator forms
x_asl_a: sla a
        ld d, a
        jp il
x_lsr_a: srl a
        ld d, a
        jp il
x_rol_a: rla
        ld d, a
        jp il
x_ror_a: rra
        ld d, a
        jp il

; Operand skipped, nothing read (the unofficial NOPs)
x_nop_m: jp il

; ---------------------------------------------------------------------------
; Implied
x_nop:  jp il
x_inx:  inc c
        ld d, c
        jp il
x_dex:  dec c
        ld d, c
        jp il
x_iny:  inc e
        ld d, e
        jp il
x_dey:  dec e
        ld d, e
        jp il
x_tax:  ld c, a
        ld d, a
        jp il
x_tay:  ld e, a
        ld d, a
        jp il
x_txa:  ld a, c
        ld d, a
        jp il
x_tya:  ld a, e
        ld d, a
        jp il
x_tsx:  ld hl, (s6_ptr)
        ld c, l
        ld d, c
        jp il
x_txs:  ld hl, s6_ptr
        ld (hl), c
        jp il
x_clc:  scf
        ccf
        jp il
x_sec:  scf
        jp il
x_clv:  ld hl, vflag
        ld (hl), 0
        jp il
x_cli:  ld hl, p_id
        res 2, (hl)
        jp il
x_sei:  ld hl, p_id
        set 2, (hl)
        jp il
x_cld:  ld hl, p_id
        res 3, (hl)
        jp il
x_sed:  ld hl, p_id
        set 3, (hl)
        jp il
x_pha:  ld hl, (s6_ptr)
        ld (hl), a
        dec l
        ld (s6_ptr), hl
        jp il
x_pla:  ld hl, (s6_ptr)
        inc l
        ld a, (hl)
        ld (s6_ptr), hl
        ld d, a
        jp il
x_php:  call php_rt
        jp il
x_plp:  call plp_rt
        jp il

; Branches: the offset follows
x_bne:  inc d
        dec d
        jr nz, br_do
        jr br_no
x_beq:  inc d
        dec d
        jr z, br_do
        jr br_no
x_bmi:  inc d
        dec d
        jp m, br_do
        jr br_no
x_bpl:  inc d
        dec d
        jp p, br_do
        jr br_no
x_bcc:  jr nc, br_do
        jr br_no
x_bcs:  jr c, br_do
        jr br_no
x_bvc:  ld hl, vflag
        bit 6, (hl)
        jr z, br_do
        jr br_no
x_bvs:  ld hl, vflag
        bit 6, (hl)
        jr nz, br_do
br_no:  inc iy
        jp il
br_do:  call fetch              ; L = offset
        push af
        ld a, l
        exx
        ld e, a
        ld d, 0
        bit 7, e
        jr z, br_pos
        dec d
br_pos: push iy
        pop hl
        add hl, de
        push hl
        pop iy
        exx
        pop af
        jp ij

; ---------------------------------------------------------------------------
; Jumps
x_jmp:  call am_abs
        push hl
        pop iy
        jp ij
x_jmpi: call am_abs              ; HL = the pointer; the 6502 wraps its low byte
        call rdwz
        push hl
        pop iy
        jp ij
x_jsr:  call am_abs              ; HL = target, IY = after the operand
if FAITHFUL
        push af
        exx
        push iy
        pop de
        dec de
        ld hl, (s6_ptr)
        ld (hl), d
        dec l
        ld (hl), e
        dec l
        ld (s6_ptr), hl
        exx
        pop af
endif
        di
        ex af, af'
        call dyn_find
        cp INTERP_BANK
        jr z, js_int
        push iy                 ; the translated callee may jump back into the
        call far_call           ; interpreter (interp_entry reloads IY), whose
        pop iy                  ; RTS returns here (xret restores this bank)
        jp il
js_int: ex af, af'
        ei
        push iy                 ; interpreted routine: nested, its RTS returns
        ld iy, (bad_addr)
        call il
        pop iy
        jp il
x_rts:
if FAITHFUL
        ld hl, s6_ptr
        inc (hl)
        inc (hl)
endif
        ret

; BRK, RTI and the unofficial opcodes: stop. bad_addr = the opcode's address.
x_bad:  push iy
        pop hl
        dec hl
        ld (bad_addr), hl
        jp crash
