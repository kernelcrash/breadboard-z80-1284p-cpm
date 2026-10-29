# ATmega1284P GPIO Assignment — AUTHORITATIVE

Single source of truth for ATmega1284P pin usage. `firmware/avr-1284p/src/pins.h` is generated from this document. Any change here requires a matching change to `pins.h` and a review of every alternate-function conflict below.

**Constraint**: 27 of 32 GPIOs allocated, 5 free (PB0–PB3, PB6).

**2026-09-16 redesign (74LS373 → 74HC595, see `gate-equations.md` §4 and `74HC595-plan.md`):** the parallel 8-bit data-bus port (`D0`–`D7`, all of `PORTB`) is replaced by a 3-signal serial interface to a 74HC595 (`SER`/`SRCLK`/`RCLK`), freeing `PB0`–`PB3` and `PB6`. `SER`/`SRCLK` are driven by the AVR's hardware SPI peripheral (`MOSI`/`SCK`) rather than bit-banged GPIO — SPI was otherwise completely unused on this board (the SD card is bit-banged through the 8255, not this peripheral). `RCLK` (the 595's storage-register clock, no SPI-signal equivalent) is an ordinary GPIO pulsed low→high→low after each byte's 8 SPI clocks complete. See `firmware/avr-1284p/src/databus.c`/`databus.h`.

**Package**: ATmega1284P-PU, 40-pin PDIP. Verified against Atmel-42719C datasheet, Table 6-1 (PORT Function Multiplexing) and Section 5.1.1 (PDIP pinout). DIP-40 exposes all 32 GPIO (all four 8-bit ports) — only 2× VCC + 2× GND pins are dropped vs TQFP-44, which is why the 32-GPIO pin budget in plan.md holds.

**2026-09-02 redesign (mode-latch → 8255, `_S`-based WAIT → clock-driven WAIT FF, see `gate-equations.md`): confirmed, not assumed, that this needs zero changes to the AVR pin table below.** The 8255's `mode_pin`, `_CS`, and `RESET` are all wired on the Z80/gate side only (`wiring.md`) — no AVR GPIO is involved. The WAIT FF's `_RD`/clock inputs are likewise Z80-side. The only AVR pin touched by this redesign is PD2 (Z80 `_RESET`, row 27 below), which now also feeds the shared `POR` net — same physical AVR pin, same direction, same firmware behavior, just one more thing wired to that net downstream.

## DIP-40 pin reference (datasheet Table 6-1)

| DIP | Port | Alt functions |
|---|---|---|
| 1  | PB0 | T0/XCK0, PCINT8 |
| 2  | PB1 | T1/CLKO, PCINT9 |
| 3  | PB2 | INT2/AIN0, PCINT10 |
| 4  | PB3 | AIN1/OC0A, PCINT11 |
| 5  | PB4 | OC0B/SS, PCINT12 |
| 6  | PB5 | MOSI, PCINT13 |
| 7  | PB6 | MISO, PCINT14 |
| 8  | PB7 | SCK, PCINT15 |
| 9  | RESET | — |
| 10 | VCC | — |
| 11 | GND | — |
| 12 | XTAL2 | oscillator amp output |
| 13 | XTAL1 | oscillator amp input / external clock in |
| 14 | PD0 | RXD0/T3, PCINT24 |
| 15 | PD1 | TXD0, PCINT25 |
| 16 | PD2 | RXD1/INT0, PCINT26 |
| 17 | PD3 | TXD1/INT1, PCINT27 |
| 18 | PD4 | OC1B/XCK1, PCINT28 |
| 19 | PD5 | OC1A, PCINT29 |
| 20 | PD6 | OC2B/ICP1, PCINT30 |
| 21 | PD7 | OC2A, PCINT31 |
| 22 | PC0 | SCL, PCINT16 |
| 23 | PC1 | SDA, PCINT17 |
| 24 | PC2 | TCK (JTAG), PCINT18 |
| 25 | PC3 | TMS (JTAG), PCINT19 |
| 26 | PC4 | TDO (JTAG), PCINT20 |
| 27 | PC5 | TDI (JTAG), PCINT21 |
| 28 | PC6 | TOSC1, PCINT22 |
| 29 | PC7 | TOSC2, PCINT23 |
| 30 | AVCC | — |
| 31 | GND | — |
| 32 | AREF | — |
| 33 | PA7 | ADC7, PCINT7 |
| 34 | PA6 | ADC6, PCINT6 |
| 35 | PA5 | ADC5, PCINT5 |
| 36 | PA4 | ADC4, PCINT4 |
| 37 | PA3 | ADC3, PCINT3 |
| 38 | PA2 | ADC2, PCINT2 |
| 39 | PA1 | ADC1, PCINT1 |
| 40 | PA0 | ADC0, PCINT0 |

## Signal → port.pin → DIP pin

| # | Signal | Port.Pn | DIP | Alt on pin | Dir | Notes |
|---|--------|---------|-----|------------|-----|-------|
| 1  | A0   | PA0 | 40 | ADC0 | bidir | in: Z80 (ROM emu/IO), out: video fetch |
| 2  | A1   | PA1 | 39 | ADC1 | bidir | |
| 3  | A2   | PA2 | 38 | ADC2 | bidir | |
| 4  | A3   | PA3 | 37 | ADC3 | bidir | |
| 5  | A4   | PA4 | 36 | ADC4 | bidir | |
| 6  | A5   | PA5 | 35 | ADC5 | bidir | |
| 7  | A6   | PA6 | 34 | ADC6 | bidir | |
| 8  | A7   | PA7 | 33 | ADC7 | bidir | |
| 9  | A8   | PC0 | 22 | SCL | bidir | TWI unused |
| 10 | A9   | PC1 | 23 | SDA | bidir | TWI unused |
| 11 | A10  | PC2 | 24 | TCK (JTAG) | bidir | JTAG disabled by fuse |
| 12 | A11  | PC3 | 25 | TMS (JTAG) | bidir | |
| 13 | A12  | PC4 | 26 | TDO (JTAG) | bidir | |
| 14 | A13  | PC5 | 27 | TDI (JTAG) | bidir | |
| 15 | *(free)* | PB0 | 1 | T0/XCK0 | — | freed 2026-09-16 (was D0, parallel data bus) |
| 16 | *(free)* | PB1 | 2 | T1/CLKO | — | freed 2026-09-16 (was D1). CKOUT fuse unprogrammed → I/O |
| 17 | *(free)* | PB2 | 3 | INT2/AIN0 | — | freed 2026-09-16 (was D2) |
| 18 | *(free)* | PB3 | 4 | AIN1/OC0A | — | freed 2026-09-16 (was D3) |
| 19 | RCLK (74HC595) | PB4 | 5 | OC0B/SS | out | latches shifted byte into 595's output register; also ISP SS |
| 20 | SER (74HC595) | PB5 | 6 | **MOSI (ISP)** | out | hardware SPI (`databus.c`); ISP conflict — see below |
| 21 | SH_LD (74LS166) | PB6 | 7 | **MISO (ISP)**, OC3A | out | **2026-09-21**: freed 2026-09-16 (was D6, 595 has no data-out pin to receive on MISO) then given SH_LD's job when it moved off PD5 -- Timer3 Fast PWM generates the pulse train in hardware, phase-locked to the video-fetch burst (sync.c's `SHLD_TIMER3_PHASE`); the AVR only gates `DDRB6` on/off around each burst (`shld_test.c`), it never toggles the pulse itself. `databus_init()` permanently enables SPI master mode, which unconditionally forces MISO's direction to input regardless of DDRB6 -- `shld_test_init()` disables SPI (`SPCR=0`) to free the pin for this, safe since ROM emulation (the only real MISO user) has already exited by the time video runs |
| 22 | SRCLK (74HC595) | PB7 | 8 | **SCK (ISP)** | out | hardware SPI (`databus.c`); ISP conflict — see below |
| 23 | _MREQ | PD4 | 18 | OC1B | bidir | in: ROM-emu sense; out: video burst |
| 24 | *(free)* | PD5 | 19 | OC1A | out | **2026-09-05, was `_IORQ`**: this pin no longer connects to the Z80's `_IORQ` at all — physically disconnected on the breadboard, its pull-up removed. Was then dedicated to the pixel-data 74LS166's `SH_LD` input (chosen after PD3/`wait_rel` turned out fundamentally unable to share that duty with the WAIT flip-flop's needs, gate-equations.md §3/§6, bring-up-log.md) until **2026-09-21**, when `SH_LD` moved to `PB6`/`OC3A` (hardware-generated, see that row above) and this pin came free again. Still configured as a permanent output by `main.c` and pulsed by `video_fetch.c`'s legacy debug-only path (monitor's `vf` command) -- that pulse no longer reaches real hardware (nothing's wired to this pin any more), so `vf`'s own video output is not meaningful post-2026-09-21 pending its own migration or removal. Real IO-instruction virtualization (CLAUDE.md's original `_IORQ`-sensing idea, Phase 7, never implemented) could reclaim this pin if it's ever built |
| 25 | _RD   | PD6 | 20 | OC2B/ICP1 | bidir | in: ROM-emu sense; out: video burst |
| 26 | _BUSRQ | PD7 | 21 | OC2A | out | video steal only. **2026-09-05**: also asserted during `video_run()`'s bring-up test (sync.c) — a fixed 40us window in the middle of each of the first 200 lines, no address bus/`_MREQ`/`_RD` involvement yet |
| 27 | Z80 _RESET | PD2 | 16 | RXD1/INT0 | out | held low at power-up; also feeds the shared `POR` net (74LS74A `_CLR2`, 8255 `RESET` via inverter) — see gate-equations.md "Power-on reset" |
| 28 | WAIT-release | PD3 | 17 | TXD1/INT1 | out | pulses WAIT FF's `_PRE2` (now clocked by the Z80's own CPU clock, not `_S` — gate-equations.md §3, 2026-09-02 redesign); same pin/pulse behavior as before, no firmware change. **2026-09-05**: briefly reused during bring-up (sync.c's now-removed "fat pixel" test, and an abandoned attempt at sourcing 74LS166 `SH/LD` from this pin) but both uses turned out incompatible with this pin's real job — see gate-equations.md §3/§6 and bring-up-log.md. Back to its original, sole role: `rom_emu.c` drives it low once and leaves it low permanently after the magic-address exit, holding the WAIT FF's PRESET asserted forever |
| 29 | UART RXD (host) | PD0 | 14 | **RXD0 fixed** | in | USART0 hardware. **Also the power-up boot-mode strap** (2026-09-11): `main.c` enables the internal pull-up and samples PD0 once, *before* `usart_init()`. A permanent external ~3.3k (≤4.7k) to GND reads LOW whenever no serial adapter is driving the line → the AVR autoboots the Z80 from the flash-embedded `stage1.bin`; adapter connected (idle-high TX overrides the resistor) or bare pin (internal pull-up) reads HIGH → monitor mode. Not a repurposing — PD0 stays USART0 RXD, only strapped. Datasheet Atmel-42719C "Reading the Pin Value": PINxn readable regardless of DDxn / RXEN0; `RPU` 20–50k. |
| 30 | UART TXD (host) | PD1 | 15 | **TXD0 fixed** | out | USART0 hardware |
| 31 | HSYNC | PC6 | 28 | TOSC1 | out | see Sync generation below |
| 32 | VSYNC | PC7 | 29 | TOSC2 | out | |

## Sync generation — OC pin allocation

This heading's "no free OC pins" was true as of 2026-09-05 (`SH_LD` on
`OC1A`/`PD5`) but is stale now -- the 74HC595 swap freed `OC3A`/`PB6`
(2026-09-16), and `SH_LD` itself later moved onto it (2026-09-21),
leaving `PD5` free again:

| OC pin | Port.Pn | Allocated to |
|--------|---------|--------------|
| OC0A | PB3 | *(free)* |
| OC0B | PB4 | RCLK (74HC595) |
| OC1A | PD5 | *(free)* (2026-09-21, was SH_LD; see PD5's row above) |
| OC1B | PD4 | _MREQ |
| OC2A | PD7 | _BUSRQ |
| OC2B | PD6 | _RD |
| OC3A | PB6 | SH_LD (2026-09-21, hardware Fast PWM -- see PB6's row above) |
| OC3B | PB7 | SRCLK (74HC595) |
| CLKO | PB1 | *(free)* |

**Decision** (revised 2026-09-04, see sync.c/sync.h): HSYNC is a timer-driven GPIO toggle, not a hardware OC output — Timer1 (CTC, 64.000 µs period) runs a compare-match ISR that toggles PC6. VSYNC (PC7) is *not* a second independent timer any more — it's derived from a 312-line counter incremented inside that same ISR, toggled at line 0 and line 156, so it always lands exactly on an HSYNC edge (an earlier version used a free-running Timer3 at 20.000 ms; even though individually exact, two unsynchronized timers can't guarantee an integer line count per frame — a real rolling-picture bug, not just a jitter one).

- **HSYNC must be accurate; VSYNC only needs to be roughly right.** A wobbly VSYNC edge shifts where the picture starts vertically — visually harmless within a wide tolerance. A wobbly HSYNC edge shifts *where each line's pixel burst starts horizontally* if anything downstream ever syncs to it, which shows up as visible jaggedness — so it gets the real work below; VSYNC just inherits whatever timing the shared ISR happens to have, no separate effort.
- Plain compare-match ISR toggles are **not** cycle-accurate: AVR interrupt response is a datasheet-documented 4+3=7 cycle minimum (Sec. 8.8.1; the 3 is the vector table's own `JMP`, confirmed via this project's compiled `avr-objdump` output) plus however long an in-flight instruction takes to finish — several hundred ns of real jitter is typical, not negligible at video timescales.
- Fixed via the technique the Uzebox AVR-console project uses: Timer1 runs **unprescaled** so `TCNT1` increments once per CPU cycle and clears to 0 the cycle after a CTC match — reading `TCNT1L` at ISR entry gives the *exact* elapsed cycle count since the true edge (all jitter, as one number), and the ISR burns exactly enough more cycles (a NOP sled entered via a computed `ijmp`, single-cycle resolution) to always reach the PC6 toggle at a fixed, constant total latency. Constant latency is invisible to the output — only the *variation* mattered. Implementation, full cycle accounting (disassembly-verified against the real compiled ISR, not just hand-derived), and the "not yet bench-confirmed" caveat live in `sync.c`.
- This still leaves the *pixel-fetch* "wait for HSYNC" loop (Phase 6a/6b, not yet built) as an open question in its own right: it should poll the hardware compare flag/counter directly rather than sample this ISR-toggled pin, so pixel-burst timing doesn't depend on ISR latency at all, jitter-cancelled or not — see open-questions.md.

Timer setup:

| Sync | Timer | Mode | Prescale | OCR | Period |
|------|-------|------|----------|-----|--------|
| HSYNC | Timer1 | CTC (WGM=4, OCR1A) | CS12:CS11:CS10 = 001 (÷1, unprescaled → 16 MHz) | OCR1A = 1023 | 64.000 µs |
| VSYNC | (derived from HSYNC's own line counter, no separate timer) | — | — | toggle at line 0 and line 156 of 312 | ~19.968 ms ≈ 50.08 Hz |

(History: an earlier version of this table had the HSYNC row at ÷16 prescale — not a valid Timer1 CS12:CS11:CS10 option — with `OCR1A = 63999`, 1000x too large; fixed same-day to ÷8/`OCR1A=127`, then revised again same-day to unprescaled/`OCR1A=1023` once the jitter-cancellation scheme above required single-cycle `TCNT1` resolution. The independent-Timer3-VSYNC row was removed for the phase-lock reason above.)

312 lines × 64 µs = 19.968 ms/frame ≈ 50.08 Hz, not exactly 50.000 Hz — real broadcast PAL gets 50.000 Hz via 312.5 lines over two interlaced fields, which this project isn't attempting (CLAUDE.md's target is non-interlaced, "PAL timing" in the loose sense already used throughout memory-map.md's 200-active + 112-blank line count). VSYNC position within the frame (which of the 312 lines carries it) is set by firmware counting HSYNC interrupts, per PAL: 25 frames/s, 312 lines per frame (26.25 ms), active lines 2–201 after the VSYNC line. Line numbering and the exact VSYNC line index are finalized in Phase 6b; the plan's 200 active + 112 blank lines total 312, consistent with PAL.

## Alternate-function conflicts and resolutions

| Pins | Alt function | Resolution |
|------|--------------|------------|
| PC2–PC5 (A10–A13) | JTAG TCK/TMS/TDO/TDI | JTAG disabled: HIGH fuse JTAGEN=**1** (unprogrammed; 0x99→0xD9 — JTAGEN is active-low, see Fuse settings note below). With the fuse actually unprogrammed the TAP controller is held in reset from power-up, so PC2–PC5 are guaranteed normal port pins with no software involvement needed. Programming via ISP only. `main.c` still writes `MCUCR.JTD=1` as extra belt-and-braces, though note it's a single write — the datasheet requires writing the bit twice within 4 cycles for a *software* JTD change to reliably take effect, so this line should not be relied on alone; the fuse is the real protection. |
| PB4/PB5/PB7 (RCLK/SER/SRCLK) | ISP SS/MOSI/SCK | See ISP section. |
| PB1 | CLKO | free since 2026-09-16 (was D1). CKOUT fuse unprogrammed → normal I/O. |
| PD0/PD1 | USART0 RXD/TXD | intended use, no conflict. PD0 additionally carries the power-up boot-mode strap (external ~3.3k to GND = autoboot from flash-embedded stage1) — sampled once before `usart_init()`, does not disturb USART0 RXD afterward. See the PD0 row above. |
| PD2/PD3 | USART1/INT0/INT1 | USART1, INT0, INT1 unused. |
| PC0/PC1 | TWI SCL/SDA | TWI unused. |
| PC6/PC7 | TOSC1/TOSC2 | RTC osc unused (external clock on XTAL1/2). |
| PB0/PB2/PB3 | T0/INT2/OC0A/OC0B | Timer0 unused, INT2 unused. |

## ISP / programming

JTAG is off by fuse, so **ISP is the only programming path**. ISP pins are RCLK (PB4/SS), SER (PB5/MOSI), *(free)* (PB6/MISO), SRCLK (PB7/SCK), RESET, GND — three of them also drive the 74HC595 (2026-09-16, was the 74LS373 data bus; PB6/MISO is no longer used for anything, the 595 has no data-out pin).

- During normal operation the 595's `/OE` is gated by `_RD`/mode hardware, so it only drives when the 1284p is actually serving a byte. While the Z80 is in reset (power-up state) `_RD` is pulled high and the 595 is tri-stated; an ISP session then has full MISO access (moot now anyway, since MISO/PB6 carries no board signal).
- ISP header: 6×2 on DIP pins 5 (SS), 6 (MOSI), 7 (MISO), 8 (SCK), 9 (RESET), 11 (GND). Note RCLK/SER/SRCLK = PB4/PB5/PB7 = DIP 5,6,8, so the ISP header still shares pins with the serial data-bus interface — fine while the Z80 is held in reset and the 595 `/OE` is deasserted. An ISP session driving SCK/MOSI will shift arbitrary bits into the 595's *input* stage, but `avrdude` never pulses `RCLK` (PB4/SS is used only as the ISP chip-select, not toggled as a clock), so those bits never reach the 595's *output* register — the Z80 data bus stays inert throughout programming regardless.
- For in-system reprogramming of the finished board, the monitor gets a `reprogram` command: it holds Z80 _RESET, guarantees the 595 is tri-stated (idle state already does this), and the host runs avrdude over ISP.

## Fuse settings (16 MHz external clock)

> **Corrected 2026-09-01** — the previous values here (LOW 0xF0/HIGH
> 0x91/EXT 0x0F) were wrong, verified by reading the actual datasheet
> tables rather than assuming fuse-bit polarity. All three mistakes traced
> to `hardware/datasheets/atmega1284p-datasheet.pdf`: (1) the PDF contains
> a second, spurious "Fuse High Byte" table (its Table 28-7, with
> `RSTDISBL`/`DWEN`/`BODLEVEL` fields) that describes a different,
> debugWIRE-style AVR part, not the 1284P — the correct HIGH-byte table
> for this chip is **Table 28-6** (`OCDEN`/`JTAGEN`/`SPIEN`/`WDTON`/
> `EESAVE`/`BOOTSZ`/`BOOTRST`), confirmed against JTAG being a documented
> 1284P feature (TCK/TMS/TDO/TDI on PC2–PC5) and DWEN never appearing
> anywhere else for this part. A previous edit of this doc had pulled the
> LOW byte's bit layout from that same wrong table, mislabeling bit 7 as
> `RSTDISBL` — the LOW byte's actual bit 7 (Table 28-8) is `CKDIV8`.
> (2) The old LOW value encoded SUT[1:0]=11, which Table 10-15 marks
> **"Reserved"**, not the intended 00 (6 CK, BOD-enabled start-up).
> (3) `JTAGEN` is **active-low**: Table 28-6 states its default value is
> "0 (programmed, JTAG **enabled**)", confirmed by the MCUCR/JTD register
> description ("the JTAG interface is enabled if the JTAGEN Fuse is
> programmed"). So `JTAGEN=0` (the old HIGH byte) leaves JTAG **on** —
> the opposite of this design's stated intent. Disabling it via fuse
> requires `JTAGEN=1` (unprogrammed). (4) The old EXT value encoded
> BODLEVEL[2:0]=111, which Table 29-8 lists as **"BOD Disabled"**, not
> 2.7 V — 2.7 V (typ) is code 101.

LOW fuse bit layout (Table 28-8, MSB→LSB): CKDIV8, CKOUT, SUT1, SUT0, CKSEL3, CKSEL2, CKSEL1, CKSEL0.
HIGH fuse bit layout (Table 28-6, MSB→LSB): OCDEN, JTAGEN, SPIEN, WDTON, EESAVE, BOOTSZ1, BOOTSZ0, BOOTRST.
EXT fuse bit layout (Table 28-5, MSB→LSB): — (bits 7–3 unimplemented, read 0), BODLEVEL2, BODLEVEL1, BODLEVEL0.

External clock 0–20 MHz ⇒ CKSEL[3:0] = 0000 (datasheet Table 10-14). SUT = 00 (6 CK start-up + 14 CK, BOD enabled — Table 10-15; SUT=11 is reserved, not usable). CKDIV8, CKOUT unprogrammed (no /8 division, no CLKO output). JTAGEN unprogrammed (1) to actually disable JTAG — see note above. BODLEVEL = 101 for 2.7 V typ (Table 29-8).

avrdude convention (1 = unprogrammed):

| Byte | Value | Detail |
|------|-------|--------|
| LOW | **0xC0** | 1100 0000: CKDIV8=1(off) CKOUT=1(off) SUT=00 CKSEL=0000 |
| HIGH | **0xD9** | 1101 1001: OCDEN=1(off) JTAGEN=**1**(JTAG **disabled**) SPIEN=0(ISP enabled) WDTON=1 EESAVE=1 BOOTSZ=00 BOOTRST=1 — identical to the factory-default HIGH byte (0x99) with only JTAGEN flipped |
| EXT | **0x05** | 000 0101: BODLEVEL=101 → 2.7 V typ |

```
avrdude -p m1284p -c <prog> -U lfuse:w:0xC0:m -U hfuse:w:0xD9:m -U efuse:w:0x05:m
```

## Power / clock pins (DIP-40)

| Pin | Signal | Connection |
|-----|--------|------------|
| 10 | VCC | 5 V + 100 nF to GND (plus bulk 10–47 µF near the rail) |
| 30 | AVCC | tie to VCC (ADC unused; still must be powered per datasheet 5.2.10) + 100 nF |
| 11, 31 | GND | 0 V |
| 32 | AREF | GND (ADC unused) |
| 12 | XTAL2 | oscillator CLKOUT in external-clock mode |
| 13 | XTAL1 | external clock input, 16 MHz |
| 9 | RESET | 10 kΩ pull-up to VCC, reset button to GND |

Note: in external-clock mode the 16 MHz clock is fed to XTAL1 (pin 13) and XTAL2 (pin 12) is the inverting-amp output. Confirm direction on the scope in Phase 1 before trusting it; if the datasheet's "input" pin differs from practice at 16 MHz, the 74LS74 divide-by-2 (Z80 clock) is a separate path and the machine can't be damaged — the 1284p just won't run until the clock is on the correct pin.

## Generated header

`firmware/avr-1284p/src/pins.h` must match this table. Regenerate/edit it whenever this document changes.
