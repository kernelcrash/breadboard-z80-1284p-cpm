# Wiring — All Chips

Physical wiring reference for the whole board — every chip, every pin.
Each section is a one-line summary of what the chip does, followed by
its pin connections. Boolean logic derivations are in
`gate-equations.md`; bring-up history is in `bring-up-log.md`.

**Roles, in one line each:**
- **Z80** — the CPU. Runs CP/M and every program on it.
- **ATmega1284P (AVR)** — a service processor, not a CPU peer: emulates
  the boot ROM (serving bytes from its own RAM over the 74HC595),
  generates the video address stream + HSYNC/VSYNC during the display's
  active lines, and controls the Z80's `_RESET`/`_BUSRQ`/`_WAIT`-release
  lines. Never executes Z80 code and isn't visible to Z80 software.
- **74HC595** — shift register that presents the AVR's ROM byte on the
  Z80 data bus (serial in from the AVR, parallel out to the bus).
- **74LS74A** (1 chip, 2 flip-flops) — FF#1: divides the 16MHz master
  clock by 2 for the Z80's 8MHz CPU clock. FF#2: generates `_WAIT`
  during a ROM-emulation read.
- **74LS00 #1** (quad NAND, all 4 gates used) — computes the 74HC595's
  and SRAM's output-enable signals.
- **74LS00 #2** (quad NAND, 3 of 4 gates used) — computes the memory
  bank-switch bit (`A16`) for CP/M's banked SRAM, plus (gate 4, wired as
  an inverter) the 8255's `RESET` line.
- **SRAM (TC551001BPL, 128K)** — the Z80's RAM; `A16` (driven by 74LS00
  #2) selects which 64K half is currently mapped in.
- **74LS166A** — parallel-in/serial-out shift register that turns a
  byte fetched from SRAM into the serial pixel stream during a video
  burst.
- **74LS138** — 3-to-8 IO port decoder (MSX-style), currently used only
  to select the 8255; 7 of 8 outputs spare for future IO devices.
- **8255 PPI** — general-purpose IO the Z80 drives directly: the
  mode/bank control bits, the keyboard matrix scan, and the SD card's
  bit-banged SPI all live here.
- **74LS145** — BCD-to-decimal decoder that drives the keyboard
  matrix's row-select lines from the 8255.
- **microSD breakout module** — mass storage for CP/M, bit-banged SPI
  through the 8255.
- **Composite video driver** (discrete, one BC547) — mixes `HSYNC`/
  `VSYNC` into composite sync and combines it with the 74LS166A's pixel
  stream into a single black-and-white composite video signal, out to
  an RCA jack.

---

## Z80 (DIP-40)

The CPU. Standard pinout — nothing project-specific about its own pin
assignment. Lines this design actually uses beyond the address/data bus:

| Z80 pin | Wired to |
|---------|----------|
| `A0`-`A15` | shared address bus (AVR reads `A0`-`A13` during ROM emulation and drives them during a video burst; `A14`/`A15` pulled high → video RAM at `0xC000`-`0xFFFF`) |
| `D0`-`D7` | shared data bus (74HC595 `Q0`-`Q7`, SRAM `I/O1`-`I/O8`) |
| `_MREQ` | SRAM `CE1`; AVR senses it during ROM emulation; pulled up |
| `_RD` | 74LS74A FF#2 `D2`; 74LS00 #1 gate 1 input; AVR senses it during ROM emulation; pulled up |
| `_WR` | SRAM `R/W`, direct wire, no gate; pulled up |
| `_IORQ` | 74LS138 enable pin; pulled up |
| `_WAIT` | 74LS74A FF#2 `Q2` |
| `_BUSRQ` | AVR-driven (video burst); pulled up |
| `_BUSACK` | 74LS00 #2 gate 2 input |
| `_RESET` | AVR PD2 (via the shared `POR` net, see below) — that net is a **pull-down**, not a pull-up, deliberately (see "Power-on reset" below) |
| `_INT`, `_NMI` | pulled up to VCC, unused, populated so they don't float |

## ATmega1284P (AVR, DIP-40)

Every GPIO pin, in physical DIP order. JTAG is fuse-disabled, so
`PC2`-`PC5` are plain GPIO despite their alt-function column.

| DIP | Pin | Signal in this design | Dir | Notes |
|-----|-----|------------------------|-----|-------|
| 1 | `PB0` | *(free)* | — | |
| 2 | `PB1` | *(free)* | — | |
| 3 | `PB2` | *(free)* | — | |
| 4 | `PB3` | *(free)* | — | |
| 5 | `PB4` | `RCLK` → 74HC595 `ST_CP` | out | latches the shifted byte |
| 6 | `PB5` | `SER` → 74HC595 `DS` | out | hardware SPI `MOSI` |
| 7 | `PB6` | `SH_LD` (Timer3/`OC3A`) → 74LS166A pin 15 | out | hardware-generated, phase-locked to the video-fetch burst (sync.c); idles high-Z outside each burst (`shld_test.c`), not driven by software `cbi`/`sbi` |
| 8 | `PB7` | `SRCLK` → 74HC595 `SH_CP` | out | hardware SPI `SCK` |
| 9 | `RESET` | AVR's own reset | in | pulled up internally, no external wiring beyond the ISP header |
| 10 | `VCC` | +5V | — | |
| 11 | `GND` | ground | — | |
| 12 | `XTAL2` | 16MHz oscillator | — | |
| 13 | `XTAL1` | 16MHz oscillator | — | |
| 14 | `PD0` | UART `RXD` (host) | in | USART0; also the power-up boot-mode strap (external ~3.3k pull-down = autoboot from flash `stage1.bin`) |
| 15 | `PD1` | UART `TXD` (host) | out | USART0 |
| 16 | `PD2` | Z80 `_RESET` | out | drives the Z80 low at power-up; also feeds the shared `POR` net |
| 17 | `PD3` | `wait_rel` | out | pulses 74LS74A FF#2's `/PRE2` to release `_WAIT` |
| 18 | `PD4` | Z80 `_MREQ` | bidir | in: senses it during ROM emulation; out: drives it during a video burst |
| 19 | `PD5` | *(free)* | — | was `SH_LD` until 2026-09-21; moved to `PB6` (Timer3/`OC3A`, hardware-generated) |
| 20 | `PD6` | Z80 `_RD` | bidir | in: senses it during ROM emulation; out: drives it during a video burst |
| 21 | `PD7` | Z80 `_BUSRQ` | out | asserted during a video burst |
| 22 | `PC0` | Z80 `A8` | bidir | in: ROM emulation/IO; out: video fetch address |
| 23 | `PC1` | Z80 `A9` | bidir | " |
| 24 | `PC2` | Z80 `A10` | bidir | " |
| 25 | `PC3` | Z80 `A11` | bidir | " |
| 26 | `PC4` | Z80 `A12` | bidir | " |
| 27 | `PC5` | Z80 `A13` | bidir | " |
| 28 | `PC6` | `HSYNC` | out | timer-driven GPIO toggle, 64µs period |
| 29 | `PC7` | `VSYNC` | out | derived from the same line counter as HSYNC |
| 30 | `AVCC` | +5V | — | |
| 31 | `GND` | ground | — | |
| 32 | `AREF` | unused | — | |
| 33 | `PA7` | Z80 `A7` | bidir | " |
| 34 | `PA6` | Z80 `A6` | bidir | " |
| 35 | `PA5` | Z80 `A5` | bidir | " |
| 36 | `PA4` | Z80 `A4` | bidir | " |
| 37 | `PA3` | Z80 `A3` | bidir | " |
| 38 | `PA2` | Z80 `A2` | bidir | " |
| 39 | `PA1` | Z80 `A1` | bidir | " |
| 40 | `PA0` | Z80 `A0` | bidir | " |

`A0`-`A13` (`PA0`-`PA7`, `PC0`-`PC5`) are inputs while the AVR is
sensing a ROM-emulation read or waiting, and outputs only while it's
driving the address bus itself during a video burst — never both at
once.

## 74HC595 — data latch (DIP-16)

```
 1   Q1  → Z80/SRAM D1 ─────┤1                    16├────────── VCC
 2   Q2  → Z80/SRAM D2 ─────┤2                    15├────────── Q0 → Z80/SRAM D0
 3   Q3  → Z80/SRAM D3 ─────┤3                    14├────────── DS  ← AVR PB5 (SER/MOSI)
 4   Q4  → Z80/SRAM D4 ─────┤4       74HC595      13├────────── OE̅  → 595_OE (74LS00 #1 gate 4)
 5   Q5  → Z80/SRAM D5 ─────┤5                    12├────────── ST_CP ← AVR PB4 (RCLK)
 6   Q6  → Z80/SRAM D6 ─────┤6                    11├────────── SH_CP ← AVR PB7 (SRCLK/SCK)
 7   Q7  → Z80/SRAM D7 ─────┤7                    10├────────── MR̅ (SRCLR̅) → VCC (tied high, unused)
 8   GND → GND ─────────────┤8                     9├────────── Q7' (serial out, unused)
```
Note the non-contiguous `Q` pin order: `Q0` is pin 15, then `Q1`-`Q7`
are pins 1-7. `DS`/`SH_CP` are driven by the AVR's hardware SPI
peripheral (8 clocks/byte, MSB first); `ST_CP` is a plain GPIO pulsed
once per byte after the shift completes. `MR̅` tied high (unused,
shift-register clear never needed). Pinout is textbook/standard, not
yet checked against a locally-collected datasheet — confirm before
any rewiring.

## 74LS74A — clock ÷2 + `_WAIT` generator (DIP-14)

```
 1  /CLR1 → VCC  ──────────┤1                         14├────────── VCC
 2   D1   ← Q1' (pin 6) ───┤2                         13├────────── POR   /CLR2
 3  CLK1  → 16MHz ─────────┤3                         12├────────── _RD   D2
 4  /PRE1 → VCC  ──────────┤4       74LS74A           11├────────── 8MHz (pin5) CLK2
 5   Q1   → 8MHz ──────────┤5                         10├────────── wait_rel  /PRE2
 6   Q1'  → D1 (pin 2) ────┤6                          9├────────── _WAIT → Z80
 7   GND  → GND  ──────────┤7                          8├────────── unused Q2'
```
- **FF#1** (pins 1-6): `D1` wired to its own `Q1'` (pin 6→2) — the
  D-flip-flop-as-toggle trick, giving a 50%-duty 8MHz clock at `Q1`.
- **FF#2** (pins 8-13): `CLK2` = the same 8MHz (jumpered from pin 5);
  `D2` = `_RD` directly; `Q2` = `_WAIT` to the Z80; `/PRE2` = `wait_rel`
  (AVR PD3, active low, pulsed to force `_WAIT` released); `/CLR2` =
  the shared `POR` net (not VCC — see "Power-on reset" below).

## 74LS00 #1 — gate network (DIP-14, all 4 gates used)

```
 1  in  ← _RD ──────────────┤1                        14├────────── VCC
 2  in  ← _RD (tied to 1) ──┤2                        13├────────── in ← NOT(_RD) [pin 3, fanned out]
 3  out → NOT(_RD) ─────────┤3      74LS00            12├────────── in ← mode_pin (direct, not inverted)
 4  in  ← mode_pin ─────────┤4                        11├────────── 595_OE → 595 pin13 (OE̅)
 5  in  ← mode_pin (tied) ──┤5                        10├────────── in ← NOT(_RD) [pin 3, fanned out]
 6  out → NOT(mode_pin) ────┤6                         9├────────── in ← NOT(mode_pin) [pin 6]
 7  GND → GND ──────────────┤7                         8├────────── SRAM_OE → SRAM pin 24 (OE̅)
```
Gate 1 = `NOT(_RD)` (wired as inverter, both inputs tied). Gate 2 =
`NOT(mode_pin)` (same trick). Gate 3 = `SRAM_OE = NAND(NOT(mode_pin),
NOT(_RD))`, output on the *low* pin of the group (8, not 10 — this
chip's gates 3-4 are mirrored vs. gates 1-2). Gate 4 = `595_OE =
NAND(mode_pin, NOT(_RD))` — note `mode_pin` feeds this one **raw, not
inverted**, unlike gate 3; output likewise on the low pin (11, not 13).
Logic derivation: `gate-equations.md` §4/§5.

## SRAM — TC551001BPL-70L (DIP-32)

| Pin | Signal | Wired to |
|-----|--------|----------|
| 22 | `CE1` | Z80 `_MREQ` |
| 30 | `CE2` | VCC (tied active-high, single-chip design) |
| 24 | `OE̅` | 74LS00 #1 gate 3 (`SRAM_OE`) |
| 29 | `R/W` | Z80 `_WR`, direct wire, no gate |
| 2  | `A16` | 74LS00 #2 gate 2 output (bank-switch) |
| 12,11,10,9,8,7,6,5,4,3,31,28,27,26,25,23 | `A0`-`A15` (in that pin order) | shared address bus |
| 13-15,17-21 | `I/O1`-`I/O8` | shared data bus |

`OE̅`/`R/W` have no `_MREQ` term — SRAM's own `CE1` (already wired to
`_MREQ`) makes that redundant.

## 74LS166A — video shift register (DIP-16)

```
 1   SER (unused, tie LOW) ─┤1                  16├────────── VCC
 2   A ← SRAM I/O1 (D0, LSB)┤2                  15├────────── SH/LD ← AVR PB6 (Timer3/OC3A)
 3   B ← SRAM I/O2 (D1) ────┤3                  14├────────── H ← SRAM I/O8 (D7, MSB)
 4   C ← SRAM I/O3 (D2) ────┤4      74LS166A    13├────────── QH → composite video mixer
 5   D ← SRAM I/O4 (D3) ────┤5                  12├────────── G ← SRAM I/O7 (D6)
 6   CLK_INH → GND ─────────┤6                  11├────────── F ← SRAM I/O6 (D5)
 7   CLK ← 16MHz pixel clock┤7                  10├────────── E ← SRAM I/O5 (D4)
 8   GND → GND ─────────────┤8                   9├────────── CLR̅ → VCC (tied high, unused)
```
Parallel data inputs are **not contiguous**: `A`-`D` = pins 2-5, `E`-`H`
= pins 10,11,12,14 (`CLK_INH`/`CLK`/`GND`/`CLR̅` sit in between, pins
6-9) — easy to mis-wire by assuming a simple run of consecutive pins.
`SER` (pin 1, serial cascade input) tied low, unused — this design
only ever loads in parallel, never chains a second 166. `CLK` (pin 7)
= 16MHz pixel clock, one bit shifted out per pixel. `CLK_INH` (pin 6)
tied to GND permanently (the part has no separate "load" state beyond
`SH/LD` — holding this high would inhibit clocking outright, which
this design never wants). `SH/LD` (pin 15, active low) ← AVR `PB6`
(Timer3/`OC3A`, hardware Fast PWM, phase-locked to the video-fetch
burst — sync.c's `SHLD_TIMER3_PHASE`), idles high outside each burst
and pulses low once per byte to parallel-load the next byte from SRAM.
Not software-driven — no `cbi`/`sbi` in the loop generates this pulse;
the AVR only gates the pin's output driver on/off around each burst
(`DDRB6`, `shld_test.c`), it never toggles the pulse itself. `QH` (pin
13, serial output) → the
composite video mixing network, below. `CLR̅` (pin 9) tied to VCC
(inactive — never needs an async clear). No complementary output pin
on this part (pin 16 is plain VCC).

## Composite video driver — discrete, black & white (one BC547)

| Component | Value | Wired to |
|-----------|-------|----------|
| `D1` (1N4148) | — | cathode → `HSYNC`; anode → `SYNC_MIX` |
| `D2` (1N4148) | — | cathode → `VSYNC`; anode → `SYNC_MIX` |
| `R21` | 1k | `SYNC_MIX` → VCC (pull-up) |
| `R22` | 330R | `SYNC_MIX` → `Q1` base |
| `R23` | 500R | `Q1` base → GND |
| `R24` | 2.2k | `Q1` base → 74LS166A `QH` |
| `Q1` (BC547, NPN) | — | base per `R22`/`R23`/`R24`; collector → `R25`; emitter → `R26` and `C14`'s `+` lead |
| `R25` | 330R | `Q1` collector → VCC |
| `R26` | 220R | `Q1` emitter → GND |
| `C14` | 47uF electrolytic | `+` → `Q1` emitter; `-` → `COMPOSITE_OUT` |
| `J3` (RCA jack) | — | centre/signal → `COMPOSITE_OUT`; shield → GND |

`D1`/`D2` are a diode-OR sync mixer: whichever of `HSYNC`/`VSYNC` is
low pulls the shared `SYNC_MIX` node low, combining the two into one
composite-sync signal (`R21` holds it high when neither is active).
`Q1` sums that composite sync with the pixel stream (`QH`, via `R24`)
at its base and buffers the mixed result at its emitter, AC-coupled
through `C14` into the RCA jack as the finished composite video output.

## 74LS138 — IO port decode (DIP-16, MSX-style)

```
 1   A0 ← Z80 A3 ───────────┤1                        16├────────── VCC
 2   A1 ← Z80 A4 ───────────┤2                        15├────────── O0 (unused, spare)
 3   A2 ← Z80 A5 ───────────┤3                        14├────────── O1 (unused, spare)
 4   E (active low) ← _IORQ ┤4      74LS138           13├────────── O2 (unused, spare)
 5   E (active low) ← Z80 A6┤5                        12├────────── O3 (unused, spare)
 6   E (active HIGH)← Z80 A7┤6                        11├────────── O4 (unused, spare)
 7   O7 (unused, spare) ────┤7                        10├────────── O5 → 8255 _CS
```
Select lines = Z80 `A3`-`A5` (index = `A5·4+A4·2+A3·1`). Enables:
`_IORQ` + `A6` (active-low pair), `A7` (active-high) — asserted for
`0xA8`-`0xAF`. `O5` → 8255 `_CS`; every other output spare for future
IO devices.

## 8255 PPI (DIP-40)

```
                    8255A (DIP-40)
               PA3 ─┤1        40├─ PA4
               PA2 ─┤2        39├─ PA5
               PA1 ─┤3        38├─ PA6
    PA0 (mode_pin) ─┤4        37├─ PA7
               _RD ─┤5        36├─ _WR
               _CS ─┤6        35├─ RESET (active HIGH)
               GND ─┤7        34├─ D7
                A1 ─┤8        33├─ D6
                A0 ─┤9        32├─ D5
               PC7 ─┤10       31├─ D4
               PC6 ─┤11       30├─ D3
               PC5 ─┤12       29├─ D2
               PC4 ─┤13       28├─ D1
               PC0 ─┤14       27├─ D0
               PC1 ─┤15       26├─ VCC
               PC2 ─┤16       25├─ PB7
               PC3 ─┤17       24├─ PB6
               PB0 ─┤18       23├─ PB5
               PB1 ─┤19       22├─ PB4
               PB2 ─┤20       21├─ PB3
```
Port C's pin order is non-sequential: `PC7`-`PC4` on pins 10-13, then
`PC0`-`PC3` on pins 14-17.

| Port pin | Signal | Direction | Notes |
|----------|--------|-----------|-------|
| `PA0` (`mode_pin`) | ROM/SRAM-exec select | out | pulled down externally; feeds 74LS00 #1 gates 2/4 directly |
| `PA1` (`bank`) | CP/M memory bank select | out | pulled down externally; feeds 74LS00 #2 gate 1 |
| `PA2` | SD `CS` | out | shares Port A with `mode_pin`/`bank` — every write must preserve those bits via a RAM shadow copy |
| `PA3` | SD `SCK` | out | idles low (SPI mode 0) |
| `PA4` | SD `MOSI` | out | |
| `PA5`-`PA7` | free | — | |
| `PC0`-`PC3` | keyboard row-select → 74LS145 `A`-`D` | out | control word `$8A` (Port C lower = output) |
| `PC4`-`PC6` | free | in | |
| `PC7` | SD `MISO` | in, pulled up 10k to +5V | bit 7 specifically lets `spi_xfer` shift it into carry via one `RLA` |
| `PB0`-`PB7` | keyboard columns | in, pulled up | |
| `_CS` (pin 6) | 74LS138 `O5` | — | address-qualified (`0xA8`-`0xAF`), not a bare `_IORQ` wire |
| `RESET` (pin 35, active HIGH) | 74LS00 #2 gate 4 output (wired as inverter, `NOT(POR)`) | — | |
| `A0`,`A1` (pins 9,8) | Z80 `A0`,`A1` | — | internal register select |
| `_RD`,`_WR` (pins 5,36) | Z80 `_RD`,`_WR` | — | direct |
| data bus (pins 27-34) | shared Z80/SRAM/595 data bus | — | |

## 74LS145 — keyboard row decoder (DIP-16)

```
              74LS145
        Q0 ──┤1        16├── VCC
        Q1 ──┤2        15├── D (row select bit 3, MSB) ← 8255 PC3
        Q2 ──┤3        14├── C (row select bit 2)      ← 8255 PC2
        Q3 ──┤4        13├── B (row select bit 1)      ← 8255 PC1
        Q4 ──┤5        12├── A (row select bit 0, LSB) ← 8255 PC0
        Q5 ──┤6        11├── Q9
        Q6 ──┤7        10├── Q8
       GND ──┤8         9├── Q7
```
`Q0`-`Q9` (active-low, open-collector, no pull-up needed) → keyboard
matrix rows 0-9 (rows 9-10 don't exist on this keyboard; `Q9` unused).
Columns (`PB0`-`PB7`) need external pull-ups (4.7k-10k to VCC), rows
don't. Key map (unshifted, row/col → symbol) is in `gate-equations.md`'s
own keyboard section / `cpm-plan.md` §5 — not duplicated here.

## 74LS00 #2 — memory bank-switch gate + 8255 RESET inverter (DIP-14, 3 of 4 gates used)

A **second, separate** 74LS00 chip from #1 above. Gate 4 is wired as a
plain inverter (both inputs tied together) generating the 8255's
`RESET` signal.

| Pin | Signal | Wired to |
|-----|--------|----------|
| 1 | Gate 1 input A (`bank`) | 8255 `PA1`, pulled down 4.7k-10k to GND |
| 2 | Gate 1 input B (`A15`) | Z80 `A15` directly |
| 3→4 | Gate 1 output → Gate 2 input A (`X = NAND(bank, A15)`) | jumpered |
| 5 | Gate 2 input B | Z80 `_BUSACK` directly (not `_BUSRQ` — `_BUSACK` is the Z80's own confirmation it released the bus) |
| 6 | Gate 2 output (`A16 = NAND(X, _BUSACK)`) | SRAM pin 2 (`A16`) |
| 9,10 | Gate 3, unused | tie both inputs LOW; output (pin 8) left disconnected |
| 12,13→11 | Gate 4, wired as inverter (`8255 RESET = NOT(POR)`) | inputs 12+13 tied to the `POR` net; output (pin 11) → 8255 `RESET` pin |

## microSD breakout module

Assumes a common 5V-tolerant module with onboard 3.3V regulator/level
shifting (`GND`/`VCC`/`MISO`/`MOSI`/`SCK`/`CS`) — wire `VCC` to +5V,
logic pins straight to the 8255 pins listed above. Bit-banged SPI mode
0, no dedicated SPI hardware chip. Full init/read/write command
sequence and known limitations (SDHC/SDXC only, no CRC checking): see
`bring-up-log.md` Phase 11, or `cpm-plan.md` §6 for the summary.

## Power-on reset (`POR`)

Shared net: a pull-down resistor (~10k to GND), feeding 74LS74A `_CLR2`
(FF#2), 74LS00 #2 gate 4 (→ 8255 `RESET`, see above), and the AVR's own
PD2 (Z80 `_RESET`) — one shared power-on-reset line for all three.

## Pull-up / pull-down summary

| Net | Resistor | Reason |
|-----|----------|--------|
| `_WR`, `_MREQ`, `_RD`, `_IORQ` | 4.7k-10k to VCC | never driven by the AVR outside a burst/ROM-emulation read, and tri-stated by the Z80 itself whenever `_BUSACK` is granted; must idle high rather than float |
| `_BUSRQ` | 4.7k-10k to VCC | Z80 input, only ever driven by the AVR (asserted during a video burst); must idle high (not requested) the rest of the time |
| `A14`, `A15` | 4.7k-10k to VCC | places video RAM at `0xC000`-`0xFFFF` |
| `mode_pin`, `bank` (8255 port pins) | 4.7k-10k to GND | no internal pull-up on 8255 ports; sets the ROM-mode/bank-0 power-on default |
| `_INT`, `_NMI` | 4.7k-10k to VCC | Z80 inputs, unused, populated so they don't float |
| `POR` net (incl. `_RESET`) | ~10k to GND | a **pull-down**, not a pull-up — see above; keeps the Z80/8255/FF#2 in reset by default at cold power-up, before the AVR's firmware drives `PD2` |
| keyboard columns (`PB0`-`PB7`) | 4.7k-10k to VCC, one per column | |
| SD `MISO` | 10k to +5V | card only drives it while `CS` is asserted; floats otherwise |

## Power / decoupling

100nF ceramic cap from VCC to GND right at every chip's own power pins
(14-, 16-, 32-, and 40-pin parts alike) — breadboards ring badly at
these speeds.

Also add a few 1000uF or larger electrlytics around the breadboards especially where power enters the board
and around larger chips.

