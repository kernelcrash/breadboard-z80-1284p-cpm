; console-io-test.asm -- Phase 12: standalone bring-up of the CBIOS
; console driver (CONST/CONIN/CONOUT) before it's wired into the real
; BIOS. cpm-plan.md's CBIOS needs a genuine streaming character
; console (cursor tracking, wrap, scroll) rather than the fixed-
; position write_msg used by every earlier test -- this is new ground,
; verified here in isolation first.
;
; CONOUT (input: C = character): CR resets column to 0; LF advances a
; row (scrolling the whole video buffer up by one character row -- 8
; pixel lines, 640 bytes -- once at the bottom row); BS backs up one
; column (no wrap); other control characters (<$20) are ignored;
; anything printable is blitted at the cursor via write_msg (reused
; verbatim, fed a 1-character string -- no new font-blit code needed)
; and the cursor advances, wrapping to the next row (with scroll) at
; column 80.
;
; CONST/CONIN: matrix-scan based, reusing keyboard-scan-test.asm's row
; select/column read, with a 1-key debounce (a physical keypress is
; only ever reported once, on the transition into being held) and a
; depth-1 pending-character buffer so CONST (peek) and CONIN (consume)
; have the correct, separate BDOS-standard contracts -- CONST must not
; eat the character CONIN is about to return. CTRL is checked
; explicitly (row 6 col 1) and transforms a letter into its control
; code (A-Z -> $01-$1A). SHIFT is deliberately NOT handled yet (every
; key reports its unshifted symbol regardless) -- flagged, not silently
; dropped: this is real CBIOS CONIN work still to do, matching
; keyboard-wiring.md's own note that this was deferred to Phase 12.
; Function keys (F1-F5), GRAPH/CODE/CAPS, and the cursor/editing keys
; (HOME/INS/arrows) have no ASCII meaning in a plain CP/M console and
; are left unmapped (ignored) for the same reason -- real terminal
; escape-sequence emulation is out of scope here.
;
; Test: prints a banner via the new CONOUT (proving streaming output,
; wrap, and -- if you keep typing long enough -- scroll), then loops
; CONST (poll) -> CONIN (consume) -> CONOUT (echo), exactly the
; pattern CCP itself uses. Type enough to fill the screen to see
; scrolling; press CTRL-C to see a control code echo (as bit pattern,
; since it's not printable) rather than a hang or a dropped/corrupted
; character.
org 0

video_base: equ $c000

MODE_SRAM: equ $03	; mode=1 (sram-exec), bank=1 -- fixed, needed for
			; write_msg's video writes to land in visible RAM

CTRL_ROW: equ 6
CTRL_COL: equ 1

start:
    LD   A,$8A
    OUT  ($AB),A
    LD   A,$00
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

    XOR  A
    LD   (cur_row),A
    LD   (cur_col),A
    LD   A,$FF
    LD   (last_row),A
    LD   (last_col),A
    XOR  A
    LD   (pending_char),A

; ---- magic address: exits ROM emulation, starts video generation ----
    LD   A,($3FFF)

    LD   HL,banner_msg
    CALL print_string

; ---- main loop: CONST (peek) -> CONIN (consume) -> CONOUT (echo) --
; ---- exactly the pattern real CCP uses ----
main_loop:
    CALL CONST
    OR   A
    JR   Z,main_loop
    CALL CONIN
    LD   C,A
    CALL CONOUT
    JR   main_loop

; ---- print_string: HL -> null-terminated string, streamed through
; ---- CONOUT one character at a time. ----
print_string:
    LD   A,(HL)
    OR   A
    RET  Z
    PUSH HL
    LD   C,A
    CALL CONOUT
    POP  HL
    INC  HL
    JR   print_string

; ============================================================
; CBIOS console driver: CONST / CONIN / CONOUT
; ============================================================

; ---- CONST: A = $FF if a character is ready to be read (CONIN won't
; ---- block), $00 otherwise. Must NOT consume the character -- CONIN
; ---- has to be able to return the exact same one. ----
CONST:
    CALL poll_key
    LD   A,(pending_char)
    OR   A
    JR   Z,const_no
    LD   A,$FF
    RET
const_no:
    XOR  A
    RET

; ---- CONIN: blocks until a character is available, returns it in A,
; ---- and consumes it (clears pending_char) so it's returned exactly
; ---- once. ----
CONIN:
cin_wait:
    CALL poll_key
    LD   A,(pending_char)
    OR   A
    JR   Z,cin_wait
    PUSH AF
    XOR  A
    LD   (pending_char),A
    POP  AF
    RET

; ---- CONOUT: C = character to output. ----
CONOUT:
    LD   A,C
    CP   $0D
    JR   Z,co_cr
    CP   $0A
    JR   Z,co_lf
    CP   $08
    JR   Z,co_bs
    CP   $20
    JR   C,co_ignore	; other control chars (<$20): ignored for now
    LD   (char_buf),A
    XOR  A
    LD   (char_buf+1),A
    LD   HL,char_buf
    LD   A,(cur_row)
    LD   B,A
    LD   A,(cur_col)
    LD   C,A
    CALL write_msg
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
    JR   Z,co_bs_done
    DEC  A
    LD   (cur_col),A
co_bs_done:
    RET
co_ignore:
    RET

; ---- advance_cursor: column+1, wrapping to column 0 and calling
; ---- newline (which scrolls if needed) at column 80. ----
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

; ---- newline: row+1, scrolling (and clamping at the last row) once
; ---- past row 24 (25 rows, 0-indexed). ----
newline:
    LD   A,(cur_row)
    INC  A
    CP   25
    JR   C,nl_store
    CALL scroll_screen
    LD   A,24
nl_store:
    LD   (cur_row),A
    RET

; ---- scroll_screen: moves character rows 1-24 (pixel rows 8-199,
; ---- 15360 bytes) up to become rows 0-23, then clears the newly
; ---- exposed last character row (640 bytes) to blank. ----
scroll_screen:
    LD   HL,video_base+640
    LD   DE,video_base
    LD   BC,15360
    LDIR
    LD   HL,video_base+15360
    LD   BC,640
sc_clear:
    XOR  A
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,sc_clear
    RET

; ---- poll_key: checks for a genuinely NEW physical keypress (one
; ---- that wasn't already being held on the previous call) and, if
; ---- found and nothing is already pending, stashes its ASCII code
; ---- into pending_char. Called by both CONST and CONIN so exactly
; ---- one of them ends up consuming any given keypress. ----
poll_key:
    CALL get_key_event
    RET  NC
    LD   (pending_char),A
    RET

; ---- get_key_event: carry SET + A=ascii if a new key-down transition
; ---- was found this call; carry CLEAR otherwise (nothing currently
; ---- pressed, the same key still held from last call, a pure
; ---- modifier key alone, or an unmapped key). ----
get_key_event:
    CALL find_key
    JR   Z,gke_none
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
    JR   C,gke_none		; row 6, col<5: pure modifier, no event
gke_lookup:
    LD   A,B
    ADD  A,A
    ADD  A,A
    ADD  A,A
    ADD  A,D
    LD   E,A
    LD   D,0
    LD   HL,ascii_table
    ADD  HL,DE
    LD   A,(HL)
    OR   A
    JR   Z,gke_none		; unmapped key: no event
    LD   (key_ascii),A
    CALL check_ctrl		; Z set = CTRL held
    JR   NZ,gke_plain
    LD   A,(key_ascii)
    CP   'A'
    JR   C,gke_plain
    CP   'Z'+1
    JR   NC,gke_plain
    AND  $1F
    SCF
    RET
gke_plain:
    LD   A,(key_ascii)
    SCF
    RET
gke_none:
    LD   A,$FF
    LD   (last_row),A
    LD   (last_col),A
    OR   A
    RET

; ---- find_key: scans rows 0-8 for the first pressed column. Z SET =
; ---- nothing pressed; Z CLEAR + B=row, D=col otherwise. ----
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
    RET				; Z still set from the last CP $FF
fk_found:
    LD   E,A
    LD   D,0
fk_col_loop:
    SRL  E
    JR   NC,fk_col_done
    INC  D
    JR   fk_col_loop
fk_col_done:
    OR   1		; force Z clear unconditionally before returning --
			; SRL sets Z from its OWN shifted result, not from
			; "was a column found," and when the found column is
			; the last one (col 7) the shifted E is always
			; exactly 0 (nothing above bit 7 to keep it nonzero),
			; giving a misleading Z=1 that would make the caller
			; (get_key_event's "JR Z,gke_none") silently discard
			; a correctly-identified keypress in column 7 of any
			; row. Clobbers A (already consumed into E, not
			; needed again by any caller).
    RET

; ---- check_ctrl: Z SET = CTRL (row 6 col 1) is currently held. ----
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

; ============================================================
; Data
; ============================================================

banner_msg: db "CONSOLE I/O TEST",13,10
            db "TYPE TO ECHO. KEEP TYPING TO SEE IT SCROLL.",13,10,0

cur_row:      ds 1
cur_col:      ds 1
last_row:     ds 1
last_col:     ds 1
pending_char: ds 1
key_ascii:    ds 1
char_buf:     ds 2

; ---- ascii_table[row*8+col], rows 0-8, matching keyboard-wiring.md's
; ---- confirmed key map. 0 = unmapped (SHIFT/CTRL/GRAPH/CAPS/CODE, F1-
; ---- F5, HOME/INS/arrows -- see this file's header comment for why).
; ---- Unshifted symbols only -- SHIFT is not yet implemented. ----
ascii_table:
    db '0','1','2','3','4','5','6','7'			; row 0
    db '8','9','-','=','\\','[',']',';'		; row 1
    db $27,$60,',','.','/',0,'A','B'			; row 2
    db 'C','D','E','F','G','H','I','J'			; row 3
    db 'K','L','M','N','O','P','Q','R'			; row 4
    db 'S','T','U','V','W','X','Y','Z'			; row 5
    db 0,0,0,0,0,0,0,0					; row 6 (modifiers/F1-F3)
    db 0,0,$1B,$09,0,$08,0,$0D				; row 7 (F4,F5,ESC,TAB,STOP,BS,SELECT,RET)
    db $20,0,0,$7F,0,0,0,0				; row 8 (SPACE,HOME,INS,DEL,arrows)

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
