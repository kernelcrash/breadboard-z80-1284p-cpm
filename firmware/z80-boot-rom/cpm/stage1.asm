; stage1.asm -- Phase 12: the stage-1 ROM bootstrap. Uploaded via
; xmodem into the AVR's 8K ROM-emulation window exactly like every
; other test-progs/*.asm file -- this is the ONLY thing baked into
; that window for the real CP/M build; CCP+BDOS+BIOS live on the SD
; card and are loaded by this program (cpm-plan.md section 4).
;
; Job: initialize the SD SPI interface, load three separate chunks
; from fixed, known SD blocks into their correct destinations (each
; under the bank setting that destination needs), then flip to
; SRAM-exec and jump to BOOT ($F200).
;
; ============================================================
; Storage layout on the SD card (raw blocks, NOT through the CP/M
; DPB/SELDSK mechanism -- this program reads the card directly, before
; any CP/M filesystem concept exists yet). Block-aligned for a simple
; loader (no byte-offset-within-block tracking needed) -- each chunk's
; real size is smaller than the whole-block count reserved for it; the
; small overflow past each chunk's real end lands in adjacent, unused
; scratch memory and is harmless (see each chunk's own comment below).
;
; **Multi-drive plan (cpm-plan.md): the SD card now carries a real MBR**
; whose partition 1 is this boot area + drive A, starting at LBA 2048
; (1 MiB, matching every modern fdisk/parted/gdisk alignment default --
; chosen so a real partition table's own bytes at LBA0 offset 446-511
; never collide with this loader's own chunk1, which used to occupy
; the whole of LBA0). BOOT_PARTITION_BASE below is that start LBA,
; hand-synced against the actual MBR the same way CHUNK*_BLOCKS
; already is -- **if the card is ever repartitioned with a different
; partition 1 start, this must be updated too.** Everything below is
; relative to that base; drive A's own DPB (bios.asm) and this
; program's own chunk layout are otherwise completely unchanged by the
; multi-drive work -- only WHERE they physically sit on the card moved.
;
; Lives within the DPB's OFF=5 reserved boot tracks (cpm-plan.md
; section 7, bios.asm's own DPB comment) -- 16640 bytes reserved, this
; uses 25 blocks (1+6+18 = 12800 bytes), comfortable margin for growth.
;
;   Chunk 1: LBA BOOT_PARTITION_BASE+0,  1 block  -- the bank-flip
;            trampoline. Real size 38 bytes. Loaded to a $7C00 scratch
;            pad (load_blocks is 512-byte granular, far more than its
;            real home -- the $0008-$005B page-zero gap -- can hold),
;            then LDIRed down to $0008 just before JP BOOT_ENTRY. See
;            bios.asm's header for why page zero (real PIP/Zork buffer
;            math trampled the old $7C00 location); TRAMPOLINE_DEST/
;            TRAMPOLINE_SIZE below are hand-synced against bios.sym.
;   Chunk 2: LBA BOOT_PARTITION_BASE+1,  6 blocks (was 5 until
;            2026-10-12 -- see CHUNK2_BLOCKS's own comment) -- font +
;            video_blit_impl/video_scroll_impl/video_cls_impl/
;            hb_toggle_impl/bank1_scratch ($8000), bank=1. Real size
;            ~2653 bytes; overflow lands within the bank=1-only free
;            region -- harmless.
;   Chunk 3: LBA BOOT_PARTITION_BASE+7 (right after chunk 2 -- derived
;            as 1+CHUNK2_BLOCKS in code now, not hand-synced; was +6
;            until chunk2 grew past 5 blocks, 2026-10-12), 18 blocks --
;            CCP+BDOS+BIOS
;            ($DC00), bank=0. Real size ~9000 bytes (exactly CPM_BASE
;            to bios.asm's `end` = $FF22); overflow lands in unused RAM
;            -- harmless. HARD CEILING 18 blocks ($DC00+18*512=$10000
;            exactly) -- see CHUNK3_BLOCKS's own comment.
;
; These sizes/LBAs are hand-verified against bios.asm's own assembled
; layout (see bios.sym) each time bios.asm changes -- not derived
; automatically. **If bios.asm's total size grows past what these
; block counts cover, this must be updated by hand or the load will
; truncate.**
; ============================================================

CS_BIT:    equ 2
SCK_BIT:   equ 3
MOSI_BIT:  equ 4
; ---- MISO moved from PC4 to PC7 (2026-09-10) -- a real physical
; ---- rewire shared with bios.asm's own copy of spi_xfer, not just
; ---- this constant: both read the same physical pin at different
; ---- times (this one during boot, bios.asm's afterward), so this
; ---- MUST match bios.asm's MISO_BIT exactly or SD access breaks
; ---- entirely once the wire moves. See bios.asm's own comment and
; ---- bring-up-log.md for the T-state reasoning (this copy only
; ---- loads ~12KB once at boot, so the speed gain here is negligible
; ---- compared to bios.asm's -- applied anyway for consistency, since
; ---- both files must track the same physical wiring regardless).
MISO_BIT:  equ 7

; ---- boot_partition_base (declared with this file's other RAM state,
; ---- below) replaces the old compile-time BOOT_PARTITION_BASE equ --
; ---- read_mbr populates it from the SD card's own real MBR at boot,
; ---- instead of trusting a hand-synced guess that silently goes stale
; ---- the moment the card is ever repartitioned differently from
; ---- write_mbr.py's current layout (LBA 2048). Only the low 16 bits of
; ---- partition 1's start-LBA field are kept -- this whole file's LBA
; ---- math is 16-bit only throughout (build_rw_cmd's own comment), so a
; ---- partition starting past 65536 is a hard failure here (read_mbr
; ---- checks the high 16 bits are genuinely zero and halts otherwise),
; ---- not a silent truncation. Each CHUNKn_LBA below is now
; ---- boot_partition_base+offset, computed at runtime by
; ---- calc_chunk_lba (see each load site) rather than a compile-time
; ---- constant -- the offsets themselves (0/1/6) are unchanged.

CHUNK1_BLOCKS: equ 1
CHUNK1_DEST:   equ $7C00	; SD-load landing pad only -- chunk 1's real
				; home is page zero (TRAMPOLINE_DEST below).
				; load_blocks works in 512-byte units, far more
				; than the 84-byte $0008-$005B page-zero gap can
				; hold, so it lands at $7C00 (free RAM during
				; boot) and gets relocated by a small LDIR just
				; before JP BOOT_ENTRY.
CHUNK1_BANK:   equ 0

; ---- The page-zero trampoline (2026-09-10 -- see bios.asm's header for
; ---- the full why: real PIP/Zork buffer math trampled the old $7C00
; ---- location). HAND-SYNCED with bios.asm's porta_shadow/trampoline_end
; ---- symbols, same as CHUNK*_BLOCKS/LBA already are -- rebuild bios.sym
; ---- and re-check these if bios.asm's page-zero block changes size.
TRAMPOLINE_DEST: equ $0008	; = bios.sym porta_shadow
TRAMPOLINE_SIZE: equ $2E-$08	; = bios.sym (trampoline_end - porta_shadow) = 38

CHUNK2_BLOCKS: equ 6           ; was 5 until 2026-10-12, when bios.asm's
                               ; own bank1_scratch grew 16->256 bytes
                               ; (a real stack-starvation bug fix, see
                               ; that file's own comment) pushed chunk2
                               ; to 2653 bytes -- past the old 5-block
                               ; (2560-byte) budget. Re-verify against
                               ; bios.sym any time bios.asm's bank=1
                               ; region changes size again.
CHUNK2_DEST:   equ $8000
CHUNK2_BANK:   equ 1

; ---- CHUNK3_BLOCKS: HARD CEILING IS 18, NOT the OFF=5 reservation's
; ---- own 32-block budget. CHUNK3_DEST($DC00) + CHUNK3_BLOCKS*512 must
; ---- stay <= $10000 -- this is a 16-bit ADDRESS SPACE wraparound, not
; ---- a soft convention like OFF's. A real bug, hit on the bench: this
; ---- was raised to 20 to fix a *different*, genuinely soft margin
; ---- problem (only 22 bytes spare after the SHIFT fix), without
; ---- checking this harder ceiling -- 20 blocks wraps the last 1024
; ---- bytes of the load around to $0000-$03FF, corrupting stage1's OWN
; ---- running code (it executes from low memory) mid-load. Crashed
; ---- silently before ever reaching CHUNK3's own report line, which is
; ---- exactly what a corruption of the code between "load" and
; ---- "report" would look like. 18 is the true, exact maximum
; ---- (verified: $DC00+18*512=$10000 precisely) -- not sized with any
; ---- further headroom below that, because there is nowhere left in
; ---- the address space to put headroom; the OFF=5/32-block budget
; ---- (1+5+18=24) still has real slack of its own if more room is ever
; ---- needed on that side instead.
CHUNK3_BLOCKS: equ 18
CHUNK3_DEST:   equ $DC00
CHUNK3_BANK:   equ 0

; ---- Expected 16-bit sum-of-bytes checksums over each chunk's full
; ---- padded size (matching boot.img's own layout exactly -- computed
; ---- directly from the built boot.img, not derived by hand). Verified
; ---- after each load to catch SD-read corruption directly, rather
; ---- than inferring it from downstream symptoms. **Must be
; ---- recomputed whenever bios.asm/boot.img changes** -- same
; ---- hand-sync burden as CHUNK*_BLOCKS/LBA already carry (see this
; ---- file's own header). ----
; ---- Recomputed 2026-10-12 after bios.asm's own bank1_scratch grew
; (CHUNK2_BLOCKS 5->6, see that constant's own comment). CHUNK2_CKSUM
; changing is expected -- chunk2's content genuinely changed. A real,
; separate finding made recomputing these: CHUNK1_CKSUM/CHUNK3_CKSUM
; ALSO no longer matched a freshly-built boot.img, even though neither
; chunk's own content should have been touched by the bank1_scratch
; edit (chunk 1 is the $0008-$002D trampoline, chunk 3 is $DC00+
; CCP/BDOS/BIOS -- both untouched by a $8000+ region change). Most
; likely explanation: these were ALREADY stale before this session,
; undetected because kc-z80-comp-emu's own harnesses all jump straight
; to BOOT_ENTRY ($F200), bypassing stage1.asm's own checksum
; verification entirely -- this project's own emulator-based testing
; has never actually exercised this code path. Not chased further
; (real-hardware-only, no emulator coverage to verify a root cause
; against) -- fixed to match the current, real boot.img while already
; here, rather than left silently broken. ----
CHUNK1_CKSUM: equ $0CC6
CHUNK2_CKSUM: equ $B6E6
CHUNK3_CKSUM: equ $97D4

BOOT_ENTRY: equ $F200

org 0

start:
    LD   A,$8A
    OUT  ($AB),A
    LD   A,$04		; mode=0 (rom emulation, still), bank=0,
			; CS deasserted, SCK=0, MOSI=0
    OUT  ($A8),A

; copy rom to sram -- same idiom every test-progs/*.asm uses. Not
; strictly needed for this program to keep RUNNING after the eventual
; mode-flip (it only needs one more instruction, the final JP, after
; that point) -- but that one instruction still has to be FETCHED from
; wherever mode=1 now says reads come from, so this program's own
; image needs to already be correctly present in SRAM at that exact
; address just like every other test relies on. Skipping this step
; would be a real, subtle bug, not a valid simplification.
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

    LD   A,$04
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   SP,$7FFF

; ---- flip to SRAM-exec NOW, before doing anything else, and read the
; ---- magic address immediately after. This is NOT just for the
; ---- diagnostic below -- it's a hard correctness requirement, found
; ---- the hard way on real hardware: rom_emu.c's magic-address handler
; ---- is a one-way trip. Once it serves that read it permanently drives
; ---- wait_rel low (releasing _WAIT forever) and returns, with nothing
; ---- left running on the AVR side to service any *further*
; ---- ROM-emulation read. If mode_pin were still 0 at that moment, every
; ---- subsequent instruction fetch would still be routed through the
; ---- 373 (mode_pin=0 = "read from rom"), but nothing is left to drive
; ---- it -- the Z80 would fetch garbage off a dead/floating bus with no
; ---- WAIT to save it. mode_pin=1 makes every read after this point
; ---- come from real SRAM instead, independent of the AVR, which is
; ---- exactly what's needed for this to be safe. (This is also why
; ---- every prior test-progs/*.asm file only ever reads $3FFF right
; ---- after its own mode-flip, never before -- same constraint, just
; ---- not written down until it bit us here.)
; ---- bank is already 0 (set above) -- CP/M's steady state, and correct
; ---- for chunk 1's destination below $8000 too.
; ---- NOTE: literal value here, NOT a porta_shadow read-modify-write.
; ---- A "LD A,(porta_shadow)" at this exact point would be a real,
; ---- separate bug (caught on review, not yet hit in practice as far
; ---- as we can tell): mode_pin is STILL 0 here, so that read would be
; ---- serviced by the AVR's ROM-emulation path (the byte statically
; ---- present in the uploaded image at that offset), NOT the $04 we
; ---- just wrote into real SRAM a few instructions above -- writes
; ---- always land in SRAM regardless of mode_pin, but reads don't
; ---- reflect that until mode_pin actually flips. We already know the
; ---- exact current state literally (just set it to $04 above), so
; ---- there's no need to read it back at all -- avoids the hazard
; ---- entirely instead of relying on how a stale read happens to
; ---- combine with OR.
    LD   A,$05		; $04 | mode_pin(bit0) -- bank=0, CS deasserted,
			; mode=1 (SRAM-exec)
    LD   (porta_shadow),A
    OUT  ($A8),A

; ---- Reverted: moving the magic address to after chunk 1's SD load
; ---- (to test whether BUSRQ-during-SPI causes the byte-drop
; ---- corruption) surfaced a DIFFERENT, confounding problem instead --
; ---- sd_init hung completely. sd_init's retry loops (ACMD41's LD B,0/
; ---- DJNZ, wait_token's 4096-iteration count) are iteration-count
; ---- based, not wall-clock-time based -- every prior successful SD
; ---- test (sdcard-test.asm, cbios-disk-test.asm) also had video
; ---- generation (and its ~1.75x average slowdown, per the earlier
; ---- NMI/video-steal benchmark) active throughout sd_init, meaning
; ---- those retry counts may have never actually been exercised at
; ---- the Z80's true, unthrottled 8MHz speed before. Without that
; ---- slowdown, the same iteration count elapses in less real time --
; ---- plausibly not enough for the SD card's own internal init to
; ---- finish, independent of host polling speed. This confounds a
; ---- clean test of the BUSRQ hypothesis, so reverted back to the
; ---- known-working position (magic address immediately after the
; ---- mode-flip, before any SD I/O) rather than chase two problems
; ---- through one experiment. ----
    LD   A,($3FFF)	; magic address -- tells the AVR to stop emulating
			; ROM and switch to video generation.


; ---- DIAGNOSTIC REPORTING: each stage prints its own name, the
; ---- checksum it actually computed, and OK/BAD, instead of the
; ---- progress bars -- counting white bars by eye turned out to be
; ---- unreliable in practice. stage1 carries its own copy of the font
; ---- (low memory, bank-invariant, copied to SRAM with the rest of
; ---- this program) so it can print before chunk2's font is loaded.
; ---- The screen is cleared ONCE here and deliberately never again --
; ---- boot_init's clear is disabled and CP/M's own output starts
; ---- below these lines, so this report stays readable after boot. ----
    CALL video_cls_s1

    CALL sd_init
    JR   NC,sd_ok
    LD   HL,msg_sdbad
    XOR  A
    CALL print_at
    JP   boot_halt
sd_ok:
    LD   HL,msg_sdok
    XOR  A
    CALL print_at

    CALL read_mbr
    JR   NC,mbr_ok
    LD   HL,msg_mbrbad
    LD   A,1
    CALL print_at
    JP   boot_halt
mbr_ok:

; ---- chunk 1: low-memory trampoline ($7C00), bank=0 ----
    LD   A,(porta_shadow)
    AND  $FD		; clear bank bit (bit 1) -- CHUNK1_BANK=0
    LD   (porta_shadow),A
    OUT  ($A8),A

    LD   HL,CHUNK1_DEST
    LD   DE,0
    CALL calc_chunk_lba
    LD   B,CHUNK1_BLOCKS
    CALL load_blocks

    LD   HL,CHUNK1_DEST
    LD   BC,CHUNK1_BLOCKS*512
    CALL compute_checksum
    LD   DE,CHUNK1_CKSUM
    LD   BC,lbl_chunk1
    LD   A,1
    CALL report
    JP   C,boot_halt

; ---- chunk 2: font + blit/scroll code ($8000), bank=1. The checksum
; ---- must be computed while still bank=1 -- that is the only bank in
; ---- which this data is addressable at all. report itself leaves
; ---- bank=0 on exit. ----
    LD   A,(porta_shadow)
    OR   $02		; set bank bit -- CHUNK2_BANK=1
    LD   (porta_shadow),A
    OUT  ($A8),A

    LD   HL,CHUNK2_DEST
    LD   DE,1
    CALL calc_chunk_lba
    LD   B,CHUNK2_BLOCKS
    CALL load_blocks

    LD   HL,CHUNK2_DEST
    LD   BC,CHUNK2_BLOCKS*512
    CALL compute_checksum
    LD   DE,CHUNK2_CKSUM
    LD   BC,lbl_chunk2
    LD   A,2
    CALL report
    JP   C,boot_halt

; ---- chunk 3: CCP+BDOS+BIOS ($DC00), bank=0 ----
    LD   HL,CHUNK3_DEST
    LD   DE,1+CHUNK2_BLOCKS   ; chunk3's own LBA offset = right after
                              ; chunk2 -- was a hardcoded 6 (1+5) until
                              ; 2026-10-12's CHUNK2_BLOCKS growth to 6;
                              ; now derived so this can't go stale again
    CALL calc_chunk_lba
    LD   B,CHUNK3_BLOCKS
    CALL load_blocks

    LD   HL,CHUNK3_DEST
    LD   BC,CHUNK3_BLOCKS*512
    CALL compute_checksum
    LD   DE,CHUNK3_CKSUM
    LD   BC,lbl_chunk3
    LD   A,3
    CALL report
    JP   C,boot_halt

; ---- Relocate chunk 1 (the bank-invariant trampoline) from its
; ---- $7C00 landing pad to its real home in page zero. Safe here even
; ---- though stage1 itself runs from org 0: this LDIR and the JP below
; ---- both sit well above $002D in stage1's own layout, and the
; ---- $0008-$002D bytes being overwritten are stage1's OWN startup
; ---- instructions, which already ran and never run again. Page zero
; ---- $0008+ is otherwise untouched from here until CCP starts. ----
    LD   HL,CHUNK1_DEST
    LD   DE,TRAMPOLINE_DEST
    LD   BC,TRAMPOLINE_SIZE
    LDIR

    LD   HL,msg_boot
    LD   A,4
    CALL print_at
    JP   BOOT_ENTRY

; ---- print_at: HL -> NUL-terminated string, A = row. Prints at
; ---- column 0. Flips to bank=1 for the write and back to bank=0.
; ---- Safe to CALL freely while bank=1 here: stage1's SP is $7FFF,
; ---- below $8000, so the stack is bank-invariant (unlike the CBIOS,
; ---- whose CCPSTACK sits inside the aliased range). ----
print_at:
    LD   B,A
    LD   A,(porta_shadow)
    SET  1,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   C,0
    CALL write_msg
    LD   A,(porta_shadow)
    RES  1,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    RET

; ---- report: HL = computed checksum, DE = expected, BC -> label
; ---- string, A = row. Renders "<label><hex> OK|BAD" and returns with
; ---- carry SET on mismatch, so the caller can halt on a bad load. ----
report:
    LD   (rep_row),A
    LD   (rep_cksum),HL
    LD   (rep_expect),DE
    LD   H,B
    LD   L,C
    LD   DE,repbuf
rep_copy:
    LD   A,(HL)
    OR   A
    JR   Z,rep_copied
    LD   (DE),A
    INC  HL
    INC  DE
    JR   rep_copy
rep_copied:
    LD   HL,(rep_cksum)
    LD   A,H
    CALL byte_to_hex	; byte_to_hex advances DE and preserves HL
    LD   A,L
    CALL byte_to_hex
    CALL rep_verdict
    LD   HL,str_bad
    JR   C,rep_tail
    LD   HL,str_ok
rep_tail:
    LD   A,(HL)
    OR   A
    JR   Z,rep_show
    LD   (DE),A
    INC  HL
    INC  DE
    JR   rep_tail
rep_show:
    XOR  A
    LD   (DE),A
    LD   HL,repbuf
    LD   A,(rep_row)
    CALL print_at
    JP   rep_verdict	; recompute so the carry flag survives print_at

; ---- rep_verdict: carry set if (rep_cksum) != (rep_expect). ----
rep_verdict:
    LD   HL,(rep_cksum)
    LD   BC,(rep_expect)
    LD   A,H
    CP   B
    JR   NZ,rv_bad
    LD   A,L
    CP   C
    JR   NZ,rv_bad
    OR   A		; clear carry
    RET
rv_bad:
    SCF
    RET

; ---- video_cls_s1: clear the framebuffer. Straight-line, no stack
; ---- activity while bank=1 (same discipline the CBIOS needs). ----
video_cls_s1:
    LD   A,(porta_shadow)
    SET  1,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   HL,$C000
    LD   BC,16000
s1cls_loop:
    XOR  A		; INSIDE the loop -- LD A,B/OR C clobbers A below
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,s1cls_loop
    LD   A,(porta_shadow)
    RES  1,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    RET

msg_sdok:    db 'SD INIT OK',0
msg_sdbad:   db 'SD INIT FAILED',0
msg_mbrbad:  db 'MBR READ FAILED',0
lbl_chunk1:  db 'CHUNK1 TRAMPOLINE ',0
lbl_chunk2:  db 'CHUNK2 FONT+BLIT  ',0
lbl_chunk3:  db 'CHUNK3 CCP+BDOS   ',0
str_ok:      db ' OK',0
str_bad:     db ' BAD',0
msg_boot:    db 'JUMPING TO BOOT',0

boot_halt:
    JR   boot_halt




compute_checksum:
    PUSH DE
    LD   DE,0
cc_loop:
    LD   A,(HL)
    ADD  A,E
    LD   E,A
    LD   A,0
    ADC  A,D
    LD   D,A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,cc_loop
    LD   H,D
    LD   L,E
    POP  DE
    RET
; ---- calc_chunk_lba: DE = offset from the boot partition's own start
; ---- (0/1/6 for chunk 1/2/3), HL = caller's dest pointer (preserved).
; ---- Returns DE = boot_partition_base + offset, ready for load_blocks.
calc_chunk_lba:
    PUSH HL
    LD   HL,(boot_partition_base)
    ADD  HL,DE
    EX   DE,HL
    POP  HL
    RET

; ---- read_mbr: reads the real MBR (raw LBA 0 -- always the physical
; ---- start of the disk, no partitioning ambiguity there) into the
; ---- CHUNK1_DEST scratch pad ($7C00 -- free at this point, chunk 1
; ---- hasn't been loaded there yet), verifies the standard $55AA boot
; ---- signature, and copies primary partition 1's start-LBA field (low
; ---- 16 bits) into boot_partition_base. Unlike bios.asm's own, much
; ---- more byte-constrained copy of this idea, this file has room
; ---- (stage1.bin is well under the AVR's 8K xmodem buffer) to check
; ---- the signature AND that the high 16 bits of the partition-start
; ---- field are genuinely zero -- if a real card's partition 1 somehow
; ---- starts past 65536, this loader (16-bit LBA math throughout)
; ---- genuinely cannot reach it, so that's a hard failure here, not a
; ---- silent truncation. Returns carry set on any failure (SD read,
; ---- bad signature, or partition start too large) -- caller halts. ----
read_mbr:
    LD   HL,0
    LD   A,$51		; CMD17 = READ_SINGLE_BLOCK
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,rm_cmd_ok
    CALL sd_settle
    CALL sd_cs_deassert
    SCF
    RET
rm_cmd_ok:
    LD   HL,CHUNK1_DEST
    CALL read_block
    PUSH AF
    CALL sd_settle
    CALL sd_cs_deassert
    POP  AF
    RET  C

    LD   A,(CHUNK1_DEST+510)
    CP   $55
    JR   NZ,rm_bad
    LD   A,(CHUNK1_DEST+511)
    CP   $AA
    JR   NZ,rm_bad

    LD   HL,(CHUNK1_DEST+446+8+2)	; partition 1 LBA-start, high 16
    LD   A,H				; bits -- must be 0 (16-bit-only
    OR   L				; LBA math throughout this file)
    JR   NZ,rm_bad

    LD   HL,(CHUNK1_DEST+446+8)
    LD   (boot_partition_base),HL
    OR   A		; clear carry -- success
    RET
rm_bad:
    SCF
    RET

; ---- load_blocks: HL=destination address, DE=starting LBA (block
; ---- number), B=block count. Reads B consecutive 512-byte blocks via
; ---- CMD17, writing each one to (HL) and advancing HL by 512 (via
; ---- read_block's own contract), advancing the LBA by 1 each time.
; ---- Halts (via boot_halt) on any command or read failure -- nothing
; ---- meaningful to do if the boot media fails partway through.
; ----
; ---- State lives in memory (lb_dest/lb_lba/lb_count), not registers:
; ---- a real bug (found on real hardware -- chunks with >1 block
; ---- loaded the first block correctly, then read wrong sectors from
; ---- there on) turned out to be spi_xfer clobbering D/E as its own
; ---- scratch registers (LD E,A / LD D,8) -- and spi_xfer runs, via
; ---- send_cmd/read_r1/read_block/sd_settle, at every single stage of
; ---- this loop's body, including after a plain push/pop-based
; ---- restore of DE=LBA, corrupting it again before the next INC DE.
; ---- Saving state to memory instead sidesteps needing to know (or
; ---- keep re-verifying) exactly which registers every callee happens
; ---- to preserve. ----
load_blocks:
    LD   (lb_dest),HL
    LD   (lb_lba),DE
    LD   A,B
    LD   (lb_count),A
lb_loop:
    LD   HL,(lb_lba)
    LD   A,$51		; CMD17 = READ_SINGLE_BLOCK
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   Z,lb_cmd_ok
    JP   boot_halt

lb_cmd_ok:
    LD   HL,(lb_dest)
    CALL read_block	; fills 512 bytes at (HL), advances HL by 512
    LD   (lb_dest),HL

    CALL sd_settle
    CALL sd_cs_deassert
    JR   NC,lb_read_ok
    JP   boot_halt

lb_read_ok:
    LD   HL,(lb_lba)
    INC  HL
    LD   (lb_lba),HL
    LD   A,(lb_count)
    DEC  A
    LD   (lb_count),A
    JR   NZ,lb_loop
    RET

; ============================================================
; SD card driver -- reused verbatim from sdcard-test.asm/
; cbios-disk-test.asm/bios.asm (full design history in bring-up-log.md)
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

; ---- sd_cs_assert / sd_cs_deassert: REAL FIX, not a diagnostic --
; ---- found by comparing against the Z80-Retro/2063-Z80-cpm reference
; ---- implementation (lib/spi.asm's spi_ssel_true/spi_ssel_false),
; ---- itself citing the SD Physical Layer Simplified Spec section 4.4's
; ---- mandatory "dummy 8 clock edges" requirements around every CS
; ---- transition and command/response/data boundary. Our own version
; ---- had NONE of this -- just a bare CS toggle -- which is a real,
; ---- spec-mandated gap, not a soft nicety: without it the card may
; ---- still be internally busy from its previous operation when the
; ---- next command starts, and different cards have different internal
; ---- margins for how much this actually matters, matching exactly
; ---- what was observed (different SD cards showing different
; ---- corruption for the same reads, memory/protocol/timing already
; ---- ruled out otherwise). sd_cs_assert now also busy-waits (clocking
; ---- until the card returns $FF) after asserting CS, matching
; ---- spi_ssel_true exactly. ----
sd_cs_assert:
; ---- Preserves BC: every other routine in this driver does (spi_xfer,
; ---- send_cmd, read_r1, wait_token, read_block all push/pop it), and
; ---- sd_init's ACMD41 retry loop holds its counter in B across a call
; ---- to this routine. The busy-wait's own LD BC,4096 below would
; ---- otherwise silently destroy that counter -- a real bug introduced
; ---- along with the busy-wait itself.
    PUSH BC
    LD   A,$FF		; 8 dummy clocks BEFORE asserting CS (spec 4.4)
    CALL spi_xfer
    LD   A,(porta_shadow)
    RES  CS_BIT,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   BC,4096	; busy-wait: clock until the card reports $FF
sd_csa_busy:
    LD   A,$FF
    CALL spi_xfer
    CP   $FF
    JR   Z,sd_csa_done
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,sd_csa_busy
sd_csa_done:
    POP  BC
    RET

sd_cs_deassert:
; ---- Preserves the caller's flags (esp. carry, e.g. read_block's own
; ---- success/failure result) across the new spi_xfer calls below --
; ---- spi_xfer itself does not preserve flags (its own BIT/DEC
; ---- instructions set them freely), and callers like load_blocks
; ---- check carry immediately after this returns. ----
    PUSH AF
    LD   A,$FF		; 8 dummy clocks BEFORE deasserting (still CS=0)
    CALL spi_xfer
    LD   A,(porta_shadow)
    SET  CS_BIT,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   A,$FF		; 16 more dummy clocks AFTER deasserting
    CALL spi_xfer
    LD   A,$FF
    CALL spi_xfer
    POP  AF
    RET

sd_settle:
    PUSH AF
    LD   A,$FF
    CALL spi_xfer
    POP  AF
    RET

; ---- spi_xfer: A = byte to send, returns received byte in A. Same
; ---- two optimizations as bios.asm's copy (see its own comment for
; ---- the full T-state accounting) -- MISO on bit 7 lets the old
; ---- branch-based IN/SLA C/BIT/JR Z/SET 0,C become a fixed IN/RLA/
; ---- RL C, and the loop counter moved from D (DEC D/JR NZ) to B
; ---- (DJNZ, preserved via the same PUSH BC/POP BC as before). ----
spi_xfer:
    PUSH BC
    LD   E,A
    LD   B,8
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
    RLA			; MISO (bit 7) -> carry
    RL   C		; carry -> C's bit 0, shifting C left
    LD   A,(porta_shadow)
    OUT  ($A8),A
    DJNZ sx_bit
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

; ---- read_r1: poll until a real R1 response arrives, return it in A.
; ---- An R1 byte is DEFINED by having its MSB clear; $FF is just the
; ---- idle/no-response state. Testing "not $FF" (as this used to) also
; ---- accepts any MSB-set byte -- $FE, or a partially-settled value --
; ---- as though it were a response. Test the MSB instead, matching the
; ---- SD spec and the Z80-Retro reference. Retry count also raised
; ---- from 8 to 240 to match that reference: Ncr can legitimately run
; ---- to 8 byte-times, leaving no margin at all at 8. ----
read_r1:
    PUSH BC
    LD   B,240
r1_loop:
    LD   A,$FF
    CALL spi_xfer	; preserves BC, so C is free to hold the byte
    LD   C,A		; keep the received byte -- AND below destroys A,
			; and unlike the reference's spi_read8 our spi_xfer
			; leaves no copy in E (E ends up back at the SENT
			; byte after its 8 RLC rotations)
    AND  $80		; MSB clear => this is a real R1 response
    JR   Z,r1_done
    DJNZ r1_loop
    LD   C,$FF		; timed out -- report the idle value
r1_done:
    LD   A,C
    POP  BC
    RET

; ---- wait_token: wait for the data-start token. Carry set = failure.
; ---- Waits only while the card is idle ($FF); the FIRST non-$FF byte
; ---- must BE the token ($FE), else it's an error token or junk and we
; ---- fail immediately. This used to scan onward looking for any $FE,
; ---- which would silently skip past an error token and could latch
; ---- onto a byte inside the payload that merely happened to equal
; ---- $FE -- then store 512 bytes from that arbitrary offset, giving
; ---- clean but byte-shifted data. Matches the Z80-Retro reference's
; ---- sd_cmd17 token handling. ----
wait_token:
    PUSH BC
    LD   BC,4096
wt_loop:
    LD   A,$FF
    CALL spi_xfer
    CP   $FF		; still idle? keep waiting
    JR   NZ,wt_got
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,wt_loop
    POP  BC
    SCF			; timed out
    RET
wt_got:
    CP   $FE		; the only valid thing here is the data token
    JR   Z,wt_ok
    POP  BC
    SCF			; error token or junk -- fail, don't scan onward
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

; ---- build_rw_cmd: A = command byte, HL = 16-bit block number (top
; ---- 16 bits of the 32-bit argument forced to 0 -- fine, all our LBAs
; ---- here are well under 65536). ----
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

porta_shadow: ds 1
boot_partition_base: ds 2	; real MBR partition 1 start LBA -- see
				; read_mbr's own comment.
sdi_stage:    ds 1
sdi_info:     ds 1
spi_tmp:      ds 1
spi_tmp2:     ds 1
cmd_buf:      ds 6
lb_dest:      ds 2
lb_lba:       ds 2
lb_count:     ds 1
rep_row:      ds 1
rep_cksum:    ds 2
rep_expect:   ds 2
repbuf:       ds 40


; ---- byte_to_hex: A=byte, DE=dest ptr -- writes 2 ASCII hex chars,
; ---- advances DE by 2. ----
byte_to_hex:
    PUSH AF
    RRA
    RRA
    RRA
    RRA
    AND  $0F
    CALL hex_nibble_to_ascii
    LD   (DE),A
    INC  DE
    POP  AF
    AND  $0F
    CALL hex_nibble_to_ascii
    LD   (DE),A
    INC  DE
    RET

hex_nibble_to_ascii:
    CP   10
    JR   C,hnta_digit
    ADD  A,'A'-10
    RET
hnta_digit:
    ADD  A,'0'
    RET

; ---- write_msg: reused verbatim from video-test3.asm/
; ---- cbios-disk-test.asm. HL -> null-terminated message; B = row
; ---- (0-24); C = column (0-79). Assumes bank=1 already set (matches
; ---- video-test3.asm's own convention) -- caller's job here. ----
write_msg:
    LD   IX,$c000
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

wm1:
    LD   A,(HL)
    OR   A
    JR   Z,wm_exit
    PUSH HL
    LD   L,A
    LD   H,0
    ADD  HL,HL
    ADD  HL,HL
    ADD  HL,HL
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
    JR   wm1
wm_exit:
    RET

char_base:
    incbin 'msxfont.img'


end:
