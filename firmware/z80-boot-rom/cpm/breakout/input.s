; input.s -- keyboard polling for a TPA-resident CP/M program.
;
; Deliberately NOT a general-purpose "scan all 10 rows" routine like
; bios.asm's find_key (lines 1195-1211) -- breakout only ever cares
; about LEFT/RIGHT, and both live in the same matrix row (row 8, per
; docs/keyboard-wiring.md's key map: col4=LEFT, col7=RIGHT), so this
; selects that one row once and tests both column bits directly.
; Ports match find_key's own ($AA = row-select output -> 8255 Port C
; lower nibble -> 74LS145; $A9 = column input, active-low, 8255 Port
; B) -- doesn't reconfigure the 8255's control word, because CP/M's own
; CONIN/CONST already run through find_key during ordinary operation,
; so Port C's lower nibble must already be configured as an output
; ($8A, not $8B -- docs/keyboard-wiring.md) by the time this program is
; even running under CP/M.
;
; This also gives breakout something the BDOS-level CONST/CONIN path
; can't: find_key stops at the first row with any column pressed, i.e.
; single-key-wins detection. That's a real limitation for a game
; needing simultaneous keys in general (see the feasibility plan's own
; comparison of breakout/invaders/pacman on this point) -- but it
; doesn't matter here, since LEFT and RIGHT are never meaningfully held
; at the same time on a 2-direction paddle, and this routine bypasses
; find_key's row-scanning behavior entirely by going straight to row 8.
    .module input
    .globl _poll_lr
    .globl _poll_quit
    .globl _delay_short

    .area _CODE

; ---- poll_lr(): returns a bitmask in A -- bit0 = LEFT held, bit1 =
; RIGHT held (both bits can be set; the caller just checks each
; independently, matching main.c's own "which way to move" logic). No
; C arguments, ordinary `ret` (no stack-arg cleanup needed -- unlike
; fill_rect, see video.s's own comment on why that one is different). ----
_poll_lr::
    ld a, #8            ; row 8 -- LEFT (col4) / RIGHT (col7)
    out (0xaa), a
    nop                 ; settle delay, matching find_key's own timing
    nop
    nop
    nop
    in a, (0xa9)        ; active-low column bits
    ld b, a
    ld a, #0
    bit 4, b
    jr nz, plr_no_left  ; bit set = not pressed (active low)
    or #1
plr_no_left:
    bit 7, b
    jr nz, plr_no_right
    or #2
plr_no_right:
    ret

; ---- poll_quit(): returns 1 in A if ESC (row 7, col 2 per
; docs/keyboard-wiring.md's key map) is currently held, 0 otherwise.
; Added 2026-09-16 specifically to AVOID BDOS function 6 (direct
; console I/O) for the game's quit key -- a real bench-found bug:
; DIRCIO's own E=0xFF path (cpm22.asm) calls BDOS's CONST, and
; bios.asm's const_impl calls show_cursor() whenever no key is ready
; -- which XORs CP/M's own text cursor into video RAM via enter_bank1
; EVERY time it's called. Polling that every frame (as this game's
; first cut of the quit key did) repeatedly redrew a stale cursor at
; whatever (cur_row,cur_col) CP/M's console was last left at,
; corrupting a border pillar on real hardware. Direct hardware
; polling -- same technique as poll_lr() above, just a different
; row/column -- never touches CONST/CONOUT/porta_shadow at all. ----
_poll_quit::
    ld a, #7            ; row 7 -- ESC lives at col 2
    out (0xaa), a
    nop
    nop
    nop
    nop
    in a, (0xa9)        ; active-low column bits
    ld b, a
    ld a, #0
    bit 2, b            ; bit set = not pressed (active low)
    ret nz              ; not pressed -- return 0 (already in A)
    inc a               ; pressed -- return 1
    ret

; ---- delay_short(): a rough, fixed busy-wait -- there is no VSYNC or
; frame-timing primitive reaching the Z80 at all on this hardware (the
; feasibility plan's own finding: _INT/_NMI are tied inactive, no IO
; port exposes VSYNC), so this is a placeholder throttle, not a
; calibrated 50Hz frame pace. ~65536 iterations of a 4-cycle inner
; loop -- tune this constant by feel once running on real hardware
; (this is exactly the "add calibrated pacing only if it's actually
; needed" polish item the plan itself deferred, done here in its
; roughest possible form to make LEFT/RIGHT humanly controllable at
; all for Phase 3). ----
_delay_short::
    push bc
    ld b, #24           ; was #0 (=256) -- real-hardware feedback: that
                        ; made LEFT/RIGHT feel sluggish. #24 cuts the
                        ; total to roughly 1/10th; retune this constant
                        ; further by feel, not by recalculating cycles.
dly_outer:
    ld c, #0
dly_inner:
    dec c
    jr nz, dly_inner
    dec b
    jr nz, dly_outer
    pop bc
    ret
