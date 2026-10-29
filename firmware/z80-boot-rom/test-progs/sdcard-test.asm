; sdcard-test.asm -- Phase 11: bit-banged SPI SD card bring-up
; (docs/sdcard-wiring.md, cpm-plan.md §6).
;
; CS/SCK/MOSI = 8255 PA2/PA3/PA4 (Port A -- shares the byte with
; mode_pin/PA0 and bank/PA1, both fixed at 1 for this whole test, see
; SHADOW_INIT below). MISO = 8255 PC4 (Port C upper nibble, already
; input under the same $8A control word the keyboard interface uses --
; no control-word change needed to add SD on top of keyboard support).
;
; Implements: >=74 power-up clocks, CMD0 (GO_IDLE_STATE), CMD8
; (SEND_IF_COND, checks for SD v2), CMD55+ACMD41 (SD_SEND_OP_COND with
; HCS) until ready, CMD58 (READ_OCR, checks CCS) -- see sdcard-wiring.md
; for the full sequence and its documented limitations (SDHC/SDXC only,
; no CRC checking, single fixed bit-bang rate). Then: fills a 512-byte
; buffer with a known pattern, writes it to TEST_SECTOR (CMD24), reads
; it back (CMD17) into a second buffer, and compares the two on-device
; -- a full round trip with no PC involvement needed to judge pass/fail.
; Finally reads sector 0 (the MBR, safe on any card -- read-only) and
; hex-dumps its first 16 bytes on screen, so the result can be cross-
; checked against what a PC shows for the same card's real sector 0.
;
; *** WARNING: TEST_SECTOR is overwritten by this test. Use a card you
; *** don't mind wiping, or a blank/unpartitioned card. See
; *** sdcard-wiring.md's bring-up warning before running this on a card
; *** that has anything on it worth keeping. ***
;
; Carry-flag convention used throughout this file's SD routines:
; **Carry SET means failure/error**, carry clear means success --
; matches the common CP/M-ish idiom, chosen deliberately so every
; "CALL foo / JR NC,ok_path" reads naturally as "proceed if no error."
;
; Register-preservation contract for the low-level SPI routines
; (spi_xfer, send_cmd, read_r1, wait_token): **BC and HL are always
; preserved across a call, DE is not** (spi_xfer uses D/E internally
; for its own bit-shift state) -- higher-level code in this file relies
; on this to keep buffer pointers (HL) and loop/retry counters (BC)
; alive across chains of SPI calls without having to save them itself.
org 0

video_base: equ $c000

MODE_SRAM: equ $03	; mode=1 (sram-exec), bank=1 -- fixed for the whole
			; run (this test doesn't exercise bank-switching,
			; just needs bank=1 so write_msg's video writes
			; land in the AVR's visible video RAM, same
			; reasoning as keyboard-scan-test.asm).

CS_BIT:    equ 2	; 8255 PA2
SCK_BIT:   equ 3	; 8255 PA3
MOSI_BIT:  equ 4	; 8255 PA4
MISO_BIT:  equ 4	; 8255 PC4

; Port A baseline once we're done with the ROM-copy phase: mode=1,
; bank=1 (MODE_SRAM=$03), CS deasserted (bit2=1), SCK=0, MOSI=0.
SHADOW_INIT: equ $07

; Sector to use for the destructive write/read-back round-trip test.
; Only 16-bit sector addressing is implemented in this test driver
; (build_rw_cmd forces the top 16 bits of the 32-bit LBA argument to
; zero) -- fine for sectors 0-65535 on any card, which is all this
; bring-up test needs; a real CBIOS disk driver would need the full
; 32-bit argument for large images. EDIT THIS before assembling if you
; want a different scratch sector, or leave the default if using a
; blank/unpartitioned card.
TEST_SECTOR: equ 5000

start:
    LD   A,$8A
    OUT  ($AB),A
    LD   A,$04		; mode=0,bank=0,CS deasserted,SCK=0,MOSI=0 -- keep
			; CS deasserted even during the ROM-copy phase,
			; defensive (nothing drives SPI yet regardless)
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

; switch to sram mode and establish the SPI-safe Port A baseline in one
; write -- from here on, EVERY Port A write must go through
; porta_shadow (see sd_cs_assert/deassert, spi_xfer) so CS/SCK/MOSI
; never get clobbered by something that only meant to touch mode_pin/
; bank (which never change again in this test anyway).
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
    LD   B,2
    LD   C,8
    CALL write_msg

; ---- magic address: exits ROM emulation, starts video generation ----
    LD   A,($3FFF)

; ---- SD card init ----
    CALL sd_init
    JR   C,init_failed
    LD   HL,initok_msg
    LD   B,4
    LD   C,8
    CALL write_msg
    JR   roundtrip_test
init_failed:
    LD   HL,initfail_msg
    LD   B,4
    LD   C,8
    CALL write_msg

    LD   A,(sdi_stage)
    ADD  A,'0'
    LD   (stage_digit),A
    LD   A,(sdi_info)
    LD   DE,info_hex
    CALL byte_to_hex
    LD   HL,initfail_detail
    LD   B,5
    LD   C,8
    CALL write_msg
    JP   halt

; ---- round-trip self test: write a known pattern, read it back,
; ---- compare on-device ----
roundtrip_test:
    CALL fill_test_pattern

    LD   A,$58		; CMD24 = WRITE_BLOCK
    LD   HL,TEST_SECTOR
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,wr_cmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    LD   HL,wrcmdfail_msg
    LD   B,6
    LD   C,8
    CALL write_msg
    JP   halt
wr_cmd_ok:
    LD   HL,sd_wbuf
    CALL write_block
    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,write_ok
    LD   HL,writefail_msg
    LD   B,6
    LD   C,8
    CALL write_msg
    JP   halt

write_ok:
    LD   A,$51		; CMD17 = READ_SINGLE_BLOCK
    LD   HL,TEST_SECTOR
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,rd_cmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    LD   HL,rdcmdfail_msg
    LD   B,6
    LD   C,8
    CALL write_msg
    JP   halt
rd_cmd_ok:
    LD   HL,sd_rbuf
    CALL read_block
    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,read_ok
    LD   HL,readfail_msg
    LD   B,6
    LD   C,8
    CALL write_msg
    JP   halt

read_ok:
    CALL compare_buffers
    JR   C,cmp_fail
    LD   HL,cmppass_msg
    LD   B,6
    LD   C,8
    CALL write_msg
    JR   sector0_dump
cmp_fail:
    LD   HL,cmpfail_msg
    LD   B,6
    LD   C,8
    CALL write_msg

; ---- read sector 0 (the MBR) and hex-dump its first 16 bytes. Purely
; ---- read-only, safe to run on any card regardless of the round-trip
; ---- test's outcome above -- lets the user cross-check the dump
; ---- against what a PC shows for the same card's real sector 0. ----
sector0_dump:
    XOR  A
    LD   H,A
    LD   L,A		; HL = 0 (sector 0)
    LD   A,$51		; CMD17 = READ_SINGLE_BLOCK
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,s0_cmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    LD   HL,s0fail_msg
    LD   B,8
    LD   C,8
    CALL write_msg
    JP   halt
s0_cmd_ok:
    LD   HL,sd_rbuf
    CALL read_block
    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,s0_ok
    LD   HL,s0fail_msg
    LD   B,8
    LD   C,8
    CALL write_msg
    JP   halt
s0_ok:
    LD   HL,s0label_msg
    LD   B,8
    LD   C,8
    CALL write_msg
    LD   HL,sd_rbuf+16
    LD   DE,hexline
    CALL dump_hex16
    LD   HL,hexline
    LD   B,8
    LD   C,20
    CALL write_msg

halt:
    JP   halt

; ============================================================
; SD card driver
; ============================================================

; ---- sd_init: power-up clocks + CMD0 + CMD8 + ACMD41 + CMD58.
; Returns carry SET on failure, carry CLEAR (and CS deasserted) on
; success. Assumes porta_shadow already holds SHADOW_INIT (CS
; deasserted) on entry. ----
sd_init:
    LD   B,10		; >=74 clocks (10 bytes = 80 clocks) with CS high
sdi_preclock:
    LD   A,$FF
    CALL spi_xfer
    DJNZ sdi_preclock

    CALL sd_cs_assert
    CALL build_cmd0
    CALL send_cmd
    CALL read_r1
    LD   (sdi_info),A	; stash R1 (or $FF if read_r1 timed out entirely
			; -- no response at all is the most likely first-
			; bring-up symptom: miswiring, card not detected,
			; or MISO stuck) BEFORE sd_cs_deassert below can
			; touch A -- real bug found the hard way: this used
			; to run AFTER sd_cs_deassert, which clobbers A
			; (LD A,(porta_shadow)/SET.../OUT...), so both this
			; stash AND the CP below were silently testing
			; sd_cs_deassert's own leftover shadow byte, not
			; read_r1's real response, every single time --
			; deterministically the same value ($17: mode=1,
			; bank=1,CS=1,SCK=0,MOSI=1) regardless of the card,
			; wiring, or anything else, which is exactly the
			; symptom that sent this debugging arc down several
			; wrong paths before the user asked to re-check the
			; code directly.
    CP   $01		; compare NOW, while A is still the real value --
			; sd_settle explicitly preserves flags (PUSH/POP AF)
			; and sd_cs_deassert never touches them (LD/SET/OUT
			; are all flag-neutral on the Z80), so the Z flag
			; from this CP survives both calls intact
    CALL sd_settle
    CALL sd_cs_deassert
    JR   Z,sdi_cmd0_ok
    LD   A,1
    JP   sdi_fail_tag
sdi_cmd0_ok:

    CALL sd_cs_assert
    CALL build_cmd8
    CALL send_cmd
    CALL read_r1
    LD   (spi_tmp),A	; stash R1 in MEMORY, not a register -- see
			; spi_tmp's own comment: D would get clobbered by
			; the 4 spi_xfer calls immediately below
    LD   A,$FF
    CALL spi_xfer	; R7 byte 1
    LD   A,$FF
    CALL spi_xfer	; R7 byte 2
    LD   A,$FF
    CALL spi_xfer	; R7 byte 3 (voltage-accepted field)
    LD   A,$FF
    CALL spi_xfer	; R7 byte 4 (echo pattern, should be $AA)
    LD   (spi_tmp2),A	; stash the echo byte in memory too, NOT E --
			; sd_settle below calls spi_xfer internally, which
			; clobbers D and E unconditionally (same bug class
			; as the D-register one above; E survived until now
			; only because nothing called spi_xfer between
			; setting it and using it -- sd_settle's insertion
			; broke that assumption)
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,(spi_tmp)
    CP   $01
    JR   Z,sdi_cmd8_r1_ok
    LD   (sdi_info),A	; A = spi_tmp = R1 here
    LD   A,2
    JP   sdi_fail_tag	; illegal-command/other -- v1 or MMC card,
			; unsupported by this driver (sdcard-wiring.md)
sdi_cmd8_r1_ok:
    LD   A,(spi_tmp2)
    CP   $AA
    JR   Z,sdi_cmd8_ok
    LD   (sdi_info),A	; A = spi_tmp2 = echo byte here
    LD   A,3
    JP   sdi_fail_tag	; echo pattern mismatch -- comms problem
sdi_cmd8_ok:

    LD   B,0		; 256 retries of CMD55+ACMD41 (generous ceiling)
sdi_acmd41:
    CALL sd_cs_assert
    CALL build_cmd55
    CALL send_cmd
    CALL read_r1
    CALL sd_settle
    CALL sd_cs_deassert
    CALL sd_cs_assert
    CALL build_acmd41
    CALL send_cmd
    CALL read_r1
    OR   A		; test NOW, before sd_cs_deassert clobbers A -- same
			; bug class as CMD0's fix above: this used to run
			; after sd_cs_deassert, meaning "ready" could never
			; actually be detected (always testing the deassert
			; call's own leftover shadow byte, never zero)
    LD   (sdi_info),A	; stash the real R1 too, in case this iteration
			; is the one that exhausts retries below -- also
			; moved before the deassert call for the same reason
    CALL sd_settle
    CALL sd_cs_deassert
    JR   Z,sdi_ready
    DJNZ sdi_acmd41
    LD   A,4
    JP   sdi_fail_tag

sdi_ready:
    CALL sd_cs_assert
    CALL build_cmd58
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,sdi_cmd58_ok
    LD   (sdi_info),A	; A = CMD58's own R1
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,5
    JP   sdi_fail_tag
sdi_cmd58_ok:
    LD   A,$FF
    CALL spi_xfer	; OCR byte 1 -- bit6 is CCS
    LD   (spi_tmp),A	; stash in MEMORY -- same reason as CMD8's R1
			; above, the 3 spi_xfer calls below would clobber D
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,(spi_tmp)
    LD   (sdi_info),A	; stash the raw OCR byte 1 before AND masks it
    AND  $40
    JR   NZ,sdi_ccs_ok
    LD   A,6
    JP   sdi_fail_tag	; CCS=0 -- SDSC, unsupported by this driver
sdi_ccs_ok:
    OR   A		; success -- carry clear
    RET

; ---- sdi_fail_tag: A = stage number (1-6, see sd_init's comments
; ---- above for what each means), sdi_info already holds the
; ---- associated response/echo/OCR byte. Stashes the stage and falls
; ---- into the plain failure return. ----
sdi_fail_tag:
    LD   (sdi_stage),A
sdi_fail:
    SCF
    RET

; ---- sd_cs_assert / sd_cs_deassert: CS low/high via porta_shadow.
; Touch only A; safe to call from anywhere. ----
sd_cs_assert:
    LD   A,(porta_shadow)
    RES  CS_BIT,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    RET

sd_cs_deassert:
    LD   A,(porta_shadow)
    SET  CS_BIT,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    RET

; ---- sd_settle: clocks one extra byte (CS still whatever it already
; is -- always called before sd_cs_deassert, so still asserted) to
; give the card a little settling/completion time after a *complete*
; response (including any payload) before the next command starts.
; Preserves A and all flags across itself via PUSH/POP AF, so it's
; safe to insert right before any existing "CALL sd_cs_deassert"
; without disturbing whatever the caller is about to test.
;
; History: this used to live *inside* read_r1 instead, applied right
; after finding R1 -- worked for CMD0 (no payload follows R1) but
; silently ate the first byte of any payload that DOES follow R1
; (CMD8's R7, CMD58's OCR), shifting every subsequent payload read by
; one. Moved out here, called explicitly after a command's *entire*
; response (payload included) has been read, so it never overlaps
; with payload bytes regardless of how many a given command has. ----
sd_settle:
    PUSH AF
    LD   A,$FF
    CALL spi_xfer
    POP  AF
    RET

; ---- spi_xfer: A = byte to send, returns received byte in A.
; SPI mode 0 (idle low, sample while SCK high). Preserves BC and HL;
; clobbers D and E (bit counter / shift register). ----
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
    OUT  ($A8),A	; MOSI valid, SCK low (setup)
    SET  SCK_BIT,A
    OUT  ($A8),A	; SCK high -- card samples MOSI, drives MISO
    IN   A,($AA)
    SLA  C		; shift first -- SLA sets Z from its OWN result,
			; so testing BIT after it (not before, as an
			; earlier version of this file did) is required:
			; otherwise SLA's flag write clobbers BIT's Z
			; before the JR ever sees it, and since C starts
			; at 0 the bug is self-reinforcing (SLA of 0 is
			; always 0, always "skip", C can never leave 0) --
			; the accumulated byte would be $00 unconditionally,
			; regardless of the real MISO signal. Caught by the
			; user reading this exact code.
    BIT  MISO_BIT,A
    JR   Z,sx_miso0
    SET  0,C
sx_miso0:
    LD   A,(porta_shadow)
    OUT  ($A8),A	; SCK back low
    DEC  D
    JR   NZ,sx_bit
    LD   A,C
    POP  BC
    RET

; ---- send_cmd: clocks out the 6 bytes at cmd_buf. Preserves BC/HL. ----
send_cmd:
    PUSH BC
    PUSH HL
    LD   HL,cmd_buf
    LD   B,6
scmd_loop:
    LD   A,(HL)
    CALL spi_xfer
    INC  HL
    DJNZ scmd_loop
    POP  HL
    POP  BC
    RET

; ---- read_r1: clocks $FF until a byte != $FF comes back (or 8 tries
; ---- run out, leaving A=$FF). Returns the byte in A. Preserves BC.
;
; History: briefly added a trailing dummy clock here (common SD-over-
; SPI advice: give the card a few extra clock edges to settle after a
; response). Removed again -- it turned out to be based on a wrong
; diagnosis (the real bug behind the symptom that prompted it was a
; register-clobber bug elsewhere, fixed separately -- see bring-up-
; log.md), and worse, the extra clock was actively harmful for any
; multi-byte response: it happens *inside* read_r1, so it silently
; consumes the first byte of whatever immediately follows R1 in the
; stream (R7's payload, for CMD8) -- harmless for CMD0 (nothing
; follows R1 there), but it shifted every subsequent R7 byte read by
; one, so CMD8's echo-pattern check ended up reading past the end of
; the real response and got a garbage $FF. ----
read_r1:
    PUSH BC
    LD   B,8
r1_loop:
    LD   A,$FF
    CALL spi_xfer
    CP   $FF
    JR   NZ,r1_done
    DJNZ r1_loop
r1_done:
    POP  BC
    RET

; ---- wait_token: clocks $FF until the $FE data-start token arrives.
; Carry SET = timeout, carry CLEAR = found. Preserves BC (uses it as
; its own timeout countdown internally, safe because spi_xfer itself
; preserves BC across each call). ----
wait_token:
    PUSH BC
    LD   BC,4096
wt_loop:
    LD   A,$FF
    CALL spi_xfer
    CP   $FE
    JR   Z,wt_ok
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,wt_loop
    POP  BC
    SCF
    RET
wt_ok:
    POP  BC
    OR   A
    RET

; ---- read_block: HL -> 512-byte destination buffer. Assumes CS
; already asserted and R1 already checked OK. Carry SET = failure
; (token timeout), carry CLEAR = success (buffer filled, 2 trailing
; CRC bytes clocked in and discarded). ----
read_block:
    CALL wait_token
    RET  C
    PUSH BC
    LD   C,2
rb_outer:
    LD   B,0
rb_inner:
    LD   A,$FF
    CALL spi_xfer
    LD   (HL),A
    INC  HL
    DJNZ rb_inner
    DEC  C
    JR   NZ,rb_outer
    LD   A,$FF
    CALL spi_xfer	; CRC byte 1, discarded (CRC checking is off)
    LD   A,$FF
    CALL spi_xfer	; CRC byte 2, discarded
    POP  BC
    OR   A
    RET

; ---- write_block: HL -> 512-byte source buffer. Assumes CS already
; asserted and R1 already checked OK. Sends the $FE data token, the
; 512 bytes, 2 dummy CRC bytes, checks the data-response token
; (accepted iff (response & $1F) == $05), then polls busy (MISO held
; low by the card while it programs) up to a generous ceiling. Carry
; SET = failure (rejected or busy-timeout), carry CLEAR = success. ----
write_block:
    PUSH BC
    LD   A,$FE
    CALL spi_xfer
    LD   C,2
wb_outer:
    LD   B,0
wb_inner:
    LD   A,(HL)
    CALL spi_xfer
    INC  HL
    DJNZ wb_inner
    DEC  C
    JR   NZ,wb_outer
    LD   A,$FF
    CALL spi_xfer	; dummy CRC byte 1
    LD   A,$FF
    CALL spi_xfer	; dummy CRC byte 2
    LD   A,$FF
    CALL spi_xfer	; data-response token
    AND  $1F
    CP   $05
    JR   NZ,wb_reject
    LD   BC,8000h	; busy-wait ceiling, reusing BC now that the
			; 512-byte loop above is done with it
wb_busy:
    LD   A,$FF
    CALL spi_xfer
    CP   $00
    JR   NZ,wb_done
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,wb_busy
    POP  BC
    SCF
    RET
wb_done:
    POP  BC
    OR   A
    RET
wb_reject:
    POP  BC
    SCF
    RET

; ---- build_cmd0 / build_cmd8 / build_cmd55 / build_acmd41 /
; ---- build_cmd58: fill cmd_buf (6 bytes: command | 4 arg bytes | CRC)
; ---- for the fixed-argument commands. CMD0/CMD8 need real CRC7
; ---- values ($95/$87, well-known constants for their fixed all-zero/
; ---- $000001AA arguments); every other command's CRC byte just needs
; ---- its stop bit set (CRC checking is off by default outside
; ---- CMD0/CMD8), so $01 is used throughout. ----
build_cmd0:
    LD   A,$40
    LD   (cmd_buf+0),A
    XOR  A
    LD   (cmd_buf+1),A
    LD   (cmd_buf+2),A
    LD   (cmd_buf+3),A
    LD   (cmd_buf+4),A
    LD   A,$95
    LD   (cmd_buf+5),A
    RET

build_cmd8:
    LD   A,$48
    LD   (cmd_buf+0),A
    XOR  A
    LD   (cmd_buf+1),A
    LD   (cmd_buf+2),A
    LD   A,$01
    LD   (cmd_buf+3),A
    LD   A,$AA
    LD   (cmd_buf+4),A
    LD   A,$87
    LD   (cmd_buf+5),A
    RET

build_cmd55:
    LD   A,$77
    LD   (cmd_buf+0),A
    XOR  A
    LD   (cmd_buf+1),A
    LD   (cmd_buf+2),A
    LD   (cmd_buf+3),A
    LD   (cmd_buf+4),A
    LD   A,$01
    LD   (cmd_buf+5),A
    RET

build_acmd41:
    LD   A,$69
    LD   (cmd_buf+0),A
    LD   A,$40		; HCS bit (bit30 of the 32-bit arg)
    LD   (cmd_buf+1),A
    XOR  A
    LD   (cmd_buf+2),A
    LD   (cmd_buf+3),A
    LD   (cmd_buf+4),A
    LD   A,$01
    LD   (cmd_buf+5),A
    RET

build_cmd58:
    LD   A,$7A
    LD   (cmd_buf+0),A
    XOR  A
    LD   (cmd_buf+1),A
    LD   (cmd_buf+2),A
    LD   (cmd_buf+3),A
    LD   (cmd_buf+4),A
    LD   A,$01
    LD   (cmd_buf+5),A
    RET

; ---- build_rw_cmd: A = command byte ($51=CMD17 read, $58=CMD24
; ---- write), HL = 16-bit block number (top 16 bits of the 32-bit
; ---- argument are forced to 0 -- see TEST_SECTOR's comment above).
; ---- Fills cmd_buf. ----
build_rw_cmd:
    LD   (cmd_buf+0),A
    XOR  A
    LD   (cmd_buf+1),A
    LD   (cmd_buf+2),A
    LD   A,H
    LD   (cmd_buf+3),A
    LD   A,L
    LD   (cmd_buf+4),A
    LD   A,$01
    LD   (cmd_buf+5),A
    RET

; ============================================================
; Test-buffer helpers
; ============================================================

; ---- fill_test_pattern: fills sd_wbuf with an incrementing
; ---- 0..255,0..255 byte pattern (512 bytes, two 256-byte passes). ----
fill_test_pattern:
    LD   HL,sd_wbuf
    LD   D,2
    XOR  A
ftp_outer:
    LD   B,0
ftp_inner:
    LD   (HL),A
    INC  HL
    INC  A
    DJNZ ftp_inner
    DEC  D
    JR   NZ,ftp_outer
    RET

; ---- compare_buffers: sd_wbuf vs sd_rbuf, 512 bytes. Carry SET on
; ---- first mismatch, carry CLEAR if all 512 bytes match. ----
compare_buffers:
    LD   HL,sd_wbuf
    LD   DE,sd_rbuf
    LD   C,2
cb_outer:
    LD   B,0
cb_inner:
    LD   A,(DE)
    CP   (HL)
    JR   NZ,cb_fail
    INC  HL
    INC  DE
    DJNZ cb_inner
    DEC  C
    JR   NZ,cb_outer
    OR   A
    RET
cb_fail:
    SCF
    RET

; ---- dump_hex16: HL -> 16 source bytes, DE -> destination buffer.
; ---- Writes "XX XX XX ... XX",0 (48 hex/space chars + null). ----
dump_hex16:
    LD   B,16
dh_loop:
    LD   A,(HL)
    CALL byte_to_hex
    LD   A,' '
    LD   (DE),A
    INC  DE
    INC  HL
    DJNZ dh_loop
    XOR  A
    LD   (DE),A
    RET

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

title_msg:      db "SD CARD TEST",0
initok_msg:     db "SD INIT: OK",0
initfail_msg:   db "SD INIT: FAILED",0
wrcmdfail_msg:  db "WRITE CMD REJECTED",0
writefail_msg:  db "WRITE FAILED (TIMEOUT/CRC)",0
rdcmdfail_msg:  db "READ CMD REJECTED",0
readfail_msg:   db "READ FAILED (NO TOKEN)",0
cmppass_msg:    db "ROUNDTRIP: PASS",0
cmpfail_msg:    db "ROUNDTRIP: FAIL",0
s0fail_msg:     db "SECTOR0 READ FAILED",0
s0label_msg:    db "MBR[0..15]=",0

; ---- init-failure detail line: "STAGE=n INFO=$xx", filled in at
; ---- runtime from sdi_stage/sdi_info (see sd_init's sdi_fail_tag).
; ---- Stage numbers: 1=CMD0 no/bad response, 2=CMD8 illegal command
; ---- (v1/MMC, unsupported), 3=CMD8 echo mismatch, 4=ACMD41 never
; ---- went ready (256 retries), 5=CMD58 command itself rejected,
; ---- 6=CMD58 OK but CCS=0 (SDSC, unsupported). INFO is the
; ---- associated R1/echo/OCR byte for that stage. ----
initfail_detail: db "STAGE="
stage_digit:     db "0 INFO=$"
info_hex:        db "00",0

porta_shadow:   ds 1
sdi_stage:      ds 1
sdi_info:       ds 1
spi_tmp:        ds 1	; scratch byte for values that must survive
			; multiple spi_xfer calls -- D and E can't be used
			; for this (spi_xfer clobbers both unconditionally,
			; D as its own bit counter, always left at 0 when
			; it returns), only memory or BC/HL (which spi_xfer
			; does preserve) survive across a call. Real bug
			; found here: CMD8's R1 and CMD58's OCR byte 1 were
			; both being stashed in D across several more
			; spi_xfer calls (the R7/OCR payload bytes), so by
			; the time either was read back, D had been clobbered
			; to 0 by the last of those calls -- deterministic,
			; regardless of the card's real response, and the
			; actual explanation for the CMD8 "$00" that survived
			; a completely unrelated fix attempt unchanged.
spi_tmp2:       ds 1	; second scratch byte, same reasoning as spi_tmp
			; -- needed once sd_settle (see its own comment)
			; started getting called between capturing a value
			; and using it, since sd_settle's internal spi_xfer
			; call clobbers D/E just as much as any other; CMD8's
			; echo byte briefly relied on E surviving that gap
			; and broke the same way spi_tmp's own history did
cmd_buf:        ds 6
hexline:        ds 49
sd_wbuf:        ds 512
sd_rbuf:        ds 512

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
