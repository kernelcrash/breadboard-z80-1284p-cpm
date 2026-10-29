# Gate Equations (Discrete Logic)

All logic is 74LS (5 V). Active-low signals are prefixed `_`. This is the
single source of truth for the discrete-logic portion and must be kept in
sync with the KiCad schematic. Part numbers in `bom.csv`. The pin-by-pin
breadboard wiring for every chip on the board — the 74LS74A (clock/2,
WAIT generator), the data latch (74HC595 as of 2026-09-16, was a 74LS373
— see §4 and `74HC595-plan.md`), the 74LS00 gate network, the SRAM, and
the 8255 — is consolidated in `wiring.md`.

> **Redesigned 2026-09-02.** The original design used a second
> flip-flop-based mode latch and an `_S`-derived combinational network
> (`_G`/`_L1`/`_L2`/`mode_clk`/`M1`/inverters) to gate the WAIT flip-flop,
> the 373, and the SRAM. Through iterative design — verified against the
> Z80 UM's actual timing diagram and the TC551001 SRAM datasheet's
> operating-mode and write-cycle sections, not assumed — this collapsed
> to a much smaller network: the WAIT flip-flop now clocks directly off
> the Z80's own CPU clock, and the mode signal comes from an 8255 GPIO
> pin instead of a flip-flop. Net effect: one 74LS74A, one 74LS32, one
> 74LS08, and one 74LS04 all eliminate down to a single 74LS00 + a
> partially-used 74LS02, despite adding the 8255. See "Gate / chip
> budget" at the bottom for the full accounting, and `bring-up-log.md`
> for the design history (including two dead ends found and corrected
> along the way — worth reading if this looks surprisingly minimal).

## Signals

| Signal | Source | Meaning |
|--------|--------|---------|
| `_MREQ` | Z80 (out) / 1284p (out during video) | memory request, active low |
| `_IORQ` | Z80 (out) | IO request, active low |
| `_RD` | Z80 (out) / 1284p (out during video) | read, active low |
| `_WR` | Z80 (out) | write, active low (pull-up only) |
| `_BUSRQ` | 1284p (out) | bus request to Z80, active low |
| `_INT` | tied inactive (pull-up only) | Z80 input, active low; unused, not driven by anything in this design |
| `_NMI` | tied inactive (pull-up only) | Z80 input, active low, edge-triggered; unused, not driven by anything in this design |
| `mode_pin` | 8255 GPIO port pin (external **pull-down**, flipped 2026-09-04 — see §2) | 0 = ROM emulation (default), 1 = SRAM execution |
| `clk16` | oscillator | 16 MHz master |
| `clk8` | 74LS74A Q (pin 5, FF#1) | 8 MHz Z80 clock |
| `wait_rel` | 1284p (out, PD3) | pulse to release `_WAIT` |
| `POR` | pull-down network on shared Z80-`_RESET`/1284p-PD2 net | drives `_CLR` on the WAIT FF and (via inverter) the 8255's `RESET` |

## 1. Clock divide-by-2 — 74LS74A FF#1

- D (pin 2) = **Q1' (pin 6), fed back** — NOT tied to GND. A D flip-flop
  with D held at a constant level does not toggle: it latches that level on
  the first clock edge and then never changes again. The standard D-FF
  divide-by-2 trick is to feed the *complementary* output back into D, so
  every rising edge loads `D = NOT(current Q)` and Q flips every clock.
- CLK (pin 3) = `clk16`, Q (pin 5) = `clk8` → Z80 `CLK`.
- Toggle on every rising 16 MHz edge ⇒ 8 MHz, 50 % duty.
- Preset (pin 4) and Clear (pin 1) tied high (inactive) — this FF needs no
  power-on-defined-state fix (see "Power-on reset" below): it's a
  free-running toggle, and the Z80 doesn't care what phase its clock
  "happens to start on," only that it's a clean periodic signal once
  running.

**74LS74A DIP-14 pinout** (checked against `hardware/datasheets/sn74ls74a.pdf`'s
actual datasheet image, and independently cross-checked against the local
KiCad symbol library `74xx.kicad_sym` — see `bring-up-log.md`):

| Pin | FF#1 | Pin | FF#2 |
|-----|------|-----|------|
| 1  | _CLR1 | 8  | Q2' |
| 2  | D1    | 9  | Q2  |
| 3  | CLK1  | 10 | _PRE2 |
| 4  | _PRE1 | 11 | CLK2 |
| 5  | Q1    | 12 | D2  |
| 6  | Q1'   | 13 | _CLR2 |
| 7  | GND   | 14 | VCC |

## 2. Mode signal — 8255 GPIO pin, not a flip-flop

The original design used a second 74LS74A flip-flop (D tied to VCC,
clocked by a Z80 `OUT`) as a one-way mode latch. That's gone: the mode
signal is now a single GPIO pin on an 8255 PPI (`mode_pin`).

- **Polarity flipped 2026-09-04, from a real bench finding — see
  `bring-up-log.md`.** After reset, 8255 ports default to input mode
  (standard, well-documented 8255 behavior — **not yet verified against a
  local datasheet, none collected**, see `open-questions.md`). With an
  external **pull-down**, `mode_pin` reads LOW (0) by default:
  ROM-emulation mode. Software later issues an 8255 control-word write
  reconfiguring that port bit as an output, then a data write driving it
  HIGH (1): SRAM-execution mode.
- **Why the pull-*down*, not pull-up, and why this polarity specifically**:
  configuring an 8255 port as an output is documented 8255 behavior to
  force that port's pins LOW immediately, regardless of whatever an
  external resistor was holding them at. With the original pull-up/HIGH=
  ROM convention, merely *reconfiguring* the port (an unavoidable first
  step before ever intentionally driving it) already forced `mode_pin`
  low — which under that convention meant an immediate, premature switch
  to SRAM mode, before the boot ROM had copied anything or done any real
  setup. Flipping to LOW=ROM makes that same forced-low reconfiguration
  step harmless (still reads as ROM mode); an actual switch now needs a
  deliberate follow-up write driving the pin HIGH. The pull-down (instead
  of the original pull-up) is required so the *pre-configuration* default
  — while the port is still an input, right after reset — is also LOW,
  consistent with the new convention from the very first instant, not
  just after the 8255 is configured.
- Unlike the old flip-flop, **this is not hardware-enforced one-way** — an
  8255 GPIO pin can in principle be reconfigured back to input or driven
  high again. The one-way property the old design had is now a software
  convention (boot code should never do this), not a hardware guarantee.
  Worth remembering if a debug/rescue path is ever wanted.
- `mode_pin` feeds directly into the 595 and SRAM `_OE` NAND gates (§4,
  §5) and the 8255's own `RESET`/`_CS` are unrelated to it (§8) — no
  `mode_clk`, no AND/inverter chain, no flip-flop.

This eliminates the entire old `_S`/`_G`/`_L1`/`_L2`/`mode_clk`/`M1`/
`NOT_G`/`NOT_M1`/`NOT_S` network — traced every consumer of every one of
those signals; nothing else in the design needs any of them once the mode
latch and the old `_S`-clocked WAIT mechanism are both gone.

## 3. `_WAIT` generation — 74LS74A FF#2 (same chip as clock divide)

**Redesigned.** Clocked directly from the Z80's own CPU clock, not a
derived `_S` signal — removes the entire gate chain that used to feed it.

**No `mode_pin` gating on D, by design — and this only works because of a
firmware-level fix, not a hardware one.** D=`_RD` unconditionally means
this FF latches `_WAIT` low on *every* read, ROM or SRAM alike; nothing
in the gate network itself stops it once the mode switches to SRAM. That
initially looked like a real bug (found 2026-09-05: plan.md's original
architecture recap called mode-gating "critical... without it the Z80
would WAIT-stall on every fetch once running from SRAM, with nothing
left to release it"), until realizing the AVR doesn't need hardware
mode-gating to satisfy that requirement — it can just stop needing a
release at all. `rom_emu.c`'s ROM-emulation loop pulses `wait_rel` low-
then-high per byte throughout ROM emulation (releasing WAIT, as normal)
right up until it serves the magic address — at that point, instead of
leaving `wait_rel` idle-high (ready to pulse again), it drives it low
and **leaves it there permanently**. Since `wait_rel` is this FF's async
PRESET (below), holding it asserted forces `Q` (`_WAIT`) permanently
high (released) regardless of `_RD`/CLK from then on — electrically
equivalent to mode-gating D, achieved entirely in firmware with zero
extra gates. (This was invisible before Phase 6 prep: the *previous*
version of the ROM-emulation loop ran forever regardless of the magic
address, which accidentally had the same net effect by continuing to
service every read — ROM or SRAM — blindly, for as long as the Z80 ran.
Once that loop was changed to actually exit on the magic address, the
gap became real and needed this explicit fix — see rom_emu.c and
bring-up-log.md.) One-way, matching the mode switch itself: no path back
into ROM emulation without a full reset, which re-asserts the POR/CLEAR
net below and reinitializes everything cleanly anyway.

- D (pin 12) = `_RD`, directly (see above for why this doesn't need
  `mode_pin` gating).
- CLK (pin 11) = the Z80 CPU clock (`clk8`, same net as §1's Q1 output).
- Q (pin 9) = `_WAIT` → Z80 `_WAIT` pin.
- Async Preset (pin 10, `_PRE2`, active low) = `wait_rel` (1284p PD3):
  pulsed low-then-high per byte throughout ROM emulation to force Q=1
  (`_WAIT` released) once data is on the bus; driven low and held there
  permanently once the magic address is served (see above). `video.c`'s
  later reuse of this same pin as a brief high-then-low test pulse
  (bring-up-log.md, "fat pixel" test) is compatible with this — it
  always returns to low, preserving the invariant.
  **Unchanged from the old design at the firmware level** — `rom_emu.c`'s
  pulse-low-then-high behavior is electrically identical regardless of
  what clocks the far end of the flip-flop; no firmware change needed.
- Async Clear (pin 13, `_CLR2`) = the shared `POR` net (pull-down — see
  "Power-on reset" below), same net as the 8255's `RESET`.

**Timing, verified against the Z80 UM** (`hardware/datasheets/z80-um.pdf`
Figure 6 — rendered the actual page image, its text layer is garbled for
this PDF): `_RD`/`_MREQ` fall together at **T1's falling edge**; the CPU
"samples the WAIT line... during T2 and every subsequent Tw... with the
falling edge of Clock" (UM's own wording). For this positive-edge-
triggered FF: the first rising edge after `_RD` goes low is the one that
starts T2 — so `Q` (`_WAIT`) loads LOW at the T2-start rising edge, a full
T-state (125 ns at 8 MHz) before the Z80's T2-falling-edge sampling
point. Comfortable margin.

Because D=`_RD` stays low for the *entire* read cycle (T1 through T3),
the FF can never release WAIT via clocking alone — every rising edge just
reloads Q=0 again. Release only happens via the `wait_rel` PRESET pulse:
pulse it low long enough to be seen HIGH at the Z80's next T2/Tw-falling-
edge sampling point, then release — it's fine if Q gets re-clocked low
again immediately after (during T3), since the Z80 has already committed
to T3 by then and doesn't re-check WAIT.

Z80 WAIT behaviour relied on (Z80 UM, Overview chapter): the Z80 samples
`_WAIT` at the end of T2/Tw; if LOW it inserts another Tw and re-samples,
so holding `_WAIT` low indefinitely is legal and merely stretches the
read. No refresh hazard (SRAM is static).

**This FF needs no power-on-defined-state fix in principle** (unlike the
old mode latch): D=`_RD` gets clocked in reliably on the very first real
slow-read start regardless of whatever garbage state `Q` happened to
power up in, since that's a genuine, well-timed clock edge with a solid
D value (see the timing paragraph above) — self-correcting on first use.
Tied to the `POR` pull-down net anyway (§ below), since it costs nothing
now that the network exists for other reasons and removes any reliance
on that self-correction argument alone.

## Power-on reset (`POR`) — pull-down, not an RC network

**Superseded 2026-09-02** — an earlier fix in this project's history used
a dedicated RC power-on-reset network (resistor + capacitor + diode) to
give the WAIT/mode-latch flip-flops a defined power-on state, after
finding that a 74LS74A's `Q` at power-up (before anything actively clocks
or clears it) is genuinely undefined silicon-dependent behavior, not a
documented reset value. That RC network is now gone, replaced by
something simpler, discovered while designing the 8255's own reset:

**A single pull-down resistor on the shared Z80-`_RESET`/1284p-PD2 net**
is sufficient. Reasoning: tying the WAIT FF's `_CLR` (and the 8255's
`RESET`, via an inverter — §8) directly to PD2 initially looked unsound
(that net floats — high-impedance, no pull-up — until AVR firmware
configures and drives it), but works out correctly: the Z80 can't do
anything meaningful during that same floating window either (it's relying
on that same undefined signal to know it's in reset), and the AVR always
asserts PD2 low for a real duration before ever releasing it. So the
actual requirement is "cleared before the Z80 is ever released," not
"cleared at time zero" — satisfied once the net reads LOW from the very
first instant VCC appears, before the AVR has done anything at all, which
a plain pull-down (no capacitor, no delay-timing estimate to defend)
achieves directly.

```
VCC ──[ R ~10k ]──┬── POR net (WAIT FF _CLR, 8255 RESET via inverter, 1284p PD2)
                   │
                  GND
```

This also closes a gap the old RC-network fix never covered: the Z80's
*own* `_RESET` pin floating during that same early AVR-startup window,
not just the flip-flops.

## 4. 74HC595 output-enable (data latch to Z80)

**2026-09-16: chip swap, gate equation unchanged.** The 74LS373 parallel
latch was replaced with a 74HC595 serial-in/parallel-out shift register
(`74HC595-plan.md`) to free 5 AVR GPIO pins (`pin-map.md`) — the AVR now
presents each byte via hardware SPI (`SER`/`SRCLK`) plus a manual `RCLK`
pulse (`firmware/avr-1284p/src/databus.c`) instead of a single parallel
port write. This is purely an AVR-side/firmware change: the gate-level
output-enable logic below is **identical** to the old 373 formula, just
driving the 595's `/OE` pin instead of the 373's `OE̅` — the property that
made a latch the right choice in the first place (combinational
tri-state control, independent of how fast the AVR can get a byte onto
the D inputs) carries over exactly, because it's a property of `/OE`,
not of how the chip's internal register gets loaded.

`/OE = NAND(NOT(mode_pin), NOT(_RD))` — one NAND gate plus two shared
inverters (`NOT(_RD)`, reused by the SRAM `_OE` path too, §5;
`NOT(mode_pin)`, reused by the same, note the formulas swap which one is
inverted compared to §5 — updated 2026-09-04 for the `mode_pin` polarity
flip, see §2). Asserts (LOW, drives) exactly when `mode_pin=0` (ROM
mode, the new convention) AND `_RD=0` (a read is in progress) —
tri-stated at all other times.

Unlike the old `_S`-based formula, this has **no `_MREQ`/`_IORQ` term** —
the 595 has no CE-equivalent pin, so nothing else protects it, unlike
SRAM (§5). Two consequences, both deliberate, accepted limitations, not
oversights — **document prominently, they matter for every later phase
that touches IO**:

1. **Once `mode_pin` goes high (SRAM-execution — HIGH now, since the
   2026-09-04 polarity flip), this NAND can never assert again** — the
   595 stops driving entirely, including for IO-device reads. The
   AVR-virtualized-IO path (e.g. a future UART, Phase 7) cannot be served
   once in SRAM-execution mode under this scheme. No fix designed yet;
   revisit once Phase 7's actual shape is decided.
2. **Real electrical hazard while still in ROM-emulation mode — but only
   for `IN`, not `OUT`, and (as of the 2026-09-04 74LS138 redesign, §7/§8)
   only for `IN`s actually targeting the 8255's decoded range
   (`0xA8`-`0xAF`), not any IO address.** Since this NAND ignores
   `_MREQ`/`_IORQ`/address entirely, it asserts on *any* `_RD`-low cycle
   while `mode_pin=0` (ROM mode), memory or IO. The 8255's `_CS` is now
   address-qualified (no longer the bare `_IORQ` wire this used to say),
   which narrows the exposure but doesn't eliminate it — an `IN` from
   `0xA8`-`0xAF` while still in ROM mode would still have **both the 595
   and the 8255 driving the data bus simultaneously**: genuine contention
   between two active outputs, not a benign garbage-value situation.
   `OUT` is always safe, though: `NOT(_RD)` requires `_RD` low, and `_RD`
   stays high through the entire duration of any write cycle (`_WR`
   asserts instead) — the 595 categorically cannot drive during a write,
   and the 8255 itself never drives during a write either (it's the
   receiver). **Accepted for now**: Z80-side software must never execute
   an `IN` from the 8255 before the mode switch to SRAM-execution
   completes. Configuring the 8255 (control word) and driving `mode_pin`
   high are both `OUT`s, so a boot ROM that only ever writes to the 8255
   before switching needs no workaround in practice — the constraint just
   needs to be remembered. Real hardware fix (distinguishing memory-reads
   from IO-reads for the 595's gating specifically, while still in ROM
   mode) deferred deliberately, not forgotten.

Unlike the 373 (a transparent latch, no clock, LE tied to VCC
permanently), the 595 is a genuine two-stage device: an 8-bit shift
register (clocked by `SRCLK`, fed by `SER`) feeds a separate 8-bit output
register (loaded from the shift register on `RCLK`'s rising edge, this is
what `databus_send()` pulses after each byte's 8 SPI clocks). `/OE`
governs only the *output* register → `Qn` pins, exactly like the 373's
`OE̅` governed its Q outputs — the shift register's contents are never
visible to the Z80 regardless of `/OE`, so partially-shifted-in bytes
can never leak onto the data bus mid-transfer. `SRCLR̅` (shift-register
clear, no 373 equivalent) must be wired inactive (tied high) since this
design never uses it. See `wiring.md`'s 74HC595 section for the
physical pinout.

## 5. SRAM (TC551001BPL-70L) control — DIP-32

| SRAM pin (DIP-32) | Name | Drive | Equation |
|-------------------|------|-------|----------|
| 31 | CE1 | `_MREQ` | memory select; LOW during any memory cycle |
| 6  | CE2 | VCC | inactive (single-chip); must be HIGH for R/W |
| 32 | OE̅ | see below | LOW only when `mode_pin=0` (SRAM-exec) AND a read is in progress |
| 5  | R/W | **`_WR`, direct wire — no gate** | see below |
| 10 | A16 | GND | collapses 128K → 64K |
| 1,2,3,5,8,10–15,17–22,30,31,32 | A0–A15 | shared address bus | A14/A15 pulled high (video 0xC000–0xFFFF) |
| 20–24,26–29 | I/O1–I/O8 | shared data bus | D0–D7 |

**`_OE`, redesigned**: `OE̅ = NAND(NOT(mode_pin), NOT(_RD))` — one NAND
gate plus one inverter (`NOT(mode_pin)`; `NOT(_RD)` shared with §4).
Asserts exactly when `mode_pin=0` (SRAM-execution) AND `_RD=0` (read in
progress). Deliberately has **no `_MREQ` term** — verified this is
correct, not an oversight, against `hardware/datasheets/tc551001cp.pdf`'s
Operating Mode table: `CE1=H → I/O = High-Z, regardless of OE/CE2/R-W`
(the table's own "*" = don't-care marks for those three columns on that
row). SRAM's `CE1` is already wired directly to `_MREQ` — that gating is
already enforced independently by the chip itself; adding `_MREQ` to the
`_OE` formula would be redundant. Consequence: SRAM never contends with
anything during an IO cycle (`_MREQ` high, deselected) regardless of what
`_OE` computes to.

**`R/W`, redesigned**: a **plain wire from SRAM pin 5 to the Z80's `_WR`
pin — no gate at all.** Same CE1-redundancy reasoning, confirmed via the
same datasheet's Write Cycle section: a dedicated "Write Cycle 2 (CE1
Controlled Write)" timing diagram plus a `tCW` ("Chip Selection to End of
Write") parameter show `CE1` is a fully timed, formal part of the
write-enable logic, not just an output-tristate control — an IO `OUT`
(`_WR` low, `_MREQ` high) cannot trigger a write regardless of `R/W`,
because `CE1` independently blocks it. During the Phase 6 video-steal
window (Z80 tristated), `_WR`'s existing pull-up (§ pull-up table below)
holds `R/W` high/read — no accidental-write risk during a video fetch.

This was the *last* surviving piece of the old `_S`/`_G` gate network
(`R/W = _MREQ OR _WR`, one OR gate) — with it now a direct wire, nothing
from that old network remains at all.

Notes:
- **SRAM CE1 pin is 31, OE pin is 32** on the TC551001BPL DIP-32 (verify
  against tc551001cp.pdf pin table when wiring — the CE1/OE/WE pins are
  easy to transpose).
- During video, the 1284p drives `_MREQ` low (CE1 low) and `_RD` low.
  `mode_pin=0` by then (video only happens after the mode switch), so
  `_OE`'s NAND asserts ⇒ SRAM drives the shared bus into the 166. `_WR`
  pulled high (its existing pull-up) ⇒ `R/W`=1 ⇒ no accidental write.
  Correct.
- During the pre-burst gap (Z80 released the bus, 1284p not yet driving),
  `_MREQ`/`_RD` held high by pull-ups ⇒ CE1 high ⇒ SRAM tri-stated ⇒ no
  contention.

## 6. Video shift register (74LS166A) — DIP-16

**Pinout corrected 2026-09-05** — this section had been carrying wrong
pin numbers since it was first written (pre-dates this session's
redesigns, never actually verified against a datasheet until now).
Rendered `hardware/datasheets/sn74ls166a.pdf` page 1 (text layer
garbled like other datasheets in this project) to get the real pinout:
`1=SER, 2=A, 3=B, 4=C, 5=D, 6=CLK_INH, 7=CLK, 8=GND, 9=CLR, 10=E, 11=F,
12=G, 13=QH, 14=H, 15=SH/LD, 16=VCC`. The old text had CLK at pin 11
(actually the `F` data input), CLR at pin 1 (actually `SER`), and
claimed a "QH' active-low serial output" at pin 16 (actually VCC — this
part has no complementary output at all, just `QH` at pin 13).
**Important for wiring**: the 8 parallel data inputs are *not*
contiguous pins — `A-D` are 2-5, but `E-H` are 10, 11, 12, 14, with
`CLK_INH`/`CLK`/`GND`/`CLR` sitting in between (pins 6-9). Easy to
mis-wire by assuming a simple run of consecutive pins.

- Parallel data inputs `A-H` (pins 2,3,4,5,10,11,12,14) = SRAM
  I/O1-I/O8 (the byte currently on the shared bus during a burst), `H`
  = D7 (MSB) through `A` = D0 (LSB) — see shift-order note below.
- CLK (pin 7) = `clk16` (16 MHz pixel clock) — one bit per pixel (8
  px/byte).
- CLK_INH (pin 6) = GND (tied permanently low): per the datasheet,
  CLK and CLK_INH feed a 2-input positive NOR gate internally, and
  holding CLK_INH high would inhibit clocking entirely — GND keeps
  the register free-running off CLK continuously, which the SH_LD
  design below depends on.
- SH/LD (pin 15, active low) — software-pulsed from a dedicated 1284p
  pin, PD5 (main.c: permanent output, idles high). **Not the pin's
  original candidate** — resolved through two more bench-found bugs
  after the initial choice (open-questions.md #3 originally settled on
  reusing `wait_rel`/PD3):
  1. PD3 doubles as the WAIT flip-flop's async PRESET, held low
     *permanently* by rom_emu.c after ROM emulation exits (that FF has
     no `mode_pin` gating, §3, and would otherwise latch `_WAIT` low on
     every read with nothing to release it). SH_LD pulsing needs the
     opposite resting state (high, "shift", between loads) -- the very
     first burst left PD3 high on return, hanging the Z80's next read.
  2. Forcing PD3 back low after each burst "fixed" that but broke the
     166 instead: SH_LD low is "load" mode, and since CLK never stops,
     resting low between bursts meant the 166 kept re-loading whatever
     floated onto the shared data bus on every clock edge for the whole
     inter-burst/blanking period -- garbage bleeding into the video
     output. PD3 and SH_LD fundamentally want opposite idle states and
     can't share a pin no matter the ordering.
  Fixed for good by moving SH_LD to PD5, which had been the 1284p's
  `_IORQ`-sensing pin for an unimplemented Phase 7 feature -- physically
  disconnected from the Z80's `_IORQ` net on the breadboard (pull-up
  removed, see the pull-up table below) and dedicated entirely to SH_LD
  instead, with no competing role left to conflict with. Per-byte
  recipe unchanged: `adiw` (2, 16-bit address increment) + `out`x2 (1
  each, address to both ports) + `cbi`+`sbi` (2 each, SH_LD low-then-
  high) = 8 cycles exactly, matching the 500ns/byte budget with zero
  cycles spare -- verified safe despite the zero margin against the
  datasheet's function table: SH/LD is re-evaluated on *every* CLK
  rising edge, so holding it low across the 2 edges `cbi`+`sbi`
  guarantees (125ns) means even if the first edge lands before the
  TC551001's ~70ns access time has elapsed, the second edge (125ns
  after the address changed) reloads with the now-settled data and
  simply overwrites the first result. Full per-byte recipe and the
  79-iteration pipeline structure (priming + main loop + trailing
  window) in `open-questions.md` #3 and `video_fetch.c`.

  **2026-09-21 update**: `SH_LD` moved again, off `PD5` entirely, onto
  `PB6`/`OC3A` -- generated by Timer3's own Fast PWM hardware instead of
  the `cbi`/`sbi` pair described above, phase-locked to the video-fetch
  burst (`sync.c`'s `SHLD_TIMER3_PHASE`) so it stays synchronized with
  the address bus regardless of unrelated cycle-count changes elsewhere
  in the ISR. `PD5` is free again. The `cbi`/`sbi` recipe above is now
  historical -- still accurate for how `SH_LD` briefly worked between
  2026-09-05 and 2026-09-21, not for the current design. See `wiring.md`
  and `pin-map.md` for the current pin assignment, `shld_test.c` for how
  the hardware pulse was bench-verified before the real rewire.
- CLR (pin 9, active low) = VCC (never clear mid-frame; garbage content
  before the first real burst is harmless, nothing is displayed yet).
- SER (pin 1) = GND (tie off; parallel loading every byte means the
  serial-shift-in path is never exercised in a way that matters here).
- Serial out = **QH (pin 13)** → composite video mixing network. Shift
  order: loading `A..H` then shifting emits `H,G,F,E,D,C,B,A` on
  successive clocks (datasheet function table) — with `H`=D7(MSB),
  `A`=D0(LSB) per the wiring above, that's D7 first, D0 last: MSB-first.
  Pixel polarity (whether QH's HIGH level means "bright" or "dark") is
  set by the mixing network / an inverter — verify against the monitor
  in Phase 6b.

## 7. 74LS138 IO-port decode — redesigned 2026-09-04, MSX-style

**Rewired on the bench**, superseding both the previous version of this
section *and* resolving the `_CS`-coexistence conflict it used to flag
(§8's 8255 `_CS` is no longer unconditional on `_IORQ` — see below).
Along the way, corrected a real error in the *old* version of this
section: it labeled pin 6 `_G1` (implying active-low) and left pins 4/5
unlabeled as `_G2A`/`_G2B` — backwards. Verified against the local KiCad
symbol library: **pins 4 and 5 are the two active-low enables; pin 6 is
the active-high one.** The old wiring (`_IORQ` tied to pin 6) would have
enabled the chip precisely when *no* IO cycle was in progress — moot now
since this section is fully rewired anyway, but worth knowing the old
one was wrong, not just superseded.

Modeled on real MSX hardware's 8255/PPI decode (0xA8-0xAB), verified by
deriving the address range from the gate-level wiring rather than just
citing the MSX convention:

- Select inputs: pin 1 (`A0`) = Z80 `A3`, pin 2 (`A1`) = Z80 `A4`, pin 3
  (`A2`) = Z80 `A5` → output index = `A5·4 + A4·2 + A3·1`.
- Enables: pin 4 and pin 5 (active-low) = `_IORQ` and Z80 `A6` (either
  pin to either signal, they're interchangeable — both must be low to
  enable). Pin 6 (active-high) = Z80 `A7`.
- Outputs `O0`-`O7` (active low) on pins 15,14,13,12,11,**10**,9,7 respectively.

**`O5` (pin 10) → 8255 `_CS`** (§8). Selected exactly when `A7=1`,
`A6=0`, `A5=1`, `A4=0`, `A3=1`, with `A2`/`A1`/`A0` unconstrained (not
part of the decode) — binary `1010_1xxx` = **0xA8-0xAF**, matching the
`_CS` of a real MSX's PPI. The 8255's own internal register select
(typically its own `A0`/`A1` pins, tied to Z80 `A0`/`A1`) picks among its
4 registers (Port A/B/C/Control) within that window — `0xA8`-`0xAB` are
the 4 addresses that matter; `0xAC`-`0xAF` alias the same 4 registers
again, since Z80 `A2` isn't part of this decode either.

Other `O` outputs are unused for now — free for future IO devices within
this same address-decode scheme, still gated the same way (`_IORQ` +
`A6`/`A7` fixed, only the `A3`-`A5` select differs per device).

**Still flagged, not solved**: `io-map.md` (and the "virtual UART"
register layout plan.md's Phase 7 describes) was written around the
*old*, different A8-A10-based decode scheme with 16-bit-style IO
addressing (`IN r,(C)`, full `B:C` pair) — this new MSX-style A3-A7-based
8-bit-port decode is a different addressing convention entirely.
Reconciling `io-map.md` with what's actually on the breadboard now is
still open (see `open-questions.md`).

## 8. 8255 PPI — `_CS`, `RESET`, mode pin, bank pin

**Pinout and reset/mode-change behavior verified 2026-09-06** (CP/M-
planning session) against the standard 8255A DIP-40 pinout and its
documented control-word behavior — closes the "pending a real datasheet"
gap this section used to carry; see `wiring.md`'s 8255
section for the full pin diagram.

- **`_CS` (pin 6) = 74LS138 `O5` (pin 10), redesigned 2026-09-04 — see
  §7.** Real address-qualified decode now (`0xA8`-`0xAF`, MSX-style), not
  the bare `_IORQ` wire this used to be — resolves §7's old
  "unconditional `_CS` claims the whole IO space" coexistence flag for
  real, rather than just noting it. `_CS` is active low, matching the
  74LS138's active-low outputs directly — no inversion needed, `O5`
  wires straight to `_CS`.

  (Earlier history, before the 74LS138 redecode, kept for the record:
  first tried gating `_CS` by `mode_pin` too — `NOR(_IORQ, mode_pin)` then
  inverted — which created a hard deadlock (`_CS` would only ever assert
  once `mode_pin` was *already* low, but `mode_pin` can only become low
  via a successful write *to* the 8255, which itself needs `_CS` asserted
  — no way to ever get the first write through). Simplified that to
  `_CS = NOT(_IORQ)` — itself wrong, backwards from what an active-low
  `_CS` needs. Then simplified further to a bare `_CS = _IORQ` direct
  wire (correct polarity, but unconditional on address — the coexistence
  problem noted above). All three superseded now by the real 74LS138
  decode.)
- **`RESET` (pin 35) — confirmed active HIGH** against the real 8255A
  datasheet (previously "standard convention, not yet verified" — now
  settled) `= NOT(POR-net)`** (no dedicated 74LS02 in this design — a
  spare gate on 74LS00 #2, §9, wired as an inverter, does this job
  instead). The `POR` net (see above) is the AVR's active-low
  Z80-`_RESET` line (PD2): when the Z80 is held in reset (PD2=0), the
  8255 is also held in reset (`RESET`=1); when released (PD2=1), both
  run. Automatically covered by the same pull-down already planned for
  that net — no separate protection needed for the 8255.
- **All ports confirmed to default to input mode when `RESET` is
  driven high** (previously "standard, well-documented behavior... not
  yet verified" — now settled against the real datasheet), matching
  `mode_pin`'s and `bank`'s pull-resistor-based defaults below.
- **`mode_pin` = Port A bit 0 (`PA0`, pin 4)**, one 8255 GPIO port bit,
  externally **pulled down** (§2 — corrects a stale "pulled up" reference
  that had crept into an earlier draft of this section; §2 itself has
  always specified pull-*down*, this section just hadn't been kept in
  sync). No gate involved — it's a direct input to the 595/SRAM `_OE`
  NANDs (§4, §5).
- **`bank` = Port A bit 1 (`PA1`, pin 3)**, new this session (CP/M
  memory banking, `cpm-plan.md` §2) — one more 8255 GPIO port bit,
  externally **pulled down** (4.7k-10k to GND).

  **History**: briefly dropped this pull-down (reasoning: `mode_pin`'s
  pull-down is load-bearing because it gates the 595/SRAM output-enable
  logic live on *every* memory access from address 0 onward including
  the first instruction fetch, whereas `bank` only affects `A16`, which
  only matters for `0x8000-0xFFFF` — untouched until after Port A is
  configured, at which point the 8255's own "any mode-set write zeroes
  all of that port's outputs" behavior forces `bank` to a known 0
  regardless of the pre-configuration float). **Restored 2026-09-06
  after a real bench finding**: with `bank` unpulled, a program that
  never even touches `bank`/`PA1` (`video-test3.asm`) became unreliable
  specifically tied to addresses at/above `0x8000` (`A15=1`) — stable
  with `SP=$7FFF`, unreliable with `SP=$8000`. The logical argument above
  is still correct about the *software-visible* state being deterministic
  quickly, but it didn't account for a genuinely floating LS-TTL input
  being electrically noisy (capacitive coupling from nearby switching
  signals, not just "an arbitrary but stable wrong value") for however
  long it takes software to pull it to a defined state — `NAND(bank,
  A15)` (and hence `A16`) can glitch the instant `A15` goes high,
  independent of what `bank`'s logical/software value "is" at that
  moment. One resistor is cheap insurance against a real, intermittent
  failure mode; not worth the electrical risk to save it.

(`RESET` inverter gate usage is tallied under 74LS00 #2, §9, since
that's the chip it actually lives on — `_CS` above is a direct wire,
no gate at all.)

## 9. Memory bank switch — 74LS00 #2, SRAM `A16`

New this session (`cpm-plan.md` §2) — lets the top half of the Z80's
address space (`A15=1`) switch between two physical 64K-chip halves,
freeing CP/M from permanently losing 16K of TPA to video RAM. Full
derivation, physical memory mapping, and the reasoning that led here
(considered and rejected a mux/latch network first) are in
`cpm-plan.md` §2 — this section is the settled gate-level result plus
its own truth-table verification, kept in sync with the schematic per
this file's usual role.

**2026-09-07: gate 2's second input is `_BUSACK`, not `_BUSRQ` --
found via a real bench symptom, not caught by the original truth-table
check.** The first version of this circuit used `_BUSRQ` directly, on
the (unverified) assumption that `_BUSRQ` asserted means the Z80 has
already released the bus. It doesn't -- this project's own Z80 UM
lookup, done earlier for an unrelated reason, already established that
"BUSREQ... is always recognized at the end of the current machine
cycle": there's a real window, up to one full machine cycle, between
the AVR asserting `_BUSRQ` and the Z80 actually tristating, during
which the Z80 is still fully active -- still fetching, still driving
the address bus. With `_BUSRQ` gating this circuit, that window forced
`A16=1` while the Z80 was still using the bus for its own, unrelated
purposes, corrupting whatever memory access was genuinely in flight (a
live instruction fetch reading from the wrong physical bank, for
instance) at a rate tied to the AVR's video timing, not the Z80's own
clock -- consistent with two failed fix attempts before this one
(swapping 74LS00 for 74HCT00, and slowing the Z80 to 4MHz) neither
touching the real cause, and with tying `A16` to a fixed level -- either
level -- fixing it completely (a hardwired pin can't be affected by a
signal it no longer listens to at all).

`_BUSACK` (Z80 pin 23, per the real Z80 UM pinout diagram -- verified,
not assumed) is the Z80's own hardware confirmation that it has
actually relinquished the bus (UM: "indicates to the requesting device
that the CPU address bus, data bus, and control signals... have entered
their high-impedance states"). Unlike a fixed delay margin (the
alternative considered and rejected: delaying `_BUSRQ` by roughly
`BUSRQ_SAFE_CYCLES` before it reaches this gate), `_BUSACK` can't be
"too short" for some worst-case instruction, because it's driven by the
real event rather than an estimate of how long the event takes. Costs
nothing pin-wise: `plan.md`'s GPIO budget already dropped `_BUSACK` from
the *AVR's* pin budget (Phase 6b decided not to sense it in firmware,
relying on the fixed `BUSRQ_SAFE_CYCLES` delay instead for the AVR's own
bus takeover) -- wiring it into this gate is a pure hardware connection
that never touches the AVR at all, so that earlier decision stands
unchanged.

- **Gate 1: `X = NAND(bank, A15)`.** `bank` = 8255 `PA1` (§8). `A15` =
  Z80 `A15` directly.
- **Gate 2: `A16 = NAND(X, _BUSACK)`.** Drives the SRAM's `A16` pin
  (TC551001BPL, §5) directly — previously grounded (tied A16 low, per
  `memory-map.md`'s pre-CP/M "128K SRAM, A16 grounded → 64K effective"
  note); that ground strap is removed and replaced by this gate's
  output.
- **Gate 4: wired as an inverter, `8255 RESET = NOT(POR)` (§8)** — no
  dedicated 74LS02 in this design; this spare gate does that one job
  instead, both inputs tied to the `POR` net. Gate 3 remains genuinely
  spare (unused, inputs tied low).

Collapses to `A16 = (bank AND A15) OR busack_asserted` (De Morgan;
`busack_asserted` means `_BUSACK` is being driven low, i.e. the Z80 has
*actually* relinquished the bus for the AVR's video fetch, not merely
been asked to) — truth-tabled before trusting it:

| bank | A15 | `_BUSACK` asserted | A16 |
|------|-----|------|-----|
| 0 | 0 | no | 0 |
| 0 | 0 | yes | 1 |
| 0 | 1 | no | 0 |
| 0 | 1 | yes | 1 |
| 1 | 0 | no | 0 |
| 1 | 0 | yes | 1 |
| 1 | 1 | no | **1** |
| 1 | 1 | yes | 1 |

Two properties this buys, both load-bearing: the AVR's video fetch
*always* forces `A16=1` once the Z80 has genuinely released the bus,
regardless of whatever `bank` the Z80 last left set (video RAM must be
reachable at a fixed physical location no matter what the Z80 was
doing) — the `_BUSACK` term in the OR unconditionally wins, but only
once it's actually safe. And when the Z80 owns the bus, `A16=1` only
when it deliberately asks for it (`bank=1`) *and* is addressing the top
half of its own space (`A15=0` leaves `A16=0` always, permanently
fixing the bottom 32K regardless of `bank` — see `cpm-plan.md` §2 for
exactly what physical bytes this maps where, and why `bank=0` — not
`bank=1` — is CP/M's normal running state).

**New 74LS00 required** — the existing 74LS00 (§4/§5) is fully used (0
of 4 spare, confirmed against the chip budget below), so this can't
share it. This second 74LS00 uses 3 of its 4 gates (bank-switch gates
1-2, plus gate 4 as the 8255 RESET inverter above); 1 spare.

## Gate / chip budget (discrete logic)

**Redesigned 2026-09-02**, **updated 2026-09-06 for CP/M banking (§9)**,
**updated 2026-09-16 for the 373→595 data-latch swap (§4)**, **74LS02
removed** (its one gate, the 8255 `RESET` inverter, moved onto 74LS00
#2's own spare gate 4 — no dedicated NOR chip needed for one inverter)
— see the note at the top of this file for the full before/after
reasoning on the 2026-09-02 redesign; this table is the settled result
including the new bank-switch chip. The 373→595 swap is chip-count-
neutral (one DIP-20 latch for one DIP-16 shift register, same gate
network drives its `/OE`) — it only changes AVR GPIO usage
(`pin-map.md`), not this table.

| Gate | Count | Function |
|------|-------|----------|
| 2-input NAND (74LS00 #1) | 4 of 4 | shared `NOT(_RD)`, `NOT(mode_pin)`, SRAM `_OE`, 595 `_OE` (§4, §5) |
| 2-input NAND (74LS00 #2) | 3 of 4 | bank-switch `A16` logic (§9, gates 1-2), 8255 `RESET` inverter (§8, gate 4) — 1 spare |
| D flip-flop (74LS74A) | 2 of 2 | clk/2 (FF#1), WAIT gen (FF#2) — both on **one** chip now |

⇒ **2× 74LS00** (chip #1 fully used; chip #2 new for §9, 3 of 4 used),
**1× 74LS74A** (down from 2 —
mode latch eliminated), **1× 74HC595** (was 74LS373 until 2026-09-16,
see §4), **1× 74LS166A**, **1× 74LS138**
(MSX-style IO decode, 1 of 8 outputs used, 7 spare for future devices),
**1× 8255** (address-decoded via the 138 rather than claiming all of IO
space; Port A now carries both `mode_pin` and `bank`, §8). All DIP.

Eliminated entirely: 74LS32 (was 2 chips), 74LS08 (was 1), 74LS04
(was 1) — nothing left in the design needs an OR, AND, or standalone
inverter gate; the two inverters the new network still needs are
NAND/NOR-wired instead.

## Pull-up / pull-down summary

| Net | Resistor | Reason |
|-----|----------|--------|
| `_WR` | 4.7k–10k to VCC | never driven by 1284p; must idle high |
| `_IORQ` (to the 1284p) | ~~4.7k–10k to VCC~~ **removed 2026-09-05** | was for the 1284p's own sensing pin, which is gone (see pin-map.md: PD5 physically disconnected from `_IORQ`). PD5 was then a dedicated SH_LD output until 2026-09-21, when SH_LD moved to PB6/OC3A -- PD5 is free again (pin-map.md, video_fetch.c). **Not the same net as `_IORQ` into the 74LS138's enable input (§7)** -- that decoder still needs `_IORQ` to be well-defined while it floats during `_BUSRQ` grant, same as any other 138 enable input would. Double-check on the real board whether removing this resistor takes the 138's own supply with it (one shared pull-up serving both) or leaves it alone (separate pull-ups) -- this doc can't tell which from here. |
| `_MREQ` | 4.7k–10k to VCC | float in pre-burst gap before 1284p drives it |
| `_RD` | 4.7k–10k to VCC | same as `_MREQ` |
| A14, A15 | 4.7k–10k to VCC | place video in 0xC000–0xFFFF |
| `mode_pin` (8255 port pin) | 4.7k–10k to VCC | no internal pull-up on 8255 ports; needed for the ROM-mode default |
| `_INT` | 4.7k–10k to VCC | Z80 input, active low; not addressed anywhere else in this project's docs before this — confirmed populated on the breadboard 2026-09-03 during Phase 4 bring-up, documented here to close the gap. Without it, a floating `_INT` risks a spurious interrupt-acknowledge cycle (asserts `_IORQ` + `M1` together, per the Z80 UM), easy to mistake for a real IO write. |
| `_NMI` | 4.7k–10k to VCC | Z80 input, active low (edge-triggered); same rationale and same confirmation as `_INT` above. |
| `POR` (shared Z80-`_RESET`/PD2/WAIT-FF-`_CLR`/8255-`RESET` net) | ~10k to GND | pull-*down* — see "Power-on reset" above; PD2 is a 1284p GPIO (output, driven by firmware once running), not a passive pull-up net like the others in this table |

Verify pull-up values against real loading in Phase 6b (risk #8).
