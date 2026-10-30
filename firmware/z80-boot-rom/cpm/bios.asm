; bios.asm -- Phase 12: the real, integrated CBIOS, combining
; test-progs/console-io-test.asm and test-progs/cbios-disk-test.asm
; (both bench-confirmed standalone) with cpm22.asm (CCP+BDOS, MEM=62 --
; see cpm22.asm's own header for why 62, not the 64 an earlier pass
; through this project's planning used).
;
; ============================================================
; Memory layout (see cpm-plan.md sections 2-4 for the full reasoning)
; ============================================================
;
; This BIOS's own vector table lands at $F200 (MEM=62), giving it
; $F200-$FFFF = 3584 bytes -- enough for the disk+console driver LOGIC,
; but NOT the 2048-byte font, which lives separately in the bank=1-only
; $8000-$BFFF region (cpm-plan.md section 2), loaded there by the
; stage-1 bootstrap under bank=1 regardless of what mode the Z80's own
; reads are currently in (A16 for writes depends only on bank/A15/
; _BUSACK, never on mode_pin).
;
; **Critical constraint the standalone tests didn't have to deal
; with**: CONOUT's character blit needs to write to video RAM, which
; only exists under bank=1 -- but $F200+ (this BIOS's own region) is
; ITSELF inside the bank-switched address range ($8000-$FFFF). Code
; that must keep executing correctly *while* bank=1 is briefly active
; cannot live there: the instant bank flips, that same address range
; resolves to completely different physical bytes (video RAM, not this
; BIOS's own compiled instructions), and the CPU would immediately
; start executing garbage. The same is true for any DATA that must be
; readable/writable throughout the flip (porta_shadow -- since flipping
; the bank bit at all requires reading and rewriting it -- plus
; cur_row/cur_col, needed to compute where to blit).
;
; **Design refined from an earlier draft that put the entire blit
; routine (write_msg included) in low memory.** Since bank=1 is what we
; want active during the blit/scroll ANYWAY (to reach both the font and
; video RAM), the actual blit/scroll CODE can live in the bank=1-only
; region too -- right after the font, e.g. $8800 onward -- reachable
; exactly when the trampoline has already flipped to bank=1 and jumped
; there. The bank-invariant part then only needs the shared enter_bank1/
; leave_bank1 flip stubs plus the two state bytes that genuinely must be
; readable from BOTH bank states (porta_shadow -- needed to flip the
; bank bit itself; char_buf -- written from bank=0 by CONOUT, read by
; address from bank=1 by the blit) plus saved_sp -- 38 bytes total, down
; from ~185 in an early draft (write_msg itself lived down there) and
; 158 in the version just before this one (cur_row/cur_col, blit's
; scratch stack, vbi_guard and alv1 all rode along without actually
; needing to -- see the org $0008 block below).
;
; **Corrected on the bench**: an earlier version of this design had each
; bank=1-resident routine (video_blit_impl/video_scroll_impl) flip back
; to bank=0 and RET *itself*. That cannot work, and it is worth stating
; plainly because it reads as obviously fine: those routines live at
; $8000-$88xx, which is inside the banked range, so the moment their own
; OUT ($A8) clears the bank bit they cease to exist. The next
; instruction fetch comes from whatever occupies that address in the
; bank=0 TPA -- garbage. On the bench this presented as exactly one
; character rendering correctly and the machine then dying, which looked
; far more like a console-driver or CCP fault than a memory-map one.
; So the flip back happens in the shared leave_bank1 stub the impls JP
; to while still bank=1. The rule is: **any change of the bank bit must
; be executed from code below $8000.** enter_bank1 JPs (not CALLs) to
; the impl, so the only stack activity is the original CALL-into-the-
; entry-stub's return address, pushed (on the real SP) before any flip
; and popped (by leave_bank1, after flipping back) never straddling it.
;
; **Relocated $7C00 -> $0008 (page zero), 2026-09-10.** $7C00 sat inside
; the range every transient program treats as its own free memory
; (everything from its end up to MAXB, the JP-BDOS operand at page-zero
; bytes 6-7): real PIP.COM's own buffer sizing (verified against its
; DR-published PL/M source) splits that whole span into two big
; buffers, tens of KB each, guaranteed to cross $7C00 -- silently
; corrupting the trampoline before any real disk I/O. Zork's own
; interpreter, also memory-hungry, is a plausible second victim of the
; same mechanism. $0000-$00FF is safe in a way $7C00 never was:
; TBASE=$0100 is where every program's own code loads, so no compliant
; program's buffer math can generate an address below it -- structural,
; not conventional. Getting the true bank-invariant footprint down to
; the 38 bytes that fit the free $0008-$005B gap (cpm22.asm claims only
; IOBYTE/TDRIVE/ENTRY/TFCB/TBUFF in page zero) needed real restructuring
; -- see the org $0008 block's own comments for exactly which pieces
; turned out never to have needed bank invariance at all.
;
; ============================================================
; Loading (stage-1 bootstrap's job, not this file's) -- three separate
; chunks, not one contiguous image:
;   1. The page-zero trampoline ($0008-$002d). stage1 loads it to a
;      $7C00 scratch pad (load_blocks works in 512-byte units, far more
;      than the page-zero gap holds) and LDIRs it down to $0008 just
;      before jumping to BOOT.
;   2. The bank=1 region ($8000 onward under bank=1): the font
;      (msxfont.img, unmodified, 2048 bytes) immediately followed by
;      video_blit_impl/video_scroll_impl/video_cls_impl/hb_toggle_impl's
;      own compiled code plus vbi_guard/bank1_scratch -- one combined
;      chunk, since it's all destined for the same bank=1 window and the
;      code's addresses depend on where the font ends.
;   3. This file's CPM_BASE-$FFFF content (CCP+BDOS+BIOS proper) under
;      bank=0.
; ============================================================

video_base: equ $c000

CS_BIT:    equ 2
SCK_BIT:   equ 3
MOSI_BIT:  equ 4
; ---- MISO moved from PC4 to PC7 (2026-09-10), a real physical
; ---- rewire, not just this constant -- PC7 is the ONLY bit position
; ---- that lets spi_xfer read it into carry via a single RLA
; ---- instruction (bit 0 would work equally via RRA, but PC0-PC3 are
; ---- the keyboard row-select outputs, not free). This constant MUST
; ---- match stage1.asm's own copy: both read the same physical pin at
; ---- different times (stage1 during boot, this BIOS afterward) --
; ---- moving the wire without updating both would break SD access
; ---- entirely, not just slow it down. See docs/sdcard-wiring.md/
; ---- bring-up-log.md for the full reasoning and the T-state
; ---- measurements that motivated this.
MISO_BIT:  equ 7
CTRL_ROW:  equ 6
CTRL_COL:  equ 1
SHIFT_COL: equ 0

; Port A baseline: mode=1 (sram-exec, permanent from here on), bank=0
; (CP/M's steady state -- cpm-plan.md section 2), CS=1 (deasserted),
; SCK=0, MOSI=0.
SHADOW_BASELINE: equ $05

CPM_BASE: equ $DC00

; ============================================================
; Page-zero trampoline (org $0008): the absolute minimum that must be
; bank-invariant, relocated here (2026-09-10) from $7C00 after tracing
; a real, serious bug: real PIP.COM (and very plausibly Zork's own
; story-file paging) sizes its own working buffers from MAXB (page-zero
; bytes 6-7, the JP-BDOS instruction's own operand -- verified directly
; against PIP's own DR-published PL/M source, SIZE$MEMORY), splitting
; *everything* between its own end and MAXB into buffers -- tens of KB
; on this system. $7C00-$7FFF sat squarely inside that range: any
; program with a big enough buffer would silently trample it before
; touching a single real disk record, with no way for a program written
; for stock CP/M to know that memory was special. $0000-$00FF is
; different in kind, not just relocated: TBASE=$0100 is where every
; transient program's own code physically loads, so no compliant
; program's own buffer math can *ever* generate an address below it,
; regardless of what MAXB reports -- protection by structural
; necessity, not by convention. cpm22.asm's own declared page-zero
; users (grepped directly, not assumed) are just IOBYTE(3)/TDRIVE(4)/
; ENTRY(5-7)/TFCB($5C)/TBUFF($80) -- $0008-$005B (84 bytes) is
; genuinely unclaimed.
;
; Getting the true bank-invariant footprint down to something that
; fits took real restructuring, not just a move -- most of what used to
; live here turned out to never actually need to: cur_row/cur_col are
; read into B/C registers before the flip and survive it there
; (register state isn't affected by bank switching, only the memory
; map is) -- moved to this BIOS's own scratch area. blit_saved_sp is
; written before the flip and read only after flipping back -- always
; bank=0 context -- moved there too. blit_scratch (video_blit_impl's
; own nested-call stack) and vbi_guard are only ever touched from
; *inside* bank=1 code, and $8000+ is just as consistently mapped
; throughout that whole window as low memory is -- moved up into the
; bank=1 region alongside video_blit_impl itself. alv1 (drive B's
; 800-byte allocation vector) is read only during ordinary bank=0 BDOS
; execution and was only ever down here for the same reason as
; cur_row/cur_col (spare room, not necessity) -- moved to this BIOS's
; own high-memory region, which is structurally safe for the same
; MAXB reason page zero is (nothing ever writes at or above FBASE).
;
; enter_bank1/leave_bank1 also replace FOUR separate, near-identical
; flip sequences (video_blit/scroll/cls/hb_toggle's own copies, plus
; vbi_return/vsi_return) with one shared pair -- video_cls's and
; hb_toggle's own real work moved up into the bank=1 region alongside
; video_blit_impl/video_scroll_impl, following the same entry-stub-
; down-here/real-work-up-there split those two already used, so the
; shared exit stub has exactly one calling convention to serve.
; ============================================================
    org $0008

porta_shadow: ds 1
char_buf:     ds 2
; ---- saved_sp: shared by all four bank=1 entry points (blit/scroll/
; ---- cls/hb_toggle), not separate per-caller copies -- only one of
; ---- them is ever in flight at a time (CONOUT calls exactly one per
; ---- character and it runs to completion before returning), so
; ---- sharing is safe. Every entry now swaps to bank1_scratch_top for
; ---- the duration (harmless for scroll/cls/hb_toggle, which never
; ---- push/pop while bank=1 anyway -- see bank1_scratch's own comment)
; ---- rather than only video_blit switching stacks while the others
; ---- don't, which would need leave_bank1 to know which case it's
; ---- handling.
saved_sp:     ds 2

; ---- enter_bank1: HL = target address in the bank=1 ($8000+) region.
; ---- Swaps to the bank=1-resident scratch stack, flips the bank bit,
; ---- and JPs (not CALLs) to the target -- the only stack activity is
; ---- the original CALL-into-here's own return address, pushed (onto
; ---- the REAL, CCPSTACK-based SP, before the swap below) by the
; ---- caller and popped only by leave_bank1 after flipping back,
; ---- never straddling either flip. ----
enter_bank1:
    LD   (saved_sp),SP
    LD   SP,bank1_scratch_top
    LD   A,(porta_shadow)
    SET  1,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    JP   (HL)

; ---- leave_bank1: bank=1 code ends with "JP leave_bank1" (not RET) --
; ---- see the header comment's own account of why the flip back MUST
; ---- happen from down here: video_blit_impl/video_scroll_impl/
; ---- video_cls_impl/hb_toggle_impl live at $8000+, inside the banked
; ---- range, so the instant their own OUT ($A8) cleared the bank bit
; ---- they would cease to exist -- the next instruction fetch would
; ---- come from whatever occupies that address in the bank=0 TPA. This
; ---- stub is bank-invariant, so the JP into it (made while still
; ---- bank=1) lands on code that reads identically in both banks and
; ---- survives its own flip. ----
leave_bank1:
    LD   A,(porta_shadow)
    RES  1,A
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   SP,(saved_sp)
    RET

trampoline_end: equ $	; real end of the page-zero chunk -- read out of
			; the label file by stage1.asm/build-boot-
			; image.py rather than assumed.

; ============================================================
; Bank=1 region ($8000+, under bank=1 only): the font immediately
; followed by video_blit_impl/video_scroll_impl's own code -- loaded
; as one combined chunk by the stage-1 bootstrap (see this file's
; header). Reachable exactly when the low-memory trampolines above
; have already flipped to bank=1 and jumped here; both routines end by
; flipping back to bank=0 and RETurning straight to CONOUT's original
; caller.
; ============================================================
    org $8000
char_base:
    incbin 'msxfont.img'

; ---- video_blit_impl: blits char_buf (a 1-character string, set up
; ---- by the video_blit trampoline) at (cur_row,cur_col) -- the same
; ---- write_msg logic every other test in this project has used,
; ---- relocated here and given a bank-flip-back ending instead of a
; ---- plain RET. B/C/HL are pre-loaded by the trampoline above. ----
; B = character row (0-24); C = character column (0-79); HL -> the
; 1-character string to blit.
;
; ---- DIAGNOSTIC (2026-09-10, parked Zork black-screen investigation):
; ---- vbi_1's scan for char_buf's NUL terminator has no bound at all
; ---- -- if something ever corrupts that terminator (char_buf lives
; ---- right in the low-memory region under suspicion), this loop would
; ---- read forward through memory as if it were a string indefinitely,
; ---- blitting whatever it finds, until it happens to reach a zero
; ---- byte somewhere. vbi_guard caps this at 4 iterations (real usage
; ---- is always exactly 1 character) -- changes nothing for normal
; ---- operation, but if this IS the crash mechanism, it should turn
; ---- "system permanently dead" into "system stays alive, maybe some
; ---- visible glitching at that moment" -- a real, observable test of
; ---- the hypothesis, not just a guess. See bring-up-log.md. ----
video_blit_impl:
    LD   HL,char_buf		; video_blit_impl now loads its own
				; parameter -- HL is consumed by enter_bank1
				; itself as the jump target now, not handed
				; down from a caller-side "LD HL,char_buf".
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

    LD   A,4
    LD   (vbi_guard),A
vbi_1:
    LD   A,(vbi_guard)
    OR   A
    JR   Z,vbi_exit		; guard exhausted -- bail out defensively
    DEC  A
    LD   (vbi_guard),A
    LD   A,(HL)
    OR   A
    JR   Z,vbi_exit
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
    JR   vbi_1
vbi_exit:
    JP   leave_bank1	; flip back + restore SP + RET from low,
			; bank-invariant memory -- doing it here would
			; delete this routine mid-instruction-stream. See
			; leave_bank1's own comment.

; ---- video_scroll_impl: moves character rows 1-24 up to become rows
; ---- 0-23 (15360 bytes), clears the newly exposed last row (640
; ---- bytes), flips back to bank=0. ----
video_scroll_impl:
    LD   HL,video_base+640
    LD   DE,video_base
    LD   BC,15360
    LDIR
    LD   HL,video_base+15360
    LD   BC,640
vs_clear:
    XOR  A
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,vs_clear
    JP   leave_bank1	; same reason as vbi_exit above -- see leave_bank1's own comment.


; ---- vbi_guard: diagnostic bound on video_blit_impl's char_buf scan --
; ---- see that routine's own comment. Only ever touched from inside
; ---- video_blit_impl, which runs entirely within the bank=1 window --
; ---- lives up here (not bank-invariant low memory) for that reason.
vbi_guard: ds 1

; ---- bank1_scratch: the stack for the duration of ANY bank=1 work
; entered via enter_bank1 (a real bug, found the hard way on the bench
; -- bring-up-log.md -- when this used to be CCPSTACK, which falls
; inside $C000-$FFFF, the range that IS real video RAM whenever
; bank=1: internal PUSH HL/PUSH IX wrote directly into live video RAM
; at CCPSTACK's offset, every character blitted -- the "white bar"/
; "flickering pixels" bug).
;
; GREW 2026-10-12 (elite/testprogs Tier 1 item 3, the scanner/radar's
; own ship-type-variety phase): this was originally sized "8 words (16
; bytes), a generous margin over the real max nesting depth (PUSH HL +
; PUSH IX = 2 words)" -- true for video_blit_impl/video_scroll_impl/
; video_cls_impl/hb_toggle_impl, the four bios-level primitives
; enter_bank1 was built for. But elite/testprogs/launch_demo.asm's own
; draw_frame -- planet/sun/station/population/dashboard/scanner
; rendering, genuinely many levels of nested CALLs deep (confirmed:
; dashboard_update -> hud_scan -> hud_scan_obj -> hud_dot ->
; hud_set_px -> hud_px_addr -> hud_row_addr alone is 6 levels, on top
; of whatever depth draw_frame itself already has by that point) --
; ALSO enters via this exact same "ld hl,draw_frame / call
; ENTER_BANK1" mechanism, reusing this SAME 16-byte stack it was never
; sized or verified for. A real, pre-existing architectural gap, not
; new to this phase -- this phase's own growth (population records
; 131->172 bytes) is what finally tipped it from "surviving by luck"
; into an actual, reproducible crash (confirmed via direct SP
; tracing: a scripted DOCKCOMP_POKE_TEST run -- repeated dock/respawn
; every frame -- drove SP down from this region into low memory and
; eventually into application data, landing on a PC inside
; launch_demo.asm's own popSlot array; see DEVLOG.md's own entry on
; this). Grown generously (not just "enough for today") since
; undersizing this exact thing is what caused the problem -- same
; "burned once, be generous" precedent this project already applies
; elsewhere (CURHEAP's own $6000 move, DEVLOG 2026-10-11). Confirmed
; safe: $8000-$C000 (VIDEO_BASE) has over 14KB of headroom past this
; point, and nothing anywhere in the codebase references any address
; in this region as a literal (grepped directly) -- everything reaches
; it by label, so shifting bank1_scratch_top and everything after it
; is safe.
bank1_scratch:     ds 256
bank1_scratch_top: equ $

; ---- video_cls_impl: clear the whole 640x200 framebuffer. Moved up
; ---- here (2026-09-10, from a low-memory inline loop) now that
; ---- enter_bank1/leave_bank1 exist to serve it the same way they
; ---- serve video_blit_impl/video_scroll_impl -- no reason left for
; ---- this to be a special case. Straight-line, no stack activity of
; ---- its own beyond what enter_bank1 already set up. ----
video_cls_impl:
    LD   HL,video_base
    LD   BC,16000
vcls_loop:
    XOR  A
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,vcls_loop
    JP   leave_bank1

; ---- hb_toggle_impl (heartbeat: XOR the first video byte on every
; ---- CONOUT call) lived here through the Zork black-screen hunt --
; ---- it's what established that CONOUT stops being called at a true
; ---- CPU lockup. Removed 2026-09-10 once that hunt closed (root
; ---- cause: the bank-flip trampoline sat in transient-program buffer
; ---- space -- see this file's header). It was also the source of the
; ---- constant top-left-corner corruption during normal use.

; ---- row_addr: A = character row (0..24). Returns HL = video_base +
; ---- A*640 (the row's top scanline). Clobbers A and DE; B and C are
; ---- preserved (lineop_impl relies on BC surviving). Shared by the
; ---- three bank=1 routines that need row-origin addressing. ----
row_addr:
    LD   L,A
    LD   H,0
    LD   D,H
    LD   E,L		; DE = row
    ADD  HL,HL		; 2*row
    ADD  HL,HL		; 4*row
    ADD  HL,DE		; 5*row
    ADD  HL,HL		; 10
    ADD  HL,HL		; 20
    ADD  HL,HL		; 40
    ADD  HL,HL		; 80
    ADD  HL,HL		; 160
    ADD  HL,HL		; 320
    ADD  HL,HL		; 640*row
    LD   DE,video_base
    ADD  HL,DE
    RET

; ---- cursor_xor_impl: B = row, C = col. XOR $FF into all 8 scanlines
; ---- of that one cell -- the non-destructive inverting block cursor
; ---- (see show_cursor/hide_cursor). Self-inverse: called identically
; ---- to show and to hide. ----
cursor_xor_impl:
    LD   A,B
    CALL row_addr
    LD   D,0
    LD   E,C
    ADD  HL,DE		; HL = cell's top scanline
    LD   DE,80
    LD   B,8
cxi_loop:
    LD   A,(HL)
    XOR  $FF
    LD   (HL),A
    ADD  HL,DE
    DJNZ cxi_loop
    JP   leave_bank1

; ---- eeol_impl: B = row, C = col. Erase from (row,col) to (row,79) --
; ---- write $00 to all 8 scanlines of every cell in that span. Backs
; ---- VT52 ESC K (Turbo Pascal's editor ClrEol). Runs in the bank=1
; ---- window like the blit/scroll/cls impls; ends JP leave_bank1. ----
eeol_impl:
    LD   A,B
    CALL row_addr
    LD   D,0
    LD   E,C
    ADD  HL,DE		; HL = first cell's top scanline
    LD   A,80
    SUB  C
    LD   B,A		; B = cell count (1..80)
eeol_cell:
    PUSH HL
    LD   DE,80
    XOR  A
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    ADD  HL,DE
    LD   (HL),A
    POP  HL
    INC  HL
    DJNZ eeol_cell
    JP   leave_bank1

; ---- lineop_impl: B = cursor row (0..24), C = 0 -> INSERT a blank
; ---- line at that row (it and every row below scroll down one; the
; ---- old bottom row falls off); C != 0 -> DELETE that row (rows below
; ---- scroll up one; the bottom row is cleared). Backs VT52/Zenith-H19
; ---- ESC L / ESC M, which Turbo Pascal's editor emits. Cursor row/col
; ---- are left untouched -- the editor repositions with ESC Y after.
; ---- Rows are 640 bytes; whole-row moves via LDIR/LDDR. Ends
; ---- JP leave_bank1. ----
lineop_impl:
    LD   A,24
    SUB  B
    JR   NZ,lo_scroll
    ; cursor already on the bottom row: no scroll, just clear it
    LD   A,B			; = 24
    CALL lo_clear_row
    JP   leave_bank1
lo_scroll:
    PUSH BC			; save row (B) + op flag (C)
    ; BC = (24 - row) * 640  = bytes to move
    LD   L,A
    LD   H,0
    LD   D,H
    LD   E,L
    ADD  HL,HL			; 2
    ADD  HL,HL			; 4
    ADD  HL,DE			; 5
    ADD  HL,HL			; 10
    ADD  HL,HL			; 20
    ADD  HL,HL			; 40
    ADD  HL,HL			; 80
    ADD  HL,HL			; 160
    ADD  HL,HL			; 320
    ADD  HL,HL			; 640 * (24-row)
    LD   B,H
    LD   C,L
    POP  DE			; D = row, E = op flag
    PUSH DE
    LD   A,E
    OR   A
    JR   NZ,lo_delete
    ; INSERT: LDDR rows [row..23] down into [row+1..24]
    LD   A,D
    CALL row_addr		; HL = &row[row]
    ADD  HL,BC			; HL = &row[24] (one past source block)
    DEC  HL			; HL = src_end (last byte of row 23)
    LD   D,H
    LD   E,L
    EX   DE,HL
    LD   HL,640
    ADD  HL,DE			; HL = src_end + 640 = dst_end
    EX   DE,HL			; HL = src_end, DE = dst_end
    LDDR
    POP  DE			; D = row -- insert clears the opened row
    LD   A,D
    CALL lo_clear_row
    JP   leave_bank1
lo_delete:
    ; DELETE: LDIR rows [row+1..24] up into [row..23]
    LD   A,D
    CALL row_addr		; HL = &row[row] = dest
    LD   E,L
    LD   D,H
    LD   HL,640
    ADD  HL,DE			; HL = src = &row[row+1]
    LDIR
    POP  DE			; discard saved row/flag
    LD   A,24			; delete clears the bottom row
    CALL lo_clear_row
    JP   leave_bank1

; ---- lo_clear_row: A = row. Writes $00 to all 640 bytes of that row.
; ---- Clobbers A/BC/DE/HL. ----
lo_clear_row:
    CALL row_addr		; HL = &row[A]
    LD   BC,640
lo_cr_loop:
    LD   (HL),0
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,lo_cr_loop
    RET

bank1_end: equ $	; marks the real end of the bank=1 chunk (font +
			; video_blit_impl/video_scroll_impl) for the
			; image-building script to read out of the label
			; file.

    ds CPM_BASE-$,0
    include 'cpm22.asm'

; ============================================================
; BIOS proper (high memory, $F200+, bank=0 throughout -- nothing here
; ever touches bank=1 directly; CONOUT reaches video RAM only via the
; low-memory video_blit/video_scroll above)
; ============================================================

BOOT:   JP   boot_init
WBOOT:  JP   wboot_init
CONST:  JP   const_impl
CONIN:  JP   conin_impl
CONOUT: JP   conout_impl
LIST:   JP   list_stub
PUNCH:  JP   punch_stub
READER: JP   reader_stub
HOME:   JP   home_impl
SELDSK: JP   seldsk_impl
SETTRK: JP   settrk_impl
SETSEC: JP   setsec_impl
SETDMA: JP   setdma_impl
READ:   JP   read_impl
WRITE:  JP   write_impl
PRSTAT: JP   prstat_stub
SECTRN: JP   sectran_impl

; ---- BOOT: cold start. Called by the stage-1 bootstrap once CCP,
; ---- BDOS, this BIOS, and the font are all loaded and bank=0/mode=1
; ---- are set. Establishes a known Port A baseline, re-runs sd_init
; ---- (the bootstrap's own init was a separate program/context),
; ---- resets console/disk driver state, writes the page-zero vectors,
; ---- and jumps to CCP with drive A selected. ----
boot_init:
			; NOTE: deliberately NOT re-writing the 8255's
			; control word ($8A -> port $AB) here, unlike every
			; test-progs/*.asm file's own startup -- a real,
			; severe bug found on the bench. A mode-set control-
			; word write is documented 8255 behavior to force
			; ALL of that port's output latches to 0 immediately
			; (gate-equations.md's own §2 relies on this same
			; fact for mode_pin's power-up-safe default) --
			; including mode_pin (Port A bit 0), even though
			; stage1.asm already established mode_pin=1 (SRAM-
			; exec) long before BOOT_ENTRY is ever reached. By
			; this point _WAIT has ALSO been permanently disabled
			; (the magic-address one-way trip, rom_emu.c) -- so
			; there's nothing left to stall the Z80 if even one
			; instruction fetch (this routine's own next few
			; instructions, fetched from wherever mode_pin
			; momentarily says to read) lands during the glitch
			; window before the OUT ($A8) below re-establishes
			; mode_pin=1. That fetch would be served by the by-
			; now-completely-dead 373 path instead of real SRAM
			; -- a real crash right at BOOT_ENTRY, not a
			; theoretical one. The 8255 was already correctly
			; configured once, by stage1.asm, before mode_pin
			; ever mattered -- it never needs reconfiguring
			; again. The plain data-port write below (`OUT
			; ($A8)`) is safe and still needed: it sets specific
			; bits to a known baseline without the control
			; register's "reset everything" side effect.
    LD   A,SHADOW_BASELINE
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   SP,CCPSTACK
			; NOTE: the magic-address read ($3FFF, tells the
			; AVR to stop emulating ROM and switch to video
			; generation) does NOT happen here. It's a one-shot,
			; one-way trip (rom_emu.c: once served, the AVR
			; permanently disables _WAIT and stops servicing
			; ROM-emulation reads, with nothing left to do so)
			; that is only safe once mode_pin is already 1 --
			; stage1.asm now does the mode-flip and the magic-
			; address read together, once, right after copying
			; itself into SRAM, before any SD loading happens.
			; An earlier version of this code read $3FFF here
			; instead, AFTER stage1's SD-driven loading -- which
			; is also after the flip, so that placement was
			; actually safe too, but redundant now that stage1
			; does it up front (and doing it here again would
			; just be a harmless second plain SRAM read at this
			; point, not a second real trigger).
    CALL sd_init	; result not checked in v1 -- if the card isn't
			; ready, disk I/O will simply fail later, not
			; block booting to a (disk-less) command prompt.
			; Flagged as a known simplification, not silently
			; assumed away.
    CALL parse_partition_table	; base_lba_a/b -- real MBR values, or
				; the write_mbr.py defaults if the read
				; above already failed (own comment).
    LD   A,6		; DIAGNOSTIC: start CP/M's output below stage1's
    LD   (cur_row),A	; on-screen load report (rows 0-4) instead of at
			; row 0, so that report stays readable after boot.
			; Revert to XOR A once bring-up is done.
    XOR  A
    LD   (cur_col),A
    LD   A,$FF
    LD   (last_row),A
    LD   (last_col),A
    XOR  A
    LD   (release_cnt),A	; see get_key_event's own comment -- release
				; debounce counter, must start at 0
    LD   (pending_char),A
    LD   (cursor_shown),A	; no cursor drawn yet
    LD   (term_state),A		; VT52 parser idle
    LD   (cur_drive),A		; A is still 0 here (from the XOR A above)
				; -- BOOT always logs in drive A, matching
				; set_page0_vectors' own "LD C,0" convention
				; a few lines below.
    LD   A,$FF
    LD   (cached_lba+0),A
    LD   (cached_lba+1),A
    LD   (cached_lba+2),A
    LD   (cached_lba+3),A
    LD   (cached_drive),A	; $FF matches neither drive 0 nor 1 -- the
				; very first disk access always misses,
				; regardless of which drive it's for.

			; DIAGNOSTIC: the CALL video_cls that was here is
			; deliberately disabled -- stage1 now clears the
			; screen once itself and prints a per-stage load
			; report, and clearing here would wipe it just as
			; it becomes useful. video_cls is kept defined (it
			; is wanted for a real CLS later) and is currently
			; unreferenced on purpose.

    CALL set_page0_vectors
    LD   C,0
    JP   CBASE

; ---- WBOOT: warm start. Reloads CCP+BDOS from the boot partition
; ---- (wboot_reload) before returning to CCP -- what the DR 2.2
; ---- Alteration Guide says WBOOT must do, and which this BIOS skipped
; ---- as a v1 simplification until Turbo Pascal's exit (stack parked
; ---- at MAXB, growing down through CCP's serial-number bytes ->
; ---- CCP's VERIFY hits DI/HLT on the next command) forced the issue.
; ---- See wboot_reload's own header for the full account. ----
wboot_init:
			; NOTE: same 8255-control-word hazard as boot_init
			; above (see its comment) -- also removed here.
    LD   A,SHADOW_BASELINE
    LD   (porta_shadow),A
    OUT  ($A8),A
    LD   SP,sector_cache+512	; scratch stack: CCPSTACK ($E3AB) sits
				; inside the CCP image wboot_reload is about
				; to overwrite, so we can't stand on it here
    CALL wboot_reload
    LD   SP,CCPSTACK
    CALL set_page0_vectors
    XOR  A
    LD   (cursor_shown),A	; a transient may have exited mid-ESC-seq
    LD   (term_state),A		; or with a cursor half-drawn -- clear both
				; so CCP's first output lands clean (only
				; boot_init reset these before)
			; Preserve the logged drive/user across the warm
			; boot: page-zero byte 4 (TDRIVE) is BDOS's own
			; (uuuudddd) record, kept current as programs select
			; drives, and CBASE/COMMAND wants exactly that in C.
			; boot_init still forces C=0 -- byte 4 is
			; uninitialised RAM at cold boot. cpm22.asm never
			; reloads CCP so this used to always drop back to A:
			; after any transient; the DR-standard behaviour is
			; to come back on whatever drive you were on.
    LD   A,(4)
    LD   C,A
    JP   CBASE

; ---- set_page0_vectors: writes "JP WBOOT" at 0 and "JP FBASE" at 5,
; ---- the fixed CP/M-wide convention (ENTRY=5 is cpm22.asm's own
; ---- constant for the BDOS call vector). ----
; ---- set_page0_vectors: writes "JP WBOOT" at 0 and "JP FBASE" at 5 --
; ---- ENTRY=5, cpm22.asm's own constant for the BDOS call vector.
; ---- **A real design mistake, found and reverted (2026-09-10)**: an
; ---- earlier version of this routine wrote a deliberately-shrunk
; ---- fake address here instead of the real FBASE, on the theory that
; ---- the word at 6-7 is a separate, standard "report top of my
; ---- available memory" convention independent of the JP instruction
; ---- it's part of. That's wrong -- bytes 6-7 ARE the JP's own operand
; ---- bytes; `CALL 5` works by literally executing this instruction,
; ---- so it is the SAME field, not two conventions sharing a
; ---- coincidental address. Faking a smaller value here doesn't just
; ---- change what a program *believes* about its memory size -- it
; ---- makes `CALL 5` itself jump to that fake, non-code address,
; ---- breaking every BDOS call in the system immediately, including
; ---- the ones CCP makes during its own startup (confirmed on the
; ---- bench: boot hung right after "JUMPING TO BOOT", never reaching
; ---- CCP's own prompt). There is no lightweight way to report a
; ---- smaller TPA through this mechanism -- the only real way to
; ---- shrink what a program sees is to actually shrink MEM (moving
; ---- FBASE/CBASE themselves down), which is the already-scoped,
; ---- separate ~1GiB drive-B Tier-2 follow-up, not a small page-zero
; ---- trick. See bring-up-log.md for the full account. ----
set_page0_vectors:
    LD   A,$C3		; Z80 JP opcode
    LD   (0),A
    LD   HL,WBOOT
    LD   (1),HL
    LD   (5),A
    LD   HL,FBASE
    LD   (6),HL
    RET

; ============================================================
; Bank=1 entry stubs (video_blit/video_scroll/video_cls): set up
; whatever registers the target bank=1 impl needs (cheap, ordinary
; bank=0 memory access -- these run entirely before the flip, so unlike
; their old low-memory selves they don't need to be bank-invariant at
; all), then JP into the shared enter_bank1 (page zero, $0008+) with HL
; pointing at the real implementation. ----
; ============================================================
video_blit:
    LD   A,(cur_row)
    LD   B,A
    LD   A,(cur_col)
    LD   C,A
    LD   HL,video_blit_impl
    JP   enter_bank1

video_scroll:
    LD   HL,video_scroll_impl
    JP   enter_bank1

video_cls:
    LD   HL,video_cls_impl
    JP   enter_bank1

; ============================================================
; Console driver (CONST/CONIN/CONOUT) -- reused from
; test-progs/console-io-test.asm, disassembly-verified and bench-
; confirmed there. CONOUT's actual video touch now goes through the
; low-memory video_blit/video_scroll instead of calling write_msg
; directly.
; ============================================================

; ---- Input cursor: a NON-DESTRUCTIVE inverting block, XOR'd into the
; ---- cell at (cur_row,cur_col) whenever the system is waiting for a
; ---- keystroke and XOR'd back out the moment output resumes or a key
; ---- is read. XOR is self-inverse, so "hide" restores the exact
; ---- character that was under it -- essential for full-screen editors
; ---- (Turbo Pascal) that position the cursor over existing text with
; ---- ESC Y and never rewrite cells they think are unchanged. An
; ---- earlier version drew a solid glyph and "erased" with a space,
; ---- which permanently destroyed whatever character the cursor had
; ---- passed over.
; ----
; ---- Managed through a single cursor_shown flag by CONST/CONIN/CONOUT
; ---- so the different ways callers structure input don't fight:
; ----   - CCP's line editor calls CONIN directly (no CONST first).
; ----   - function-6 (direct console I/O) callers -- Zork, the TP
; ----     editor -- poll CONST and only call CONIN once it says ready,
; ----     so the cursor MUST be driven from CONST too.
; ----   - CONOUT hides it before any output so the invert is removed
; ----     before the cell might change, then CONST/CONIN redraws it.
; ---- Both idempotent (flag-gated) -- the actual XOR only happens on
; ---- the transition. (cursor_shown declared with the console vars
; ---- further down.)

show_cursor:
    LD   A,(cursor_shown)
    OR   A
    RET  NZ			; already shown
    LD   A,1
    LD   (cursor_shown),A
    JR   cursor_xor
hide_cursor:
    LD   A,(cursor_shown)
    OR   A
    RET  Z			; already hidden
    XOR  A
    LD   (cursor_shown),A
    ; fall through
cursor_xor:
    PUSH BC
    PUSH DE
    PUSH HL
    LD   A,(cur_row)
    LD   B,A
    LD   A,(cur_col)
    LD   C,A
    LD   HL,cursor_xor_impl
    CALL enter_bank1		; toggles the 8 scanlines of the (B,C) cell;
    POP  HL			; the CALL's return addr is consumed by
    POP  DE			; leave_bank1's own RET, landing us right here
    POP  BC			; (same pattern the old blit_at_cursor used).
    RET

; ---- CONST: A = $FF if a character is ready, $00 otherwise. Must not
; ---- consume the character. Draws the cursor while returning "not
; ---- ready" -- that's the poll-wait signal for function-6 callers. ----
const_impl:
    CALL poll_key
    LD   A,(pending_char)
    OR   A
    JR   Z,const_no
    LD   A,$FF
    RET
const_no:
    CALL show_cursor
    XOR  A
    RET

; ---- CONIN: blocks until a character is available, returns and
; ---- consumes it. show_cursor covers CCP's direct-CONIN path (no
; ---- CONST first); hide_cursor before returning so CCP's echo (a
; ---- CONOUT right after) lands on clean video RAM. cur_row/cur_col
; ---- can't move during the wait -- only poll_key runs. ----
conin_impl:
    CALL show_cursor
cin_wait:
    CALL poll_key
    LD   A,(pending_char)
    OR   A
    JR   Z,cin_wait
    PUSH AF
    CALL hide_cursor
    XOR  A
    LD   (pending_char),A
    POP  AF
    RET

; ---- CONOUT: C = character to output. Handles a VT52-subset
; ---- terminal so Turbo Pascal's full-screen editor works: ESC Y
; ---- <row+32> <col+32> (direct cursor address), ESC E (clear screen +
; ---- home), ESC H (home), ESC K (erase to end of line), ESC L / ESC M
; ---- (insert / delete line -- a Zenith H19 extension the TP editor
; ---- uses). Relative moves ESC A/B/C/D are NOT handled (see the note
; ---- at co_esc_cmd). Unknown ESC letters are swallowed silently.
; ---- Everything else is plain glass-TTY behavior (CR/LF/BS/printable).
; ---- TINST config: pick VT52, or custom -- cursor lead-in ESC Y, row
; ---- then col, offset 32; clear-screen ESC E; clear-EOL ESC K;
; ---- insert-line ESC L; delete-line ESC M.
; ---- term_state: 0 normal, 1 = saw ESC (C is the command letter),
; ---- 2 = saw ESC Y (C is row+32), 3 = saw ESC Y row (C is col+32). ----
conout_impl:
    CALL hide_cursor	; output resumes -> remove any waiting cursor
			; first (cursor_xor preserves BC, so C survives)
    LD   A,(term_state)
    OR   A
    JR   NZ,co_in_esc
    LD   A,C
    CP   $1B		; ESC -- begin a sequence
    JR   NZ,co_normal
    LD   A,1
    LD   (term_state),A
    RET
co_normal:
    CP   $0D
    JR   Z,co_cr
    CP   $0A
    JR   Z,co_lf
    CP   $08
    JR   Z,co_bs
    CP   $20
    JR   C,co_ignore
    LD   (char_buf),A
    XOR  A
    LD   (char_buf+1),A
    CALL video_blit
    CALL advance_cursor
    RET
co_cr:
    XOR  A
    LD   (cur_col),A
    RET
co_lf:
    CALL newline
    RET
co_bs:
    LD   A,(cur_col)
    OR   A
    JR   Z,co_ignore
    DEC  A
    LD   (cur_col),A
co_ignore:
    RET

; ---- VT52 escape handling (see conout_impl's header comment). ----
co_in_esc:
    CP   2
    JR   Z,co_esc_row
    JR   NC,co_esc_col		; term_state == 3
    ; term_state == 1: C is the command letter
    XOR  A
    LD   (term_state),A		; sequence ends here, unless it's ESC Y
    LD   A,C
    CP   'Y'
    JR   NZ,co_esc_cmd
    LD   A,2
    LD   (term_state),A
    RET
co_esc_row:
    LD   A,C
    SUB  $20
    CP   25
    JR   C,cer_ok
    LD   A,24
cer_ok:
    LD   (cur_row),A
    LD   A,3
    LD   (term_state),A
    RET
co_esc_col:
    LD   A,C
    SUB  $20
    CP   80
    JR   C,cec_ok
    LD   A,79
cec_ok:
    LD   (cur_col),A
    XOR  A
    LD   (term_state),A
    RET

; ---- ESC A/B/C/D (relative cursor moves) are deliberately NOT handled
; ---- -- Turbo Pascal's editor (and most full-screen CP/M software)
; ---- positions with ESC Y, never relative moves, and the bank=0
; ---- region is right up against its $10000 ceiling. Easy to add back
; ---- if something needs them and room is freed.
co_esc_cmd:
    LD   A,C
    CP   'H'
    JR   Z,ce_home
    CP   'E'
    JR   Z,ce_clr
    CP   'K'
    JR   Z,ce_eeol
    CP   'L'
    JR   Z,ce_insline
    CP   'M'
    JR   Z,ce_delline
    RET				; unknown / unhandled ESC letter -- swallowed
ce_clr:
    CALL video_cls
ce_home:
    XOR  A
    LD   (cur_row),A
    LD   (cur_col),A
    RET
ce_eeol:
    LD   A,(cur_row)
    LD   B,A
    LD   A,(cur_col)
    LD   C,A
    LD   HL,eeol_impl
    JP   enter_bank1
ce_insline:
    LD   C,0			; lineop_impl: 0 = insert blank line
    JR   ce_lineop
ce_delline:
    LD   C,1			; nonzero = delete line
ce_lineop:
    LD   A,(cur_row)
    LD   B,A
    LD   HL,lineop_impl
    JP   enter_bank1

advance_cursor:
    LD   A,(cur_col)
    INC  A
    CP   80
    JR   C,ac_store
    XOR  A
    LD   (cur_col),A
    CALL newline
    RET
ac_store:
    LD   (cur_col),A
    RET

newline:
    LD   A,(cur_row)
    INC  A
    CP   25
    JR   C,nl_store
    CALL video_scroll
    LD   A,24
nl_store:
    LD   (cur_row),A
    RET

; ---- poll_key / get_key_event / find_key / check_ctrl: reused
; ---- verbatim from test-progs/console-io-test.asm (bench-confirmed;
; ---- includes the OR-1 fix for the column-7 find_key bug). ----
poll_key:
    CALL get_key_event
    RET  NC
    LD   (pending_char),A
    RET

; ---- DEBOUNCE_N: consecutive "no key found" scans required before a
; ---- held key is considered released. Found on the bench: mechanical
; ---- contact bounce during a keypress occasionally makes a single
; ---- find_key scan read as "nothing pressed" for one poll, even
; ---- though the key is still physically held. Without this, that one
; ---- blip cleared last_row/last_col, so the very next (correct) scan
; ---- of the SAME still-held key looked like a brand-new keypress --
; ---- an accidental repeat, not a real second press. Tune on the
; ---- bench: too small still lets bounce through; too large adds
; ---- perceptible lag before a genuine release (or a fast retype of
; ---- the same key) is recognised. CONST is polled in a tight loop
; ---- while CCP/BDOS wait for input, so this window is real wall-clock
; ---- time, not just an iteration count -- if typing still repeats,
; ---- raise this before suspecting the logic; too large just feels
; ---- like slightly sluggish key release, not a new bug.
DEBOUNCE_N: equ 40

get_key_event:
    CALL find_key
    JR   Z,gke_none
    XOR  A
    LD   (release_cnt),A	; a real signal seen -- any bounce window
				; in progress is over.
    LD   A,(last_row)
    CP   B
    JR   NZ,gke_new
    LD   A,(last_col)
    CP   D
    JR   NZ,gke_new
    OR   A
    RET
gke_new:
    LD   A,B
    LD   (last_row),A
    LD   A,D
    LD   (last_col),A
    LD   A,B
    CP   CTRL_ROW
    JR   NZ,gke_lookup
    LD   A,D
    CP   5
    JR   C,gke_none
gke_lookup:
    LD   A,B
    ADD  A,A
    ADD  A,A
    ADD  A,A
    ADD  A,D
    LD   E,A
    LD   D,0
    LD   HL,ascii_table
    ADD  HL,DE		; DE preserved from here on -- reused below for
			; the shift_table lookup at the same (row,col)
			; index, since ADD HL,DE doesn't touch DE itself.
    LD   A,(HL)
    OR   A
    JR   Z,gke_none
    LD   (key_ascii),A
    CALL check_ctrl
    JR   NZ,gke_check_shift	; CTRL not held -- shift may still apply
    LD   A,(key_ascii)
    CP   'A'
    JR   C,gke_plain
    CP   'Z'+1
    JR   NC,gke_plain
    AND  $1F
    SCF
    RET
gke_check_shift:
    CALL check_shift
    JR   NZ,gke_plain		; SHIFT not held -- report the unshifted
				; value already in key_ascii
    LD   HL,shift_table
    ADD  HL,DE
    LD   A,(HL)
    OR   A
    JR   Z,gke_plain		; shift_table has no entry here (matches
				; ascii_table's own 0 for the same key,
				; e.g. modifier/function keys) -- fall back
				; to the unshifted value rather than
				; reporting nothing.
    LD   (key_ascii),A
gke_plain:
    LD   A,(key_ascii)
    SCF
    RET
gke_none:
    LD   A,(release_cnt)
    CP   DEBOUNCE_N
    JR   NC,gke_released	; already at (or somehow past) threshold
    INC  A
    LD   (release_cnt),A
    OR   A			; not yet confirmed released -- report no
    RET				; event, but leave last_row/last_col alone
				; so a still-held key isn't seen as "new"
				; on its next good scan.
gke_released:
    LD   A,$FF
    LD   (last_row),A
    LD   (last_col),A
    OR   A
    RET

find_key:
    LD   B,0
fk_row_loop:
    LD   A,B
    OUT  ($AA),A
    NOP
    NOP
    NOP
    NOP
    IN   A,($A9)
    CP   $FF
    JR   NZ,fk_found
    INC  B
    LD   A,B
    CP   9
    JR   NZ,fk_row_loop
    RET
fk_found:
    LD   E,A
    LD   D,0
fk_col_loop:
    SRL  E
    JR   NC,fk_col_done
    INC  D
    JR   fk_col_loop
fk_col_done:
    OR   1
    RET

check_ctrl:
    LD   A,CTRL_ROW
    OUT  ($AA),A
    NOP
    NOP
    NOP
    NOP
    IN   A,($A9)
    BIT  CTRL_COL,A
    RET

; ---- check_shift: same idiom as check_ctrl, its own row-select scan
; ---- (independent of whatever row find_key left selected) -- tests
; ---- SHIFT (row 6, col 0) instead of CTRL (row 6, col 1). ----
check_shift:
    LD   A,CTRL_ROW
    OUT  ($AA),A
    NOP
    NOP
    NOP
    NOP
    IN   A,($A9)
    BIT  SHIFT_COL,A
    RET

; ---- Console state (high memory -- never touched during a bank=1
; ---- window, safe here unlike cur_row/cur_col/char_buf above). ----
last_row:     ds 1
last_col:     ds 1
release_cnt:  ds 1
pending_char: ds 1
key_ascii:    ds 1
cursor_shown: ds 1	; 1 = block cursor currently drawn at (cur_row,
			; cur_col); 0 = not. Managed by CONST/CONIN/CONOUT
			; via show_cursor/hide_cursor.
term_state:   ds 1	; VT52 escape parser state (0/1/2/3 -- see
			; conout_impl's header comment).

; ---- ascii_table[row*8+col], rows 0-8 -- see keyboard-wiring.md's
; ---- confirmed key map. 0 = unmapped. ----
ascii_table:
    db '0','1','2','3','4','5','6','7'
    db '8','9','-','=','\\','[',']',';'
    db $27,$60,',','.','/',0,'A','B'
    db 'C','D','E','F','G','H','I','J'
    db 'K','L','M','N','O','P','Q','R'
    db 'S','T','U','V','W','X','Y','Z'
    db 0,0,0,0,0,0,0,0
    db 0,0,$1B,$09,0,$08,0,$0D
    ; row 8: SPACE, HOME, INS, DEL, LEFT, UP, DOWN, RIGHT (MSX matrix
    ; positions). Arrows -> the WordStar diamond ^S/^E/^X/^D so Turbo
    ; Pascal's editor cursor keys work with its default bindings (^S
    ; left, ^E up, ^X down, ^D right). ^S doubles as XOFF at the CP/M
    ; prompt -- minor, and the alternative (a multi-byte ESC sequence
    ; per key) isn't possible from a one-byte-per-key table. HOME/INS
    ; left unmapped -- no clean single-char CP/M code, and the editor
    ; reaches them via ^Q prefixes anyway.
    db $20,0,0,$7F,$13,$05,$18,$04

; ---- shift_table[row*8+col] -- same layout as ascii_table, the
; ---- symbol each key reports while SHIFT is held. Standard US/MSX
; ---- shift pairing for the punctuation/number row; letters map to
; ---- their lowercase form (this hardware's unshifted letters are
; ---- already uppercase, matching MSX convention -- SHIFT gives
; ---- lowercase, the reverse of a modern PC keyboard, but consistent
; ---- with typing plain CP/M commands needing no shift at all).
; ---- Modifier/function/whitespace keys (rows 6-8) are unaffected by
; ---- their own shift state, so those entries mirror ascii_table
; ---- exactly rather than being left 0 -- see gke_check_shift's own
; ---- fallback for why a genuine 0 here (a key with no ascii_table
; ---- entry either) still degrades safely. **Not yet bench-verified
; ---- key-by-key** -- flagged, not assumed: confirm each punctuation
; ---- pair on real hardware and correct any that don't match this
; ---- specific keyboard.
shift_table:
    db ')','!','@','#','$','%','^','&'
    db '*','(','_','+','|','{','}',':'
    db $22,'~','<','>','?',0,'a','b'
    db 'c','d','e','f','g','h','i','j'
    db 'k','l','m','n','o','p','q','r'
    db 's','t','u','v','w','x','y','z'
    db 0,0,0,0,0,0,0,0
    db 0,0,$1B,$09,0,$08,0,$0D
    db $20,0,0,$7F,$13,$05,$18,$04

; ============================================================
; Disk driver -- originally reused from test-progs/cbios-disk-test.asm,
; disassembly-verified and bench-confirmed (ROUNDTRIP: PASS) there.
; Extended for a second drive (multi-drive plan, cpm-plan.md): every
; routine below branches on cur_drive (0=A, 1=B) rather than using a
; generic table, matching this project's own preference (see the plan)
; for keeping drive A's already-proven arithmetic completely untouched
; in its own code path rather than generalizing it. NUM_DRIVES bounds
; SELDSK; adding a drive C later means one more CP/JR pair here plus a
; new DPH/DPB, not a redesign.
; ============================================================

NUM_DRIVES: equ 2

seldsk_impl:
    LD   A,C
    CP   NUM_DRIVES
    JR   NC,seldsk_none
    LD   (cur_drive),A
    OR   A
    JR   NZ,seldsk_b
    LD   HL,dph0
    RET
seldsk_b:
    LD   HL,dph1
    RET
seldsk_none:
    LD   HL,0
    RET

; ---- settrk_impl/setsec_impl: drive A keeps its original single-byte
; ---- storage untouched (cur_track/cur_sector) -- a real, pre-existing
; ---- width limit (discarding B/D entirely caps drive A at ~8MB
; ---- regardless of its DPB, but drive A's real size, ~234KB, is
; ---- nowhere near that, so this is harmless for it and left alone
; ---- rather than risked). Drive B needs the full 16-bit BC (its own
; ---- SETTRK argument can exceed 255 -- 50MiB/16384-byte blocks is
; ---- 3200 possible track values), stored in separate cur_track1/
; ---- cur_sector1 words. ----
settrk_impl:
    LD   A,(cur_drive)
    OR   A
    JR   NZ,settrk_b
    LD   A,C
    LD   (cur_track),A
    RET
settrk_b:
    LD   (cur_track1),BC
    RET

setsec_impl:
    LD   A,(cur_drive)
    OR   A
    JR   NZ,setsec_b
    LD   A,C
    LD   (cur_sector),A
    RET
setsec_b:
    LD   (cur_sector1),BC
    RET

setdma_impl:
    LD   (cur_dma),BC
    RET

home_impl:
    LD   BC,0
    CALL settrk_impl
    RET

sectran_impl:
    LD   H,B
    LD   L,C
    RET

; ---- read_impl/write_impl: cache-key widened from a 16-bit LBA to a
; ---- 32-bit LBA + a drive tag (new_lba/cached_lba/cached_drive) --
; ---- drive B's absolute LBAs run past 2,000,000 (21+ bits), and per
; ---- the multi-drive plan's own defensive reasoning, the drive tag is
; ---- checked even though a pure absolute-LBA key would in principle
; ---- already be safe (partitions 1/2 never overlap) -- one extra byte
; ---- and one extra compare against exactly the class of "forgot to
; ---- fold in a base offset" bug this project's own bring-up history
; ---- has hit more than once. The actual read-modify-write data
; ---- movement below (sector_cache, the 128-byte quarter copy) is
; ---- completely unchanged -- it only ever operated in terms of the
; ---- final absolute LBA and quarter offset, which is exactly what
; ---- compute_lba_and_offset still hands back, now just wider. ----
read_impl:
    CALL compute_lba_and_offset
    ; BC:HL = absolute 32-bit LBA, DE = quarter byte-offset
    LD   (new_lba+0),HL
    LD   (new_lba+2),BC
    PUSH DE
    LD   A,(cur_drive)
    LD   HL,cached_drive
    CP   (HL)
    JR   NZ,rd_miss
    LD   HL,new_lba
    LD   DE,cached_lba
    LD   B,4
rd_cmp_loop:
    LD   A,(DE)
    CP   (HL)
    JR   NZ,rd_miss
    INC  HL
    INC  DE
    DJNZ rd_cmp_loop
    JR   rd_have_cache
rd_miss:
    LD   HL,sector_cache
    CALL read_raw_sector	; new_lba already holds this call's absolute LBA
    JR   C,rd_err
    LD   HL,new_lba
    LD   DE,cached_lba
    LD   B,4
rd_copy_loop:
    LD   A,(HL)
    LD   (DE),A
    INC  HL
    INC  DE
    DJNZ rd_copy_loop
    LD   A,(cur_drive)
    LD   (cached_drive),A
rd_have_cache:
    POP  DE
    LD   HL,sector_cache
    ADD  HL,DE
    LD   DE,(cur_dma)
    LD   BC,128
    LDIR
    XOR  A
    RET
rd_err:
    POP  DE		; discard the saved quarter-offset
    LD   A,1		; nonzero -> BDOS "bad sector"; the old code
    RET			; split r1-fail (1) vs data-token-fail (2), but
			; BDOS treats every nonzero return identically and
			; the distinction was only ever a diagnostic.

write_impl:
    CALL compute_lba_and_offset
    LD   (new_lba+0),HL
    LD   (new_lba+2),BC
    PUSH DE
    LD   A,(cur_drive)
    LD   HL,cached_drive
    CP   (HL)
    JR   NZ,wr_need_read
    LD   HL,new_lba
    LD   DE,cached_lba
    LD   B,4
wr_cmp_loop:
    LD   A,(DE)
    CP   (HL)
    JR   NZ,wr_need_read
    INC  HL
    INC  DE
    DJNZ wr_cmp_loop
    JR   wr_have_cache
wr_need_read:
    LD   HL,sector_cache
    CALL read_raw_sector	; RMW pre-read -- same path read_impl uses
    JR   C,wr_rd_err
    LD   HL,new_lba
    LD   DE,cached_lba
    LD   B,4
wr_copy_loop:
    LD   A,(HL)
    LD   (DE),A
    INC  HL
    INC  DE
    DJNZ wr_copy_loop
    LD   A,(cur_drive)
    LD   (cached_drive),A
    JR   wr_have_cache
wr_rd_err:
    POP  DE
    LD   A,1
    RET
wr_have_cache:
    POP  DE
    LD   HL,sector_cache
    ADD  HL,DE
    EX   DE,HL
    LD   HL,(cur_dma)
    LD   BC,128
    LDIR
    LD   A,$58
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

; ---- compute_lba_and_offset: returns the ABSOLUTE 32-bit physical SD
; ---- LBA in BC:HL (B=bits31-24 ... L=bits7-0) and the 128-byte
; ---- quarter-within-block offset in DE. Branches on cur_drive rather
; ---- than generalizing -- drive A's own arithmetic below is BYTE FOR
; ---- BYTE the original, proven code (only the LD BC,0 + base-add at
; ---- the end are new), deliberately kept untouched rather than risked
; ---- to serve a "generic" multi-drive formula. ----
; ---- base_lba_a/base_lba_b (declared with the rest of this driver's RAM
; ---- state, below) hold the REAL primary partition 1/2 start LBAs, read
; ---- off the SD card's own MBR at boot (parse_partition_table, called
; ---- from boot_init) instead of trusting a compile-time guess that goes
; ---- silently stale the moment the card is ever repartitioned
; ---- differently from write_mbr.py's current layout. Still 16-bit only
; ---- (matching this driver's pre-existing assumption, unchanged by this
; ---- -- "both constants fit in 16 bits on their own" was already true
; ---- of the old compile-time BASE_LBA_A/BASE_LBA_B, so reading the same
; ---- values at runtime instead adds no new limitation). BASE_LBA_A/B_
; ---- DEFAULT below are write_mbr.py's own current values, used only if
; ---- parse_partition_table's SD read fails -- see its own comment for
; ---- why that's the one failure mode worth a fallback here, and why a
; ---- bad/missing MBR's *content* isn't separately validated: this
; ---- BIOS region is within 3 bytes of CHUNK3_BLOCKS' hard $10000
; ---- ceiling (see stage1.asm) after this feature, no room left for a
; ---- more thorough check -- verify against a fresh bios.sym `end`
; ---- after any future change here, not just this comment's arithmetic.
BASE_LBA_A_DEFAULT: equ 2048
BASE_LBA_B_DEFAULT: equ 4096

compute_lba_and_offset:
    LD   A,(cur_drive)
    OR   A
    JR   NZ,clo_driveB

clo_driveA:
    ; EXACTLY the original arithmetic, unchanged, through the point
    ; where HL=16-bit relative LBA and DE=quarter offset.
    LD   A,(cur_track)
    LD   L,A
    LD   H,0
    ADD  HL,HL
    LD   D,H
    LD   E,L
    ADD  HL,HL
    ADD  HL,HL
    LD   B,H
    LD   C,L
    ADD  HL,HL
    ADD  HL,BC
    ADD  HL,DE
    LD   A,(cur_sector)
    LD   E,A
    LD   D,0
    ADD  HL,DE
    PUSH HL
    LD   A,L
    AND  3
    ADD  A,A
    LD   E,A
    LD   D,0
    LD   HL,quarter_offsets
    ADD  HL,DE
    LD   E,(HL)
    INC  HL
    LD   D,(HL)
    POP  HL
    SRL  H
    RR   L
    SRL  H
    RR   L
    ; HL = 16-bit relative LBA, DE = quarter offset (identical to the
    ; original routine up to here).
    PUSH DE			; stash quarter offset across the base-add
    LD   BC,0			; high word of the 32-bit relative LBA is
				; always 0 -- drive A's whole 1 MiB
				; partition is comfortably under 16 bits.
    LD   DE,(base_lba_a)
    JR   clo_finish_add

clo_driveB:
    ; SPT=128 (dpb1) makes one "track" exactly one block, and (since
    ; 128 is a multiple of 4) the quarter offset depends only on
    ; sector's low 2 bits, never on track -- do that lookup FIRST and
    ; stash it, before HL/DE get reused for the 32-bit track<<5 below.
    LD   A,(cur_sector1)
    AND  3
    ADD  A,A
    LD   E,A
    LD   D,0
    LD   HL,quarter_offsets
    ADD  HL,DE
    LD   E,(HL)
    INC  HL
    LD   D,(HL)
    PUSH DE			; stash quarter offset

    ; BC:HL (32-bit) = cur_track1 << 5. cur_track1 is only ever 16
    ; bits wide, but the shift can carry out past bit 16 (track up to
    ; 3199 -> 3199<<5 = 102368, > 16 bits) -- a real overflow, not a
    ; theoretical one, so this is done as a genuine 32-bit shift (5
    ; iterations of SLA L/RL H/RL C/RL B, propagating the carry chain
    ; low-to-high through all four bytes each time), not a 16-bit ADD
    ; HL,HL chain.
    LD   HL,(cur_track1)
    LD   BC,0
    SLA  L
    RL   H
    RL   C
    RL   B
    SLA  L
    RL   H
    RL   C
    RL   B
    SLA  L
    RL   H
    RL   C
    RL   B
    SLA  L
    RL   H
    RL   C
    RL   B
    SLA  L
    RL   H
    RL   C
    RL   B

    ; += (cur_sector1 low byte) >> 2. Provably safe as a plain 8-bit
    ; add into L with no carry propagation needed: track<<5 always has
    ; its low 5 bits clear, and sector>>2 is at most 31 (sector max
    ; 127, SPT=128) -- the two ranges never overlap, so this can never
    ; carry out of L into H.
    LD   A,(cur_sector1)
    SRL  A
    SRL  A
    ADD  A,L
    LD   L,A
    ; BC:HL = drive B's full 32-bit relative LBA.

    LD   DE,(base_lba_b)

clo_finish_add:
    ; BC:HL (relative) += 0000:DE -- both real base constants (2048,
    ; 4096) fit entirely in 16 bits, so only HL needs the add, with any
    ; carry rippling into BC.
    ADD  HL,DE
    JR   NC,clo_no_carry
    INC  BC
clo_no_carry:
    POP  DE			; restore the quarter offset
    RET

quarter_offsets: dw 0,128,256,384

; ---- stubs: no line printer or paper-tape devices on this machine. ----
list_stub:
prstat_stub:
    XOR  A
    RET
punch_stub:
reader_stub:
    XOR  A
    RET

; ============================================================
; Disk Parameter Header / Block (cpm-plan.md section 7's geometry).
;
; OFF=5 (revised from an original OFF=2, Phase 12 2026-09-08): the
; stage-1 bootstrap's own loaded data (low-memory trampoline + the
; combined bank=1 font/blit-code region + the main CCP+BDOS+BIOS
; block, ~10035 bytes total, see stage1.asm) needs to fit in the
; reserved boot area -- OFF=2 only reserves 6656 bytes, not enough.
; OFF=5 reserves 16640 bytes (comfortable, ~6.6K spare for growth) and
; -- checked before adopting it, not assumed -- divides evenly into
; DSM with no fractional remainder (234.0 exactly, vs OFF=2's own
; 243.75), a cleaner result than the original by coincidence, not by
; design. DSM recomputed accordingly: (77*26*128-5*26*128)/1024-1=233.
; ALV size recomputed to match: ceil((233+1)/8)=30 (was 31 for DSM=242).
; ============================================================

dph0:
    dw   0
    dw   0,0,0
    dw   dirbuf
    dw   dpb0
    dw   csv0
    dw   alv0

dpb0:
    dw   26
    db   3
    db   7
    db   0
    dw   233
    dw   63
    db   $C0
    db   $00
    dw   16
    dw   5

dirbuf: ds 128
csv0:   ds 16
alv0:   ds 30

; ---- Drive B: a large, hard-disk-style volume (50 MiB, shrunk down
; ---- from the original 100 MiB Tier 1 on 2026-09-16 specifically to
; ---- buy back BIOS code-size margin -- alv1's size is directly
; ---- proportional to DSM (ceil((DSM+1)/8) bytes, i.e. 1 byte per 8
; ---- blocks = 128KiB of drive B capacity per alv1 byte at this BLS),
; ---- and alv1 lives in this same $DC00-$FFFF region that's within a
; ---- few bytes of CHUNK3_BLOCKS' hard $10000 wraparound ceiling (see
; ---- stage1.asm) -- unlike merely shipping fewer SD-transfer bytes
; ---- (which doesn't move where alv1's address sits, and so doesn't
; ---- actually help -- see bring-up-log.md/this project's own
; ---- discussion), *shrinking* alv1's real size genuinely frees real
; ---- bytes here. ~1GiB remains a later, separately-scoped follow-up
; ---- needing a TPA/MEM change; see cpm-plan.md. DSM>255 forces 2-byte
; ---- block-allocation pointers (8 per 32-byte directory entry instead
; ---- of 16), which is why EXM is double what BLS/1024-1 would give --
; ---- both derived from scratch, not copied:
; ----   SPT=128, BSH=7 (BLS=16384 -- largest standard block size),
; ----   BLM=127 (BLS/128-1), EXM=7 (BLS/2048-1, the DSM>255 formula --
; ----   self-checked against dpb0's own EXM=0 via the DSM<=255 formula
; ----   BLS/1024-1, which matches exactly), DSM=3199 (3200 blocks x
; ----   16384 = exactly 50.0 MiB -- still comfortably above the
; ----   DSM<=255 threshold, so this stays a 2-byte-pointer drive, no
; ----   further DPB/directory-format change needed), DRM=1023 (1024
; ----   entries = exactly 2 directory blocks, mirroring dpb0's own
; ----   AL0/AL1 pattern -- unchanged: DRM doesn't have to scale with
; ----   DSM), CKS=0 (fixed-disk convention -- the SD card is never
; ----   hot-swapped while running, so BDOS's directory-changed check is
; ----   skipped entirely, and -- unlike dph0 -- NO CSV buffer is needed
; ----   at all: the CSV pointer below is 0, never dereferenced by BDOS
; ----   when CKS=0), OFF=0 (the boot image lives entirely in drive A's
; ----   own reserved area; drive B needs no reserved tracks of its
; ----   own). SPT=128 is chosen (not borrowed from dpb0's floppy-track
; ----   fiction) so BLS=SPT*128 -- one "track" is exactly one block --
; ----   which also makes compute_lba_and_offset's quarter-offset
; ----   depend only on sector's low 2 bits, never on track (128 is a
; ----   multiple of 4).
; ---- alv1 (400 = ceil(3200/8) bytes) lives in this BIOS's own
; ---- high-memory scratch area (near cur_drive/sector_cache), not
; ---- inline here -- see its own comment there for why.
dph1:
    dw   0
    dw   0,0,0
    dw   dirbuf	; shared with drive A -- only one drive's directory is
		; ever resident/being scanned by BDOS at a time
    dw   dpb1
    dw   0	; CSV pointer -- never dereferenced (CKS=0 below)
    dw   alv1

dpb1:
    dw   128
    db   7
    db   127
    db   7
    dw   3199
    dw   1023
    db   $C0
    db   $00
    dw   0
    dw   0

; ============================================================
; SD card driver -- reused verbatim from sdcard-test.asm/
; cbios-disk-test.asm (full design history in bring-up-log.md)
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

; ---- spi_xfer: A = byte to send, returns received byte in A. Two
; ---- speed optimizations applied 2026-09-10 (measured, not just
; ---- assumed -- see bring-up-log.md for the full T-state accounting):
; ---- (1) MISO is now bit 7 (see MISO_BIT's own comment), so the old
; ---- branch-based IN/SLA C/BIT/JR Z/SET 0,C sequence (39-42 T-states,
; ---- data-dependent) becomes a fixed IN/RLA/RL C (23 T-states, no
; ---- branch) -- RLA moves bit 7 of the just-read port byte into
; ---- carry, RL C shifts that carry into C's bit 0, exactly
; ---- replicating the old shift-and-conditionally-set behavior in one
; ---- pass. (2) the bit counter moved from D (DEC D/JR NZ, 16T taken/
; ---- 11T not) to B (DJNZ, 13T taken/8T not) -- B was unused inside
; ---- this routine (only preserved for the caller via the existing
; ---- PUSH BC/POP BC, which still does exactly that). Both changes
; ---- together: ~140+24=164 fewer T-states per byte, and the routine
; ---- is 6 bytes SMALLER (5 from the MISO fix, 1 from DJNZ), not
; ---- larger -- unlike loop-unrolling (considered and rejected: it
; ---- would cost roughly +200 bytes in this same tight $F200-$FFFF
; ---- BIOS region for a further ~8-9%, a poor trade right after
; ---- CHUNK3_BLOCKS's own margin had to be fixed this session). ----
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

; ---- build_cmd0/8/55/acmd41/58: copy a fixed 6-byte SD command frame
; ---- (index + 32-bit arg + CRC) into cmd_buf. Table-driven (2026-09-11)
; ---- -- the five were near-identical LD-immediate sequences costing
; ---- ~141 bytes; the tables + one shared copy are ~55, and freeing
; ---- room in this against-the-$10000-ceiling BIOS region is what let
; ---- WBOOT's CCP reload and the VT52 ESC L/M handlers fit. The frame
; ---- bytes are byte-for-byte what the old code assembled (verified by
; ---- disassembly). build_rw_cmd stays separate -- its arg is dynamic. ----
build_cmd0:
    LD   HL,cmdf_cmd0
    JR   build_cmd_copy
build_cmd8:
    LD   HL,cmdf_cmd8
    JR   build_cmd_copy
build_cmd55:
    LD   HL,cmdf_cmd55
    JR   build_cmd_copy
build_acmd41:
    LD   HL,cmdf_acmd41
    JR   build_cmd_copy
build_cmd58:
    LD   HL,cmdf_cmd58
build_cmd_copy:
    PUSH BC			; sdi_acmd41's retry counter is in B -- the
				; old per-routine LD-immediate code only ever
				; touched A, so preserve BC here (DE/HL are
				; not live across these calls in sd_init)
    LD   DE,cmd_buf
    LD   BC,6
    LDIR
    POP  BC
    RET

cmdf_cmd0:   db $40,$00,$00,$00,$00,$95
cmdf_cmd8:   db $48,$00,$00,$01,$AA,$87
cmdf_cmd55:  db $77,$00,$00,$00,$00,$01
cmdf_acmd41: db $69,$40,$00,$00,$00,$01
cmdf_cmd58:  db $7A,$00,$00,$00,$00,$01

; ---- build_rw_cmd: A = command byte ($51=CMD17 read, $58=CMD24
; ---- write). Reads the 32-bit LBA from new_lba (populated by
; ---- read_impl/write_impl right after compute_lba_and_offset) instead
; ---- of taking it in a register pair -- stage1.asm's own copy of this
; ---- routine still takes it in HL (16-bit only, correct there: it
; ---- only ever addresses the boot image, well under 65536). This
; ---- copy needs the full 32 bits (drive B's LBAs run past 2,000,000,
; ---- 21+ bits), which doesn't fit in one register pair alongside
; ---- everything else read_impl/write_impl already need live, so it's
; ---- simplest and clearest read directly from memory. SD command
; ---- argument bytes are big-endian (MSB first); new_lba is stored
; ---- little-endian (as any Z80 LD (nn),HL/BC does), so the read-back
; ---- order below is deliberately reversed from new_lba's own byte
; ---- order. ----
build_rw_cmd:
    LD   (cmd_buf+0),A
    LD   A,(new_lba+3)
    LD   (cmd_buf+1),A
    LD   A,(new_lba+2)
    LD   (cmd_buf+2),A
    LD   A,(new_lba+1)
    LD   (cmd_buf+3),A
    LD   A,(new_lba+0)
    LD   (cmd_buf+4),A
    LD   A,$01
    LD   (cmd_buf+5),A
    RET

; ---- read_raw_sector: HL = destination buffer, new_lba = absolute
; ---- 32-bit LBA. Reads one 512-byte block via CMD17. Returns carry
; ---- clear on success, carry set on any failure (command rejected or
; ---- data-token timeout). Factored out of read_impl's old rd_miss
; ---- (2026-09-11) so WBOOT's CCP reload can share the exact same,
; ---- already-bench-proven single-block read path. Clobbers A/BC/DE/HL
; ---- (HL is advanced by read_block); the caller keeps nothing live
; ---- across it except memory. ----
read_raw_sector:
    PUSH HL			; read_block needs it after the command frame
    LD   A,$51			; CMD17 (READ_SINGLE_BLOCK)
    CALL build_rw_cmd
    CALL sd_cs_assert
    CALL send_cmd
    CALL read_r1
    OR   A
    JR   NZ,rrs_cmd_fail
    POP  HL
    CALL read_block		; carry set on data-token timeout
    PUSH AF
    CALL sd_settle
    CALL sd_cs_deassert
    POP  AF
    RET
rrs_cmd_fail:
    POP  HL
    CALL sd_settle
    CALL sd_cs_deassert
    SCF
    RET

; ---- parse_partition_table: reads the real MBR (LBA 0) into
; ---- sector_cache (safe to reuse here -- boot_init invalidates the
; ---- cache right after this call anyway) and copies primary partition
; ---- 1/2's own start-LBA field (low 16 bits only -- see base_lba_a/b's
; ---- own comment) into base_lba_a/base_lba_b. Only the SD *read itself*
; ---- failing gets a fallback (BASE_LBA_A/B_DEFAULT, write_mbr.py's own
; ---- values) -- deliberately NOT also checking the $55AA boot signature
; ---- or that the high 16 bits of each partition's start LBA are really
; ---- zero, unlike this same idea done more thoroughly in stage1.asm.
; ---- Accepted narrower checking here, not an oversight: this BIOS
; ---- region sits within a few bytes of CHUNK3_BLOCKS' hard $10000
; ---- wraparound ceiling (stage1.asm) even with just this much added --
; ---- re-verify against a fresh bios.sym `end` before adding any more
; ---- checking here, there is no slack to spare. A garbled MBR that
; ---- passes the SD read itself but fails a content check that was left
; ---- out would misdirect every later disk access at boot -- a real,
; ---- accepted risk for this file specifically, matching sd_init's own
; ---- unchecked-result philosophy a few lines above in boot_init. ----
parse_partition_table:
    LD   HL,0
    LD   (new_lba+0),HL
    LD   (new_lba+2),HL
    LD   HL,sector_cache
    CALL read_raw_sector
    LD   HL,BASE_LBA_A_DEFAULT
    LD   DE,BASE_LBA_B_DEFAULT
    JR   C,ppt_store
    LD   HL,(sector_cache+454)	; partition 1 entry: offset 446+8
    LD   DE,(sector_cache+470)	; partition 2 entry: offset 462+8
ppt_store:
    LD   (base_lba_a),HL
    LD   (base_lba_b),DE
    RET

; ---- wboot_reload: re-read CCP+BDOS ($DC00-$F1FF) from the boot
; ---- partition. WBOOT calls this because a transient can legally use
; ---- memory right up to MAXB ($E406) and overwrite CCP's image -- in
; ---- particular Turbo Pascal parks its stack at MAXB and grows it
; ---- straight down through CCP, trampling the six serial-number bytes
; ---- at PATTRN2 ($E400); on the next command CCP's own VERIFY finds
; ---- PATTRN1 != PATTRN2 and executes DI/HLT, locking the machine.
; ---- Reloading restores CCP (code + PATTRN2) and BDOS every warm
; ---- boot, which is what the DR 2.2 Alteration Guide says WBOOT is
; ---- supposed to do anyway (this BIOS skipped it as a v1
; ---- simplification). BIOS itself ($F200+) is running and is never
; ---- part of the reload. Best-effort: a failed sector read is
; ---- skipped, not retried -- a dead card means disk I/O was already
; ---- broken. RELOAD_OFF is hand-synced with stage1.asm's chunk3
; ---- offset (same no-single-source-of-truth caveat as CHUNK*_LBA / OFF). ----
RELOAD_OFF:   equ 1+6		; partition-relative LBA of CCP+BDOS: 1 (chunk 1)
				; + CHUNK2_BLOCKS (6) -- hand-synced with stage1.asm's
				; chunk3 offset (1+CHUNK2_BLOCKS). Was a compile-time
				; absolute 2048+6 until 2026-10-30: wrong twice over
				; (chunk 2 grew to 6 blocks on 2026-10-12, so CCP+BDOS
				; moved to +7, and it ignored the real partition start
				; parse_partition_table reads from the MBR), so every
				; warm boot loaded the wrong sectors over CCP.

wboot_reload:
    LD   HL,(base_lba_a)	; real partition 1 start, read off the MBR
    LD   DE,RELOAD_OFF
    ADD  HL,DE
    LD   (new_lba+0),HL
    LD   HL,0
    LD   (new_lba+2),HL
    LD   HL,CBASE
    LD   (wr_dst),HL
wr_loop:
    LD   HL,(wr_dst)
    CALL read_raw_sector	; ignore carry -- best effort (see header)
    LD   HL,(new_lba+0)
    INC  HL
    LD   (new_lba+0),HL
    LD   HL,(wr_dst)
    LD   DE,512
    ADD  HL,DE
    LD   (wr_dst),HL
    LD   A,H			; done once the destination reaches BOOT:
    CP   BOOT>>8		; CBASE + 11*512 == BOOT exactly
    JR   NZ,wr_loop
    RET

; ---- SD driver + disk driver state (high memory -- never touched
; ---- during a bank=1 window, safe here). ----
wr_dst:       ds 2	; wboot_reload's running destination pointer
sdi_stage:    ds 1
sdi_info:     ds 1
spi_tmp:      ds 1
spi_tmp2:     ds 1
cmd_buf:      ds 6

cur_drive:    ds 1	; 0 = A, 1 = B -- set by seldsk_impl, read by
			; every routine above that branches on drive.
cur_track:    ds 1	; drive A only (untouched width/storage)
cur_sector:   ds 1	; drive A only (untouched width/storage)
cur_track1:   ds 2	; drive B only -- full 16-bit SETTRK argument
cur_sector1:  ds 2	; drive B only -- full 16-bit SETSEC argument
cur_dma:      ds 2
new_lba:      ds 4	; scratch: this call's just-computed absolute LBA
			; (32-bit, little-endian) -- written by read_impl/
			; write_impl right after compute_lba_and_offset,
			; read back by build_rw_cmd and the cache-update
			; copy loops.
cached_lba:   ds 4	; the sector_cache buffer's absolute LBA (32-bit,
			; little-endian) -- widened from 2 bytes; a 16-bit
			; key can't distinguish drive B's LBAs (21+ bits).
cached_drive: ds 1	; which drive cached_lba belongs to -- checked
			; alongside cached_lba on every cache-hit test
			; (defensive: partitions 1/2 never overlap in
			; practice, but this is one byte and one compare
			; against exactly the class of "forgot to fold in
			; a base offset" bug this project has hit before).
base_lba_a: ds 2	; real partition 1/2 start LBAs, read off the SD
base_lba_b: ds 2	; card's own MBR at boot -- see parse_partition_table.
; ---- cur_row/cur_col: text cursor state. Read into B/C registers by
; ---- video_blit's own entry stub *before* the bank=1 flip and carried
; ---- across purely in registers from there (register state isn't
; ---- affected by bank switching, only the memory map is) -- never
; ---- dereferenced by address from inside bank=1 code, so this doesn't
; ---- need to be bank-invariant like porta_shadow/char_buf do. Lives
; ---- here (not page zero) since 2026-09-10's trampoline shrink.
cur_row: ds 1
cur_col: ds 1

; ---- alv1: drive B's allocation vector (BDOS-maintained free-block
; ---- bitmap, ceil((DSM+1)/8) bytes -- see dpb1 below). Moved here
; ---- 2026-09-10 from the low-memory trampoline gap it used to share
; ---- with video_blit's own stubs -- it was only ever there because
; ---- there happened to be spare room, not because it needs to be
; ---- bank-invariant (BDOS only ever touches this during ordinary
; ---- bank=0 execution, disk I/O never runs during a bank=1 window).
; ---- This region is structurally safe from the PIP/Zork memory-
; ---- trampling bug that motivated the trampoline shrink in the first
; ---- place: nothing above FBASE is ever part of a transient program's
; ---- own buffer math, by the same MAXB convention that caused the
; ---- bug down in low memory.
alv1: ds 400

sector_cache: ds 512

end:
