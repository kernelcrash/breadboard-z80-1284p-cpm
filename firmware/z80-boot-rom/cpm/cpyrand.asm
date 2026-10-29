; cpyrand.asm -- variant of cpydbg.asm that writes the DESTINATION via
; BDOS random-access I/O (WRITERAND, function 34) instead of plain
; sequential WRITESEQ, keeping the SOURCE read sequential and
; everything else (including the REC=/BLK= progress printout)
; identical. Built to test a specific, concrete hypothesis from the
; drive-B write-hang investigation (bring-up-log.md): cpydbg.com's pure
; sequential copy completed an entire ~300KB file correctly (proving
; the sequential write/allocation path is sound), but real PIP.COM's
; own binary includes wrapper stubs for READRAND/WRITERAND/SETRAN
; (BDOS 33/34/36) that cpydbg never exercises -- a genuinely different
; BDOS code path (POSITION/COMPRAND in cpm22.asm) for translating a
; random record number into the extent/record fields sequential access
; uses. If PIP (or Zork's own story-file paging) hangs specifically
; because of THAT path, this program should reproduce it; if this also
; completes cleanly, the random-access position/extent logic itself is
; also fine, and the real difference lies elsewhere (PIP's own
; .$$$-then-rename, its indirect-call-table structure I couldn't trace
; statically, or something else again).
;
; Usage: identical to cpydbg -- CPYRAND destname sourcename.
;
; Mechanics: BDOS's random functions read the target record number from
; the FCB's own r0/r1/r2 bytes (offsets 33/34/35 -- verified directly
; against cpm22.asm's own POSITION routine, which reads r0 at fcb+33
; and r1 at fcb+34 via two INC HL steps from there), not from a
; register argument. So before each write this pokes the current
; record counter into FCB1+33/+34 as a 16-bit little-endian value and
; zeroes FCB1+35 (r2) -- our record numbers never exceed a few thousand,
; nowhere near needing r2 (which would only matter beyond CP/M 2.2's
; documented 8MB-per-file random-access ceiling anyway). No SETRAN call
; is needed: SETRAN only exists as a convenience to COMPUTE r0/r1/r2
; FROM the current sequential position for a program that wants to
; switch access modes mid-stream -- we already know the exact record
; number we want (it's our own loop counter), so we can just write it
; directly.
;
; BDOS function numbers verified directly against cpm22.asm's own
; FUNCTNS jump table: 34=WTRANDOM, alongside the same 15/16/20/22/26/
; 2/9 cpydbg.asm already verified.

BDOS:      equ 5
FCB1:      equ 005Ch   ; dest -- CCP-built, ready to use as-is
FCB1_R0:   equ 005Ch+33
FCB2NAME:  equ 006Ch   ; source's drive+name+type only (12 raw bytes)
F_OPEN:    equ 15
F_CLOSE:   equ 16
F_READ:    equ 20
F_WRITERAND: equ 34
F_MAKE:    equ 22
F_DMAOFF:  equ 26
FN_CONOUT: equ 2
FN_PRSTR:  equ 9

    org 100h

start:
    LD   DE,dmabuf
    LD   C,F_DMAOFF
    CALL BDOS

    ; Build the source FCB: copy the 12 raw bytes (drive+name+type)
    ; from $6C, then zero offsets 12-35 -- see cpydbg.asm's own comment
    ; for why (CCP only does this automatically for the FIRST filename).
    LD   HL,FCB2NAME
    LD   DE,srcfcb
    LD   BC,12
    LDIR
    XOR  A
    LD   HL,srcfcb+12
    LD   B,36-12
zero_src:
    LD   (HL),A
    INC  HL
    DJNZ zero_src

    LD   DE,srcfcb
    LD   C,F_OPEN
    CALL BDOS
    INC  A                     ; A=$FF (not found) -> 0 (Z)
    JP   Z,src_not_found

    LD   DE,FCB1
    LD   C,F_MAKE
    CALL BDOS
    INC  A                     ; A=$FF (directory full) -> 0 (Z)
    JP   Z,dest_make_failed

    ; FCREATE (cpm22.asm) only clears S2 (via CLEARS2) and offsets
    ; 15-31 (via GETEMPTY's own zeroing loop) -- CR (32) and r0/r1/r2
    ; (33/34/35) are left as whatever was already in memory. POSITION
    ; treats a nonzero r2 as "record number out of range" (error 6)
    ; regardless of r0/r1, so this must be zeroed explicitly before the
    ; first WRITERAND call, not assumed already clean.
    XOR  A
    LD   (FCB1+32),A
    LD   (FCB1+35),A

    LD   HL,0
    LD   (reccount),HL

copy_loop:
    LD   DE,srcfcb
    LD   C,F_READ
    CALL BDOS
    OR   A
    JR   NZ,copy_done          ; non-zero = EOF (or read error either way)

    ; Print progress BEFORE the write -- if the write itself is what
    ; hangs, we still want this record's number to already be on
    ; screen, not buffered/lost.
    LD   HL,(reccount)
    CALL print_progress

    ; Poke the target record number into FCB1's r0/r1 (little-endian);
    ; r2 stays zero (see header comment).
    LD   HL,(reccount)
    LD   (FCB1_R0),HL

    LD   DE,FCB1
    LD   C,F_WRITERAND
    CALL BDOS
    OR   A
    JR   Z,write_ok
    LD   (lasterr),A
    JR   write_error
write_ok:

    LD   HL,(reccount)
    INC  HL
    LD   (reccount),HL
    JR   copy_loop

write_error:
    LD   DE,msg_werr
    LD   C,FN_PRSTR
    CALL BDOS
    LD   A,(lasterr)
    LD   L,A
    LD   H,0
    CALL print_dec16
    LD   DE,msg_crlf
    LD   C,FN_PRSTR
    CALL BDOS
    JR   close_and_exit

copy_done:
    LD   DE,msg_done
    LD   C,FN_PRSTR
    CALL BDOS

close_and_exit:
    LD   DE,FCB1
    LD   C,F_CLOSE
    CALL BDOS
    LD   C,0
    JP   BDOS                  ; function 0 (system reset) -- documented
                                ; way to end a .COM program.

src_not_found:
    LD   DE,msg_srcnf
    LD   C,FN_PRSTR
    CALL BDOS
    LD   C,0
    JP   BDOS

dest_make_failed:
    LD   DE,msg_mkfail
    LD   C,FN_PRSTR
    CALL BDOS
    LD   C,0
    JP   BDOS

; ---- print_progress: HL = 0-based record number just read. Prints
; ---- "REC=nnnnn BLK=nnnnn\r\n". BLK = record>>7 (128 records = one
; ---- 16384-byte block/logical-extent on drive B's specific DPB --
; ---- informational only, not meaningful for drive A's geometry). ----
print_progress:
    PUSH HL
    LD   DE,msg_rec
    LD   C,FN_PRSTR
    CALL BDOS
    POP  HL
    PUSH HL
    CALL print_dec16
    LD   DE,msg_blk
    LD   C,FN_PRSTR
    CALL BDOS
    POP  HL
    LD   B,7
shr7:
    SRL  H
    RR   L
    DJNZ shr7
    CALL print_dec16
    LD   DE,msg_crlf
    LD   C,FN_PRSTR
    CALL BDOS
    RET

; ---- print_dec16: HL = value, prints all 5 decimal digits (no
; ---- leading-zero suppression) -- identical to cksum.asm's own
; ---- routine, reused verbatim (same reasoning: obviously correct
; ---- over pretty). ----
print_dec16:
    LD   DE,10000
    CALL pd_digit
    LD   DE,1000
    CALL pd_digit
    LD   DE,100
    CALL pd_digit
    LD   DE,10
    CALL pd_digit
    LD   DE,1
    ; fall through
pd_digit:
    LD   B,'0'-1
pd_sub:
    INC  B
    OR   A                     ; clear carry
    SBC  HL,DE
    JR   NC,pd_sub
    ADD  HL,DE                 ; undo the last (failed) subtraction
    LD   A,B
    LD   E,A
    PUSH HL
    PUSH DE
    LD   C,FN_CONOUT
    CALL BDOS
    POP  DE
    POP  HL
    RET

msg_rec:     db 'REC=$'
msg_blk:     db ' BLK=$'
msg_crlf:    db 13,10,'$'
msg_srcnf:   db 'SOURCE NOT FOUND',13,10,'$'
msg_mkfail:  db 'DEST MAKE FAILED (ALREADY EXISTS?)',13,10,'$'
msg_werr:    db 'WRITE ERROR CODE=$'
msg_done:    db 'DONE',13,10,'$'

srcfcb:   ds 36
reccount: ds 2
lasterr:  ds 1
dmabuf:   ds 128

end:
