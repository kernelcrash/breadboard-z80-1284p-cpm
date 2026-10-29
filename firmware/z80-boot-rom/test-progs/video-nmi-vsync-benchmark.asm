; video-nmi-vsync-benchmark.asm -- measures the real-world Z80 slowdown
; caused by the per-line _BUSRQ video-fetch steals, using VSYNC (wired to
; the Z80's _NMI pin on the bench, external to this program) as a real,
; hardware-timed wall-clock reference.
;
; Every VSYNC pulse (once per 312-line frame, see sync.c) edges the Z80's
; NMI line low. NMI is non-maskable and always vectors to a fixed address
; ($0066), so unlike every other test-progs/*.asm in this project, this
; one needs a real interrupt-vector table at the bottom of memory rather
; than starting execution at address 0 -- see the vector table below.
;
; The benchmark itself is a plain, closed-form Z80 delay loop (24 outer
; reps x 65536 inner reps of DEC HL/LD A,H/OR L/JR NZ, DJNZ-driven outer)
; chosen so its *exact* T-state count is known: 40,894,898 T-states.
; At a true, uninterrupted 8MHz (this project's nominal Z80 clock,
; CLAUDE.md), that's 5.1119s -- and since each VSYNC/NMI tick is one
; 312-line frame (312 x 64us = 19.968ms, not quite the "20ms" of the
; filename/NMI-handler's job, close enough that this file just calls
; them "20ms intervals" throughout), a benchmark run with *zero* slowdown
; would count very close to 256.0 ticks (40,894,898 / 8,000,000 /
; 0.019968 = 256.00) -- chosen deliberately as a clean, memorable
; reference number. Whatever this program actually prints on the bench,
; divided by 256, is the real slowdown factor caused by the video-steal
; mechanism (BUSRQ arbitration + the fetch burst itself, ~44us of every
; 64us active line -- see video_fetch.c/sync.c), which is exactly what
; this test exists to measure.
;
; ---- vector table ----
; NMI safety requires SP to be valid and $0066 to hold a real jump
; *before any NMI can possibly occur*, including during the initial
; rom-copy phase below (before the mode-control switch to sram
; execution). Two things make this safe here specifically, not just
; assumed:
;   - Per CLAUDE.md, mode 0 ("rom mode") is "read from rom, write to
;     sram" -- writes always land in real SRAM regardless of mode, so
;     an NMI's automatic PC push (and this handler's own PUSH AF/PUSH HL)
;     work correctly even before the mode-control OUT below executes,
;     as long as SP itself is already valid. SP is set as the very
;     first instruction after the vector table for exactly this reason
;     -- every other test-progs/*.asm sets SP only after switching to
;     sram mode, since none of them use interrupts and don't need it
;     any earlier.
;   - VSYNC cannot actually pulse this early regardless: main.c
;     configures VSYNC (PC7) as an output driven HIGH at boot, and
;     nothing touches it again until sync.c's sync_init() (Timer1 CTC)
;     is armed -- which only happens once video_run() starts, which is
;     only reachable after this program's own magic-address read exits
;     ROM emulation, itself long after the mode switch below. So no NMI
;     edge is physically possible until well after this program has
;     already switched to sram execution -- the SP-early precaution
;     above is defense in depth, not covering a real gap given the
;     current hardware/firmware, but kept because it costs nothing and
;     the reasoning it depends on (video timing not yet armed) lives in
;     a different file than this one.
;
; The rom-copy loop below copies the *whole* image starting at address
; 0 (label `vectors`), not just from `init` (unlike every other
; test-progs/*.asm, which start their copy at their own `start` label
; == address 0 since none of them have a vector table before it) --
; the vector table must exist in real SRAM too, since after the mode
; switch all reads (including a future NMI's own instruction fetch from
; $0066) come from SRAM, not the emulated ROM.
;
; No CALL/RET/PUSH/POP before SP is set (there is none before it, SP is
; the very first instruction); CALL/RET/PUSH/POP are used freely after
; that, unlike this project's non-interrupt test-progs/*.asm which
; avoid them by convention since they never needed a real stack.
org 0

vectors:
    JP   init
    defs $0066-$,0
    JP   nmi_handler
    defs $0100-$,0

video_base: equ $c000

init:
    LD   SP,$8000	; valid before any NMI can occur -- see header comment

    LD   A,$8B
    OUT  ($AB),A
; set rom mode
    LD   A,$00
    OUT  ($A8),A

; copy rom to sram -- from `vectors` (address 0), not `init`, so the
; vector table itself ends up in real SRAM too (see header comment).
    LD   HL,vectors
    LD   BC,end-vectors
copyloop:
    LD   A,(HL)
    LD   (HL),A
    INC  HL
    DEC  BC
    LD   A,B
    OR   C
    JR   NZ,copyloop

; switch to sram mode
    LD   A,$01
    OUT  ($A8),A

; should be running in sram now at the same address

; ---- draw a one-pixel box around the screen edge, same fill routine as
; video-test3.asm, just for a visual "video generation is really
; running" check while the benchmark (several seconds) is in progress ----
    LD   HL,video_base
; top line
    LD   B,80
    LD   A,$FF
boxtop:
    LD   (HL),A
    INC  HL
    DEC  B
    JR   NZ,boxtop

; middle lines
    LD   B,198
boxmid:
    LD   A,$80
    LD   (HL),A
    INC  HL

    LD   C,78
    LD   A,$00
boxmid_fill:
    LD   (HL),A
    INC  HL
    DEC  C
    JR   NZ,boxmid_fill

    LD   A,$01
    LD   (HL),A
    INC  HL

    DEC  B
    JR   NZ,boxmid

    LD   B,80
    LD   A,$FF
boxbot:
    LD   (HL),A
    INC  HL
    DEC  B
    JR   NZ,boxbot

; ---- title, printed before the magic-address exit so it's already on
; screen the moment video generation starts (same convention as
; video-test3.asm's "Hello there" message) ----
    LD   HL,title_msg
    LD   B,2
    LD   C,8
    CALL write_msg

; ---- magic address: exits ROM emulation and starts video generation
; (video_fetch.c/sync.c) -- VSYNC/NMI cannot pulse before this point,
; see header comment. ----
    LD   A,($3FFF)

; ---- reset the 20ms-tick counter right before the timed section ----
    LD   HL,0
    LD   (nmi_count),HL

; ---- benchmark: 24 x 65536 = 1,572,864 iterations of a 3-instruction
; delay body, DJNZ-driven outer loop. Exact cost (see header comment):
; 40,894,898 T-states = 5.1119s at a true, unslowed 8MHz = ~256.0 ticks
; expected with zero slowdown. ----
    LD   B,24
bench_outer:
    LD   HL,0
bench_inner:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,bench_inner
    DJNZ bench_outer

; ---- benchmark done -- read the tick count and print it ----
    LD   HL,(nmi_count)
    CALL hl_to_decimal

    LD   HL,ticks_msg
    LD   B,4
    LD   C,8
    CALL write_msg

    LD   HL,digit_buf
    LD   B,4
    LD   C,14		; "TICKS=" occupies cols 8-13 (6 chars), digits start at 14
    CALL write_msg

; ---- done: slow blink forever, same rate/pattern as the other
; test-progs/*.asm, so a bench observer can tell the program reached
; the end without crashing. NMI keeps ticking nmi_count in the
; background from here on -- harmless, the result is already printed. ----
    LD   C,$00
donewait:
    LD   A,C
    XOR  $01
    LD   C,A
    OUT  ($B8),A
    LD   HL,$4000
donedelay:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,donedelay
    JR   donewait

; ---- NMI handler: fires once per VSYNC pulse (once per 312-line frame,
; ~19.968ms -- called "20ms" throughout this file, per the user's
; request). Just increments a 16-bit counter in memory; 16 bits is
; ample (65535 ticks = ~21.8 minutes, far more than a "several seconds"
; benchmark needs).
;
; PUSH AF is not strictly required by the instructions actually used
; below (LD/INC HL/LD all leave flags alone), but is included anyway on
; principle: NMI can land between *any* two instructions of the
; interrupted code, including between this file's own benchmark loop's
; `OR L` and `JR NZ,bench_inner` -- if a future edit to this handler
; ever touches flags without this, that exact interruption point would
; silently corrupt the benchmark loop's own conditional jump. Cheap
; insurance (22 T-states) against a bug class that would otherwise be
; nearly impossible to notice.
;
; RETN (not RET) is the correct instruction here -- restores IFF1 from
; IFF2 as Z80 NMI convention requires, even though this program never
; uses EI/DI/maskable interrupts and it would be a functional no-op
; either way. ----
nmi_handler:
    PUSH AF
    PUSH HL
    LD   HL,(nmi_count)
    INC  HL
    LD   (nmi_count),HL
    POP  HL
    POP  AF
    RETN

; ---- HL (0-65535) -> 5-digit null-terminated decimal ASCII string at
; digit_buf. No hardware multiply/divide on the Z80, so this uses the
; standard "repeated subtraction via ADD HL,BC with a negated divisor"
; technique: carry SET after `ADD HL,BC` means the subtraction was
; valid (HL was >= the divisor beforehand) since BC holds -divisor, so
; HL + (65536-divisor) only overflows 16 bits (setting carry) when
; HL >= divisor; carry CLEAR means it underflowed and must be undone
; with `SBC HL,BC`. Verified by hand against a worked example
; (25000 / 10000 -> digit 2, remainder 5000) before trusting it here. ----
hl_to_decimal:
    LD   DE,digit_buf
    LD   BC,-10000
    CALL get_digit
    LD   BC,-1000
    CALL get_digit
    LD   BC,-100
    CALL get_digit
    LD   BC,-10
    CALL get_digit
    LD   A,L		; remainder here is always 0-9 -- the final digit
    ADD  A,'0'
    LD   (DE),A
    INC  DE
    XOR  A
    LD   (DE),A		; null terminator
    RET

; HL = value (in/out, reduced mod |BC|), BC = -divisor, DE = output
; pointer (advanced by 1 on exit). Destroys A.
get_digit:
    LD   A,$FF
get_digit_loop:
    INC  A
    ADD  HL,BC
    JR   C,get_digit_loop
    SBC  HL,BC		; undo the failed (underflowing) subtraction
    ADD  A,'0'
    LD   (DE),A
    INC  DE
    RET

; ---- write_msg: identical to video-test3.asm's routine, reused
; verbatim (per the user's request to reuse "the text message logic").
; HL -> null-terminated message; B = character row (0-24); C = character
; column (0-79). ----
write_msg:
    LD   IX,video_base	; top corner
; multiply C by 640 (80 x 8)
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
    ADD  HL,DE	; HL should point to the 8 bytes for the char
    EX   DE,HL	; DE now points to the 8 bytes for the char, HL points to char_base

    LD   BC,160

    PUSH IX
    LD   A,(DE)	; get char pixels
    LD   (IX+0),A	; write to screen
    INC  DE

    LD   A,(DE)	; get char pixels
    LD   (IX+$50),A	; write to screen
    INC  DE

    ADD  IX,BC

    LD   A,(DE)	; get char pixels
    LD   (IX+0),A	; write to screen
    INC  DE

    LD   A,(DE)	; get char pixels
    LD   (IX+$50),A	; write to screen
    INC  DE

    ADD  IX,BC

    LD   A,(DE)	; get char pixels
    LD   (IX+0),A	; write to screen
    INC  DE

    LD   A,(DE)	; get char pixels
    LD   (IX+$50),A	; write to screen
    INC  DE

    ADD  IX,BC

    LD   A,(DE)	; get char pixels
    LD   (IX+0),A	; write to screen
    INC  DE

    LD   A,(DE)	; get char pixels
    LD   (IX+$50),A	; write to screen
    INC  DE

    POP  IX
    INC  IX		; Move screen position to the right

    POP  HL
    INC  HL
    JR   wr1
exit_write_msg:
    RET

char_base:
    incbin "test-progs/msxfont.img"

title_msg: db "VSYNC/NMI BENCHMARK: RUNNING...",0
ticks_msg: db "TICKS=",0	; 6 chars, columns 8-13 if printed at col 8

nmi_count: dw 0
digit_buf: defs 6,0

end:
