; cbios-disk-test.asm -- Phase 12: standalone bring-up of the CBIOS
; disk driver (SELDSK/SETTRK/SETSEC/SETDMA/READ/WRITE/HOME/SECTRAN)
; before it's wired into the real BIOS. Reuses Phase 11's proven SD
; SPI driver (sd_init/spi_xfer/read_block/write_block/etc, copied
; verbatim from sdcard-test.asm) and adds the new translation layer
; this phase actually needs: CP/M's 128-byte logical sectors, on the
; classic IBM-3740-derived 77-track x 26-sector/track geometry
; (cpm-plan.md section 7's DPB), mapped onto the SD card's real
; 512-byte physical blocks.
;
; Mapping: absolute_128_index = track*26 + sector (sector already
; "translated" -- see SECTRAN's own comment for why that's a no-op
; here); SD LBA = absolute_128_index / 4; byte offset within that
; 512-byte block = (absolute_128_index mod 4) * 128 (a 4-entry table
; lookup, avoiding an 8-bit overflow: 3*128=384 doesn't fit in a
; byte). A one-block read cache (sector_cache/cached_lba) avoids
; re-reading the SD card on every 128-byte access within the same
; physical block; WRITE always does a full read-modify-write of the
; 512-byte block (never just blindly writing 128 bytes, which would
; destroy the other 3 quarters) and updates the cache in place rather
; than invalidating it, so a subsequent READ of the same block doesn't
; need to re-fetch what's already known-correct in RAM.
;
; *** WARNING: same as sdcard-test.asm -- this test WRITES real
; *** sectors (see TEST_TRACK/TEST_SECTOR below). Use a scratch or
; *** blank card. ***
;
; Test: SELDSK(0) (expect a non-zero DPH), SELDSK(1) (expect 0 --
; only drive A: exists so far), then SETTRK/SETSEC/SETDMA + WRITE a
; known 128-byte pattern to (TEST_TRACK,TEST_SECTOR), then
; SETTRK/SETSEC/SETDMA + READ it back into a different buffer, compare
; on-device -- the same round-trip philosophy Phase 11 already proved
; out, now exercised through the full translation+cache+RMW pipeline
; instead of talking to the SD driver directly.
org 0

video_base: equ $c000

MODE_SRAM: equ $03	; mode=1 (sram-exec), bank=1

CS_BIT:    equ 2
SCK_BIT:   equ 3
MOSI_BIT:  equ 4
MISO_BIT:  equ 4
SHADOW_INIT: equ $07

; Track/sector to use for the destructive round-trip test. Track 2 is
; the first DATA track (OFF=2 reserves tracks 0-1) -- still perfectly
; capable of being clobbered if this card already has a real CP/M
; filesystem on it, so the same scratch-card warning applies.
TEST_TRACK:  equ 2
TEST_SECTOR: equ 0

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

; ---- magic address ----
    LD   A,($3FFF)

; ---- SD card init (Phase 11, unchanged) ----
    CALL sd_init
    JR   NC,init_ok
    LD   HL,initfail_msg
    LD   B,3
    LD   C,8
    CALL write_msg
    JP   halt
init_ok:
    LD   HL,initok_msg
    LD   B,3
    LD   C,8
    CALL write_msg

; ---- SELDSK sanity: drive 0 should give a non-zero DPH, drive 1
; ---- should give 0 (not (yet) supported) ----
    LD   C,0
    CALL SELDSK
    LD   A,H
    OR   L
    JR   Z,seldsk0_fail
    LD   HL,seldsk0_msg
    LD   B,4
    LD   C,8
    CALL write_msg
    JR   seldsk1_check
seldsk0_fail:
    LD   HL,seldsk0fail_msg
    LD   B,4
    LD   C,8
    CALL write_msg
    JP   halt
seldsk1_check:
    LD   C,1
    CALL SELDSK
    LD   A,H
    OR   L
    JR   NZ,seldsk1_fail
    LD   HL,seldsk1_msg
    LD   B,5
    LD   C,8
    CALL write_msg
    JR   disk_roundtrip
seldsk1_fail:
    LD   HL,seldsk1fail_msg
    LD   B,5
    LD   C,8
    CALL write_msg
    JP   halt

; ---- round-trip: write a known 128-byte pattern to
; ---- (TEST_TRACK,TEST_SECTOR), read it back into a different buffer,
; ---- compare on-device ----
disk_roundtrip:
    LD   C,0
    CALL SELDSK		; re-select drive 0 (also proves SELDSK can be
			; called again without disturbing anything)
    CALL fill_test_pattern

    LD   BC,TEST_TRACK
    CALL SETTRK
    LD   BC,TEST_SECTOR
    CALL SETSEC
    LD   BC,disk_wbuf
    CALL SETDMA
    LD   C,0		; deblocking type (unused by this driver)
    CALL WRITE
    OR   A
    JR   Z,write_ok
    LD   HL,writefail_msg
    LD   B,7
    LD   C,8
    CALL write_msg
    JP   halt
write_ok:
    LD   BC,TEST_TRACK
    CALL SETTRK
    LD   BC,TEST_SECTOR
    CALL SETSEC
    LD   BC,disk_rbuf
    CALL SETDMA
    CALL READ
    OR   A
    JR   Z,read_ok
    LD   HL,readfail_msg
    LD   B,7
    LD   C,8
    CALL write_msg
    JP   halt
read_ok:
    CALL compare_buffers
    JR   C,cmp_fail
    LD   HL,cmppass_msg
    LD   B,7
    LD   C,8
    CALL write_msg
    JP   halt
cmp_fail:
    LD   HL,cmpfail_msg
    LD   B,7
    LD   C,8
    CALL write_msg

halt:
    JP   halt

; ============================================================
; CBIOS disk driver
; ============================================================

; ---- SELDSK: C = drive number (0=A:). Returns HL = DPH address, or
; ---- HL = 0 if the drive doesn't exist. Only drive 0 is implemented. ----
SELDSK:
    LD   A,C
    OR   A
    JR   NZ,seldsk_none
    LD   HL,dph0
    RET
seldsk_none:
    LD   HL,0
    RET

; ---- SETTRK: BC = track number (0-76). Only the low byte is kept --
; ---- fine for this geometry's 77 tracks, nowhere near 256. ----
SETTRK:
    LD   A,C
    LD   (cur_track),A
    RET

; ---- SETSEC: BC = (translated) sector number (0-25). Only the low
; ---- byte is kept -- fine for 26 sectors/track. ----
SETSEC:
    LD   A,C
    LD   (cur_sector),A
    RET

; ---- SETDMA: BC = address of the 128-byte DMA buffer for the next
; ---- READ/WRITE. ----
SETDMA:
    LD   (cur_dma),BC
    RET

; ---- HOME: seek to track 0. ----
HOME:
    LD   BC,0
    CALL SETTRK
    RET

; ---- SECTRAN: BC = logical sector, DE = translate table address.
; ---- Returns HL = physical sector. Identity mapping -- this DPB's
; ---- skew table (dph0's XLT field) is 0, since the classic IBM-3740
; ---- sector skew exists purely to give a mechanical floppy drive
; ---- time to prepare between sequentially-numbered sectors; an SD
; ---- card over SPI has no rotational latency to hide, so there is no
; ---- reason to reorder sectors at all. BDOS conventionally skips
; ---- calling SECTRAN when XLT=0, but this is implemented correctly
; ---- anyway rather than assumed unreachable. ----
SECTRAN:
    LD   H,B
    LD   L,C
    RET

; ---- READ: reads 128 bytes (cur_track,cur_sector) into (cur_dma).
; ---- Returns A=0 success, A<>0 error. ----
READ:
    CALL compute_lba_and_offset	; HL=LBA, DE=byte offset in block
    LD   A,(cached_lba)
    CP   L
    JR   NZ,rd_miss
    LD   A,(cached_lba+1)
    CP   H
    JR   NZ,rd_miss
    JR   rd_have_cache
rd_miss:
    PUSH DE
    PUSH HL
    LD   A,$51			; CMD17 = READ_SINGLE_BLOCK
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,rd_cmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    POP  HL
    POP  DE
    LD   A,1
    RET
rd_cmd_ok:
    LD   HL,sector_cache
    CALL read_block
    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,rd_read_ok
    POP  HL
    POP  DE
    LD   A,2
    RET
rd_read_ok:
    POP  HL
    LD   (cached_lba),HL
    POP  DE
rd_have_cache:
    LD   HL,sector_cache
    ADD  HL,DE
    LD   DE,(cur_dma)
    LD   BC,128
    LDIR
    XOR  A
    RET

; ---- WRITE: writes 128 bytes from (cur_dma) to (cur_track,cur_sector)
; ---- via read-modify-write of the containing 512-byte block. Returns
; ---- A=0 success, A<>0 error. C (deblocking type) is accepted but
; ---- not used -- this driver always does a full, safe RMW regardless
; ---- of whether BDOS thinks the write is to a fresh/unused block. ----
WRITE:
    CALL compute_lba_and_offset	; HL=LBA, DE=byte offset in block
    LD   A,(cached_lba)
    CP   L
    JR   NZ,wr_need_read
    LD   A,(cached_lba+1)
    CP   H
    JR   NZ,wr_need_read
    JR   wr_have_cache
wr_need_read:
    PUSH DE
    PUSH HL
    LD   A,$51
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,wr_rd_cmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    POP  HL
    POP  DE
    LD   A,1
    RET
wr_rd_cmd_ok:
    LD   HL,sector_cache
    CALL read_block
    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,wr_rd_ok
    POP  HL
    POP  DE
    LD   A,2
    RET
wr_rd_ok:
    POP  HL
    LD   (cached_lba),HL
    POP  DE
wr_have_cache:
    LD   HL,sector_cache
    ADD  HL,DE
    EX   DE,HL			; DE = sector_cache+offset (dest)
    LD   HL,(cur_dma)		; HL = source (the caller's 128 bytes)
    LD   BC,128
    LDIR
    LD   HL,(cached_lba)
    LD   A,$58			; CMD24 = WRITE_BLOCK
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,wr_wcmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,3
    RET
wr_wcmd_ok:
    LD   HL,sector_cache
    CALL write_block
    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,wr_ok
    LD   A,4
    RET
wr_ok:
    XOR  A
    RET

; ---- compute_lba_and_offset: reads cur_track/cur_sector, returns
; ---- HL = SD block (LBA) number, DE = byte offset of this 128-byte
; ---- sector within that 512-byte block (0/128/256/384 -- looked up
; ---- from a table rather than computed by shifting, since 3*128=384
; ---- doesn't fit an 8-bit register). Clobbers A/BC. ----
compute_lba_and_offset:
    LD   A,(cur_track)
    LD   L,A
    LD   H,0
    ADD  HL,HL			; 2T
    LD   D,H
    LD   E,L			; DE=2T
    ADD  HL,HL			; 4T
    ADD  HL,HL			; 8T
    LD   B,H
    LD   C,L			; BC=8T
    ADD  HL,HL			; 16T
    ADD  HL,BC			; 24T
    ADD  HL,DE			; 26T
    LD   A,(cur_sector)
    LD   E,A
    LD   D,0
    ADD  HL,DE			; HL = 26*track + sector = absolute
				; 128-byte-sector index
    PUSH HL
    LD   A,L
    AND  3
    ADD  A,A			; x2 for word-table indexing
    LD   E,A
    LD   D,0
    LD   HL,quarter_offsets
    ADD  HL,DE
    LD   E,(HL)
    INC  HL
    LD   D,(HL)			; DE = byte offset (0/128/256/384)
    POP  HL			; HL = absolute index again
    SRL  H
    RR   L
    SRL  H
    RR   L			; HL = absolute index / 4 = LBA
    RET

quarter_offsets: dw 0,128,256,384

; ============================================================
; Disk Parameter Header / Block (cpm-plan.md section 7's geometry:
; 77 tracks x 26 sectors/track x 128 bytes -- classic IBM 3740 SSSD)
; ============================================================

dph0:
    dw   0		; XLT -- 0 = no sector translation (see SECTRAN)
    dw   0,0,0		; BDOS scratch words
    dw   dirbuf		; DIRBUF -- shared 128-byte directory buffer
    dw   dpb0		; DPB
    dw   csv0		; CSV -- directory checksum vector
    dw   alv0		; ALV -- allocation vector

dpb0:
    dw   26		; SPT -- sectors/track
    db   3		; BSH -- block shift (1024-byte blocks)
    db   7		; BLM -- block mask
    db   0		; EXM -- extent mask
    dw   242		; DSM -- (77*26*128 - 2*26*128)/1024 - 1
    dw   63		; DRM -- 64 directory entries
    db   $C0		; AL0
    db   $00		; AL1
    dw   16		; CKS -- (DRM+1)/4
    dw   2		; OFF -- 2 reserved boot tracks

dirbuf: ds 128
csv0:   ds 16		; (DRM+1)/4 = 64/4 = 16
alv0:   ds 31		; ceil((DSM+1)/8) = ceil(243/8) = 31

; ============================================================
; SD card driver (Phase 11, copied verbatim from sdcard-test.asm --
; see that file/docs/sdcard-wiring.md/bring-up-log.md for the full
; design history and the bugs found and fixed along the way)
; ============================================================

sd_init:
    LD   B,10
sdi_preclock:
    LD   A,$FF
    CALL spi_xfer
    DJNZ sdi_preclock

    CALL sd_cs_assert
    CALL build_cmd0
    CALL send_cmd
    CALL read_r1
    LD   (sdi_info),A
    CP   $01
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
    LD   (spi_tmp),A
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    LD   (spi_tmp2),A
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,(spi_tmp)
    CP   $01
    JR   Z,sdi_cmd8_r1_ok
    LD   (sdi_info),A
    LD   A,2
    JP   sdi_fail_tag
sdi_cmd8_r1_ok:
    LD   A,(spi_tmp2)
    CP   $AA
    JR   Z,sdi_cmd8_ok
    LD   (sdi_info),A
    LD   A,3
    JP   sdi_fail_tag
sdi_cmd8_ok:

    LD   B,0
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
    OR   A
    LD   (sdi_info),A
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
    LD   (sdi_info),A
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,5
    JP   sdi_fail_tag
sdi_cmd58_ok:
    LD   A,$FF
    CALL spi_xfer
    LD   (spi_tmp),A
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    CALL sd_settle
    CALL sd_cs_deassert
    LD   A,(spi_tmp)
    LD   (sdi_info),A
    AND  $40
    JR   NZ,sdi_ccs_ok
    LD   A,6
    JP   sdi_fail_tag
sdi_ccs_ok:
    OR   A
    RET

sdi_fail_tag:
    LD   (sdi_stage),A
sdi_fail:
    SCF
    RET

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

sd_settle:
    PUSH AF
    LD   A,$FF
    CALL spi_xfer
    POP  AF
    RET

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
    SLA  C
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
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    POP  BC
    OR   A
    RET

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
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    AND  $1F
    CP   $05
    JR   NZ,wb_reject
    LD   BC,8000h
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
    LD   A,$40
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

; ---- fill_test_pattern / compare_buffers: exactly 128 bytes, matching
; ---- disk_wbuf/disk_rbuf's real size. "LD B,0" is the standard DJNZ
; ---- idiom for 256 iterations -- correct for a 256-byte buffer (as
; ---- Phase 11's own 512-byte, 2x256 version used), but a real bug
; ---- here: disk_wbuf/disk_rbuf are only 128 bytes each, so B=0 ran
; ---- 128 bytes past the end of each buffer. fill_test_pattern's
; ---- overflow spilled into disk_rbuf's own space (harmless in the
; ---- end, since READ legitimately overwrites disk_rbuf afterward),
; ---- but compare_buffers' overflow compared disk_wbuf[128..255]
; ---- (really disk_rbuf's space) against disk_rbuf[128..255] (whatever
; ---- comes right after disk_rbuf in memory -- write_msg's own code),
; ---- which will essentially never match -- causing a reported FAIL
; ---- regardless of whether the real, meaningful 128 bytes round-
; ---- tripped correctly. Caught because WRITE and READ both already
; ---- correctly use "LD BC,128" for their own copies, so a passing
; ---- WRITE/READ with a failing compare pointed straight at the
; ---- comparison itself, not the driver underneath. ----
fill_test_pattern:
    LD   HL,disk_wbuf
    LD   B,128
ftp_loop:
    LD   A,B
    LD   (HL),A
    INC  HL
    DJNZ ftp_loop
    RET

compare_buffers:
    LD   HL,disk_wbuf
    LD   DE,disk_rbuf
    LD   B,128
cb_loop:
    LD   A,(DE)
    CP   (HL)
    JR   NZ,cb_fail
    INC  HL
    INC  DE
    DJNZ cb_loop
    OR   A
    RET
cb_fail:
    SCF
    RET

; ============================================================
; Messages and buffers
; ============================================================

title_msg:        db "CBIOS DISK DRIVER TEST",0
initok_msg:       db "SD INIT: OK",0
initfail_msg:     db "SD INIT: FAILED",0
seldsk0_msg:      db "SELDSK(0): OK (non-zero DPH)",0
seldsk0fail_msg:  db "SELDSK(0): FAILED (returned 0)",0
seldsk1_msg:      db "SELDSK(1): OK (returned 0, as expected)",0
seldsk1fail_msg:  db "SELDSK(1): FAILED (returned non-zero)",0
writefail_msg:    db "WRITE FAILED",0
readfail_msg:     db "READ FAILED",0
cmppass_msg:      db "ROUNDTRIP: PASS",0
cmpfail_msg:      db "ROUNDTRIP: FAIL",0

porta_shadow: ds 1
sdi_stage:    ds 1
sdi_info:     ds 1
spi_tmp:      ds 1
spi_tmp2:     ds 1
cmd_buf:      ds 6

cur_track:    ds 1
cur_sector:   ds 1
cur_dma:      ds 2
cached_lba:   ds 2
sector_cache: ds 512

disk_wbuf: ds 128
disk_rbuf: ds 128

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
