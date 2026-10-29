; porta-write-portc-read-test.asm -- Phase 11 diagnostic: isolate the
; one interaction portc-probe-test.asm never exercised -- an 8255
; Port A WRITE immediately followed by an 8255 Port C READ, which is
; exactly what spi_xfer does every single bit (OUT $A8 to set MOSI/SCK,
; then IN $AA to sample MISO) but portc-probe-test.asm never did (it
; only ever reads, in a tight loop, no Port A writes at all).
;
; *** Keep the same PA4(MOSI)-to-PC4(MISO) jumper from
; *** spi-loopback-test.asm in place for this test. ***
;
; In a tight loop: writes Port A with PA4=0 (mode/bank bits fixed at
; 1/1 as always), immediately reads Port C and displays it labeled
; "PA4=0", then writes Port A with PA4=1, immediately reads Port C and
; displays it labeled "PA4=1", repeat forever. With the jumper in
; place, a working path should show PC4 (bit4, 5th character) tracking
; 0 in the first line and 1 in the second line, continuously. If PC4
; stays 0 in both lines despite PA4 alternating, this specific
; write-then-read sequence is where the bug lives -- something
; spi_xfer does on every single bit and portc-probe-test.asm never
; did at all.
org 0

video_base: equ $c000

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

    LD   A,$03		; mode=1,bank=1,PA4=0 -- fixed baseline for the
			; whole test other than the PA4 bit itself
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
    LD   HL,label0_msg
    LD   B,3
    LD   C,8
    CALL write_msg
    LD   HL,label1_msg
    LD   B,5
    LD   C,8
    CALL write_msg

; ---- magic address ----
    LD   A,($3FFF)

; ---- continuous alternate-and-read loop ----
probe_loop:
    LD   A,$03		; PA4=0
    OUT  ($A8),A
    IN   A,($AA)
    LD   DE,bin_buf0
    CALL byte_to_binary
    XOR  A
    LD   (DE),A
    LD   HL,bin_buf0
    LD   B,4
    LD   C,8
    CALL write_msg

    LD   A,$13		; PA4=1 ($03 | $10)
    OUT  ($A8),A
    IN   A,($AA)
    LD   DE,bin_buf1
    CALL byte_to_binary
    XOR  A
    LD   (DE),A
    LD   HL,bin_buf1
    LD   B,6
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

title_msg:  db "PORT A WRITE / PORT C READ TEST",0
label0_msg: db "bits w/ PA4=0 (msb..lsb 76543210):",0
label1_msg: db "bits w/ PA4=1 (msb..lsb 76543210):",0

bin_buf0: ds 9
bin_buf1: ds 9

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
