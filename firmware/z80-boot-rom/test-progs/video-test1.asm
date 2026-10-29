; video-test1.asm -- Phase 6 bring-up: exercise the magic-address exit
; and confirm the Z80 keeps running normally afterward. This is the
; first Z80-side test of rom_emu.c's 2026-09-05 fix (wait_rel driven low
; and held there once the magic address is served, since the WAIT flip-
; flop has no mode_pin gating of its own -- gate-equations.md §3): if
; that fix is wrong or missing, the Z80 hangs on the very first
; instruction fetch after the magic read below, and this program's LED
; never blinks past the initial 3.
;
; Sequence: copy self to sram, switch to sram mode, blink 3 times
; (proves sram execution -- same pattern as blink.asm), read the magic
; address (0x3FFF -- signals the 1284p to exit ROM emulation and enter
; video_run(), see sync.c's HSYNC/VSYNC + "fat pixel" _BUSRQ test), then
; just blink forever at a plain 50% duty cycle, same rate as blink.asm's
; normal blink. Mode is switched to SRAM *before* the magic read
; (deliberately, per discussion) -- the ROM-emulation loop keeps
; servicing every read blindly (mode or no mode) right up until it sees
; the magic address, so nothing about the switch itself is at risk; only
; what happens *after* the magic read depends on the wait_rel fix above.
;
; No CALL/RET anywhere, deliberately -- SP is never set up. Every delay
; is inlined instead, same convention as blink.asm / memtest-plus-blink.asm.
org 0
start:
    LD   A,$8B
    OUT  ($AB),A
; set rom mode
    LD   A,$00
    OUT  ($A8),A

; copy rom to sram
    LD   HL,start
    LD   BC,end-start
loop1:
    LD   A,(HL)
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,loop1

; switch to sram mode
    LD   A,$01
    OUT  ($A8),A
; should be running in sram now at the same address

; ---- blink 3 times (proves sram execution -- same pattern as blink.asm) ----
    LD   B,3
blink3:
    LD   A,1
    OUT  ($B8),A
    LD   HL,$0800
b3_delay_on:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,b3_delay_on
    LD   A,0
    OUT  ($B8),A
    LD   HL,$0800
b3_delay_off:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,b3_delay_off
    DJNZ blink3

; ---- magic address: signals the 1284p to exit ROM emulation and start
; video generation (sync.c/video.c). The byte read back is garbage and
; unused -- only the address on the bus matters to the 1284p, not the
; data. ----
    LD   A,($3FFF)

; ---- plain 50% duty slow blink, forever, same rate as blink.asm. If
; this keeps blinking steadily, the wait_rel-held-low fix is working; a
; hang right here (LED frozen after the initial 3 blinks) means it
; isn't. ----
    LD   C,$00
slowblink:
    LD   A,C
    XOR  $01
    LD   C,A
    OUT  ($B8),A
    LD   HL,$4000
sb_delay:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,sb_delay
    JR   slowblink
end:
