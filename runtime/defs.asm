; nes2msxtr runtime: memory map and hardware constants.
;
; Runtime memory map (all mapper RAM after boot):
;   page 0-1 $0000-$7FFF  translated code bank (2 mapper segments)
;   page 2   $8000-$BFFF  data window (PRG image, sprite tiles, CHR)
;   page 3   $C000-$FFFF  fixed: NES RAM, PPU/APU state, runtime, stack
;
; Register convention for translated 6502 code:
;   A = A, C = X (B is always 0), E = Y, D = last N/Z result,
;   Z80 carry = 6502 carry, (vflag) != 0 means V set.
;   HL, AF' are scratch. Helpers preserve AF, BC, DE unless noted.

NES_RAM:    equ $C000           ; 2K, NES $0000-$07FF
NT_SHADOW:  equ $C800           ; 2 x 1K physical nametables
OAM:        equ $D000           ; 256-byte sprite table
PAL_SHADOW: equ $D100           ; 32 palette bytes
VARS:       equ $D120           ; 96 bytes of runtime variables
APU:        equ $D180           ; 128 bytes of APU state
SPR_LUT:    equ $D200           ; 4 x 256 sprite palette expansion
SPR_PAT:    equ $D600           ; 64 bytes: V9990 pattern used by each sprite
SPR_HID:    equ $D640           ; 64 bytes: sprite is disabled in VRAM
BSTK_TOP:   equ $D700           ; bank stack for cross-bank calls, $D680-$D6FF
RUNTIME:    equ $D700           ; runtime code + tables
SC_TLO:     equ $FB00           ; sprite pattern cache, one entry per V9990
SC_THI:     equ $FC00           ; pattern: key (tile low, tile/attr/size bits)
SC_STAMP:   equ $FD00           ; and the spr_update pass that last used it
STACK_TOP:  equ $FFF0           ; stack $FE00-$FFEF; never touches $FFFF

; variables
; win_seg (mapper segment currently in page 2) lives in rom_rd
cur_bank:   equ VARS+1          ; word: code bank in pages 0-1
vflag:      equ VARS+3
ppu_ctrl:   equ VARS+4
ppu_mask:   equ VARS+5
ppu_status: equ VARS+6
ppu_w:      equ VARS+7
ppu_vaddr:  equ VARS+8          ; word
ppu_buf:    equ VARS+10
scroll_x:   equ VARS+11
scroll_y:   equ VARS+12
oam_addr:   equ VARS+13
s0_state:   equ VARS+14
split_on:   equ VARS+15
top_sx:     equ VARS+16
top_sy:     equ VARS+17
top_ctrl:   equ VARS+18
pad_shift:  equ VARS+19
in_nmi:     equ VARS+20
spr_dirty:  equ VARS+21
wr_val:     equ VARS+22         ; word
frame_cnt:  equ VARS+26
bad_addr:   equ VARS+27         ; word
nt_k:       equ VARS+29
nt_off:     equ VARS+30         ; word
nt_r:       equ VARS+32
nt_c:       equ VARS+33
nt_tile:    equ VARS+34
nt_ehi:     equ VARS+35
sp_i:       equ VARS+36
sp_t0:      equ VARS+37         ; word
sp_attr:    equ VARS+39
sp_line:    equ VARS+40
reg_sx:     equ VARS+41         ; scroll -> V9990 conversion inputs
reg_sy:     equ VARS+42
reg_ctrl:   equ VARS+43
vregs:      equ VARS+44         ; 4 bytes R#17-R#20 out of calc_scroll
bot_regs:   equ VARS+48         ; 4 bytes for the split line interrupt
dj_key:     equ VARS+52         ; word
r9_val:     equ VARS+54
psg_mix:    equ VARS+55
sp_mode:    equ VARS+56
s6_ptr:     equ VARS+57         ; word: $C100 + 6502 S (page-1 stack)
p_id:       equ VARS+59         ; 6502 I and D flags (bits 2, 3)
su_iff:     equ VARS+60         ; spr_update entered with interrupts on
su_stamp:   equ VARS+61         ; spr_update pass counter
su_kbase:   equ VARS+62         ; cache key bits shared by all sprites
sp_pat:     equ VARS+63         ; its V9990 pattern
sp_free:    equ VARS+64         ; cache slot to replace on a miss
nt_x:       equ VARS+66         ; attribute bits changed by the last write
bstk:       equ VARS+67         ; word: bank stack pointer
fc_tgt:     equ VARS+69         ; word: far_call / drop_frame scratch
fj_bank:    equ VARS+71         ; far_jump target bank
nes_bank:   equ VARS+72         ; UxROM bank mapped at NES $8000-$BFFF (MMC3: R6)
bad_bank:   equ VARS+73         ; ... when bad_addr was looked up
chr_any:    equ VARS+74         ; CHR RAM: some tile in chr_dirty
cf_left:    equ VARS+75         ; chr_flush scratch
ct_t:       equ VARS+76         ; word: chr_tile scratch
ct_s0:      equ VARS+78
ct_hi:      equ VARS+79
ct_lo:      equ VARS+80
bg_shown:   equ VARS+81         ; BG pattern table in the V9990 map (0 / 4)
spr_ctrl:   equ VARS+82         ; sprite size / table bits ($28) in use
nes_bank1:  equ VARS+83         ; MMC3: R7, the bank at NES $A000-$BFFF
chr_remap:  equ VARS+84         ; MMC3: CHR bank registers written
unw_pend:   equ VARS+85         ; nmi_rts happened, spin_wait returns
unw_a:      equ VARS+86         ; ... with this A
mir_v:      equ VARS+87         ; nametable mirroring: 1 vertical, 0 horizontal
mir_dirty:  equ VARS+88         ; MMC3: mirroring changed, map not rebuilt yet
poll_seen:  equ VARS+89         ; the main loop is waiting at an idle point
nmi_pend:   equ VARS+90         ; NMIs held back for the main loop's idle point
dma_skips:  equ VARS+91         ; NMIs held back in a row
idle_age:   equ VARS+92         ; vblanks since the main loop's last idle point

; V9990 ports (GFX9000 at $60)
V_VRAM:     equ $60
V_PAL:      equ $61
V_REGD:     equ $63
V_REGS:     equ $64
V_STAT:     equ $65
V_INT:      equ $66
V_SYS:      equ $67

; V9990 VRAM layout (P1 mode)
VR_SPRPAT_HI: equ $02           ; sprite patterns at $20000 (R#25 = $08)

; MSX
PSG_REG:    equ $A0
PSG_WR:     equ $A1
PSG_RD:     equ $A2
PPI_SLOT:   equ $A8
PPI_KEYS:   equ $A9
PPI_ROW:    equ $AA
MAP_P0:     equ $FC
MAP_P1:     equ $FD
MAP_P2:     equ $FE
EXPTBL:     equ $FCC1
CHGCPU:     equ $0180
CHPUT:      equ $00A2
ASCII16_P1: equ $6000           ; bank select for $4000-$7FFF
