; ball.s -- the ball: a small, solid, sub-byte-positioned sprite,
; drawn/erased via XOR (same principle as bios.asm's cursor_xor_impl:
; XOR is its own inverse, so "erase" is just "draw again at the same
; position").
;
; The sub-byte horizontal shift (the ball's x isn't byte-aligned like
; the bricks/paddle in Phase 2/3) adapts Knight Lore's own proven
; kl_shift16 (firmware/z80-boot-rom/cpm/knight-lore/kl.asm lines
; 268-279): shift an 8-bit image right by 0-7 bits using a 16-bit
; register pair, SRL/RR looped once per bit -- the high half keeps the
; bits that stay in this byte, the low half catches the bits that
; spill into the next byte. Simplified from kl_blit_impl's full
; mask+image compositing (kl.asm lines 154-261): that's needed for
; overwrite-style drawing over a busy background (Knight Lore's own
; case); pure XOR needs no mask at all, since XORing with a 0 bit is
; already a no-op wherever the sprite doesn't cover.
;
; Known, accepted cosmetic gap for this phase: if the ball's footprint
; overlaps an already-lit brick pixel, XOR-drawing the ball there
; toggles that pixel off, and erasing toggles it back on -- a brief
; visual flicker under the ball while it's over a brick, not a real
; corruption (round-trips correctly). Brick collision (Phase 5) will
; make the ball actually react to bricks instead of passing over them;
; this phase doesn't need that yet.
    .module ball
    .globl _ball_xor
    .globl bank_on    ; defined in video.s -- see the bug note in
    .globl bank_off   ; _ball_xor's own header below

    .area _CODE

BALL_IMAGE = 0x3C   ; bits 2-5 set -- a 4-pixel-wide solid dot
BALL_H     = 4      ; 4 scanlines tall (so the ball is a 4x4 block)

; ---- ball_xor(addr, shift): XORs the ball sprite onto video RAM.
; addr = byte address of the sprite's top-left byte column (0xC000 +
; y*80 + x/8); shift = x&7, the sub-byte pixel offset (0-7) within
; that byte -- same x/8,x&7 split used throughout this project.
;
; Calling convention verified empirically for this exact (uint, uchar)
; shape before writing this (not assumed): addr -> HL; shift, being an
; 8-bit second argument with no 16-bit argument ahead of it needing DE,
; is NOT a 3rd register slot -- it goes on the stack, at SP+2 relative
; to entry, exactly like fill_rect's stack args. Epilogue matches that
; single-byte case: pop the return address, `inc sp` once (only one
; byte to discard here, not fill_rect's pop-af-plus-inc-sp for three),
; then jump to it.
;
; **Real bug, found on real hardware**: the first version of this
; routine never called bank_on/bank_off at all -- it wrote straight to
; (HL) assuming bank=1 was already active. Nothing ever set it, so
; every XOR write landed in bank=0's own memory instead of real video
; RAM: invisible, not a crash (bank=0's $C000+ is otherwise-unused
; system RAM, not something this write would visibly corrupt either --
; which is exactly why the symptom was "no ball" rather than a hang).
; fill_rect (video.s) already did this correctly, which is why the
; bricks/paddle were visible and the ball wasn't -- the tell that
; pinned this down. bank_on/bank_off are video.s's own internal
; helpers, exported via .globl (matching this project's existing
; extern-style pattern for cross-file asm symbols, e.g. crt0.s's own
; `.globl _main`, a symbol crt0.s only ever calls, never defines). ----
_ball_xor::
    push ix
    ld ix, #0
    add ix, sp
    ld c, 4 (ix)         ; C = shift (0-7), kept for the whole call
    pop ix               ; HL (addr) untouched by any of the above

    call bank_on

    ld a, #BALL_H
    ld (ball_row_count), a
bx_row:
    ld d, #BALL_IMAGE
    ld e, #0
    ld a, c
    or a                 ; shift=0 -> skip the loop entirely (DJNZ
    jr z, bx_noshift      ; with B=0 would run 256 times, not 0 -- the
                          ; same guard kl_shift16 itself uses)
    ld b, a
bx_shift_loop:
    srl d
    rr e
    djnz bx_shift_loop
bx_noshift:
    ld a, (hl)
    xor d
    ld (hl), a
    inc hl
    ld a, (hl)
    xor e
    ld (hl), a
    dec hl               ; back to this row's own start byte

    ld a, l               ; HL += 80 (next scanline)
    add a, #80
    ld l, a
    jr nc, bx_noc
    inc h
bx_noc:
    ld a, (ball_row_count)
    dec a
    ld (ball_row_count), a
    jr nz, bx_row

    call bank_off

    pop hl
    inc sp
    jp (hl)

; Never fetched as an instruction -- jp (hl) above is unconditional and
; this is the last thing in the file, so nothing ever falls into it.
ball_row_count:
    .db 0
