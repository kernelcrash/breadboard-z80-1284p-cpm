; portc-probe-test.asm -- Phase 11 diagnostic: continuously read and
; display Port C's raw bits, live, with no SPI protocol/timing
; involved at all -- isolates one remaining question after
; spi-loopback-test.asm's result (GOT=$00 for every non-zero byte,
; despite a multimeter confirming a real 5V static level at both PA4
; and PC4 -- see docs/bring-up-log.md's Phase 11 entries): can the
; Z80/8255 see ANY live change on PC4 at all, independent of our own
; bit-banging code's timing?
;
; Loops forever: IN A,($AA), display all 8 bits as ASCII '0'/'1'
; (MSB..LSB, i.e. bit7 first/leftmost, bit0 last/rightmost) at a fixed
; screen position, repeat. A static label row above it shows which
; character is which bit.
;
; *** With this running, touch a spare wire from 8255 pin 13 (PC4) to
; *** GND, then to +5V, and watch whether the 5th character (bit4)
; *** on screen actually flips between 0 and 1. If it does, the 8255
; *** can see live changes on that pin and the bug is specific to the
; *** SPI bit-bang timing/sequencing. If it never changes no matter
; *** what you do to that physical pin, the fault is in the 8255
; *** itself (or how this program addresses it), not in spi_xfer. ***
org 0

video_base: equ $c000

MODE_SRAM: equ $03	; mode=1 (sram-exec), bank=1 -- fixed, needed for
			; write_msg's video writes to land in visible RAM

start:
    LD   A,$8A
    OUT  ($AB),A
    LD   A,$04
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

    LD   A,MODE_SRAM
    OUT  ($A8),A
    LD   SP,$7FFF

; clear screen
    LD   HL,video_base
    LD   B,200
    XOR  A
clearscreen1:
    LD   C,80
clearscreen2:
    LD   (HL),A
    INC  HL
    DEC  C
    JR   NZ,clearscreen2
    DEC  B
    JR   NZ,clearscreen1

    LD   HL,title_msg
    LD   B,1
    LD   C,8
    CALL write_msg
    LD   HL,label_msg
    LD   B,3
    LD   C,8
    CALL write_msg

; ---- magic address ----
    LD   A,($3FFF)

; ---- continuous live probe loop ----
probe_loop:
    IN   A,($AA)
    LD   DE,bin_buf
    CALL byte_to_binary
    XOR  A
    LD   (DE),A
    LD   HL,bin_buf
    LD   B,4
    LD   C,8
    CALL write_msg
    JP   probe_loop

; ---- byte_to_binary: A = byte, writes 8 ASCII '0'/'1' chars at (DE)
; ---- (MSB first) and advances DE by 8. Clobbers A. ----
byte_to_binary:
    LD   B,8
btb_loop:
    PUSH AF
    AND  $80
    JR   Z,btb_zero
    LD   A,'1'
    JR   btb_store
btb_zero:
    LD   A,'0'
btb_store:
    LD   (DE),A
    INC  DE
    POP  AF
    RLCA
    DJNZ btb_loop
    RET

; ============================================================
; Messages and buffers
; ============================================================

title_msg: db "PORT C LIVE PROBE",0
label_msg: db "bits (msb..lsb): 76543210",0

bin_buf: ds 9

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
