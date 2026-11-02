; NES APU -> MSX PSG (AY-3-8910), updated once per frame.
;
; Pulse 1 -> PSG A, pulse 2 -> PSG B, triangle -> PSG C tone,
; noise -> PSG noise mixed into C. The PSG clock equals the NES CPU clock,
; so a pulse timer t maps to PSG period t+1, the triangle to 2*(t+1).
; Quarter-frame clocks (envelope, linear counter) run 4x and half-frame
; clocks (length, sweep) 2x per 60 Hz frame. DMC is not emulated.

APU_P1: equ APU + $20   ; +0 len +1 env_start +2 env_div +3 env_decay
APU_P2: equ APU + $28   ; +4 sweep_div +5 sweep_reload +6 negate extra
APU_N:  equ APU + $30
APU_T:  equ APU + $38   ; +0 len +1 linear +2 linear_reload
APU_EN: equ APU + $3F
APU_VA: equ APU + $40   ; computed PSG volumes
APU_VB: equ APU + $41
APU_VC: equ APU + $42
APU_VN: equ APU + $43

apu_rd_tab:
        dw io_r_zero, io_r_zero, io_r_zero, io_r_zero
        dw io_r_zero, io_r_zero, io_r_zero, io_r_zero
        dw io_r_zero, io_r_zero, io_r_zero, io_r_zero
        dw io_r_zero, io_r_zero, io_r_zero, io_r_zero
        dw io_r_zero, io_r_zero, io_r_zero, io_r_zero
        dw io_r_zero, io_r_4015, io_r_4016, io_r_open
apu_wr_tab:
        dw apu_w_00, apu_w_01, apu_w_02, apu_w_03
        dw apu_w_04, apu_w_05, apu_w_06, apu_w_07
        dw apu_w_08, apu_w_09, apu_w_0a, apu_w_0b
        dw apu_w_0c, apu_w_0d, apu_w_0e, apu_w_0f
        dw apu_w_10, apu_w_11, apu_w_12, apu_w_13
        dw io_w_4014, apu_w_15, io_w_4016, io_nop

apu_w_00: ld h, $00
        jr apu_w
apu_w_01: ld h, $01
        jr apu_w
apu_w_02: ld h, $02
        jr apu_w
apu_w_03: ld h, $03
        jr apu_w
apu_w_04: ld h, $04
        jr apu_w
apu_w_05: ld h, $05
        jr apu_w
apu_w_06: ld h, $06
        jr apu_w
apu_w_07: ld h, $07
        jr apu_w
apu_w_08: ld h, $08
        jr apu_w
apu_w_09: ld h, $09
        jr apu_w
apu_w_0a: ld h, $0A
        jr apu_w
apu_w_0b: ld h, $0B
        jr apu_w
apu_w_0c: ld h, $0C
        jr apu_w
apu_w_0d: ld h, $0D
        jr apu_w
apu_w_0e: ld h, $0E
        jr apu_w
apu_w_0f: ld h, $0F
        jr apu_w
apu_w_10: ld h, $10
        jr apu_w
apu_w_11: ld h, $11
        jr apu_w
apu_w_12: ld h, $12
        jr apu_w
apu_w_13: ld h, $13
        jr apu_w
apu_w_15: ld h, $15

; H = register index, L = value
apu_w:
        push af
        push de
        ld e, h
        ld d, 0
        ld a, l
        ld hl, APU
        add hl, de
        ld (hl), a
        ld l, a
        ld a, e
        cp $03
        jr z, aw_p1_hi
        cp $07
        jr z, aw_p2_hi
        cp $0B
        jr z, aw_t_hi
        cp $0F
        jr z, aw_n_hi
        cp $01
        jr z, aw_p1_sw
        cp $05
        jr z, aw_p2_sw
        cp $15
        jr z, aw_en
aw_done:
        pop de
        pop af
        ret
aw_p1_sw:
        ld a, 1
        ld (APU_P1 + 5), a
        jr aw_done
aw_p2_sw:
        ld a, 1
        ld (APU_P2 + 5), a
        jr aw_done
aw_p1_hi:
        ld de, APU_P1
        ld a, 1
        jr aw_hi
aw_p2_hi:
        ld de, APU_P2
        ld a, 2
        jr aw_hi
aw_n_hi:
        ld de, APU_N
        ld a, 8
aw_hi:  ld h, a
        ld a, (APU_EN)
        and h
        jr z, aw_hi_env
        call len_lookup
        ld (de), a
aw_hi_env:
        inc de
        ld a, 1
        ld (de), a              ; restart envelope
        jr aw_done
aw_t_hi:
        ld a, (APU_EN)
        and 4
        jr z, aw_t_r
        call len_lookup
        ld (APU_T), a
aw_t_r: ld a, 1
        ld (APU_T + 2), a
        jr aw_done
aw_en:  ld a, l
        ld (APU_EN), a
        xor a
        bit 0, l
        jr nz, $+5
        ld (APU_P1), a
        bit 1, l
        jr nz, $+5
        ld (APU_P2), a
        bit 2, l
        jr nz, $+5
        ld (APU_T), a
        bit 3, l
        jr nz, $+5
        ld (APU_N), a
        jr aw_done

; L = length register value -> A = length counter load
len_lookup:
        push hl
        ld a, l
        rrca
        rrca
        rrca
        and $1F
        ld hl, lentab
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld a, (hl)
        pop hl
        ret

io_r_4015:
        push af
        ld l, 0
        ld a, (APU_P1)
        or a
        jr z, $+4
        set 0, l
        ld a, (APU_P2)
        or a
        jr z, $+4
        set 1, l
        ld a, (APU_T)
        or a
        jr z, $+4
        set 2, l
        ld a, (APU_N)
        or a
        jr z, $+4
        set 3, l
        pop af
        ret

; ---------------------------------------------------------------------------
; Per-frame update (from the vblank interrupt; all registers saved there).
apu_frame:
        ld b, 4
af_q:   push bc
        ld ix, APU_P1
        ld iy, APU + $00
        call env_clock
        ld ix, APU_P2
        ld iy, APU + $04
        call env_clock
        ld ix, APU_N
        ld iy, APU + $0C
        call env_clock
        call tri_linear
        pop bc
        bit 0, b
        jr z, af_nohalf
        push bc
        ld ix, APU_P1
        ld iy, APU + $00
        call len_clock
        call sweep_clock
        ld ix, APU_P2
        ld iy, APU + $04
        call len_clock
        call sweep_clock
        ld ix, APU_N
        ld iy, APU + $0C
        call len_clock
        call tri_len
        pop bc
af_nohalf:
        djnz af_q
        jp apu_out

; IX = channel state, IY = channel registers
env_clock:
        ld a, (ix+1)
        or a
        jr z, ec_run
        ld (ix+1), 0
        ld (ix+3), 15
        ld a, (iy+0)
        and 15
        ld (ix+2), a
        ret
ec_run: ld a, (ix+2)
        or a
        jr z, ec_tick
        dec (ix+2)
        ret
ec_tick:
        ld a, (iy+0)
        and 15
        ld (ix+2), a
        ld a, (ix+3)
        or a
        jr z, ec_loop
        dec (ix+3)
        ret
ec_loop:
        bit 5, (iy+0)
        ret z
        ld (ix+3), 15
        ret

len_clock:
        bit 5, (iy+0)           ; halt
        ret nz
        ld a, (ix+0)
        or a
        ret z
        dec (ix+0)
        ret

tri_linear:
        ld a, (APU_T + 2)
        or a
        jr z, tl_dec
        ld a, (APU + 8)
        and $7F
        ld (APU_T + 1), a
        jr tl_ctl
tl_dec: ld a, (APU_T + 1)
        or a
        jr z, tl_ctl
        dec a
        ld (APU_T + 1), a
tl_ctl: ld a, (APU + 8)
        bit 7, a
        ret nz
        xor a
        ld (APU_T + 2), a
        ret

tri_len:
        ld a, (APU + 8)
        bit 7, a
        ret nz
        ld a, (APU_T)
        or a
        ret z
        dec a
        ld (APU_T), a
        ret

; HL = sweep target period for the pulse channel at IX/IY
sweep_target:
        ld a, (iy+2)
        ld l, a
        ld a, (iy+3)
        and 7
        ld h, a
        push hl
        ld a, (iy+1)
        and 7
        jr z, st_nosh
        ld b, a
st_sh:  srl h
        rr l
        djnz st_sh
st_nosh:
        ex de, hl
        pop hl
        ld a, (iy+1)
        bit 3, a
        jr nz, st_neg
        add hl, de
        ret
st_neg: or a
        sbc hl, de
        ld a, (ix+6)
        or a
        ret z
        dec hl
        ret

sweep_clock:
        ld a, (ix+4)
        or a
        jr nz, sc_dec
        ld a, (iy+1)
        bit 7, a
        jr z, sc_reload
        and 7
        jr z, sc_reload
        call sweep_target
        ld a, (iy+3)            ; muted channels do not sweep
        and 7
        jr nz, sc_p8
        ld a, (iy+2)
        cp 8
        jr c, sc_reload
sc_p8:  ld a, h
        cp 8
        jr nc, sc_reload
        ld a, l
        ld (iy+2), a
        ld a, (iy+3)
        and $F8
        or h
        ld (iy+3), a
sc_reload:
        ld a, (iy+1)
        rrca
        rrca
        rrca
        rrca
        and 7
        ld (ix+4), a
        ld (ix+5), 0
        ret
sc_dec: ld a, (ix+5)
        or a
        jr nz, sc_reload
        dec (ix+4)
        ret

; A = PSG volume for the pulse channel at IX/IY
pulse_vol:
        ld a, (ix+0)
        or a
        jr z, pv_0
        ld a, (iy+3)
        and 7
        jr nz, pv_ok8
        ld a, (iy+2)
        cp 8
        jr c, pv_0
pv_ok8: ld a, (iy+1)
        bit 3, a
        jr nz, pv_vol
        call sweep_target
        ld a, h
        cp 8
        jr nc, pv_0
pv_vol: ld a, (iy+0)
        bit 4, a
        jr z, pv_env
        and 15
        jr vol_map
pv_env: ld a, (ix+3)
; A = NES volume 0-15 -> PSG volume
vol_map:
        ld hl, voltab
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld a, (hl)
        ret
pv_0:   xor a
        ret

; A = register, E = value
psg_w:  out (PSG_REG), a
        ld a, e
        out (PSG_WR), a
        ret

apu_out:
        ld ix, APU_P1
        ld iy, APU + $00
        call pulse_vol
        ld (APU_VA), a
        ld ix, APU_P2
        ld iy, APU + $04
        call pulse_vol
        ld (APU_VB), a
        ld a, (APU_N)           ; noise volume
        or a
        jr z, ao_n0
        ld a, (APU + $0C)
        bit 4, a
        jr z, ao_nenv
        and 15
        jr ao_nmap
ao_nenv:
        ld a, (APU_N + 3)
ao_nmap:
        call vol_map
ao_n0:  ld (APU_VN), a

        ld a, (APU + $02)       ; tone periods
        ld l, a
        ld a, (APU + $03)
        and 7
        ld h, a
        inc hl
        ld a, 0
        ld e, l
        call psg_w
        ld a, 1
        ld e, h
        call psg_w
        ld a, (APU + $06)
        ld l, a
        ld a, (APU + $07)
        and 7
        ld h, a
        inc hl
        ld a, 2
        ld e, l
        call psg_w
        ld a, 3
        ld e, h
        call psg_w

        ld a, (APU + $0A)       ; triangle
        ld l, a
        ld a, (APU + $0B)
        and 7
        ld h, a
        ld c, 0                 ; triangle volume
        ld a, (APU_T)
        or a
        jr z, ao_t0
        ld a, (APU_T + 1)
        or a
        jr z, ao_t0
        ld a, h
        or a
        jr nz, ao_ton
        ld a, l
        cp 2
        jr c, ao_t0
ao_ton: ld c, 13
ao_t0:  inc hl
        add hl, hl
        ld a, h
        cp $10
        jr c, ao_tok
        ld hl, $0FFF
ao_tok: ld a, 4
        ld e, l
        call psg_w
        ld a, 5
        ld e, h
        call psg_w

        ld a, (APU + $0E)       ; noise period
        and 15
        ld hl, noisetab
        add a, l
        ld l, a
        adc a, h
        sub l
        ld h, a
        ld a, 6
        ld e, (hl)
        call psg_w

        ld b, $98               ; mixer: port B out, noise A/B off
        ld a, c
        or a
        jr nz, ao_mt
        set 2, b                ; tone C off
ao_mt:  ld a, (APU_VN)
        or a
        jr nz, ao_mn
        set 5, b                ; noise C off
ao_mn:  ld a, 7
        ld e, b
        call psg_w

        ld a, (APU_VA)
        ld e, a
        ld a, 8
        call psg_w
        ld a, (APU_VB)
        ld e, a
        ld a, 9
        call psg_w
        ld a, (APU_VN)          ; C = louder of triangle and noise
        cp c
        jr nc, ao_vc
        ld a, c
ao_vc:  ld e, a
        ld a, 10
        jp psg_w

psg_init:
        ld a, 7
        ld e, $B8
        call psg_w
        ld a, 8
        ld e, 0
        call psg_w
        ld a, 9
        call psg_w
        ld a, 10
        jp psg_w
