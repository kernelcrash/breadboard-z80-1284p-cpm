; cpyren.asm -- variant of cpydbg.asm that replicates real PIP's actual
; convention: write the copy to a temporary <name>.$$$ file first, then
; CLOSE and RENAME it to the real destination name, rather than MAKEing
; the final name directly. Built to test the one concrete difference
; between cpydbg (proven to complete a full sequential copy correctly
; on real hardware) and real PIP.COM that neither cpydbg nor cpyrand
; has exercised: RENAME (BDOS function 23) modifies an EXISTING
; directory entry's name bytes in place -- a genuinely different
; operation from MAKE (new entry) or WRITE (existing entry's data),
; confirmed present in PIP.COM's own wrapper-stub table (bring-up-
; log.md) and consistent with the TEST2.$$$ artifact left behind by
; the very first observed hang.
;
; Usage: CPYREN destname sourcename (same two-argument, space-separated
; form as cpydbg/cpyrand). Internally: builds a temp FCB from FCB1's
; own drive+name with extension replaced by "$$$" (matching PIP's real
; convention exactly), MAKEs and writes to THAT, then on completion
; CLOSEs it and RENAMEs it to the real destname given on the command
; line.
;
; RENAME's own FCB convention verified directly against cpm22.asm's
; CHGNAMES (not assumed): "the fcb contains the current name as the
; first 12 characters and the new name 16 bytes into the fcb" -- the
; SAME offset-16 convention already used for the second command-line
; filename (see cpydbg.asm's own header comment), so no new mechanism
; needs inventing here, just two 12-byte name+type copies into one
; scratch buffer.
;
; BDOS function numbers verified directly against cpm22.asm's own
; FUNCTNS table: 23=RENFILE, alongside the same 15/16/20/21/22/26/2/9
; cpydbg.asm already verified.

BDOS:      equ 5
FCB1:      equ 005Ch   ; dest (final name, from the command line)
FCB2NAME:  equ 006Ch   ; source's drive+name+type only (12 raw bytes)
F_OPEN:    equ 15
F_CLOSE:   equ 16
F_READ:    equ 20
F_WRITE:   equ 21
F_MAKE:    equ 22
F_RENAME:  equ 23
F_DMAOFF:  equ 26
FN_CONOUT: equ 2
FN_PRSTR:  equ 9

    org 100h

start:
    LD   DE,dmabuf
    LD   C,F_DMAOFF
    CALL BDOS

    ; Build the source FCB (same as cpydbg.asm): copy 12 raw bytes
    ; from $6C, zero offsets 12-35.
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

    ; Build the temp FCB: FCB1's own drive+name (9 bytes: drive + 8
    ; name chars), extension replaced with "$$$", rest zeroed.
    LD   HL,FCB1
    LD   DE,tmpfcb
    LD   BC,9
    LDIR
    LD   A,'$'
    LD   (tmpfcb+9),A
    LD   (tmpfcb+10),A
    LD   (tmpfcb+11),A
    XOR  A
    LD   HL,tmpfcb+12
    LD   B,36-12
zero_tmp:
    LD   (HL),A
    INC  HL
    DJNZ zero_tmp

    LD   DE,srcfcb
    LD   C,F_OPEN
    CALL BDOS
    INC  A                     ; A=$FF (not found) -> 0 (Z)
    JP   Z,src_not_found

    LD   DE,tmpfcb
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

    LD   DE,tmpfcb
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
    JR   close_tmp_and_exit

copy_done:
    LD   DE,msg_done
    LD   C,FN_PRSTR
    CALL BDOS

    ; Close the temp file, then rename it to the real destination --
    ; the step neither cpydbg nor cpyrand has ever exercised.
    LD   DE,tmpfcb
    LD   C,F_CLOSE
    CALL BDOS

    LD   DE,msg_renaming
    LD   C,FN_PRSTR
    CALL BDOS

    ; Build the rename FCB: old name (temp, .$$$) in bytes 0-11, new
    ; name (the real destname from FCB1) at offset 16 -- verified
    ; directly against cpm22.asm's own CHGNAMES comment ("the fcb
    ; contains the current name as the first 12 characters and the new
    ; name 16 bytes into the fcb").
    XOR  A
    LD   HL,renfcb
    LD   B,36
zero_ren:
    LD   (HL),A
    INC  HL
    DJNZ zero_ren
    LD   HL,tmpfcb
    LD   DE,renfcb
    LD   BC,12
    LDIR
    LD   HL,FCB1
    LD   DE,renfcb+16
    LD   BC,12
    LDIR

    LD   DE,renfcb
    LD   C,F_RENAME
    CALL BDOS

    LD   DE,msg_done
    LD   C,FN_PRSTR
    CALL BDOS
    LD   C,0
    JP   BDOS                  ; function 0 (system reset)

close_tmp_and_exit:
    LD   DE,tmpfcb
    LD   C,F_CLOSE
    CALL BDOS
    LD   C,0
    JP   BDOS

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
; ---- routine, reused verbatim. ----
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

msg_rec:      db 'REC=$'
msg_blk:      db ' BLK=$'
msg_crlf:     db 13,10,'$'
msg_srcnf:    db 'SOURCE NOT FOUND',13,10,'$'
msg_mkfail:   db 'DEST MAKE FAILED (ALREADY EXISTS?)',13,10,'$'
msg_werr:     db 'WRITE ERROR',13,10,'$'
msg_done:     db 'DONE',13,10,'$'
msg_renaming: db 'CLOSED, RENAMING...',13,10,'$'

srcfcb:   ds 36
tmpfcb:   ds 36
renfcb:   ds 36
reccount: ds 2
dmabuf:   ds 128

end:
