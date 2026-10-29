# Replacing the 74LS373 with a 74HC595 — plan, analysis, and status

`74HC595.md` (user's original brainstorm) proposed swapping the 74LS373
(parallel latch presenting the AVR's byte to the Z80 data bus) for a
74HC595 (serial-in, parallel-out shift register), to free up AVR GPIO
pins at the cost of needing a serial byte transfer instead of a single
parallel write. This document is the feasibility analysis (2026-09-16)
plus the implementation done immediately after it was approved.

**Status: firmware implemented, disassembly-verified, and confirmed
working on real hardware** — the breadboard 373 was swapped for a
74HC595 and the board boots/runs correctly. The pinout used (see "Real
gotchas" below) was not checked against a local datasheet PDF before
wiring; it worked as wired, but that gap is still worth closing before
relying on it further (e.g. before a PCB layout).

## The one fact that makes this viable at all

**The video-fetch burst — the only genuinely hard-real-time path in
this whole design (8 AVR cycles / 500ns per byte, cycle-exact) — never
touches the data latch at all.** Confirmed by grep:
`firmware/avr-1284p/src/video_fetch.c` and `sync.c` have **zero**
references to the data-bus port. During a video steal, the AVR only
drives the *address* lines; the pixel byte flows from the SRAM's own
output pins straight into the 74LS166 shift register, completely
bypassing the latch/AVR data-bus path (`docs/architecture.md`'s own
block diagram: SRAM I/O0-I/O7 feeds both the 74LS166 and the shared bus
independently).

The **only** two things that actually use the data latch are:
1. **ROM emulation** (`rom_emu.c`, now `databus_send(rom[addr &
   rom_mask]);`) — and this file's own header comment says outright:
   "the timing is NOT a hard deadline: `_WAIT` can be held low
   indefinitely (static RAM, no refresh hazard), so the Z80 just stalls
   a little longer if this loop is slow — it never breaks correctness."
2. **Virtual IO reads** (`docs/io-map.md`), which the docs already
   accept "up to ~20ms worst-case latency (expected, not a bug)".

So a ~25x slower byte-presentation path (worked out below) costs real
boot-time and IO-latency performance, but **zero correctness risk** and
**zero impact on video generation** — this swap cannot break the one
thing in this design that actually has a hard deadline.

## Does hardware SPI exist, and is it worth using over bit-banging?

**Yes, and yes.** `docs/pin-map.md` already documented that the old
D4-D7 pins (`PB4`-`PB7`) *are* the ATmega1284P's hardware SPI pins
(`OC0B/SS`, `MOSI`, `MISO`, `SCK`) — previously just used as plain GPIO
for the parallel data bus. The hardware SPI peripheral itself was
**completely unused** before this change — the SD card interface is
bit-banged through the 8255 (`docs/wiring.md`), not the AVR's own
SPI — so there was no conflict to resolve.

Rough per-byte cost, worked out (not measured on hardware — flag this
plainly):

| Approach | Cost | vs. old (1 cycle) |
|---|---|---|
| Old (373, parallel `OUT`) | 1 cycle (62.5ns) | — |
| Hardware SPI (`SPDR=byte`, poll `SPIF`, pulse RCLK) — **chosen** | ~20-25 cycles (~1.4µs): 1 (write) + ~16 (8 bits at the fastest `SPI2X`/÷2 divider, 2 cycles/bit) + ~4-8 (RCLK pulse) | ~25x slower |
| Bit-banged (manual SER/SRCLK toggling, no SPI hardware) | ~28-36 cycles (~2µs): ~3-4 cycles/bit ×8 + RCLK pulse | ~30-35x slower, and hand-rolled |

Hardware SPI isn't dramatically faster than a tightly-written bit-bang
loop here (both land in the same "tens of cycles" ballpark) — its real
advantage is **simpler, more maintainable code using hardware that's
otherwise sitting idle**, matching this project's own already-stated
preference (`rom_emu.c`'s header) for plain, obviously-correct code over
hand-tuned assembly on a path with no hard deadline. Chose hardware SPI
over bit-banging for that reason, not because it's dramatically faster.

## What this actually buys: GPIO

Before: `D0-D7` = 8 AVR pins (all of `PORTB`), against a project that had
hit **"32 of 32 GPIOs allocated, zero spare pins"** (`pin-map.md`'s own
header). A 74HC595 interface only needs: `MOSI`(`SER`)+`SCK`(`SRCLK`)
(the hardware SPI pins, already there) + one more GPIO for `RCLK`
(latch — not part of the SPI signal set, must be pulsed manually after
the shift completes) = **3 pins total, freeing 5** (`PB0`-`PB3` plus
`PB6`(`MISO`) — `SS`(`PB4`) is reused as `RCLK` rather than freed; `MISO`
has nothing to receive, the 595 has no data-out line worth reading).
Given this project has already hit real GPIO-scarcity walls (the
V20-swap feasibility pass earlier the same session found the same
"zero spare pins" constraint blocking that exploration), freeing 5 pins
is a genuine, meaningful benefit — the actual point of this change, not
just a curiosity.

## What carries over unchanged at the gate level

The 373's key property — an `OE̅` pin that tri-states the outputs
*combinationally*, independent of any clocked/AVR-speed behavior, which
is *why* CLAUDE.md chose a latch in the first place ("the databus will
go tristate immediately when `_RD` goes high, rather than much longer
if the 1284p tried to do it") — **carries over exactly** to the 595: its
own `/OE` pin does the identical job, and it's not gated by the
shift/storage clocking at all. `gate-equations.md` §4's existing
`_OE = NAND(mode_pin, NOT(_RD))` equation drives the 595's `/OE`
directly, unchanged. This is a straight swap, not a chip-count change
(DIP-20 373 → DIP-16 595, same gate network, see `gate-equations.md`'s
chip budget table).

## What was implemented (2026-09-16)

- `firmware/avr-1284p/src/pins.h`: `DATA_SPI_PORT`/`DATA_SPI_DDR`/
  `BIT_MOSI`(`PB5`)/`BIT_SCK`(`PB7`)/`BIT_RCLK`(`PB4`) replace
  `DATA_PORT`/`DATA_DDR`/`DATA_MASK`.
- `firmware/avr-1284p/src/databus.h`/`databus.c` (new): `databus_init()`
  (SPI master setup, `SPI2X`+`SPR1:0=00` = fastest available rate,
  `RCLK` idle-low) and `databus_send(uint8_t b)` (`SPDR=b` → poll
  `SPIF` → pulse `RCLK`).
- `firmware/avr-1284p/src/main.c`: `databus_init()` replaces the old
  `DATA_DDR = DATA_MASK; DATA_PORT = 0;`.
- `firmware/avr-1284p/src/rom_emu.c`: `databus_send(rom[addr &
  rom_mask]);` replaces the direct `DATA_PORT = ...` write.
- Build verified clean (`make clean && make all`, zero warnings).
  Disassembly-verified both new functions match the intended design
  exactly (see `docs/bring-up-log.md`'s dated entry for the exact
  opcodes checked).
- Documentation updated to match: `docs/pin-map.md` (pin table, freed
  GPIO count), `docs/gate-equations.md` §4, `docs/wiring.md` (74HC595
  pinout/wiring section — originally landed in `373-gates-sram-
  wiring.md`, since consolidated into `docs/wiring.md` along with every
  other chip's wiring), `docs/architecture.md` (block diagram, chip
  list), plus terminology fixes in `docs/io-map.md`,
  `docs/open-questions.md`.

## Update (2026-09-16, same day): bench measurement + call/ret removal

Bench logic-analyzer measurement (with the real 595 wired in) showed
`_MREQ` low ~5us during ROM emulation, up from the previously-measured
2-2.5us with the 373. Worked out from the disassembly that this is
expected -- dominated by the SPI shift's own 1us floor at this
crystal's fastest available bit rate (`SPI2X`+÷2 = 8MHz), not a bug.
One real, avoidable contributor found in the same analysis: a `call`/
`ret` boundary that didn't exist in the old single-instruction 373
write. Fixed by moving `databus_send()` into `databus.h` as `static
inline` (databus.c now only defines `databus_init()`) -- disassembly-
confirmed the compiler folds it directly into `rom_emu_run()`'s poll
loop, no separate `<databus_send>` symbol left at all, `.text` even
shrank slightly.

**Bench re-measured: 3.6-3.75us**, better than the ~4.5us predicted from
the `call`/`ret` boundary alone. Comparing the two disassemblies
directly explains why: inlining also let the compiler keep the MREQ/RD
bit values in registers across what used to be the call boundary,
eliminating a spill-to-stack-and-reload that existed only to survive
that boundary (4 more instructions @ 2 cycles), plus collapsing a
couple of address-computation instructions. Real total savings ~16
cycles (~1us), not the ~8 cycles counted from the call/ret alone. See
`docs/bring-up-log.md`'s three dated entries for the full detail.

## Real gotchas to verify before wiring (not yet checked against a real datasheet)

- **AVR's own SPI-master auto-downgrade hazard**: if the AVR's `SS` pin
  (`PB4`) is left as an *input* and something drives it low while the
  AVR is SPI master, hardware silently switches the peripheral to slave
  mode. Not an issue here — `databus_init()` configures `PB4` as an
  output unconditionally (same reasoning the old parallel `DATA_DDR`
  write already relied on) — but worth being deliberate about, not just
  relying on the coincidence.
- **`SRCLR̅`** (595's shift-register clear pin, no 373 equivalent) needs
  tying inactive (high) — a real, new wiring detail, not a functional
  concern. Documented in `docs/wiring.md`'s 74HC595 section.
- **Exact 595 pin numbers** (which physical pin is `SER`/`SRCLK`/`RCLK`/
  `/OE`/`SRCLR̅`/`Q0-7`) — the pinout now written into
  `docs/wiring.md` is standard/textbook, **not yet checked
  against a real collected datasheet** (unlike the 373's own
  `hardware/datasheets/sn74ls373.pdf`) — needs one before physical
  wiring, matching this project's own standing practice (nearly every
  chip in `docs/` has a story about a wrong assumed pinout caught only
  on the bench).
- **Logic-family mixing (LS→HC)**: checked, not a real concern for this
  specific data-flow direction — the 595's inputs are all AVR-driven
  (CMOS-to-CMOS, compatible), and its outputs (read by the Z80) swing
  close to rail-to-rail, well within the Z80's input margins. Still
  worth a real datasheet check before committing, per the same standing
  practice.

## Bottom line

Worth pursuing because the GPIO headroom matters for other things
already planned (per this project's own recent GPIO-scarcity findings)
— the speed cost lands entirely in two paths this project has already,
explicitly, decided don't need to be fast (ROM emulation's own header
comment, and IO virtualization's documented latency tolerance), and the
one path that truly can't tolerate slowdown (video generation) never
touches this hardware at all. The remaining work before wiring anything
physical is a handful of datasheet-verification items above, not a
redesign — the firmware side is done and verified.
