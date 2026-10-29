; vram_fill.asm -- plan-emu.md Phase P3 test pattern. Not a CP/M
; program and not meant to run on real hardware -- a standalone Z80
; program purpose-built to exercise the emulator's screen abstraction
; in isolation, decoupled from CP/M/bank-switch/ROM-emulation entirely
; (this project's real hardware needs a bank=1 flip to reach video RAM;
; this emulator's own memory model doesn't gate that at all yet, so
; this program just writes 0xC000-0xFFDF directly).
;
; Fills the 640x200 1bpp framebuffer (0xC000, 80 bytes/line) in 8-line
; bands alternating solid black (0x00) and solid white (0xFF) -- chosen
; over video-test2.asm's own $AA/$55 convention specifically because
; $AA and $55 are bit-complements of each other and both render as the
; same fine 50%-dither stripe pattern just phase-shifted by one pixel,
; which is hard to tell apart at a glance in a screenshot; solid bands
; are unambiguous. Once a full screen is filled, delays, then inverts
; which band starts black vs white and redraws forever -- gives a
; genuinely live-updating image, not just a one-shot static fill.
    org 0
start:
    LD   E,$00          ; E = current fill byte, toggles $00/$FF
draw_frame:
    LD   HL,$C000
    LD   D,25           ; 200 lines / 8 lines-per-band = 25 bands
group_loop:
    LD   BC,640         ; 8 lines * 80 bytes/line
byte_loop:
    LD   (HL),E
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,byte_loop
    LD   A,E
    CPL
    LD   E,A
    DEC  D
    JR   NZ,group_loop
    ; whole screen filled -- delay, then flip the starting band's
    ; colour so the next full redraw is visibly different
    LD   BC,0
delay_loop:
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,delay_loop
    LD   A,E
    CPL
    LD   E,A
    JR   draw_frame
