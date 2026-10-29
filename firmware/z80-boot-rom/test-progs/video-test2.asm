; video-test2.asm -- extends video-test1.asm with a full-screen SRAM
; prefill, for a real Phase 6a content test: video_fetch.c's
; video_fetch_line() now gets swept over all 200 real lines by
; video_run() once this program hits the magic address, reading back
; whatever this program wrote here.
;
; Fills the video buffer $C000-$FE7F (200 lines x 80 bytes = 16000
; bytes) in 8-line (640-byte) bands, alternating $AA/$55 starting with
; $AA: lines 0-7=$AA, 8-15=$55, 16-23=$AA, ... 200 isn't a multiple of
; 16 (8+8=16), so the 13th band (lines 192-199, the last 8) falls on an
; odd-numbered band in the alternation and is $AA again, same as band 1
; -- i.e. the last 8 scanlines are $AA, not $55.
;
; Sequence: copy self to sram, switch to sram mode, prefill the video
; buffer, blink 3 times (proves sram execution -- same pattern as
; blink.asm), read the magic address, then a plain 50% duty slow blink
; forever -- identical tail to video-test1.asm, just with the prefill
; inserted before the 3 blinks.
;
; No CALL/RET/PUSH/POP anywhere, deliberately -- SP is never set up.
; Every delay/fill loop is inlined, same convention as every other
; test-progs/*.asm in this project.
org 0
start:
    LD   A,$8B
    OUT  ($AB),A
; set rom mode
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
    LD   A,$01
    OUT  ($A8),A
; should be running in sram now at the same address

; ---- prefill the video buffer: 12 (AA,55) pairs (192 lines) then one
; final AA band (8 lines) = 200 lines / 16000 bytes total. HL runs
; continuously from $C000 across the whole fill; each band is its own
; 640-byte (8-line) inner loop so the fill byte can be a plain `LD
; (HL),n` immediate -- no register needed to hold it, so nothing to
; preserve across the loop-counter arithmetic below. ----
    LD   HL,$C000
    LD   B,12
fill_pair:
    LD   DE,640
fill_aa:
    LD   (HL),$AA
    INC  HL
    DEC  DE
    LD   A,D
    OR   E
    JR   NZ,fill_aa

    LD   DE,640
fill_55:
    LD   (HL),$55
    INC  HL
    DEC  DE
    LD   A,D
    OR   E
    JR   NZ,fill_55

    DJNZ fill_pair

; final AA band (13th band, 8 lines, 640 bytes -- lines 192-199)
    LD   DE,640
fill_last_aa:
    LD   (HL),$AA
    INC  HL
    DEC  DE
    LD   A,D
    OR   E
    JR   NZ,fill_last_aa

; ---- blink 3 times (proves sram execution -- same pattern as blink.asm) ----
    LD   B,3
blink3:
    LD   A,1
    OUT  ($B8),A
    LD   HL,$0800
b3_delay_on:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,b3_delay_on
    LD   A,0
    OUT  ($B8),A
    LD   HL,$0800
b3_delay_off:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,b3_delay_off
    DJNZ blink3

; ---- magic address: signals the 1284p to exit ROM emulation and start
; sweeping the video buffer just filled above (video_fetch.c/video.c).
; The byte read back is garbage and unused -- only the address on the
; bus matters to the 1284p, not the data. ----
    LD   A,($3FFF)

; ---- plain 50% duty slow blink, forever, same rate as blink.asm/
; video-test1.asm. ----
    LD   C,$00
slowblink:
    LD   A,C
    XOR  $01
    LD   C,A
    OUT  ($B8),A
    LD   HL,$4000
sb_delay:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,sb_delay
    JR   slowblink
end:
