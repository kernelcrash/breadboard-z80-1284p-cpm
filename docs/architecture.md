# Architecture

Z80-based breadboard computer: 8 MHz Z80 + 64K SRAM + ATmega1284P (16 MHz) acting as ROM emulator, video controller, and virtual UART. DIP chips only, low chip count.

> **Redesigned 2026-09-02**: the mode-control mechanism moved from a
> 74LS74A flip-flop to an 8255 GPIO pin, and the WAIT flip-flop now
> clocks directly off the Z80's own CPU clock instead of a derived `_S`
> signal — cuts net chip count (6→4 for this subsystem) despite adding
> the 8255. Full derivation in `gate-equations.md`; this file is just the
> summary view, kept in sync with it.

## Block diagram

```
                        +---------------------------+
   16 MHz osc --------->| XTAL1 (pin 13)            |
                        |                           |
                        |        ATmega1284P        |
                        |  (128K flash / 16K SRAM)  |
                        |                           |
                        +---+--+--+--+--+--+--+--+--+
                            |  |  |  |  |  |  |  |
        A0-A7 (PA) --------+  |  |  |  |  |  |  |
        A8-A13 (PC0-5) ----+  |  |  |  |  |  |  |
        SER/SRCLK (PB5/PB7), RCLK (PB4) ------> 74HC595 --+
        _MREQ (PD4) ----------------------------------+ (bidir: input while
        _RD   (PD6) ----------------------------------+  sensing, output
        _BUSRQ (PD7) ----------------> Z80 (out only)  |  during video steal)
        Z80 _RESET (PD2) -----------------> Z80, and --+  also feeds the
        WAIT-rel (PD3) ----------+     |              |  shared POR net
        HSYNC (PC6)  ----------+     |              |
        VSYNC (PC7)  ----------+     |              |
        UART0 (PD0/1) <--> USB-serial (host)        |
                                                    v
   Gate network (74LS00 #1, 4 of 4 gates -- see wiring.md):
     NOT(_RD), NOT(mode_pin)          (74LS00 #1 gates 1,2 -- inverters)
     SRAM_OE = NAND(NOT(mode_pin), NOT(_RD))     (74LS00 #1 gate 3)
     595_OE  = NAND(mode_pin, NOT(_RD))           (74LS00 #1 gate 4)
     mode_pin: one 8255 GPIO port pin (external pull-down, LOW=ROM default)
     8255 _CS = 74LS138 O5, address-qualified 0xA8-0xAF (§7, not a bare _IORQ wire)

   Gate network (74LS00 #2, 3 of 4 gates -- see gate-equations.md §9):
     A16 = NAND(NAND(bank, A15), _BUSACK)         (gates 1,2 -- bank switch)
     8255 RESET = NOT(POR)                        (gate 4, wired as inverter --
                                                     no dedicated 74LS02 in this design)

   WAIT gen: 74LS74A FF#2 (same chip as clock divide), D=_RD, CLK=Z80 CPU
             clock (not a derived signal), /PRE=WAIT-rel, Q=_WAIT -> Z80
   595:      OE_bar = 595_OE   (drives Z80 data bus on any read while
                                 mode_pin=ROM -- see gate-equations.md §4
                                 for the accepted IO-read limitations this creates)
             (74HC595 as of 2026-09-16, was a 74LS373 -- serial SER/SRCLK
              + RCLK from the AVR instead of a parallel D0-D7 write, same
              OE_bar gating -- see gate-equations.md §4, 373-gates-sram-
              wiring.md, 74HC595-plan.md)

   Z80 (8 MHz) --- A14,A15 (pull-ups) ---+--- A0-A13 --- 1284P
      |            |                      |
      |            +--> TC551001BPL (1Mx8, A16=GND -> 64K)
      |                   CE1 = _MREQ
      |                   CE2 = VCC
      |                   OE  = SRAM_OE (mode-gated via mode_pin, no _MREQ
      |                          term needed -- CE1 already gates it, see
      |                          gate-equations.md §5)
      |                   R/W = _WR, direct wire (no gate -- same CE1
      |                          redundancy, verified via datasheet)
      |                   I/O0-I/O7 ---+--> 74LS166 (video, parallel load)
      |                                +--> shared data bus
      |
      +--- D0-D7 shared data bus <--- 74HC595 (OE = 595_OE)
      |
      +--- _MREQ, _IORQ, _RD, _WR (all pull-ups), _WAIT, _BUSRQ

   Clock divide-by-2:  74LS74A FF#1, D=Q' (fed back, toggle mode), CLK=16 MHz, Q -> Z80 CLK (8 MHz)
   WAIT FF:            74LS74A FF#2 (same chip), see above
   (Mode latch flip-flop eliminated 2026-09-02 -- mode_pin is now an 8255 GPIO pin)

   74LS166 (video):  D0-D7 <- SRAM I/O (on shared bus during burst)
                     CLK = 16 MHz master clock (pixel clock)
                     load pulse = open decision (HW divider or WAIT-rel reuse)
                     QH' (serial out) -> composite video mixing network
                     HSYNC/VSYNC (1284P timer-ISR GPIO toggles) mixed with pixel data
```

## Operating modes (from the 1284P's point of view)

1. **Monitor**: after power-up, 1284P holds Z80 in `_RESET`. Host talks over real UART: CLI (memory read/write) and Xmodem into the 8K ROM-image buffer.
2. **ROM emulation**: on "start", 1284P releases Z80 `_RESET` and tight-polls `_MREQ & _RD`. Serves bytes from its SRAM through the 595 (shifted in via hardware SPI, then latched — `databus.c`, inlined as of 2026-09-16 to avoid a real function-call boundary), using the external WAIT latch to slow the Z80 to one fetch per ~3.6-3.75 µs (bench-measured, `bring-up-log.md`; was 2-2.5 µs with the 373 — the difference is mostly the SPI shift's own 1 µs floor at this crystal's fastest available bit rate; irrelevant to correctness, see `rom_emu.c`'s own header).
3. **Video + IO virtualization**: after the Z80 configures the 8255 and drives `mode_pin` low (mode exit — see `gate-equations.md` §2, no longer a simple "any `OUT`" the way the old flip-flop worked), 1284P stops ROM emulation. For each of the 200 active PAL lines it asserts `_BUSRQ`, steals the bus, drives 80 addresses (A0-A13, A14/A15 pulled high → 0xC000-0xFFFF), each 500 ns apart; SRAM bytes flow straight into the 74LS166, which shifts them out as the pixel stream at 16 MHz. During the 112 blanking lines it services virtual UART IO (`_IORQ & _RD` cycles) — **currently only possible while `mode_pin` is still high (ROM mode); once `mode_pin` goes low the 595 can no longer drive the bus for any reason, including IO reads — see `gate-equations.md` §4, an accepted limitation, not yet solved.**

## Why the Z80 never needs to write through the 1284P

SRAM writes are pure hardware (`_WE` = SRAM `R/W`, now a direct wire to `_WR`); the 595 only presents *read* data. UART "writes" ride the address bus (`IN A,(C)` with the byte in C), so the AVR never has to read the Z80 data bus.

## Chip list

| Chip | Qty | Role |
|------|-----|------|
| Z80A DIP-40 | 1 | CPU @ 8 MHz |
| ATmega1284P-PU DIP-40 | 1 | ROM emu / video / UART |
| TC551001BPL-70L DIP-32 | 1 | 1M×8 SRAM (128K populated, 64K mapped in at a time — `A16` selects the half, CP/M bank switch, `gate-equations.md` §9) |
| 74HC595 DIP-16 | 1 | data bus latch for 1284P→Z80 reads (OE = `595_OE`); serial-loaded via AVR hardware SPI, was a 74LS373 DIP-20 until 2026-09-16 |
| 74LS74A DIP-14 | 1 | clock divide + `_WAIT` gen, both FFs on one chip (mode latch eliminated) |
| 74LS00 DIP-14 (#1) | 1 | 2-input NANDs: `NOT(_RD)`, `NOT(mode_pin)`, `SRAM_OE`, `595_OE` (4 of 4 gates) |
| 74LS00 DIP-14 (#2) | 1 | 2-input NANDs: `A16` bank-switch logic (gates 1-2), 8255 `RESET` inverter (gate 4, no dedicated 74LS02 in this design — 1 spare gate) |
| Intel 8255A PPI DIP-40 | 1 | `mode_pin`/`bank` (Port A), keyboard row-select + SD `MISO` (Port C), keyboard columns + SD `CS`/`SCK`/`MOSI` (Port B/A) |
| 74LS166A DIP-16 | 1 | video parallel-in/serial-out shift register |
| 74LS138 DIP-16 | 1 | IO port decode, MSX-style — selects the 8255 for `0xA8`-`0xAF` (1 of 8 outputs used, `gate-equations.md` §7) |
| 74LS145 DIP-16 | 1 | keyboard matrix row decoder, driven by 8255 Port C |
| 16 MHz oscillator can | 1 | master clock |

(Full pin-by-pin wiring for every chip above: `wiring.md`. Gate-level
derivations/truth tables: `gate-equations.md`. Part numbers: `bom.csv`.)
