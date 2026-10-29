# Z80 IO Map

All virtual IO is serviced **only during the 112 blanking lines** of each PAL
frame (up to ~20 ms worst-case latency — expected, not a bug). Every
transaction is an `_IORQ & _RD` cycle: the 1284P never sees `_WR`, and writes
ride the address bus (byte in A0–A7 via `LD C,data / LD B,sel / IN A,(C)`).

## Port decode

74LS138 on A8–A10, `_G1 = _IORQ`. The full 16-bit IO address is `B:0xFF`
form (Z80 `IN r,(C)` uses the full 16-bit port = B<<8 | C). Only A8–A10
select the device; A11–A15 are ignored (the Z80 must still keep them at the
values of `B` — i.e. code must use `LD A,0` style constants; in practice we
constrain code to the 0x0000–0x07FF port range).

| A10 | A9 | A8 | Y out | Port (B=0) | Device / register |
|-----|----|----|-------|------------|-------------------|
| 0   | 0  | 0  | Y0    | 0x0000     | UART RX data — `IN A,(C)` with C=0, B=0 returns next received byte (0xFF if empty → caller treats as "no data") |
| 0   | 0  | 1  | Y1    | 0x0002     | UART TX data — `LD C,data / LD B,0 / IN A,(C)` queues the byte in C for real-UART TX; returns 0 if accepted |
| 0   | 1  | 0  | Y2    | 0x0004     | reserved |
| 0   | 1  | 1  | Y3    | 0x0006     | reserved |
| …   |    |    |       |            | Y4–Y7 reserved (future: status regs, second device) |

C-value convention: C = 0 for reads, C = byte-to-send for writes; the 1284P
ignores A0–A7 for Y0 and reads A0–A7 for Y1. Any A0–A7 value is legal for
Y0; for Y1 the low byte is the payload.

## Service protocol (1284P firmware, during blanking)

1. Poll `_IORQ`.
2. On assert: read A8–A10 (device) and A0–A7 (value).
3. Y0 (RX read): pop byte from RX ring (or 0xFF if empty), drive D0–D7,
   release `_WAIT`.
4. Y1 (TX write): push A0–A7 byte to TX ring, drive D0–D7 = 0 (or TX-full
   flag: 1 if queue full and byte dropped), release `_WAIT`.
5. Tri-state D0–D7 (595 OE gated by the same `clkW` signal, was the
   373's before the 2026-09-16 chip swap — see gate-equations §4).

## Z80-side usage

```asm
; read one char (returns in A, 0xFF = none)
    LD   B,0
    LD   C,0
    IN   A,(C)
    CP   0xFF
    RET  Z

; write one char in A
    PUSH BC
    LD   B,0
    LD   C,A
    IN   A,(C)          ; A discarded (accept flag)
    POP  BC
```
