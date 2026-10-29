; crt0.s -- minimal CP/M startup stub for SDCC-compiled .com programs.
; Copied verbatim from sdcc-test/crt0.s (the proven toolchain base --
; see that file's own header for the full rationale).
;
; A CP/M .com file is a raw binary with no header, loaded verbatim at
; 0x0100 (the fixed start of the TPA -- Transient Program Area) with
; execution beginning at that same address. This stub is linked first
; (via -mz80 --no-std-crt0, listed before the other .rel files on the
; link line) and placed at --code-loc 0x0100, so it's the very first
; thing in the .com file: it sets up a private stack (well clear of the
; CCP/BDOS above the TPA), calls the C main(), then returns control to
; CP/M via the warm-boot vector.
;
; No SDCC global-constructor ("gsinit") support here -- breakout's C
; code doesn't use non-zero-initialized globals (game state is either
; zero-initialized, which BSS already gives for free, or explicitly set
; in main() before use); a program that adds any `int x = 5;`-style
; globals would need that wired in too (see SDCC's own crt0.s for the
; pattern).
    .module crt0
    .globl _main

    .area _CODE
init::
    ld sp, #stacktop        ; SP = top of our own reserved stack (below)
    call _main
    ; CP/M convention: a program returns to the CCP by jumping to
    ; address 0x0000, which CP/M's page-zero jump table always points
    ; at the BIOS warm-boot entry.
    jp 0x0000

    .area _BSS
    .ds 256                 ; stack, grows downward from stacktop --
                            ; bigger than sdcc-test's 128 since a game's
                            ; call depth (draw/collision helpers nested
                            ; under the main loop) will run deeper
stacktop:
