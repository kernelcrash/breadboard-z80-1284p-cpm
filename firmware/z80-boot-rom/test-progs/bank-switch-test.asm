; bank-switch-test.asm -- Phase 9: verify the new 2-NAND memory
; bank-switch circuit (gate-equations.md §9, bank-switch-wiring.md,
; cpm-plan.md §2) before any CP/M content ever depends on it.
;
; mode_pin = 8255 PA0, bank = 8255 PA1 (gate-equations.md §8) -- both
; bits of the SAME Port A output byte, so every OUT to $A8 sets both at
; once: bit0=mode (0=rom,1=sram), bit1=bank (0 or 1). This program only
; ever writes $01 (sram, bank=0) or $03 (sram, bank=1) once past the
; initial rom-mode setup -- mode_pin stays sram-exec throughout, only
; `bank` toggles.
;
; Test 1 (SRAM bank independence): writes $A5 to a handful of addresses
; in $8000-$BFFF under bank=0, flips to bank=1, writes $5A (bitwise
; complement) to the *same* addresses, flips back to bank=0 and confirms
; the original $A5 survived untouched, then flips to bank=1 again and
; confirms $5A also survived -- proves the two banks are genuinely
; independent physical SRAM, not aliased onto the same bytes. Uses
; $8000-$BFFF specifically (never $C000-$FFFF) so this test doesn't
; touch or depend on video RAM at all, per cpm-plan.md §2's mapping
; (only $C000-$FFFF is ever video, and only under bank=1).
;
; Test 2 (video isolation): fills the video buffer (only reachable at
; all under bank=1) with a box + "BANK TEST OK" message via the usual
; write_msg routine, triggers the magic-address exit into video
; generation, then continuously toggles `bank` between 0 and 1 forever.
; If the AVR's video fetch is genuinely isolated from `bank` (as the
; circuit's truth table predicts -- _BUSRQ unconditionally forces
; SRAM A16=1 the instant the AVR takes the bus, regardless of `bank`),
; the displayed image stays rock solid the whole time; any visible
; flicker, corruption, or rolling means the isolation isn't real.
;
; LED (port $B8): fast blink forever on a Test 1 failure (halts there,
; never reaches video, so a Test-1 failure is unambiguous -- no video
; ever appears). 3 quick blinks then Test 2's toggle loop running
; indicates Test 1 passed.
org 0

video_base: equ $c000

MODE_SRAM_BANK0: equ $01	; mode=1 (sram-exec), bank=0
MODE_SRAM_BANK1: equ $03	; mode=1 (sram-exec), bank=1

start:
    LD   A,$8B
    OUT  ($AB),A
; set rom mode (also forces bank=0 as a side effect of Port A becoming
; an output for the first time -- see gate-equations.md §8)
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

; switch to sram mode, bank=0
    LD   A,MODE_SRAM_BANK0
    OUT  ($A8),A
    LD   SP,$7fff

; ---- Test 1: SRAM bank independence ----
    LD   HL,test_addrs
    LD   B,test_addrs_count
fill_bank0:
    LD   E,(HL)
    INC  HL
    LD   D,(HL)
    INC  HL
    PUSH HL
    PUSH BC
    LD   A,$A5
    LD   (DE),A
    POP  BC
    POP  HL
    DJNZ fill_bank0

; flip to bank=1, fill the SAME addresses with a different pattern
    LD   A,MODE_SRAM_BANK1
    OUT  ($A8),A

    LD   HL,test_addrs
    LD   B,test_addrs_count
fill_bank1:
    LD   E,(HL)
    INC  HL
    LD   D,(HL)
    INC  HL
    PUSH HL
    PUSH BC
    LD   A,$5A
    LD   (DE),A
    POP  BC
    POP  HL
    DJNZ fill_bank1

; flip back to bank=0, verify the original pattern survived
    LD   A,MODE_SRAM_BANK0
    OUT  ($A8),A

    LD   HL,test_addrs
    LD   B,test_addrs_count
check_bank0:
    LD   E,(HL)
    INC  HL
    LD   D,(HL)
    INC  HL
    PUSH HL
    PUSH BC
    LD   A,(DE)
    CP   $A5
    JP   NZ,test_fail
    POP  BC
    POP  HL
    DJNZ check_bank0

; flip to bank=1, verify its pattern survived
    LD   A,MODE_SRAM_BANK1
    OUT  ($A8),A

    LD   HL,test_addrs
    LD   B,test_addrs_count
check_bank1:
    LD   E,(HL)
    INC  HL
    LD   D,(HL)
    INC  HL
    PUSH HL
    PUSH BC
    LD   A,(DE)
    CP   $5A
    JP   NZ,test_fail
    POP  BC
    POP  HL
    DJNZ check_bank1

; ---- Test 1 passed. Fill the video buffer -- only reachable under
; bank=1 -- with a box + message, same fill routine as video-test3.asm.
; ----
    LD   HL,video_base
    LD   B,80
    LD   A,$FF
boxtop:
    LD   (HL),A
    INC  HL
    DEC  B
    JR   NZ,boxtop

    LD   B,198
boxmid:
    LD   A,$80
    LD   (HL),A
    INC  HL
    LD   C,78
    LD   A,$00
boxmid_fill:
    LD   (HL),A
    INC  HL
    DEC  C
    JR   NZ,boxmid_fill
    LD   A,$01
    LD   (HL),A
    INC  HL
    DEC  B
    JR   NZ,boxmid

    LD   B,80
    LD   A,$FF
boxbot:
    LD   (HL),A
    INC  HL
    DEC  B
    JR   NZ,boxbot

    LD   HL,ok_msg
    LD   B,2
    LD   C,8
    CALL write_msg

; back to bank=0 before the magic-address read -- not required (the
; magic address, $3FFF, is well below $8000 so `bank` never affects it,
; per cpm-plan.md §2's mapping), but keeps the machine's state
; deterministic and matches bank=0 being the intended steady state.
    LD   A,MODE_SRAM_BANK0
    OUT  ($A8),A

; ---- magic address: exits ROM emulation, starts video generation ----
    LD   A,($3FFF)

; ---- Test 1 passed indicator: 3 quick blinks ----
    LD   C,$00
    LD   B,6
blink3:
    LD   A,C
    XOR  $01
    LD   C,A
    OUT  ($B8),A
    LD   HL,$1000
b3_delay:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,b3_delay
    DJNZ blink3

; ---- Test 2: continuously toggle `bank` while video runs. A rock-solid
; display through this whole loop is the pass condition. ----
toggle_loop:
    LD   A,MODE_SRAM_BANK1
    OUT  ($A8),A
    LD   HL,$2000
tg_delay1:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,tg_delay1

    LD   A,MODE_SRAM_BANK0
    OUT  ($A8),A
    LD   HL,$2000
tg_delay0:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,tg_delay0

    JR   toggle_loop

; ---- Test 1 FAILED: fast blink forever, never reaches video. ----
test_fail:
    POP  BC
    POP  HL
fail_loop:
    LD   A,1
    OUT  ($B8),A
    LD   HL,$4000
fail_delay1:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,fail_delay1
    LD   A,0
    OUT  ($B8),A
    LD   HL,$4000
fail_delay0:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,fail_delay0
    JR   fail_loop

test_addrs:
    dw $8000, $8100, $9000, $B000, $BFFF
test_addrs_count: equ 5

ok_msg: db "BANK TEST OK DOKEY",0

; ---- write_msg: reused verbatim from video-test3.asm ----
; HL -> null-terminated message; B = character row (0-24); C = character
; column (0-79).
write_msg:
    LD   IX,video_base
    PUSH HL
    LD   L,B
    LD   H,$00
    LD   D,H
    LD   E,L
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,DE
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,HL
    LD   D,H
    LD   E,L
    ADD  IX,DE
    LD   B,$00
    ADD  IX,BC
    POP  HL

wr1:
    LD   A,(HL)
    OR   A
    JR   Z,exit_write_msg
    PUSH HL
    LD   L,A
    LD   H,0
    ADD  HL,HL	; x2
    ADD  HL,HL	; x4
    ADD  HL,HL	; x8
    LD   DE,char_base
    ADD  HL,DE
    EX   DE,HL

    LD   BC,160

    PUSH IX
    LD   A,(DE)
    LD   (IX+0),A
    INC  DE

    LD   A,(DE)
    LD   (IX+$50),A
    INC  DE

    ADD  IX,BC

    LD   A,(DE)
    LD   (IX+0),A
    INC  DE

    LD   A,(DE)
    LD   (IX+$50),A
    INC  DE

    ADD  IX,BC

    LD   A,(DE)
    LD   (IX+0),A
    INC  DE

    LD   A,(DE)
    LD   (IX+$50),A
    INC  DE

    ADD  IX,BC

    LD   A,(DE)
    LD   (IX+0),A
    INC  DE

    LD   A,(DE)
    LD   (IX+$50),A
    INC  DE

    POP  IX
    INC  IX

    POP  HL
    INC  HL
    JR   wr1
exit_write_msg:
    RET

char_base:
    incbin "test-progs/msxfont.img"

end:
