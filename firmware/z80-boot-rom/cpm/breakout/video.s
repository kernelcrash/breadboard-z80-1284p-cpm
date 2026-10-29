; video.s -- direct video-RAM access for a TPA-resident CP/M program.
;
; This does NOT call bios.asm's enter_bank1/leave_bank1 trampoline
; (Phase 1 plan note superseded by this simpler discovery while
; actually writing it): that trampoline exists because bios.asm's own
; video_blit_impl/video_scroll_impl/video_cls_impl/hb_toggle_impl are
; compiled to live AT $8000+ (stage1.asm loads them into the bank=1-only
; region) -- code and stack there stop existing the instant the bank
; bit flips, which is what forces the scratch-stack swap and the
; "JP leave_bank1, never RET" discipline.
;
; A CP/M .com program's own code lives entirely in the TPA ($0100+),
; which is bank-INVARIANT ($0000-$7FFF reads/executes identically
; regardless of the bank bit) -- confirmed in bios.asm's own header
; comment and by Knight Lore's kl.asm/kl_blit_test.asm keeping their
; blit code down here for exactly this reason. So neither this file's
; instructions nor its stack (crt0.s's stacktop, also TPA-resident) are
; ever affected by flipping the bank bit -- ordinary CALL/RET is safe
; throughout this whole file, unlike bios.asm's $8000+-resident code.
;
; `bank_shadow` starts at bios.asm's own SHADOW_BASELINE ($05 --
; bios.asm line 123: mode_pin=1/SRAM-exec, bank=0, SD CS deasserted) --
; the known-good resting state whenever CP/M itself is running. Only
; bit 1 (bank) is ever touched here; every other Port A bit (mode_pin,
; SD card CS/SCK/MOSI) is preserved read-modify-write, same discipline
; sdcard-wiring.md requires of any code sharing Port A.
    .module video
    .globl _video_cls
    .globl _fill_rect
    .globl _fill_rect_tile8
    .globl _edge_col
    .globl _draw_char
    .globl bank_on
    .globl bank_off

    .area _CODE

; bank_shadow embedded here in _CODE (jumped over, not executed) rather
; than in a separate _DATA area -- a real bug, caught while building
; Phase 1: SDCC's linker defaults _DATA to start at $8000 with no
; --data-loc given, which is exactly where bank-switching takes over
; (video RAM in bank=1). A byte living there would itself become
; unreadable/corrupted the moment bank=1 goes active. Matching
; sdcc-test/hello.c's own pattern (embedded data, skipped over with a
; jr) keeps everything in one known-safe, low, bank-invariant place.
    jr video_start
bank_shadow:
    .db 0x05
video_start:

; ---- bank_on/bank_off: internal helpers (not C-callable), shared by
; every routine below. Ordinary CALL/RET -- see header comment for why
; that's safe here (unlike bios.asm's own $8000+-resident equivalents). ----
bank_on:
    ld a, (bank_shadow)
    set 1, a
    ld (bank_shadow), a
    out (0xa8), a
    ret

bank_off:
    ld a, (bank_shadow)
    res 1, a
    ld (bank_shadow), a
    out (0xa8), a
    ret

; ---- video_cls(): blank all 16000 bytes of video RAM ($C000-$FFC7).
; No C arguments -- sdcccall(1) needs no register setup for a 0-arg
; call, so this is callable as an ordinary C `void video_cls(void);`. ----
_video_cls::
    call bank_on
    ld hl, #0xc000
    ld bc, #16000
vcls_loop:
    xor a               ; INSIDE the loop, not hoisted above it -- the
    ld (hl), a          ; loop-condition check below (ld a,b / or c)
    inc hl              ; clobbers a, so a must be re-zeroed each pass
    dec bc              ; (this exact bug, and its fix, already happened
    ld a, b             ; once in this project's own stage1.asm/
    or c                ; video_cls_s1 -- same pattern, applied here).
    jr nz, vcls_loop
    jp bank_off         ; tail call -- bank_off's own RET returns to
                        ; video_cls's caller directly, one level up

; ---- fill_rect(addr, width_bytes, height, pattern): fills a
; byte-aligned rectangle in video RAM. addr = 0xC000 + y*80 + x/8 (x
; must be a multiple of 8 -- no sub-byte shifting here, see the plan's
; own Phase 2 scope note); width_bytes = pixel width / 8; height =
; scanline count; pattern = the byte written to every position (0xFF
; solid, 0x00 clears -- reused later for brick-hit clearing).
;
; C calling convention here (SDCC's sdcccall(1) default, verified
; empirically against the real compiled output before writing this --
; not assumed): a 16-bit first arg (addr) arrives in HL; a run of
; 8-bit args after it (width_bytes, height, pattern) are pushed by the
; CALLER onto the stack, ending up at, respectively, SP+2/SP+3/SP+4
; relative to SP as it stands right at this function's entry (i.e.
; BEFORE this function pushes anything of its own -- SP+0/SP+1 is the
; return address). **Critically, sdcccall(1) is callee-cleans-stack**:
; a real compiled multi-stack-arg SDCC function's own epilogue was
; checked directly (not assumed) and does NOT end in a plain `ret` --
; it pops the return address into a register, explicitly discards the
; stack-arg bytes via extra pops/`inc sp`, then jumps to the saved
; return address. This routine's epilogue mirrors that exactly; get it
; wrong and every call site would silently misalign the caller's own
; stack for everything that runs afterward. ----
_fill_rect::
    push ix
    ld ix, #0
    add ix, sp          ; IX = (SP at entry) - 2, since push ix above
                        ; moved SP down 2 -- so IX+2 = the return
                        ; address, IX+4/5/6 = width_bytes/height/pattern
    ld d, 6 (ix)        ; D = pattern (kept in a register the whole
                        ; call: it's the source for every `ld (hl),d`
                        ; below, and this file has no register left
                        ; over to spare a memory round-trip for it)
    ld b, 5 (ix)        ; B = height (outer row counter, DJNZ)
    ld c, 4 (ix)        ; C = width_bytes (re-copied into A each row
                        ; below as the inner counter -- C itself is
                        ; never modified, so it's still valid on the
                        ; next row)
    pop ix              ; restore caller's IX; SP back to entry value
                        ; (HL, holding addr, was never touched by any
                        ; of the above -- no save/restore needed for it)

    call bank_on

    ld a, #80           ; E = row stride remainder = 80 - width_bytes
    sub c               ; (bytes to skip after each row's own
    ld e, a             ; width_bytes to reach the next row's start --
                        ; safe as a plain 8-bit add into L below since
                        ; width_bytes <= 80 always for this display)
fr_row:
    ld a, c             ; inner counter = width_bytes, fresh each row
fr_byte:
    ld (hl), d          ; write the pattern byte
    inc hl
    dec a
    jr nz, fr_byte
    ld a, l             ; HL += E (8-bit add with carry into H --
    add a, e            ; cheaper than a 16-bit ADD HL,DE, and E's
    ld l, a             ; range (0-79) never needs more than this)
    jr nc, fr_noc
    inc h
fr_noc:
    djnz fr_row

    call bank_off

    ; Epilogue: callee-cleans-stack (see header comment) -- pop the
    ; return address, discard the 3 stack-arg bytes (width_bytes,
    ; height, pattern), then jump to the return address. NOT a plain
    ; `ret` -- that would leave those 3 bytes on the caller's stack.
    pop hl
    pop af              ; discards width_bytes + height (2 bytes)
    inc sp              ; discards pattern (1 byte)
    jp (hl)

; ---- fill_rect_tile8(addr, width_bytes, height, tile): like fill_rect
; above, but instead of one constant fill byte, cycles through an
; 8-byte pattern (one byte per scanline, tile[0] on the first row drawn,
; wrapping back to tile[0] every 8 rows) -- lets a brick/pillar be
; filled with a repeating dither texture instead of a flat 0xFF/0x00.
; `height` MUST be a multiple of 8 for the first drawn row to land on
; tile[0] (both call sites -- draw_bricks()'s BRICK_H=8, the border
; pillars' full-screen height=200 -- satisfy this; a non-multiple still
; runs safely, it would just start the tile at some other phase).
;
; C calling convention: verified empirically via a throwaway `sdcc -S`
; compile of this exact 4-arg signature (2026-09-16), NOT assumed to
; match fill_rect's layout just because the args look similar -- they
; don't: fill_rect's last arg is one byte (pattern), this one's is a
; 16-bit pointer (tile), so the caller's stack packing is genuinely
; different. Confirmed: width_bytes at IX+4, height at IX+5, tile
; pointer's low byte at IX+6, high byte at IX+7 -- one 16-bit push for
; the packed {width_bytes,height} pair (same as fill_rect) plus a
; SECOND full 16-bit push for the tile pointer (fill_rect's single
; `pattern` byte never needed a second push). Epilogue must therefore
; discard 4 stack-arg bytes, not fill_rect's 3.
;
; IY holds the constant tile-base pointer for the whole call (loaded
; once via a spare register pair + push/pop -- Z80 has no direct
; register-to-IY move, and no `ADD HL,IY` either, hence the push/pop
; dance below each row to read a tile byte through HL instead). This
; is not a hot path (drawn once per level/brick-break, never per
; frame) so the extra push/pop overhead per row is a deliberate,
; harmless simplicity-over-speed tradeoff, not an oversight. ----
_fill_rect_tile8::
    push ix
    ld ix, #0
    add ix, sp
    ld c, 4 (ix)        ; C = width_bytes
    ld b, 5 (ix)        ; B = height (outer DJNZ counter)
    ld e, 6 (ix)        ; stage the tile pointer in DE first --
    ld d, 7 (ix)        ; NOT in HL, which still holds `addr` and must
                        ; stay untouched (see fill_rect's own comment)
    push de
    pop iy              ; IY = tile_base, constant for this whole call
    pop ix              ; restore caller's IX; SP back to entry value

    call bank_on

    ld a, #80           ; E = row stride remainder = 80 - width_bytes
    sub c               ; (D/E's staging job above is done; both are
    ld e, a             ; free to be reused for their fill_rect-style
                        ; roles from here on)
ftr_row:
    ; tile_index (0-7) for THIS row, derived from B alone rather than
    ; kept in a separate register: B still holds "rows remaining
    ; including this one" (same as fill_rect's outer counter), and
    ; since `height` is a multiple of 8 (see header), row_number mod 8
    ; == (-B) mod 8 -- computed here as (0 - (B mod 8)) mod 8, entirely
    ; standard, documented Z80 opcodes (AND/NEG), no lookup table
    ; needed.
    ld a, b
    and #7
    neg
    and #7
    push hl             ; save the video write pointer
    push iy
    pop hl              ; HL = tile_base
    add a, l            ; HL = tile_base + tile_index (8-bit add is
    ld l, a             ; enough: tile_index is 0-7, and a tile is
    jr nc, ftr_tbnoc     ; never placed at the very top of address
    inc h               ; space where this could wrap the wrong way)
ftr_tbnoc:
    ld d, (hl)          ; D = this row's fill byte, from the tile
    pop hl              ; restore the video write pointer

    ld a, c             ; inner counter = width_bytes, fresh each row
ftr_byte:
    ld (hl), d          ; write the pattern byte (same as fill_rect)
    inc hl
    dec a
    jr nz, ftr_byte
    ld a, l             ; HL += E, same row-stride advance as fill_rect
    add a, e
    ld l, a
    jr nc, ftr_noc
    inc h
ftr_noc:
    djnz ftr_row

    call bank_off

    ; Epilogue: callee-cleans-stack, 4 arg bytes this time (see header
    ; comment) -- pop hl(2, return addr) then pop af TWICE (4 more
    ; bytes: width_bytes+height, then the tile pointer), not
    ; fill_rect's pop-af-then-inc-sp 3-byte discard.
    pop hl
    pop af              ; discards width_bytes + height (2 bytes)
    pop af              ; discards the tile pointer (2 bytes)
    jp (hl)

; ---- edge_col(addr, height, or_mask, and_mask): a genuine single-BIT
; read-modify-write down one byte column, unlike fill_rect/
; fill_rect_tile8 which always overwrite the whole byte. Added
; 2026-09-16 after a real bench report: fill_rect's own byte
; granularity made a "1-pixel bevel highlight/shadow" come out a full
; 8px (one whole byte) wide instead -- there's no way to draw less
; than a full byte with a plain overwrite. This does
; `byte = (byte & and_mask) | or_mask` at `addr`, then again `height`
; times, each iteration ROW_BYTES (80) further down -- callers pick
; the masks: or_mask=0x80/and_mask=0xFF sets just the LEFTMOST pixel
; (a 1px-wide bright edge) without touching the other 7 bits already
; drawn by fill_rect_tile8 underneath; or_mask=0x00/and_mask=0xFE
; clears just the RIGHTMOST pixel (a 1px-wide dark edge) the same way.
;
; C calling convention: verified empirically via a throwaway `sdcc -S`
; compile of this exact 4-arg signature (2026-09-16) -- NOT assumed
; just because the shape (three 8-bit trailing args) matches
; fill_rect's; confirmed identical anyway: height at IX+4, or_mask at
; IX+5, and_mask at IX+6, same 3-byte epilogue discard as fill_rect.
;
; Not a hot path (drawn once per level/brick-break, like the other
; routines in this file) -- a plain per-row loop, no attempt to be
; clever about it. ----
_edge_col::
    push ix
    ld ix, #0
    add ix, sp
    ld b, 4 (ix)        ; B = height (outer DJNZ counter)
    ld d, 5 (ix)        ; D = or_mask
    ld e, 6 (ix)        ; E = and_mask
    pop ix              ; restore caller's IX; SP back to entry value
                        ; (HL, holding addr, untouched throughout)

    call bank_on

ec_row:
    ld a, (hl)          ; read the byte fill_rect_tile8 already wrote
    and e               ; clear whatever and_mask says to clear
    or d                ; set whatever or_mask says to set
    ld (hl), a          ; write it back -- the other 7 bits survive
    ld a, l             ; HL += 80 (next row, same column) -- 8-bit
    add a, #80          ; add is enough, same reasoning as fill_rect's
    ld l, a             ; own row-stride advance
    jr nc, ec_noc
    inc h
ec_noc:
    djnz ec_row

    call bank_off

    ; Epilogue: callee-cleans-stack, 3 arg bytes (see header comment) --
    ; identical shape to fill_rect's own epilogue.
    pop hl
    pop af              ; discards height + or_mask (2 bytes)
    inc sp              ; discards and_mask (1 byte)
    jp (hl)

; ---- draw_char(addr, ascii): blits one character glyph from the SAME
; font bios.asm's own CONOUT uses ($8000 = char_base, 8 bytes/glyph,
; glyph address = char_base + ascii*8, one font byte per scanline --
; confirmed by reading bios.asm's video_blit_impl directly, not
; assumed) straight into video RAM at `addr`, entirely within this
; file's own bank_on/bank_off pairing -- both the font ($8000-$87FF)
; and video RAM ($C000+) are reachable in the same bank=1 window, so
; no CONOUT/BDOS call is needed at all.
;
; Written 2026-09-16 specifically to AVOID calling BDOS's own console
; output (function 2, which goes through CONOUT) during gameplay: a
; real bench report that same day -- a mid-game message printed
; correctly, then the whole machine locked up -- pointed at CONOUT's
; own bank-flip trampoline (bios.asm's enter_bank1/leave_bank1), which
; tracks Port A via a SEPARATE shadow byte (porta_shadow) from this
; file's own bank_shadow. Traced through both sides' actual read-
; modify-write sequences by hand and did not find a definite divergence
; (this file's bank_on/bank_off always restore bank=0 before any
; possible BDOS call, so porta_shadow's bank bit should still agree
; whenever CONOUT next reads it) -- but rather than trust an unproven
; hand-trace on hardware I can't directly poke at, this sidesteps the
; whole question: nothing in this file ever needs to call CONOUT again,
; console INPUT (BDOS function 6, used elsewhere for the quit key and
; end-game keypress-wait) never touches Port A at all (it only reads
; keyboard-matrix hardware, the same ports poll_lr() reads directly),
; so it's unaffected either way.
;
; C calling convention: verified via throwaway `sdcc -S` (2026-09-16):
; ascii (the only trailing arg, 8-bit) lands at IX+4, 1 byte to
; discard in the epilogue -- same single-trailing-arg shape as neither
; fill_rect's three args nor fill_rect_tile8's pointer-plus-two, a
; distinct case checked on its own. ----
_draw_char::
    push ix
    ld ix, #0
    add ix, sp
    ld c, 4 (ix)        ; C = ascii
    pop ix              ; restore caller's IX; SP back to entry value
                        ; (HL, holding addr, untouched throughout)

    call bank_on

    ex de, hl           ; DE = addr (video write ptr); HL = don't-care
    ld l, c             ; HL = ascii, zero-extended
    ld h, #0
    add hl, hl          ; x2
    add hl, hl          ; x4
    add hl, hl          ; x8
    ld bc, #0x8000      ; char_base -- bios.asm's own font load address
    add hl, bc          ; HL = char_base + ascii*8 = glyph address
    ex de, hl           ; DE = glyph address; HL = addr (video write ptr)

    ld b, #8
dc_row:
    ld a, (de)          ; read one font byte
    ld (hl), a          ; write it to this scanline
    inc de
    ld a, l             ; HL += 80 (next scanline), same 8-bit-add
    add a, #80          ; trick fill_rect's own row-stride advance uses
    ld l, a
    jr nc, dc_noc
    inc h
dc_noc:
    djnz dc_row

    call bank_off

    ; Epilogue: callee-cleans-stack, 1 arg byte (see header comment).
    pop hl
    inc sp              ; discards ascii (1 byte)
    jp (hl)
