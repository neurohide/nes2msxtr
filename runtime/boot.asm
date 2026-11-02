; Cartridge header and first-stage boot (ROM bank 0, page 1).
; Copies the runtime blob into page-3 RAM and continues there.

        db "AB"
        dw boot_init
        dw 0, 0, 0
        defs 6, 0

boot_init:
        di
        ld a, ($002D)           ; MSX version: 3 = turboR
        cp 3
        jr c, bi_cpu_ok
        ld a, $81               ; R800 ROM mode (we never use the BIOS later).
        call CHGCPU             ; Before the copy: CHGCPU enables interrupts,
        di                      ; and the BIOS interrupt handler writes its
bi_cpu_ok:                      ; work area at $F3xx, inside the blob
        ld sp, STACK_TOP        ; the BIOS stack (~$F0xx) lies inside the blob
        ld hl, blob_src
        ld de, RUNTIME
        ld bc, blob_end - blob_start
        ldir
        jp boot2
