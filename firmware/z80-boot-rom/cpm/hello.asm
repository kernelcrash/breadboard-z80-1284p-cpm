; hello.asm -- minimal CP/M .COM: prints "Hello, world!" and returns to CP/M.
; Build: z80asm -o hello.com hello.asm
        org     0100h

        ld      c,9             ; BDOS 9 = print $-terminated string
        ld      de,msg
        call    5
        jp      0               ; warm boot

msg:    db      "Hello, world!",13,10,"$"
