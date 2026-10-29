; blink an LED on bit 0 of a latch on IO address $00
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
    LD   C, 0x00
blinker:
    LD   A,C
    XOR  0x01
    LD   C,A
    OUT  ($B8),A
    LD   HL, 0x4000
delay:
    DEC  HL
    LD   A,H
    OR   L
    JR   NZ,delay
    JR   blinker
end:
