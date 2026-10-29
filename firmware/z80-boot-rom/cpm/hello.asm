; hello.asm -- minimal CP/M .COM: prints "Hello, world!" and returns to CP/M.
; Exits with RET back into CCP (it calls us with a return address on the
; stack), which avoids a warm boot (JP 0) and its CCP reload from the SD card.
; Build: z80asm -o hello.com hello.asm
        org     0100h

        ld      c,9             ; BDOS 9 = print $-terminated string
        ld      de,msg
        call    5
        ret                     ; back to CCP

msg:    db      "Hello, world!",13,10,"$"
