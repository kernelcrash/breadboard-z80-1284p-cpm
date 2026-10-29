; keyboard-scan-test.asm -- Phase 10: verify the MSX-style keyboard
; matrix scan (docs/keyboard-wiring.md, cpm-plan.md §5).
;
; 8255 PC0-PC3 (Port C lower nibble) select one of 10 rows via the
; 74LS145 (BCD 0-9, active low outputs); PB0-PB7 read back the 8
; columns (pulled up externally, pulled low by a pressed key connecting
; its row to its column). Matches real MSX convention (Port B=columns,
; Port C=row-select), not the row-select-on-Port-A layout this file
; first used -- see keyboard-wiring.md for why the switch, and why it
; doesn't block Phase 11's SD card SPI.
;
; This DOES need one 8255 control-word change every other test-progs/
; *.asm doesn't: $8A instead of $8B, so Port C's lower nibble is an
; output (bit 0 of the control word) instead of the input every other
; program leaves it as. Port A (mode_pin/bank) and Port B (columns)
; are unaffected -- still output and input respectively. Row-select no
; longer shares a byte with mode_pin/bank (different port entirely), so
; unlike the Port-A version this file used to be, Port A only needs to
; be written once at boot, not re-written on every row scan.
;
; Continuously scans all 10 rows and prints the actual key name (e.g.
; "A", "SPACE", "SELECT") in a fixed 8-character field, or "NO KEY" if
; none is pressed -- looked up from a (row,col)-indexed pointer table
; matching the confirmed rows-0-8 key map in keyboard-wiring.md (this
; keyboard has no numeric keypad, so row 9 is wired to nothing and
; never actually fires; the lookup guards it anyway rather than
; assuming it can't happen). This only reports the unshifted identity
; of whichever key is down -- SHIFT/CTRL/etc. modifier handling is
; deliberately out of scope here, deferred to the real CBIOS CONIN
; (Phase 12), which needs to look at row 6 simultaneously with
; whatever other key is down rather than just report the first key
; found.
;
; For initial bring-up before a full keyboard is wired: a single
; pushbutton between any one 74LS145 Qn output and any one 8255 PBn
; column input is enough to confirm detection (see keyboard-wiring.md).
org 0

video_base: equ $c000

MODE_SRAM: equ $03	; mode=1 (sram-exec), bank=1 -- MUST be bank=1, not
			; bank=0: per cpm-plan.md §2/gate-equations.md §9,
			; $C000+ is only the AVR's actual video RAM when
			; bank=1 (the AVR's own video fetch always forces
			; A16=1 via _BUSACK regardless of `bank`, but the
			; Z80's OWN writes to $C000+ only land there under
			; bank=1 too -- under bank=0 they'd go to ordinary
			; RAM in the other physical bank, invisible on
			; screen). Real bug found the hard way: the first
			; version of this file used bank=0, meaning every
			; screen write -- the clear, the title, every
			; status update -- silently went to the wrong
			; physical bank and never appeared at all. This
			; test doesn't exercise bank-switching itself (that
			; is bank-switch-test.asm's job), so bank=1 is fixed
			; for the whole run, same as plh.asm.

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

; switch to sram mode
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

    LD   HL,title_msg
    LD   B,2
    LD   C,8
    CALL write_msg

; ---- magic address: exits ROM emulation, starts video generation ----
    LD   A,($3FFF)

; ---- continuous scan loop ----
scan_loop:
    LD   B,0		; B = current row, 0-9
row_loop:
    LD   A,B		; row value goes straight to PC0-PC3, no shifting
			; or merging needed -- Port C is dedicated to this
    OUT  ($AA),A

; settle delay -- 74LS145 propagation + column-line capacitance, cheap
; insurance matching this project's usual "a couple of NOPs" margin
; (rom_emu.c) rather than assuming zero delay is fine
    NOP
    NOP
    NOP
    NOP

    IN   A,($A9)	; read columns (active low = pressed)
    CP   $FF
    JR   NZ,key_found

    INC  B
    LD   A,B
    CP   10
    JR   NZ,row_loop

; no key found in any row this pass
    LD   HL,nokey_msg
    LD   B,4
    LD   C,8
    CALL write_msg
    JR   scan_loop

key_found:
; A = column byte (one or more bits low). Find the lowest-numbered
; pressed column via shift-and-count.
    LD   E,A
    LD   D,0
find_col:
    SRL  E
    JR   NC,col_done
    INC  D
    JR   find_col
col_done:
; D = column index (0-7), B = row index (0-9). Look up the key name via
; keynames[row*8+col] -- guard row>=9 even though this keyboard has no
; row 9 wired (no numeric keypad, per keyboard-wiring.md), rather than
; assuming the table can never be indexed out of range.
    LD   A,B
    CP   9
    JR   NC,key_unknown
    ADD  A,A
    ADD  A,A
    ADD  A,A
    ADD  A,D
    LD   L,A
    LD   H,0
    ADD  HL,HL		; word-sized pointers
    LD   DE,keynames
    ADD  HL,DE
    LD   A,(HL)
    INC  HL
    LD   H,(HL)
    LD   L,A
    JR   have_name_ptr
key_unknown:
    LD   HL,unknown_name
have_name_ptr:
; HL -> null-terminated key name. Copy up to 8 characters into key_buf,
; space-padding the rest, so this fully overwrites whatever was
; on-screen before regardless of the previous and new names' lengths.
    LD   DE,key_buf
    LD   B,8
fb_loop:
    LD   A,(HL)
    OR   A
    JR   Z,fb_pad
    LD   (DE),A
    INC  HL
    INC  DE
    DJNZ fb_loop
    JR   fb_done
fb_pad:
    LD   A,' '
    LD   (DE),A
    INC  DE
    DJNZ fb_pad
fb_done:
    XOR  A
    LD   (DE),A

    LD   HL,key_buf
    LD   B,4
    LD   C,8
    CALL write_msg

    JR   scan_loop

title_msg: db "KEYBOARD SCAN TEST",0
nokey_msg: db "NO KEY  ",0	; padded to the same 8-char field width as
				; key_buf below so it fully overwrites a
				; stale key name
key_buf: ds 9			; 8-char field + null, filled at runtime

; ---- key name table: keynames[row*8+col], row 0-8, col 0-7 ----
; Unshifted symbol per keyboard-wiring.md's confirmed rows-0-8 table
; (verified against map.grauw.nl's MSX key matrix reference).
keynames:
    dw kn_r0c0, kn_r0c1, kn_r0c2, kn_r0c3, kn_r0c4, kn_r0c5, kn_r0c6, kn_r0c7
    dw kn_r1c0, kn_r1c1, kn_r1c2, kn_r1c3, kn_r1c4, kn_r1c5, kn_r1c6, kn_r1c7
    dw kn_r2c0, kn_r2c1, kn_r2c2, kn_r2c3, kn_r2c4, kn_r2c5, kn_r2c6, kn_r2c7
    dw kn_r3c0, kn_r3c1, kn_r3c2, kn_r3c3, kn_r3c4, kn_r3c5, kn_r3c6, kn_r3c7
    dw kn_r4c0, kn_r4c1, kn_r4c2, kn_r4c3, kn_r4c4, kn_r4c5, kn_r4c6, kn_r4c7
    dw kn_r5c0, kn_r5c1, kn_r5c2, kn_r5c3, kn_r5c4, kn_r5c5, kn_r5c6, kn_r5c7
    dw kn_r6c0, kn_r6c1, kn_r6c2, kn_r6c3, kn_r6c4, kn_r6c5, kn_r6c6, kn_r6c7
    dw kn_r7c0, kn_r7c1, kn_r7c2, kn_r7c3, kn_r7c4, kn_r7c5, kn_r7c6, kn_r7c7
    dw kn_r8c0, kn_r8c1, kn_r8c2, kn_r8c3, kn_r8c4, kn_r8c5, kn_r8c6, kn_r8c7

unknown_name: db "?",0

kn_r0c0: db "0",0
kn_r0c1: db "1",0
kn_r0c2: db "2",0
kn_r0c3: db "3",0
kn_r0c4: db "4",0
kn_r0c5: db "5",0
kn_r0c6: db "6",0
kn_r0c7: db "7",0

kn_r1c0: db "8",0
kn_r1c1: db "9",0
kn_r1c2: db "-",0
kn_r1c3: db "=",0
kn_r1c4: db "\\",0
kn_r1c5: db "[",0
kn_r1c6: db "]",0
kn_r1c7: db ";",0

kn_r2c0: db "'",0
kn_r2c1: db "`",0
kn_r2c2: db ",",0
kn_r2c3: db ".",0
kn_r2c4: db "/",0
kn_r2c5: db "DEAD",0
kn_r2c6: db "A",0
kn_r2c7: db "B",0

kn_r3c0: db "C",0
kn_r3c1: db "D",0
kn_r3c2: db "E",0
kn_r3c3: db "F",0
kn_r3c4: db "G",0
kn_r3c5: db "H",0
kn_r3c6: db "I",0
kn_r3c7: db "J",0

kn_r4c0: db "K",0
kn_r4c1: db "L",0
kn_r4c2: db "M",0
kn_r4c3: db "N",0
kn_r4c4: db "O",0
kn_r4c5: db "P",0
kn_r4c6: db "Q",0
kn_r4c7: db "R",0

kn_r5c0: db "S",0
kn_r5c1: db "T",0
kn_r5c2: db "U",0
kn_r5c3: db "V",0
kn_r5c4: db "W",0
kn_r5c5: db "X",0
kn_r5c6: db "Y",0
kn_r5c7: db "Z",0

kn_r6c0: db "SHIFT",0
kn_r6c1: db "CTRL",0
kn_r6c2: db "GRAPH",0
kn_r6c3: db "CAPS",0
kn_r6c4: db "CODE",0
kn_r6c5: db "F1",0
kn_r6c6: db "F2",0
kn_r6c7: db "F3",0

kn_r7c0: db "F4",0
kn_r7c1: db "F5",0
kn_r7c2: db "ESC",0
kn_r7c3: db "TAB",0
kn_r7c4: db "STOP",0
kn_r7c5: db "BS",0
kn_r7c6: db "SELECT",0
kn_r7c7: db "RET",0

kn_r8c0: db "SPACE",0
kn_r8c1: db "HOME",0
kn_r8c2: db "INS",0
kn_r8c3: db "DEL",0
kn_r8c4: db "LEFT",0
kn_r8c5: db "UP",0
kn_r8c6: db "DOWN",0
kn_r8c7: db "RIGHT",0

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
