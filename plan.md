# Z80 + ATmega1284p Breadboard Computer — Build Plan

Source spec: CLAUDE.md. This plan breaks the build into phases, each
independently testable on the breadboard before moving to the next, so that
a failure is always isolated to the thing most recently added.

## Architecture recap

- **Clock**: 16MHz oscillator feeds the ATmega1284p directly (external-clock
  fuse bits, not external-crystal) and a 74LS74 divide-by-2 toggle circuit
  produces the Z80's 8MHz clock.
- **Data bus**: one 1284p 8-bit GPIO port → 74LS373 latch → Z80 D0–D7. This
  port is **always an output** on the AVR side — the design never needs to
  read the Z80's data bus (SRAM writes are pure hardware, and UART "writes"
  ride the address bus instead, see below), so there's no direction
  switching needed for these 8 pins. Output-enable on the 373 itself is
  gated by `_RD` and mode/`_IORQ` so it only drives the Z80 bus when the
  1284p is presenting a byte (ROM emulation, IO-read virtualization; video
  is a read-only steal straight into the 74LS166 and doesn't use the 373).
- **Address bus**: 14 1284p GPIO pins wired directly to Z80 A0–A13 — inputs
  during ROM emulation (Z80 drives), outputs during video fetch (after a
  fixed conservative delay following `_BUSRQ`, not a sensed `_BUSACK` — see
  GPIO pin budget and Risk #3 below for why this needs careful validation).
- **SRAM**: 128K SRAM, A16 grounded → 64K effective. `_WE` = `_MREQ & _WR`,
  active regardless of mode (writes always go to SRAM). Bus-drive from SRAM
  gated by `_MREQ & _RD & mode==1`.
- **Mode-control latch**: single-bit 74LS74 (D=VCC), clocked by `_IORQ &
  _WR` — any Z80 `OUT` sets mode=1 permanently. Matches "flip once at boot."
- **WAIT generation**: SR latch, **Set** by `(_MREQ & _RD & mode==0) |
  (_IORQ & _RD)`, **Reset** by a dedicated 1284p GPIO pulse once it has
  placed data on the bus. The mode-gating is critical — without it the Z80
  would WAIT-stall on every fetch once running from SRAM, with nothing left
  to release it. This is not explicit in the source spec; treat it as the
  working assumption to validate in Phase 4/5.
- **Video fetch**: during the 200 active PAL lines, the 1284p asserts
  `_BUSRQ`, waits a fixed, conservative delay (no `_BUSACK` sensing — see
  GPIO pin budget), then holds `_MREQ` and `_RD` low for the *entire*
  80-byte burst (not toggled per byte) while incrementing the 14 address
  lines every 500ns. Each address change lets the SRAM present a new byte,
  which is latched into a 74LS166 shift register — either by a
  software-pulsed GPIO or a hardware-timer-driven load pulse — and shifted
  out at the 16MHz pixel clock. After 80 bytes, `_MREQ`/`_RD` go high and
  `_BUSRQ` is released.
- **UART virtualization**: real UART bytes are buffered in the 1284p and
  exposed to the Z80 via `IN`/`OUT`, serviced only during the 112 blanking
  lines. Both directions are implemented as `_IORQ & _RD` cycles, so the
  AVR never needs to sense `_WR`: reads work as normal (Z80 `IN r,(C)`,
  AVR serves the buffered byte via 373+WAIT); writes are also done as an
  `IN` — the Z80 loads the byte to send into `C` and a device-select value
  into `B` (`LD C,data / LD B,sel / IN A,(C)`), which places the write byte
  on A0–A7 and the select on A8–A15 while asserting `_IORQ & _RD`. The AVR
  reads A0–A7 as the byte to queue for TX and drives back a dummy/status
  byte to satisfy the Z80's read. Device/port-select decoded via a 74LS138
  on A8–A10.
- **Floating-bus protection on `_WR`, `_IORQ`, `_MREQ`, and `_RD`**: all
  four need pull-up resistors to VCC. The Z80 tristates *every* bus/control
  output for the entire duration `_BUSRQ` is granted, and there's a real
  gap during that period where none of these four lines is being actively
  driven by anyone:
  - `_WR` is never driven by the AVR at all (see GPIO pin budget), so it's
    undriven for the whole grant.
  - `_IORQ` is only ever an AVR *input*, never driven by it, so it's also
    undriven for the whole grant.
  - `_MREQ` and `_RD` are driven by the AVR during the video burst itself,
    but only *after* it switches those pins to outputs partway through the
    fixed post-`_BUSRQ` delay (see Phase 6b) — before that switch, and
    for as long as the Z80 has already tristated but the AVR hasn't taken
    over yet, they're floating too.
  Without pull-ups: a floating `_WR` reading low while `_MREQ` reads low
  would spuriously assert SRAM `_WE`, corrupting video RAM mid-read (or
  mid the pre-burst gap, garbage address and all). A floating `_IORQ`
  reading low while `_RD` reads low — a near-certainty over the tens of
  microseconds involved, not a rare edge case — would spuriously Set the
  WAIT latch; it stays latched after `_BUSRQ` releases, so the Z80 hangs on
  its very next bus cycle with no real IO request behind it to ever
  trigger a WAIT-release pulse. Pull-ups on all four lines make them idle
  high (inactive) whenever nothing is actively driving them, closing these
  hazards with zero AVR pins and zero added chips — a pull-up is weak
  enough that the AVR driving any of these pins low later still works
  normally.

## GPIO pin budget

The ATmega1284p has exactly 32 GPIOs. Every signal the design needs, with
none spare:

| # | Signal | Direction | Notes |
|---|--------|-----------|-------|
| 1–14 | A0–A13 | bidir (in: Z80 drives during ROM-emulation/UART; out: 1284p drives during video steal) | direction switched via DDR per phase |
| 15–22 | D0–D7 | out only | feeds 74LS373 D-inputs; never read back |
| 23 | `_MREQ` | bidir (in: ROM-emulation sensing; out: driven during video steal) | pulled up externally (see above) |
| 24 | `_IORQ` | in | distinguishes IO cycles from memory cycles; pulled up externally (see above) |
| 25 | `_RD` | bidir (in: sensing; out: driven during video steal) | pulled up externally (see above) |
| 26 | `_BUSRQ` | out | asserted for video steal only |
| 27 | `_RESET` | out | held low at power-up, released to start ROM emulation |
| 28 | WAIT-release pulse | out | resets the external WAIT SR-latch once a byte is ready |
| 29 | UART RXD | in | real hardware USART |
| 30 | UART TXD | out | real hardware USART |
| 31 | HSYNC | out | ideally a hardware timer compare-output pin |
| 32 | VSYNC | out | ideally a hardware timer compare-output pin |

Explicitly **not** wired to the AVR: `_WR` (see Architecture recap —
replaced by the `IN`-based write trick, but still pulled up in hardware)
and `_BUSACK` (replaced by a fixed conservative delay, validated in
Phase 6).

This leaves zero spare pins, which has two consequences for later phases:
- `docs/pin-map.md` (Phase 0) must account for every ATmega1284p
  alternate-function conflict up front — JTAG on PORTC (disable via fuse/
  `MCUCR.JTD`), the fixed USART0 TXD/RXD pins, and which timer/OC pins are
  usable for HSYNC/VSYNC — since there's no slack to move a signal to a
  different pin later if one turns out to be unusable.
- Any future feature (e.g. a second virtual device, extra status lines)
  needs its own open question about what to drop or multiplex to make room.

## Phase 0 — Project scaffolding & toolchain

- Pick toolchains: `avr-gcc`/`avr-libc`/`avr-as` (AVR side, hand-tuned
  assembly for the timing-critical loops); an assembler for Z80 (e.g.
  `sjasmplus`, `z80asm`, or `vasm`).
- Pick schematic capture tool (KiCad recommended) — forces the pin map and
  gate equations to be nailed down before wiring.
- Set up a logic analyzer / oscilloscope workflow (e.g. `sigrok`/PulseView)
  — this project is unusually dependent on waveform-level debugging.
- Deliverable: repo skeleton (see Directory Structure below), datasheets
  collected for Z80, ATmega1284p, 74LS373, 74LS74, 74LS166, SRAM part,
  74LS138.

## Phase 1 — Clock generation & distribution

**Hardware**: 16MHz oscillator can, 74LS74 divide-by-2 circuit, decoupling
caps at every IC power pin (breadboards are lossy at these speeds).

**Firmware**: none functionally, but set ATmega1284p fuse bits for external
clock source/speed now — a common first-bring-up failure mode.

**Test criteria**:
- Scope the oscillator: clean 16MHz.
- Trivial "toggle a GPIO in a busy loop" firmware, scope it to confirm the
  1284p is actually executing at 16MHz (validates fuses).
- Scope the divide-by-2 output: clean ~8MHz, ~50% duty, no power-up glitches.

## Phase 2 — 1284p standalone: monitor + real UART + Xmodem

**Goal**: validate the "brain" fully in isolation, zero bus risk.

**Hardware**: 1284p + ISP header, reset button, USB-serial adapter wired to
one hardware USART (fixed TXD/RXD pins).

**Firmware**:
- Monitor CLI over UART: banner, `help`, memory read/write/dump against a
  buffer representing the 1284p's internal SRAM.
- Xmodem receiver writing into a reserved ROM-image buffer (up to 8KB).
- Placeholder `start rom emulation` command (stub until Phase 4 hardware
  exists).
- Reusable "peek/poke external bus" diagnostic primitive, for reuse in later
  SRAM bring-up debugging.

**Test criteria**:
- Terminal connects, banner + CLI works.
- Upload a known file via Xmodem, verify via memory dump/checksum.
- Soak test: large transfer, no framing errors/drops at chosen baud rate.

## Phase 3 — Z80 clock/reset/address-bus bring-up (free-running, no ROM emulation)

**Goal**: validate the Z80, clock, reset control, and SRAM wiring without
depending on ROM-emulation firmware being correct yet.

**Hardware**: add Z80 + SRAM (A16 grounded) + `_RESET` from a 1284p GPIO.
Do **not** build the 373/WAIT/mode-latch yet — pull the data bus to a fixed
NOP opcode (0x00) via pull-ups/downs so the Z80 free-runs predictably.

**Firmware**: 1284p monitor command to assert/release Z80 `_RESET`.

**Test criteria**:
- Z80 held in reset: 1284p's address GPIOs read a stable idle state (no
  contention with Z80 held in reset).
- Release reset: address bus free-runs 0x0000→0xFFFF repeatedly at the NOP
  fetch rate, confirming clock/reset/address wiring before adding real-time
  logic.
- Optional: monitor "SRAM tester" command to exercise the SRAM chip in
  isolation (with Z80 held in reset) before the Z80 or 373 ever touch it.

## Phase 4 — ROM emulation bring-up (the core mechanism)

**Hardware additions**:
- 74LS373 data latch, wired per the gating equations above.
- WAIT SR-latch (e.g. 74LS00 cross-coupled pair or 74LS74) with the Set
  logic `(_MREQ & _RD & mode==0) | (_IORQ & _RD)`; a dedicated 1284p GPIO
  drives Reset/release.
- Mode-control latch (74LS74, D=VCC, clocked by `_IORQ & _WR`).
- 373 output-enable: `_RD & ((_MREQ & mode==0) | _IORQ)`.
- Pull-up resistors on `_WR`, `_IORQ`, `_MREQ`, and `_RD` (see Architecture
  recap).

**Firmware**:
- Hand-written AVR assembly ROM-emulation loop: poll `_MREQ`/`_RD`, on
  assertion read the 14 address pins, index into the uploaded ROM buffer,
  switch data-bus GPIOs to output, write the byte, pause 1–2 NOPs for
  latch/settle, pulse WAIT-release, switch data-bus GPIOs back to input,
  loop.
- `start rom emulation` command: releases Z80 `_RESET` and enters this loop.
- "Magic address" exit condition: when the polled address equals a
  pre-agreed sentinel, serve the byte as normal, then break out of the poll
  loop into the SRAM-execution/video state instead of continuing to poll.

**Z80-side test ROMs** (increasing complexity):
1. `JP $0000` infinite loop — validates address/WAIT mechanism with an
   easily-scoped pattern (address cycles 0,1,2,0,1,2…).
2. Fill first N bytes of SRAM with a known pattern, then `HALT` — validates
   SRAM writes (verify via the Phase 3 SRAM-tester or a `_BUSRQ` peek).
3. The real boot ROM — deferred to Phase 5.

**Test criteria**:
- Logic analyzer: address sequence matches the test ROM's expected pattern.
- Scope the WAIT-latch output over an extended run (minutes, thousands+ of
  fetches) — confirm it always asserts and always releases; a single missed
  release hangs the Z80 permanently, and this class of bug may only surface
  intermittently.
- Characterize actual WAIT duration / ROM-copy throughput.
- Confirm the SRAM-write path (mode-independent) is correct.

## Phase 5 — Mode switch to SRAM execution

**Hardware**: none new — exercises Phase 4's gating. **Updated
2026-09-02**: the mode signal is now an 8255 GPIO pin (`mode_pin`), not a
74LS74A flip-flop — see `gate-equations.md` §2 for the full redesign.

**Z80 boot ROM**: copy the uploaded 8K ROM image to SRAM, do final setup
(stack pointer etc.), execute the magic-address read as the last ROM
fetch, configure the 8255's port bit as an output and drive it low
(`mode_pin`=0), jump into SRAM. No longer "any `OUT` flips it" — that was
the old one-way flip-flop's behavior; this needs an actual 8255 control-
word write plus a data write, and is a software convention, not a
hardware-enforced one-way latch, so the boot ROM must still avoid further
writes to that pin afterward by discipline, not because the hardware
prevents it.

**Firmware (1284p)**: on seeing the magic address, serve it, then leave the
ROM-emulation loop into a placeholder "SRAM-execution idle" state (before
video exists — e.g. light an LED / print over UART once it exits, no
further bus involvement).

**Test criteria**:
- After mode flip, logic analyzer confirms the Z80 fetches purely from SRAM
  at full 8MHz with **no** WAIT states — validates the mode-gated WAIT
  equation; if WAIT still asserts on every fetch, the gating is wrong.
- Extended soak of a small free-running SRAM program — no spurious
  WAIT/hang, no contention artifacts from the address-bus direction change.
- Add a debug assertion/LED for "non-magic address read after 1284p thinks
  it's exited ROM mode" — the magic-address handoff is a software/hardware
  protocol, not an electrical signal, so make its failure visible.

## Phase 6 — Video generation

Highest-risk subsystem; split to isolate risk.

### 6a — Pixel-clock hardware bring-up in isolation

Validate the address-ramp + shift-register chain against a static,
known-good SRAM pattern (pre-loaded via the Phase 5 SRAM tester, e.g.
alternating 0x55/0xAA) before wiring into `_BUSRQ` arbitration and real
video timing.

**Hardware**: 74LS166 shift register on the shared data bus; HSYNC/VSYNC
timer outputs (Phase 6b) not required yet for this sub-phase.

**Firmware**: per the resolved approach — assert `_MREQ`/`_RD` once at burst
start (not per byte), loop 80 times incrementing the 14-bit address and
outputting it, then deassert `_MREQ`/`_RD`. With the GPIO pin budget at
zero spare pins (see above), the 74LS166 load pulse **cannot** be a
dedicated software-pulsed AVR GPIO — it needs one of:
  - **A free-running hardware-derived load pulse**: a small counter/divider
    driven directly off the 16MHz master clock (independent of any AVR
    pin), generating a "load" edge every 8 pixel clocks once triggered into
    sync at the start of each burst (e.g. reset by the same edge that
    asserts `_BUSRQ`). Costs one small extra chip, zero AVR pins.
  - **Reusing the WAIT-release pin** during video mode: it's never needed
    while a burst is in flight (the Z80 is off the bus), so the same
    physical AVR pin could pulse the 166's load line instead. Only valid if
    nothing on the WAIT-release net could be mistakenly triggered by this
    reuse — needs a wiring/timing check, not just an assumption.
  This is an open design decision (see Open Questions) — measure actual
  cycles needed for the 14-bit address increment across GPIO port(s) early
  in this sub-phase, since that number affects which option is preferable.

**Test criteria**: logic analyzer/scope confirms 80 bytes fetched at the
correct 500ns cadence, the shift register's serial output matches the known
test pattern, and SRAM access time (typically 55–70ns) settles comfortably
before each shift-register load edge.

### 6b — Full video generation integrated with BUSRQ/HSYNC/VSYNC

**Hardware**: HSYNC/VSYNC timer outputs; composite-video sync-mixing
network (resistor summing of HSYNC + VSYNC + pixel data into one composite
signal, per PAL CRT/TV target); `_BUSRQ` wiring finalized. `_BUSACK` is
**not** wired back to the AVR (dropped from the pin budget) — the Z80's
bus-tristate acknowledgement is assumed via a fixed delay instead of sensed.
This is also the phase where the `_WR`/`_IORQ`/`_MREQ`/`_RD` pull-ups
(Architecture recap) get their real workout, since it's the only time the
Z80 actually tristates those lines for an extended period.

**Firmware**:
- Hardware timers for 64us HSYNC period and 50Hz VSYNC (PAL), ideally using
  hardware timer compare-output pins directly for jitter-free sync.
- "Wait for HSYNC" tight-loop primitive to align the BUSRQ/fetch sequence
  to the timer-generated pulse.
- Per active line: assert `_BUSRQ`, hold for a fixed, conservatively-sized
  delay (derived from the Z80 datasheet's worst-case BUSRQ-to-tristate
  timing plus margin, then confirmed empirically — see Test criteria).
  During this delay the pull-ups are what keep `_MREQ`/`_RD` safely high
  once the Z80 has released them but before the AVR takes over. When the
  delay elapses, switch `_MREQ`/`_RD` to outputs — set their `PORT`
  register bits high *before or atomically with* setting `DDR` to output,
  so the pin transitions from pulled-high to driven-high with no glitch
  low — then explicitly drive both low to begin the burst. Set the line's
  start address, run the 80-byte burst (Phase 6a logic), release
  `_MREQ`/`_RD` (drive high, then switch back to inputs), release
  `_BUSRQ`.
- 200 active lines, then idle through 112 blanking lines (available for IO
  virtualization, Phase 7).

**Z80-side test program**: writes a simple test pattern into video RAM
(0xC000–0xFFFF, via A14/A15 tied high) — e.g. alternating scanlines or a
checkerboard, for easy visual verification.

**Test criteria**:
- Composite-capable PAL monitor/TV shows a stable, correctly-timed 640x200
  image matching the Z80 test pattern, no tearing/rolling.
- **Since there's no `_BUSACK` handshake, this is the phase that must prove
  the fixed delay is actually safe**: logic-analyzer-capture the Z80's bus
  lines around every `_BUSRQ` assertion and directly verify the Z80 has
  fully tristated (address/data/`_MREQ`/`_RD`/`_WR` all released) before the
  1284p's delay expires and it starts driving. Test across different Z80
  instructions/timings (the delay needed depends on which machine cycle
  BUSRQ happens to be sampled during), and re-verify after any change to
  clock speed or Z80-side code. If any capture shows the 1284p driving
  before the Z80 has released, the delay must be increased.
- Confirm `_WR` and `_IORQ` actually idle high (pull-ups working) for the
  full duration of every burst, and confirm `_MREQ`/`_RD` idle high during
  the pre-burst delay window specifically (before the AVR switches them to
  outputs) — scope all four directly, don't just assume the resistor value
  is adequate; if any dips or floats indeterminate, the SRAM-corruption /
  spurious-WAIT hazards described in Architecture recap are still live.
  Also confirm the `_MREQ`/`_RD` output-mode transition itself is
  glitch-free (no unintended low pulse at the moment `DDR` switches to
  output, before the deliberate low that starts the burst).
- Confirm the Z80 resumes correctly between lines/frames (e.g. have the Z80
  increment a counter during blanking, confirm expected progress on
  readback — proves it isn't glitching from repeated bus-steal cycles).
- Scope address-bus direction-change transitions (1284p output↔input, Z80
  tristate↔drive) specifically for contention.

## Phase 7 — UART virtualization

**Hardware**: 74LS138 IO-port decoder on A8–A10, selecting which virtual
register a given `IN r,(C)` is targeting (e.g. "RX data/status" vs "TX
data"). No `_WR`-related gating needed — every transaction, read or write,
is an `_IORQ & _RD` cycle (see GPIO pin budget / Architecture recap).

**Firmware (1284p)**:
- Real USART RX (ISR or polled) filling a small ring buffer.
- During the 112 blanking lines, poll `_IORQ`/`_RD` like the ROM-emulation
  loop. On any `IN`, decode the A8–A10 device-select: for "RX read", serve
  the next buffered received byte (or a status byte if none available) via
  373+WAIT; for "TX write", read the byte to send off A0–A7 (the Z80 having
  placed it there via `LD C,data` before the `IN`), push it to the TX queue
  for the real UART, and drive back a dummy/status byte via 373+WAIT to
  satisfy the Z80's read (this return value can double as a TX-ready flag
  at no extra cost).
- Cycle-budget the IO service so it never slips the next HSYNC-aligned
  `_BUSRQ` assertion.

**Z80-side test program**: echo test — `IN` a received byte via `C`, then
send it back out via `LD C,byte / IN A,(C)` against the TX device-select.

**Test criteria**:
- Typing into a terminal on the 1284p's real UART echoes back via the Z80.
- Measure/document worst-case latency: an IO request issued right as an
  active line begins can wait up to nearly one frame (~20ms) before
  service, since IO is only serviced during blanking by design — this is an
  expected characteristic, not a bug.
- Stress test rapid back-to-back characters — confirm no bytes lost to real
  UART RX-buffer overflow while virtualization can't keep up during active
  video lines.

## Phase 8 — System integration & soak testing

- Full boot sequence: power-up → 1284p monitor → Xmodem upload → `start rom
  emulation` → ROM-to-SRAM copy → mode flip → video + UART running
  concurrently. (2026-09-11: for the CP/M build, `stage1.bin` is now also
  baked into the AVR flash image and autobooted directly when the PD0
  boot-mode strap is pulled low — no host/Xmodem step. See the autoboot
  plan and `firmware/avr-1284p/src/monitor.c`.)
- A more substantial Z80 demo (e.g. reads UART input, draws to video RAM)
  exercising the full stack together.
- Hours-long soak test watching for hangs, visual glitches, dropped UART
  bytes — several interlocking mechanisms (WAIT release, magic-address
  handoff, BUSRQ arbitration, blanking-window IO scheduling) each have a
  small individual failure surface that could compound under stress.
- Optional future step (not required for correctness): migrate breadboard
  → soldered protoboard/PCB once validated, since breadboard parasitics at
  16MHz can mask or introduce marginal signal-integrity issues.

## Timing-critical and risky areas (consolidated)

1. **ROM-emulation loop timing is not a hard deadline.** `_WAIT` can be held
   low indefinitely without breaking correctness (static RAM, no refresh),
   so the poll-and-serve loop just needs reasonable throughput, not a
   correctness-critical deadline. An 8KB ROM copy should complete well
   under one video frame even with a generous per-byte cycle budget.
2. **The video pixel-fetch loop is still the highest-risk piece**, even with
   `_MREQ`/`_RD` held low for the whole burst. Each of the 80 iterations
   still needs to increment a 14-bit address (likely split across two GPIO
   ports) and output it within 500ns (~8 cycles at 16MHz) — measure this
   early (Phase 6a) rather than assuming it fits; fall back to a
   hardware-timer-driven shift-register load (freeing all 8 cycles for the
   address increment alone) if a software-pulsed load doesn't fit.
3. **`_BUSRQ` arbitration without `_BUSACK` sensing is the biggest risk
   introduced by the pin-budget fix.** The 1284p never confirms the Z80 has
   actually tristated before driving the shared address/`_MREQ`/`_RD`
   lines — it just waits a fixed delay. If that delay is ever too short
   (e.g. BUSRQ sampled right before a long instruction's bus cycle), both
   the Z80 and the 1284p could drive the address bus simultaneously. This
   makes Phase 6b's logic-analyzer verification (confirming the Z80 has
   fully released before the delay expires, across a range of Z80
   instruction timings) mandatory, not optional, before trusting this path.
4. **The WAIT-latch gating equation is load-bearing and not explicit in the
   source spec.** Without the mode-bit gating, the Z80 would permanently
   stall on every fetch after switching to SRAM execution. Validate this
   explicitly in Phase 5 before trusting it.
5. **The "magic address" mode-exit handoff is a fragile protocol**, not an
   electrical signal — depends on the boot code executing exactly one more
   ROM fetch (the magic one) and never fetching from ROM space again after.
   Add a debug/assertion path (Phase 5) rather than relying on silent
   correctness.
6. **GPIO pin budget is exactly zero-slack (32 of 32).** See the "GPIO pin
   budget" table above — this was only reached by dropping `_WR` (via the
   `IN`-based UART write trick) and `_BUSACK` (via the fixed-delay bus
   handoff, risk #3). Several remaining pins are also fixed by the chip's
   peripherals (USART pins, timer OC pins, JTAG occupies 4 pins on one port
   by default and must be disabled via fuse/`MCUCR.JTD` if that port is
   needed). Work out `docs/pin-map.md` *before* schematic capture — with no
   spare pins, a wrong alternate-function assumption forces a redesign
   rather than a quick reroute.
7. **Floating `_WR`/`_IORQ`/`_MREQ`/`_RD` during `_BUSRQ`-granted bus
   periods.** The Z80 tristates every bus/control output for the entire
   video-steal burst, and there's a real window — from when the Z80
   releases them to when the AVR either senses them (n/a here, since none
   of these four are relied on as a Z80→AVR signal during this window) or
   starts driving them itself (`_MREQ`/`_RD`, partway through the fixed
   delay) — where all four are simply undriven. Without pull-ups: a
   floating `_WR` risks spuriously asserting SRAM `_WE` (corrupting video
   RAM mid-read or during the pre-burst gap), and a floating `_IORQ` risks
   spuriously Setting the WAIT latch (hanging the Z80 permanently on its
   next bus cycle, since nothing would ever pulse WAIT-release for a
   phantom IO request) — `_MREQ`/`_RD` floating independently adds more
   ways to hit the same two hazards during the pre-burst gap specifically.
   Mitigated with pull-up resistors on all four lines (Architecture
   recap); Phase 6b must directly scope all four during a burst, including
   the pre-burst delay window, to confirm the pull-ups are actually
   holding them high and that the AVR's later transition to driving
   `_MREQ`/`_RD` is glitch-free — not just assume the fix works.
8. **UART virtualization scheduling budget**: servicing an IO request during
   blanking must not eat so many cycles it delays the next scanline's
   HSYNC-aligned `_BUSRQ`, or video timing visibly glitches. Needs an
   explicit cycle-budget analysis once real code exists.
9. **Breadboard signal integrity at 16/8MHz**: expect ringing on clock and
   control lines from breadboard parasitics. Plan for short leads,
   decoupling caps at every IC, and consider small series-termination
   resistors (220–470Ω) on the shared, unbuffered address-bus lines, since
   those lines have no buffer between the 1284p and Z80.

## Proposed directory structure

    z80-with-1284p/
      CLAUDE.md
      plan.md
      README.md
      docs/
        architecture.md        # narrative design + block diagram
        pin-map.md              # authoritative ATmega1284p GPIO assignment table (do first)
        timing-analysis.md      # WAIT/video/UART budget calculations, kept current as measured
        memory-map.md           # Z80 address space layout (rom window, sram, video RAM region)
        io-map.md                 # IO port decode table (74LS138 selects, OUT-encoded-value convention)
        gate-equations.md         # 373/SRAM/WAIT gating logic, kept in sync with schematic
        open-questions.md          # tracked list of unresolved spec ambiguities + decisions made
        bring-up-log.md            # phase-by-phase test results, waveform notes, issues found
      hardware/
        kicad/                     # schematic (KiCad project)
        datasheets/                # Z80, ATmega1284p, 74LS373/74/166/138/161, SRAM part
        bom.csv
        photos/                    # breadboard build photos per phase
      firmware/
        avr-1284p/
          Makefile
          src/
            pins.h                 # generated from docs/pin-map.md, single source of truth
            main.c
            monitor.c / monitor.h  # CLI, memory read/write
            xmodem.c / xmodem.h
            rom_emu.S               # tight hand-tuned ROM-emulation loop
            video.c / video.S       # timers, BUSRQ scanline driver, "wait for hsync" primitive
            uart_virt.c              # IO virtualization for the Z80
          test/                      # host-side unit tests for non-timing-critical logic
        z80-boot-rom/
          Makefile
          boot.asm                   # rom->sram copy, magic-address read, mode flip, jump to sram
          test-progs/
            nop_loop.asm              # Phase 4 bring-up
            fill_pattern.asm          # Phase 4 bring-up
            video_test.asm            # Phase 6 test pattern
            uart_echo.asm             # Phase 7 test
      tools/
        xmodem_send.py                # or document use of lrzsz
        logic-analyzer-captures/      # saved sigrok/PulseView sessions of known-good waveforms
      scripts/
        program_avr.sh                # avrdude + fuse-setting
        build_all.sh

## Open questions to resolve during implementation

1. **WAIT-latch gating equation**: confirm `(_MREQ & _RD & mode==0) |
   (_IORQ & _RD)` as the Set condition during Phase 4 bring-up — not
   explicit in the source spec, and wrong-by-default hangs the machine
   after the mode switch.
2. **IO port address decoding details**: which address bits drive the
   74LS138 (A8–A10), and how many virtual devices/registers are needed
   beyond "UART RX read" and "UART TX write" (both now implemented as `IN`
   cycles per the `_WR`-elimination decision — see Architecture recap).
3. **Video RAM addressing/stride**: 640×200 mono = 16000 bytes, fits the
   16KB 0xC000–0xFFFF window, but 80 bytes/line doesn't align to
   power-of-2 boundaries — the video address counter must carry across all
   14 bits correctly rather than assume an 8-bit-per-page counter.
4. **Exact ATmega1284p pin assignments**: typical alternate-function
   locations (USART pins, timer OC pins, JTAG on PORTC) must be verified
   against the datasheet before finalizing `docs/pin-map.md`.
5. **Xmodem/monitor command set specifics** — closed 2026-09-01: 38400 8N1
   (0.16% baud error); XMODEM-CRC, 128-byte blocks; monitor commands
   `help`/`d`/`w`/`f`/`c`/`x`/`i`/`s` (dump/write/fill/crc/xmodem-upload/
   info/start), operating directly on the 1284P's internal SRAM. See
   `firmware/avr-1284p/src/monitor.c` and `docs/bring-up-log.md` Phase 2.
6. **Exact `_BUSRQ`-to-safe-drive delay value**: `_BUSACK` is deliberately
   not wired to the AVR (GPIO pin budget), so the 1284p relies on a fixed
   delay after asserting `_BUSRQ` instead of sensing the Z80's actual
   tristate acknowledgement. The delay value itself needs to be derived
   from the Z80 datasheet's worst-case BUSRQ-response timing plus margin,
   then empirically confirmed via logic analyzer in Phase 6b (risk #3)
   before it can be trusted.
7. **74LS166 load-pulse source** (Phase 6a): with zero spare GPIOs, choose
   between a small free-running hardware clock-divider (extra chip, zero
   AVR pins) or reusing the WAIT-release pin during video mode (zero extra
   chips, needs a wiring/timing safety check) — see Phase 6a firmware.
8. **Pull-up resistor values for `_WR`/`_IORQ`/`_MREQ`/`_RD`**: a
   conventional value (e.g. 4.7k–10k) should be fine given
   Z80/AVR/74LS-family input characteristics, but should be checked against
   actual leakage/loading once the full schematic (including the 74LS138
   and gate inputs tied to these lines) is finalized. Also confirm the
   pull-up doesn't slow `_MREQ`/`_RD`'s falling edge enough to matter once
   the AVR starts actively driving them low every 500ns during the burst —
   likely negligible at 4.7k–10k against an AVR pin's drive strength, but
   worth a quick scope check in Phase 6a.
