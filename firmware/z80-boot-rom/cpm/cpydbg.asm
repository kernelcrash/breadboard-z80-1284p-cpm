; cpydbg.asm -- diagnostic copy utility for CP/M 2.2: like a minimal PIP,
; but prints the record number (and a derived block number) after every
; single record copied -- built specifically so a mid-copy hang shows,
; frozen on screen, exactly how far it got before dying (see
; bring-up-log.md's drive-B write-hang investigation: real PIP.COM is a
; RunCPM binary with no source, so it can't be instrumented directly).
;
; Usage: CPYDBG destname sourcename   (space-separated -- NOT
; "dest=source", PIP's own syntax). This deliberately matches
; cpm22.asm's own UNKWN4 handler (verified directly against that code,
; not assumed): CONVFST/CONVERT build the FIRST filename into the
; standard default FCB at $5C (fully zeroed EX/S1/S2/RC/AL/CR, ready to
; use as-is -- same fact cksum.asm's own comment already established),
; then CONVERT a second time (offset 16) writes the SECOND filename's
; drive+name+type (12 raw bytes only) at $5C+16=$6C, deliberately
; overlaying FCB1's own AL-array region -- harmless for FCB1 (OPEN/MAKE
; overwrite AL from the directory regardless of what's already there),
; but it means nothing at $6C is zeroed for US to use as a second FCB,
; so this program builds its own full 36-byte source FCB by copying
; those 12 bytes and zeroing the rest itself.
;
; Simplification, deliberate: unlike real PIP, this does not use a
; temporary .$$$ name + rename -- it MAKEs destname directly. Use a
; destination name that doesn't already exist (ERA it first if
; re-running) -- CP/M's MAKE doesn't check for or reject a duplicate.
;
; BDOS function numbers verified directly against this project's own
; cpm22.asm FUNCTNS jump table (same discipline as cksum.asm, not
; assumed from generic CP/M lore): 15=open, 16=close, 20=read
; sequential, 21=write sequential, 22=make file, 26=set DMA address,
; 2=console output, 9=print string ($-terminated).

BDOS:      equ 5
FCB1:      equ 005Ch   ; dest -- CCP-built, ready to use as-is
FCB2NAME:  equ 006Ch   ; source's drive+name+type only (12 raw bytes)
F_OPEN:    equ 15
F_CLOSE:   equ 16
F_READ:    equ 20
F_WRITE:   equ 21
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
    ; from $6C, then zero offsets 12-35 (EX/S1/S2/RC/AL/CR/reserved) --
    ; CCP does NOT do this for a second filename, only the first.
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

    LD   DE,FCB1
    LD   C,F_WRITE
    CALL BDOS
    OR   A
    JR   NZ,write_error

    LD   HL,(reccount)
    INC  HL
    LD   (reccount),HL
    JR   copy_loop

write_error:
    LD   DE,msg_werr
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
msg_werr:    db 'WRITE ERROR',13,10,'$'
msg_done:    db 'DONE',13,10,'$'

srcfcb:   ds 36
reccount: ds 2
dmabuf:   ds 128

end:
