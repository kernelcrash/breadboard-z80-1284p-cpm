; nop_loop.asm — Phase 4 test ROM 1
; Infinite JP $0000. Validates the address/WAIT mechanism: the logic
; analyzer should see the address cycle 0,1,2,0,1,2,... at the ROM-emu
; fetch rate, with _WAIT asserting and releasing each fetch.
org 0
loop: jp loop
