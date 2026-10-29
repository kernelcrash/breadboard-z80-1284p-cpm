; cksum.asm -- a small CP/M 2.2 utility: computes the same 16-bit
; sum-of-bytes checksum used throughout this project's own build
; tooling (stage1.asm's CHUNK*_CKSUM, cpm_put.py) over a file's real
; content, read via the actual CP/M file system (BDOS OPENFIL/READSEQ)
; -- built to let a file already on the SD card be checksummed
; on-hardware and compared directly against a host-computed reference,
; to help discriminate a genuinely corrupted stored file from anything
; else (bring-up-log.md's parked Zork black-screen investigation).
;
; Usage: CKSUM filename.ext   (or B:filename.ext, etc. -- CCP parses an
; optional drive prefix into the default FCB automatically, same as
; any other CP/M utility; no special handling needed here for that).
;
; BDOS function numbers below verified directly against this project's
; own cpm22.asm (its FUNCTNS jump table), not assumed from generic
; CP/M knowledge, even though they turn out to match the standard
; convention exactly: 0=system reset (the documented way to end a
; .COM program -- CCP transfers control via JP, not CALL, so there is
; no return address to RET to), 2=console output, 9=print string
; ($-terminated), 15=open file, 20=read sequential, 26=set DMA address.
;
; NOTE on exact host-side comparison: BDOS's sequential read has no
; concept of a binary file's "real" byte length -- it returns whole
; 128-byte records until the directory's own record count (RC, across
; all extents) is exhausted. If the real size isn't an exact multiple
; of 128, the last record's tail is whatever cpm_put.py's put_file
; zero-padded it to when the file was written (see its own comment) --
; so for a matching reference checksum, pad the host file to a
; multiple of 128 with zero bytes first:
;   python3 -c "d=open('ZORK1.DAT','rb').read(); d+=b'\0'*(-len(d)%128); print('%04X'%(sum(d)&0xFFFF))"

BDOS:         equ 5
FCB:          equ 005Ch	; the DEFAULT FCB -- fixed, standard CP/M
				; TPA address. CCP parses the command
				; tail into this exact location before
				; transferring control (JP, not CALL) to
				; any .COM program -- NOT something this
				; program builds or owns itself. A local
				; buffer of my own, however named, would
				; never see the parsed filename at all.
F_OPEN:       equ 15
F_READ:       equ 20
F_DMAOFF:     equ 26
FN_CONOUT:      equ 2
FN_PRSTR:   equ 9

    org 100h

start:
    LD   DE,dmabuf
    LD   C,F_DMAOFF
    CALL BDOS

    LD   DE,FCB
    LD   C,F_OPEN
    CALL BDOS
    INC  A			; A=$FF (not found) -> 0 (Z); A=0-3 -> 1-4 (NZ)
    JP   Z,not_found

    XOR  A			; CR (FCB+32) must be 0 before the first
    LD   (FCB+32),A		; sequential read -- universal CP/M
				; convention, set explicitly rather than
				; assumed already zero by OPENFIL (which
				; populates EX/S1/S2/RC/AL from the
				; directory, not this caller-side cursor).
    LD   HL,0
    LD   (cksum),HL
    LD   HL,0
    LD   (reccount),HL

read_loop:
    LD   DE,FCB
    LD   C,F_READ
    CALL BDOS
    OR   A
    JR   NZ,done_reading	; non-zero = EOF (or error) -- either way,
				; no more data to accumulate.

    LD   HL,dmabuf
    LD   DE,(cksum)
    LD   B,128
accum_loop:
    LD   A,(HL)
    ADD  A,E
    LD   E,A
    LD   A,0
    ADC  A,D
    LD   D,A
    INC  HL
    DJNZ accum_loop
    LD   (cksum),DE

    LD   HL,(reccount)
    INC  HL
    LD   (reccount),HL
    JR   read_loop

done_reading:
    LD   DE,msg_cksum
    LD   C,FN_PRSTR
    CALL BDOS
    LD   HL,(cksum)
    CALL print_hex16
    LD   DE,msg_records
    LD   C,FN_PRSTR
    CALL BDOS
    LD   HL,(reccount)
    CALL print_dec16
    LD   DE,msg_crlf
    LD   C,FN_PRSTR
    CALL BDOS
    LD   C,0
    JP   BDOS			; function 0 (system reset) -- the
				; documented way to end a .COM program.

not_found:
    LD   DE,msg_notfound
    LD   C,FN_PRSTR
    CALL BDOS
    LD   C,0
    JP   BDOS

; ---- print_hex16: HL = value, prints 4 uppercase hex digits. ----
print_hex16:
    LD   A,H
    CALL print_hex8
    LD   A,L
    ; fall through
print_hex8:
    PUSH AF
    RRA
    RRA
    RRA
    RRA
    CALL print_nibble
    POP  AF
print_nibble:
    AND  0Fh
    CP   10
    JR   C,pn_digit
    ADD  A,'A'-10
    JR   pn_out
pn_digit:
    ADD  A,'0'
pn_out:
    LD   E,A
    PUSH HL
    LD   C,FN_CONOUT
    CALL BDOS
    POP  HL
    RET

; ---- print_dec16: HL = value (0-65535), prints all 5 decimal digits
; ---- (no leading-zero suppression -- simple and unambiguous, matches
; ---- this project's own preference for a diagnostic tool being
; ---- obviously correct over being pretty). Repeated-subtraction
; ---- digit extraction (the Z80 has no hardware divide). ----
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
    OR   A			; clear carry
    SBC  HL,DE
    JR   NC,pd_sub
    ADD  HL,DE			; undo the last (failed) subtraction --
				; HL is now the remainder for the next digit
    LD   A,B
    LD   E,A
    PUSH HL
    PUSH DE
    LD   C,FN_CONOUT
    CALL BDOS
    POP  DE
    POP  HL
    RET

msg_cksum:    db 'CKSUM=$'
msg_records:  db ' RECORDS=$'
msg_crlf:     db 13,10,'$'
msg_notfound: db 'FILE NOT FOUND',13,10,'$'

cksum:    ds 2
reccount: ds 2
dmabuf:   ds 128

end:
