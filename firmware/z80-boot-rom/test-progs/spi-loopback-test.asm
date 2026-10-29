; spi-loopback-test.asm -- Phase 11 diagnostic: isolate the bit-banged
; SPI driver + 8255 wiring from the SD card/module entirely.
;
; *** Wire a single jumper directly from 8255 PA4 (MOSI) to 8255 PC4
; *** (MISO) on the breadboard -- the SD module/card should be
; *** disconnected or just ignored, it plays no part in this test. ***
;
; Sends a set of test bytes (chosen to exercise every bit position and
; both constant and alternating patterns -- $FF/$00 alone, as used by
; every previous SD test's polling, never actually exercises MOSI
; changing mid-byte, so this deliberately goes further) through the
; exact same spi_xfer routine sdcard-test.asm uses, and checks each
; byte comes back identical via the jumper. A clean pass here proves
; the 8255 wiring (both PA4 and PC4) and the bit-bang driver itself are
; correct, independent of anything the SD card/module might be doing --
; narrows a persistent, card-independent bad reading (see
; docs/bring-up-log.md's Phase 11 entries) down to "not this."
;
; Uses the same porta_shadow/CS_BIT/SCK_BIT/MOSI_BIT/MISO_BIT scheme
; and the identical spi_xfer routine as sdcard-test.asm (copied
; verbatim) -- CS is left permanently deasserted throughout since
; nothing on the bus needs to be selected for a loopback test.
org 0

video_base: equ $c000

MODE_SRAM: equ $03	; mode=1 (sram-exec), bank=1 -- fixed, needed for
			; write_msg's video writes to land in visible RAM

CS_BIT:    equ 2	; 8255 PA2 (unused by this test, left deasserted)
SCK_BIT:   equ 3	; 8255 PA3
MOSI_BIT:  equ 4	; 8255 PA4 -- JUMPER THIS TO PC4
MISO_BIT:  equ 4	; 8255 PC4 -- JUMPER FROM PA4

SHADOW_INIT: equ $07	; mode=1,bank=1,CS=1(deasserted),SCK=0,MOSI=0

TEST_COUNT: equ 10

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

    LD   A,SHADOW_INIT
    LD   (porta_shadow),A
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
    LD   HL,instr_msg
    LD   B,2
    LD   C,8
    CALL write_msg

; ---- magic address ----
    LD   A,($3FFF)

; ---- run the test bytes ----
    XOR  A
    LD   (test_index),A
    LD   A,1
    LD   (all_pass),A
    LD   A,4
    LD   (row_num),A

test_loop:
    LD   A,(test_index)
    CP   TEST_COUNT
    JP   Z,test_done

    LD   HL,test_bytes
    LD   E,A
    LD   D,0
    ADD  HL,DE
    LD   A,(HL)
    LD   (sent_byte),A
    CALL spi_xfer
    LD   (got_byte),A

    LD   HL,got_byte
    LD   A,(sent_byte)
    CP   (HL)
    JR   Z,test_pass
    XOR  A
    LD   (all_pass),A
    LD   HL,fail_tag
    JR   test_have_tag
test_pass:
    LD   HL,ok_tag
test_have_tag:
    LD   (tag_ptr),HL

    LD   DE,line_buf
    LD   HL,sent_label
    CALL copy_str
    LD   A,(sent_byte)
    CALL byte_to_hex
    LD   HL,got_label
    CALL copy_str
    LD   A,(got_byte)
    CALL byte_to_hex
    LD   HL,tag_sep
    CALL copy_str
    LD   HL,(tag_ptr)
    CALL copy_str
    XOR  A
    LD   (DE),A

    LD   A,(row_num)
    LD   B,A
    LD   C,8
    LD   HL,line_buf
    CALL write_msg

    LD   A,(row_num)
    INC  A
    LD   (row_num),A
    LD   A,(test_index)
    INC  A
    LD   (test_index),A
    JP   test_loop

test_done:
    LD   A,(all_pass)
    OR   A
    JR   Z,show_fail
    LD   HL,allpass_msg
    JR   show_summary
show_fail:
    LD   HL,anyfail_msg
show_summary:
    LD   A,(row_num)
    LD   B,A
    LD   C,8
    CALL write_msg

halt:
    JP   halt

; ============================================================
; spi_xfer: identical to sdcard-test.asm's -- A = byte to send,
; returns received byte in A. SPI mode 0. Preserves BC and HL;
; clobbers D and E.
; ============================================================
spi_xfer:
    PUSH BC
    LD   E,A
    LD   D,8
    LD   C,0
sx_bit:
    LD   A,(porta_shadow)
    RES  MOSI_BIT,A
    RES  SCK_BIT,A
    RLC  E
    JR   NC,sx_mosi0
    SET  MOSI_BIT,A
sx_mosi0:
    LD   (porta_shadow),A
    OUT  ($A8),A
    SET  SCK_BIT,A
    OUT  ($A8),A
    IN   A,($AA)
    SLA  C		; shift first -- see sdcard-test.asm's comment at
			; the same spot: SLA sets Z from its OWN result, so
			; testing BIT after it is required, otherwise SLA's
			; flag write clobbers BIT's Z before JR sees it, and
			; since C starts at 0 the bug is self-reinforcing
			; (C can never leave 0) -- caught by the user.
    BIT  MISO_BIT,A
    JR   Z,sx_miso0
    SET  0,C
sx_miso0:
    LD   A,(porta_shadow)
    OUT  ($A8),A
    DEC  D
    JR   NZ,sx_bit
    LD   A,C
    POP  BC
    RET

; ---- copy_str: HL -> null-terminated source, DE -> destination.
; Copies characters (not the null) and advances DE past them. ----
copy_str:
cs_loop:
    LD   A,(HL)
    OR   A
    RET  Z
    LD   (DE),A
    INC  HL
    INC  DE
    JR   cs_loop

; ---- byte_to_hex: A = byte, writes 2 ASCII hex chars at (DE) and
; ---- advances DE by 2. ----
byte_to_hex:
    PUSH AF
    RRCA
    RRCA
    RRCA
    RRCA
    AND  $0F
    CALL nibble_to_ascii
    LD   (DE),A
    INC  DE
    POP  AF
    AND  $0F
    CALL nibble_to_ascii
    LD   (DE),A
    INC  DE
    RET

nibble_to_ascii:
    CP   10
    JR   C,ntoa_digit
    ADD  A,'A'-10
    RET
ntoa_digit:
    ADD  A,'0'
    RET

; ============================================================
; Messages and buffers
; ============================================================

title_msg:   db "SPI LOOPBACK TEST",0
instr_msg:   db "JUMPER PA4(MOSI) TO PC4(MISO)",0
allpass_msg: db "ALL TESTS PASSED",0
anyfail_msg: db "MISMATCH -- SEE ABOVE",0

sent_label: db "SENT=$",0
got_label:  db " GOT=$",0
tag_sep:    db " ",0
ok_tag:     db "OK",0
fail_tag:   db "FAIL",0

test_bytes: db $00,$FF,$A5,$5A,$3C,$C3,$01,$80,$AA,$55

porta_shadow: ds 1
test_index:   ds 1
sent_byte:    ds 1
got_byte:     ds 1
all_pass:     ds 1
row_num:      ds 1
tag_ptr:      ds 2
line_buf:     ds 32

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
