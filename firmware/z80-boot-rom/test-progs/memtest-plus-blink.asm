; Set up the 8255, copy rom to sram, switch to sram mode, then run a
; simple memory test over the 32K region $4000-$BFFF (pattern = low byte
; of address, so it also catches address-line faults, not just stuck data
; lines). LED on the $B8 latch: pass = 3 short blinks then a longer gap,
; repeating; fail = continuous blink, same as blink.asm.
;
; No CALL/RET anywhere, deliberately -- SP is never set up (no reason to
; yet), and relying on the stack while testing whether SRAM works at all
; would be circular. Every delay is inlined instead.
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

; ---- memory test: $4000-$BFFF (32K), pattern = low byte of address ----
memtest:
    LD   HL,$4000
    LD   BC,$8000
write_loop:
    LD   A,L
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,write_loop

    LD   HL,$4000
    LD   BC,$8000
verify_loop:
    LD   A,L
    CP   (HL)
    JR   NZ,blink_fail
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,verify_loop
    ; fall through: verified clean, all 32K matched

; ---- pass: 3 short blinks, then a longer gap, repeat ----
blink_pass:
    LD   B,3
bp_blink3:
    LD   A,1
    OUT  ($B8),A
    LD   HL,$0800
bp_delay_on:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,bp_delay_on
    LD   A,0
    OUT  ($B8),A
    LD   HL,$0800
bp_delay_off:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,bp_delay_off
    DJNZ bp_blink3
    LD   HL,$FFFF
bp_longgap:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,bp_longgap
    JR   blink_pass

; ---- fail: continuous blink, same pattern as blink.asm ----
blink_fail:
    LD   C,0
bf_loop:
    LD   A,C
    XOR  $01
    LD   C,A
    OUT  ($B8),A
    LD   HL,$4000
bf_delay:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,bf_delay
    JR   bf_loop
end:
