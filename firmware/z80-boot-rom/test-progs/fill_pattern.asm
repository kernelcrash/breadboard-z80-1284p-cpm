; fill_pattern.asm — Phase 4 test ROM 2
; Fill the first 256 bytes of SRAM (0x0000-0x00FF) with the value of
; their address LSB, then HALT. Validates the mode-independent SRAM
; write path: after running, the host reads SRAM back (Phase 3 SRAM
; tester) and expects 00 01 02 ... FF at 0x0000.
;
; Note: in mode 0 reads come from ROM and writes go to SRAM, so the
; code fetches itself from the ROM image (uploaded via Xmodem) while
; its stores land in the Z80's SRAM — exactly the mechanism we're
; testing. The trailing HALT leaves the Z80 parked for inspection.
org 0
    LD   HL, 0x0000
    LD   C, 0x00
fill:
    LD   A, C
    LD   (HL), A
    INC  HL
    INC  C
    JP   NZ, fill
    HALT
