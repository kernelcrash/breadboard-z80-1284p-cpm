# Bring-up Log

Phase-by-phase test results, waveform notes, and issues. Newest entry at the
bottom. Format: date — observation / result / action.

## Phase 0 — Scaffolding & toolchain (2026-08-24)

- Repo skeleton created per plan.md.
- Datasheets collected into `hardware/datasheets/`:
  - atmega1284p-datasheet.pdf (Atmel-42719C, 461 pp)
  - z80-um.pdf (Z80 CPU User's Manual, 216 pp)
  - tc551001cp.pdf (TC551001BPL-70L, 1M×8 SRAM, DIP-32, 70 ns)
  - sn74ls373.pdf, sn74ls74a.pdf, sn74ls166a.pdf, sn74ls279a.pdf,
    sn74ls273.pdf, sn74ls138.pdf
  - Note: plain 74LS74/166/279 are obsolete; TI's current part numbers are
    the 'A' variants (LS74A, LS166A, LS279A) — same pinout.
- Toolchain: avr-gcc 15.2.0, avr-as, avr-objcopy, avr-size (present);
  z80asm 1.8 (present); KiCad 9.0.9 (present); **avrdude NOT installed** —
  install before Phase 1 (`sudo dnf install avrdude`).
- `docs/pin-map.md` finalized and verified against the 1284P datasheet
  (DIP-40 has all 32 GPIO; fuses LOW 0xF0 / HIGH 0x91 / EXT 0x0F for
  16 MHz external clock). **Correction (2026-09-01): these three fuse
  values were wrong** — re-derived from the actual datasheet tables
  (rather than assumed) to LOW 0xC0 / HIGH 0xD9 / EXT 0x05. See
  `pin-map.md` Fuse settings section for the full trace; the short version
  is JTAGEN is active-low (0x91 left JTAG enabled, not disabled), the old
  LOW byte encoded a reserved SUT value, and the old EXT byte disabled BOD
  entirely instead of selecting 2.7V.
- Key design corrections vs plan.md:
  - WAIT generation switched from 74LS279 (level latch, broken) to 74LS74
    edge-triggered D flip-flop. See gate-equations.md §3.
  - HSYNC/VSYNC via timer-ISR GPIO toggles (no free OC pins on DIP-40).
    See pin-map.md.
- Smoke tests: avr-1284p firmware builds clean (218 bytes, 0 warnings);
  z80 test programs assemble and disassemble to expected opcodes
  (nop_loop = C3 00 00; fill_pattern verified).
- avrdude NOT installed at time of writing (only thing missing from
  toolchain) — **installed since, avrdude 8.0, confirmed 2026-09-01.**
- Phase 1 stub verified: the PD3 toggle loop is exactly 5 cycles
  (in/eor/out/rjmp), but only one instruction (`out`) changes the pin per
  iteration, so each iteration is one half-period (5 cycles low, then 5
  cycles high) — a 10-cycle full period. PD3 = 16 MHz/10 = **1.6 MHz**
  when the chip runs at the correct 16 MHz. **Correction (2026-09-01):**
  an earlier version of this note said 3.2 MHz, confusing the 5-cycle
  edge rate with the square-wave frequency (which is half the edge rate,
  since a full cycle needs one low half-period and one high half-period).
  1.6 MHz is the scope target that validates the fuses + oscillator; a
  chip actually running at half speed would show 0.8 MHz, not 1.6 MHz.

## Phase 1 — Clock bring-up (design corrections logged 2026-08-25)

Design corrections made to gate-equations.md / bom.csv / architecture.md
after truth-table verification of the discrete logic:

1. **WAIT gen = 74LS74A D-FF, not 74LS279 level latch** (S/R both-active
   conflict). CLK = NOT S (rises at slow-read start), D = 0, /PRE =
   wait_rel, Q = _WAIT. Verified against Z80 UM §Adding Wait States
   (WAIT sampled on falling clock edge during T2/Tw).
2. **SRAM _OE must be mode-gated** (NOT _RD): OE = NOT(NOT G AND mode)
   where G = _MREQ OR _RD. Ungated _OE would put SRAM and 373 on the bus
   simultaneously during every mode-0 read.
3. **R/W = _MREQ OR _WR** — NOT "G OR _WR": during a memory write _RD is
   HIGH, so G is high and would wrongly force R/W high (read). Would have
   silently dropped every SRAM write. Caught by truth table.
4. **Mode latch clock = _IORQ OR _WR** (mode_clk): LOW only during an
   OUT cycle; rising edge at end of OUT latches mode=1. IN cycles don't
   clock (WR high). Consequence: OUT is a one-shot irreversible mode flip
   — boot ROM and SRAM programs must avoid OUT (Phase 7 UART uses IN
   both directions).
5. **Chip count**: 3 D-FFs ⇒ 2× 74LS74A. Gates: 5× OR (2× LS32), 2× AND
   (LS08), 3× INV (LS04). 279/00/02 dropped from BOM.
6. All 9 operating conditions (idle, ROM read m0, SRAM read m1, mem write
   m0/m1, IO read m0/m1, OUT, video m1) verified passing in the §0 table.
7. 74LS74A DIP-14 pinout confirmed: FF1 1=/CLR 2=D 3=CLK 4=/PRE 5=Q 6=/Q';
   FF2 8=/Q 9=Q 10=/PRE 11=D 12=CLK 13=/CLR; 7=GND 14=VCC.
8. TC551001BPL DIP-32 pinout confirmed from datasheet: CE1=31, OE=32,
   R/W=5, CE2=6, A16=10, I/O1-8=20-24,26-29, A0-15 per table. Operating
   mode table: Read CE1=L CE2=H OE=L R/W=H; Write CE1=L CE2=H R/W=L.

Bring-up procedure (hardware on bench):
1. Power: 5 V rail + 100 nF on VCC (pin 10) and AVCC (pin 30, tied to
   VCC). 10 kΩ pull-up on RESET (pin 9) + button.
2. 16 MHz oscillator: CLKOUT → XTAL1 (pin 13). XTAL2 (pin 12) unused in
   external-clock mode. (If the chip doesn't run, swap 12/13 — see
   pin-map note.)
3. 74LS74A chip 1 (clock): FF#1 only — D (pin 2) = **Q1' (pin 6), fed
   back** (NOT GND — a D-FF with D held constant never toggles, see
   `gate-equations.md` §1 / `74ls74a-wiring.md`), CLK (pin 3) = 16 MHz,
   Q (pin 5) = 8 MHz out. /CLR (1), /PRE (4), VCC (14), GND (7) wired.
   (FF#2 of this chip is the mode latch — bring it up in Phase 4.)
   Do **not** populate the Z80 yet (Phase 3) — Q1 is scoped floating/into a
   probe, nothing else on that net needs to exist for this phase.
4. Build + flash: `scripts/build_all.sh` then
   `scripts/program_avr.sh <programmer>` (default `usbasp`; pass the
   programmer id as arg 1 if different). This writes fuses (LOW 0xC0 / HIGH
   0xD9 / EXT 0x05 — see `pin-map.md` Fuse settings for the derivation) and
   the Phase 1 stub (`main.c`, PD3 toggle loop), then reads fuses back —
   confirm the readback matches before going further.
5. Power up. Scope checks, in order (stop and debug before continuing if
   any fails — each depends on the previous):
   a. Oscillator output (XTAL1, pin 13): clean 16 MHz square/sine, stable
      amplitude, no start-up glitch after power stabilizes.
   b. PD3 (DIP pin 17, WAIT-release net, `Z80_CTRL` bit 3): expect a clean
      **1.6 MHz** square wave (16 MHz / 10 — 5 cycles low + 5 cycles high
      per the loop's one `out` per iteration; see `main.c` header comment).
      This is the fuse/oscillator-execution check: if the chip is actually
      running at 8 MHz (wrong CKSEL, or XTAL1/XTAL2 swapped — see
      `pin-map.md` power/clock note), PD3 reads **0.8 MHz** instead.
      **If PD3 is flat**: this is most likely NOT a clock problem — check
      first whether the AVR's own `_RESET` (DIP pin 9) is actually being
      released. ISP programming requires RESET held low to work at all, so
      a successful fuse/flash write proves nothing about whether RESET
      gets released afterward — and some ISP programmers (USBasp clones
      especially) hold target RESET low for as long as they stay
      connected. Disconnect the programmer and confirm a 10 kΩ pull-up to
      VCC is actually populated on pin 9 (per the Power/clock pins table
      in `pin-map.md`) before suspecting the fuses or oscillator.
   c. 74LS74A chip 1, Q1 (pin 5): expect a clean ~8 MHz square wave,
      ~50% duty, tracking the oscillator 1:1 (toggles once per two 16 MHz
      edges). No runt pulses or power-up metastability once settled — if
      Q1 looks asymmetric or glitches, suspect a missing/loose decoupling
      cap (§ note about breadboards ringing at 16 MHz) before suspecting
      the chip.
6. Record actual scope readings here (frequency, duty cycle, any anomalies)
   once run.

## Phase 1 — RESULTS (complete, 2026-09-01)

- Oscillator (XTAL1, pin 13): confirmed clean 16 MHz.
- 74LS74A chip 1 Q1 (pin 5): confirmed ~8 MHz, tracking the oscillator.
- PD3: confirmed 1.6 MHz once the AVR's `_RESET` (pin 9) was actually
  released -- see the real issue hit and fixed below.
- Fuse readback: `lfuse=0xC0`, `hfuse=0xD9`, `efuse=0xFD`. The extended
  byte's upper 5 bits are unimplemented and read back as 1 regardless of
  what's written (`0xFD & 0x07 = 0x05` = the intended `BODLEVEL=101`) --
  expected, not an error; see `pin-map.md` Fuse settings.
- **Real issue found and fixed**: after fuse-programming, PD3 read flat
  with no signal even though fuse write+readback succeeded. Root cause:
  the USBasp programmer was holding the AVR's own `_RESET` (pin 9) low for
  as long as it stayed connected -- ISP itself requires RESET low to
  function, so a successful fuse session proves nothing about whether
  RESET gets released afterward. Disconnecting the programmer (with the
  10 kΩ pull-up on pin 9 populated per `pin-map.md`) let RESET float high
  and the chip started running immediately. Folded into the step 5b
  procedure above for next time.
- **Documentation bug found and fixed** (not a hardware bug): the original
  PD3 expectation of 3.2 MHz was wrong -- see the correction embedded
  above and in `main.c`'s header comment. 1.6 MHz was the correct reading
  for a properly-running 16 MHz chip the whole time.
- Also fixed during this phase (see `pin-map.md` / `open-questions.md` for
  full traces): all three fuse bytes were originally wrong (JTAGEN
  polarity, a reserved SUT value, a disabled-not-2.7V BODLEVEL), and the
  74LS74A clock-divide flip-flop's D input was wired to GND instead of
  fed back from Q' (would never have toggled).

**Phase 1 exit criteria** (all confirmed):
- [x] Oscillator: 16 MHz confirmed on scope.
- [x] PD3 toggle: 1.6 MHz confirmed (validates fuses + external-clock
      execution — the single most important go/no-go check in this phase).
- [x] 74LS74A Q1: ~8 MHz, ~50% duty, clean edges, no power-up glitch.
- [x] Fuse readback from `program_avr.sh` matches LF 0xC0 / HF 0xD9 /
      EF 0xFD (masked & 0x07 = 0x05, BODLEVEL=101).

## Phase 2 — 1284P standalone: monitor + UART + Xmodem (firmware written 2026-09-01)

Firmware-only phase so far; hardware bring-up (USB-serial adapter on the
bench, actually typing at the monitor) is still pending on the user's side.

**Implementation** (`firmware/avr-1284p/src/`):
- `usart.c/h` -- USART0 polled driver. **38400 8N1** chosen over faster
  rates specifically for timing margin: `UBRR=25` gives actual baud
  38461, error +0.16%, vs. 115200's ~3.5% (no U2X) or ~2.1% (with U2X) --
  closes open-questions.md #5's baud-rate half. `RXEN0`/`TXEN0` override
  normal port operation on PD0/PD1 automatically per the datasheet, so no
  manual DDR setup is needed for the UART pins.
- `xmodem.c/h` -- XMODEM-CRC receiver, 128-byte blocks, CRC16-CCITT
  (poly 0x1021), duplicate-block/timeout/CAN handling, buffer-overrun
  guard (aborts rather than overruns if the sender exceeds capacity).
- `monitor.c/h` -- CLI: `help`, `d`(ump)/`w`(rite)/`f`(ill)/`c`(rc) against
  the 1284P's own internal SRAM directly (bounds-checked against
  `RAMSTART`/`RAMEND` from `avr/io.h`, i.e. 0x0100-0x40FF, so a typo can't
  clobber registers/IO space), `x` to receive a file via XMODEM into the
  reserved 8K ROM buffer, `i` to show that buffer's address, `s` as the
  placeholder "start rom emulation" command (reports unavailable until
  Phase 4 hardware exists, per plan.md). Closes open-questions.md #5's
  command-set half.
- `main.c` rewritten from the Phase 1 clock-test stub to call
  `usart_init()` + `monitor_run()`. Also fixed a latent bug while touching
  this file: the old stub drove Z80 `_RESET` **high** (released) by
  default, contradicting CLAUDE.md's documented safe boot state ("the
  1284p starts up and holds the Z80 in reset"). Harmless while the Z80
  isn't populated (Phase 3), but would have been actively wrong the
  moment it was. Now defaults to `_RESET` low (asserted); Phase 3 adds the
  explicit assert/release monitor command plan.md already calls for.
- Build: clean, zero warnings (`-Wall -Wextra`). `.bss` = 8256 bytes
  (`rom_buf[8192]` + a 64-byte line buffer) of the 16 KB internal SRAM,
  leaving ~8 KB for stack. Disassembly-checked (`avr-objdump`) that
  `main()`'s init sequence matches intent, in particular that `_RESET`
  really does come up low.

**Still needed to close out Phase 2** (bench, not firmware): wire the
USB-serial adapter to PD0/PD1, confirm the banner + `help` + `d`/`w`/`f`/`c`
round-trip correctly, upload a known file via `x` and verify its CRC
against a host-computed CRC16-CCITT (e.g. an XMODEM-CRC-capable terminal
program), and soak-test a large/repeated transfer for framing errors or
drops at 38400 baud — per plan.md Phase 2 test criteria.

## Phase 2 — RESULTS: `help`/`d`/`f` confirmed, XMODEM bug found + fixed (2026-09-01)

Bench-tested by the user against the build above. `help`, `d`, `f` all
worked correctly over the USB-serial link at 38400 8N1. `x` (XMODEM
upload, 18-byte test file via minicom) failed: repeated "NAK on sector",
then no ACK on EOT, transfer aborted.

**Root cause (real firmware bug, in `usart_getc_timeout`, not a protocol
mismatch or hardware fault):** the timeout poll checked `RXC0` once, then
slept a full **1 ms** (`_delay_ms(1)`) before checking again if no byte
was ready. At 38400 baud, back-to-back bytes inside an XMODEM block
arrive only ~260 us apart, and the USART has roughly one extra byte of
hardware buffering beyond `UDR0`. Any time the poll happened to land just
before a byte arrived, the 1 ms sleep let 3-4 more bytes arrive and be
silently dropped/overwritten before the next check -- corrupting the
block (and often the following EOT byte too) on essentially every
attempt. `usart_getc()` (used by the monitor's line reader, which is why
`help`/`d`/`f` worked fine) has no such sleep and was never affected --
this bug was specific to the timeout variant, which only `xmodem.c` uses.

**Fix**: rewrote `usart_getc_timeout` as a tight spin loop that checks
`RXC0` every iteration with no delay, using a cycle-counted iteration
budget (`timeout_ms * F_CPU/1000/6`) to approximate the timeout instead of
actually blocking between checks. Disassembly-verified: the compiled loop
is a bare `lds`-from-`UCSR0A` + branch + decrement, no delay call anywhere
in it. Removed the now-unused `util/delay.h` include. Build still clean,
zero warnings; `.text` grew slightly (3400->3436 bytes, the new multiply
for the iteration-budget calculation), `.bss` unchanged.

**Status**: fix is written and builds clean, not yet bench-verified against
real hardware -- reflash and retry the XMODEM upload next.

## Phase 2 — ROM buffer addressing redesign (2026-09-01)

User feedback: raw internal-SRAM addresses for the ROM buffer (wherever
the linker's default `.bss` placement happened to put it, e.g. originally
0x058A) were unfriendly to work with interactively. Iterated through three
ideas in conversation to the following design:

1. First proposal: pin the buffer to a round address, "top half of the
   16K SRAM" (0x2000-0x3FFF). **Rejected before implementing** -- the
   ATmega1284P's stack starts at `RAMEND` (0x40FF) and grows downward;
   0x2000-0x3FFF would leave only 256 bytes (0x4000-0x40FF) before the
   stack, and the XMODEM block buffer alone (128 bytes on the stack,
   nested several calls deep) would overrun that almost immediately.
2. Better proposal: address the buffer **relative to itself**, offset
   0000-1FFF, matching the Z80's own ROM address space (memory-map.md:
   ROM window is Z80 addresses 0x0000-0x1FFF) rather than any raw AVR
   SRAM address. `rd 0100` now shows exactly the byte the Z80 will fetch
   from address 0x0100 once ROM emulation runs -- more meaningful than a
   raw address could ever be, and sidesteps the stack hazard entirely
   since the real AVR pointer no longer needs to be anywhere specific.
3. Follow-up: also pin the *real* underlying SRAM address via the linker,
   for determinism (not something the user needs to type, given #2, but
   worth having fixed rather than implicit). Required real linker-script
   work -- `--section-start` alone bloats flash with 8K of baked-in
   zeros (confirmed via `avr-size`/`objdump` experimentation) unless the
   section is explicitly marked `(NOLOAD)`; and a naive `(NOLOAD)` section
   with an address matching `.data`'s natural start collided with it
   (confirmed via `avr-nm` showing two symbols at the same address).
   Working recipe, `firmware/avr-1284p/rombuf.ld`: `.rombuf` at an
   explicit address (0x1000) clear of both ends -- `INSERT AFTER .bss`,
   `(NOLOAD)`. Verified via `avr-size`/`avr-nm`/`objdump -h`: no flash
   cost (`ALLOC` only, no `LOAD`/`CONTENTS`), correct address, no
   collision.

**Implementation**: `monitor.c`'s `rom_buf` now carries
`__attribute__((section(".rombuf")))`, pinned by `rombuf.ld` (new file,
referenced from the Makefile's `LDFLAGS`). New commands `rd`/`rw`/`rf`/`rc`
mirror `d`/`w`/`f`/`c` but index `rom_buf[]` directly with 0000-1FFF
bounds checking, sharing a refactored `hexdump()`/`crc16_bytes()` core
with the raw-SRAM commands. Since `.rombuf` sits outside
`__bss_start`..`__bss_end`, it isn't auto-zeroed by the C runtime the way
real `.bss` is -- `monitor_run()` now `memset`s it once at startup.

**Found along the way (not a bug, but worth tracking)**: `avr-size` after
this change showed `.data` at 1776 bytes -- much larger than expected.
Cause: every `usart_puts("...")` string literal in the firmware lives in
both flash and RAM (AVR doesn't auto-place string literals in flash the
way most architectures do; needs explicit `PROGMEM`), and the growing
help/status text is now ~11% of the chip's entire 16K RAM. Not urgent
(~1.9K margin still free below the pinned ROM buffer), but tracked as
open-questions.md #7 -- fix before later phases add much more text.

Build: clean, zero warnings. `.text` 3436->4898 bytes (new commands +
shared helpers), `rom_buf` confirmed at SRAM address 0x1000 via `avr-nm`.
Not yet bench-tested against real hardware.

## Phase 2 — PROGMEM refactor: message text out of RAM (2026-09-02)

User question ("why aren't those messages in flash?") led into fixing
open-questions.md #7 immediately rather than deferring it. Root cause
recap: AVR is Harvard architecture -- flash and RAM are separate address
spaces, and an ordinary pointer dereference (what a plain `const char *`
compiles to) can only read RAM; flash needs the special `LPM` instruction.
So a plain string literal gets a RAM copy made at boot purely so ordinary
code can read it, on top of the flash copy that seeded that RAM copy.

**Fix**: added `usart_puts_P()` to `usart.c/h` (`pgm_read_byte()`-based,
distinct from `usart_puts()` for the reason above -- a flash pointer isn't
safe to pass to code expecting a RAM pointer). Moved every message string
in `monitor.c` to `PSTR(...)` + `usart_puts_P()`. Also caught and fixed a
second instance of the same root cause while doing this: the command-name
comparisons in `dispatch()` (`strcmp(cmd, "help")` etc.) were pulling
their literals into RAM the same way -- switched to `strcmp_P` (compares
a RAM string against a flash one, from the same avr-libc PROGMEM family).

**Result**: `.data` 1776 -> 0 bytes. `.bss` (excluding the deliberately-
pinned `rom_buf`) down to exactly 64 bytes (`line[]`) -- confirmed via
`avr-nm` (no `__data_start`/`__data_end` symbols left at all) and
`objdump -s -j .data` (section empty). `.text` 4898->5324 bytes (flash is
cheap here: 128K total vs the 16K of RAM that mattered). Zero warnings.
RAM headroom below the pinned ROM buffer is now ~3.9K of the ~3.75K
`rombuf.ld` originally budgeted for -- comfortable margin restored.

## Phase 3 — firmware prep (2026-09-02)

XMODEM retest from the earlier `usart_getc_timeout` fix skipped by user
choice -- not yet bench-confirmed, revisit if `x` misbehaves later.

Added the two firmware primitives Phase 3 needs before the Z80/SRAM go on
the bus, per plan.md ("Z80 clock/reset/address-bus bring-up (free-running,
no ROM emulation)"):

- `z <0|1>` -- assert/release Z80 `_RESET` on demand (`main.c` already
  defaults to asserted at boot).
- `a [n]` -- sample A0-A13 (n times, hex count, default 1) via the
  existing but previously-unused `z80_read_addr()` helper in `pins.h`.
  Disassembly-verified (not just source-reviewed, given the `.text`
  savings from the PROGMEM refactor made me want to actually check the
  compiler didn't do anything surprising): `PINA`/`PINC` reads, the
  0x3F mask on the high byte, and the 16-bit combine all match intent
  exactly. Note this is `-Os` static-single-call-site inlining at work --
  `cmd_addr`/`cmd_z80_reset`/`dispatch` all got folded into `monitor_run`
  as one function, so there's no standalone symbol to disassemble by name
  anymore; had to grep the whole listing instead.
- `main.c`: explicit `ADDR_LO_DDR`/`ADDR_HI_DDR` input-mode assertion
  added (matches the hardware-reset default already in effect, but kept
  explicit per this file's established belt-and-braces style).

Build: clean, zero warnings, `.text` 5324->5906 bytes, RAM unchanged
(8256 -- the new commands add no globals).

**Hardware still needed on the bench** (per plan.md Phase 3, not done by
this firmware work): populate the Z80 and SRAM (A16 tied low), wire Z80
`_RESET` from the 1284P's existing `BIT_RESET` pin (DIP 16), and pull the
shared data bus to a fixed NOP (0x00) via pull-ups/downs so the Z80
free-runs predictably -- **do not** build the 373/WAIT/mode-latch yet
(Phase 4). Test sequence: `z 0` (should already be the boot default) and
confirm `a 20` reads a stable value with the Z80 held in reset (no bus
contention); then `z 1` and confirm `a 20` shows changing values cycling
through 0000-3FFF (only A0-A13 are wired to the AVR -- A14/A15 aren't
sensed, so the visible pattern wraps every 16384 fetches, not 65536).
Since the AVR's serial-printed samples are necessarily sparse compared to
the Z80's 8 MHz fetch rate, treat this as a quick sanity check only --
the actual Phase 3 exit criterion per plan.md is a logic-analyzer capture
of the real A0-A13 sequence, not this command.

## Phase 4 — ROM-emulation firmware + full wiring docs (2026-09-02)

User asked to push straight through to "Z80 running a small program from
the emulated ROM" -- implementing everything on the firmware/documentation
side in one pass (hardware bring-up on the bench is still the user's).

**Bug caught before it reached real WAIT-latch hardware**: `main.c` had
`WAITREL` (the async PRESET on the WAIT flip-flop, gate-equations.md §3)
idling **low** at boot. Since that PRESET is active-low, idling low means
holding it permanently asserted from power-up -- forcing `_WAIT` released
forever and defeating WAIT generation entirely, contradicting the
documented "FFs reset to Q=0, `_WAIT` starts asserted" power-up
assumption. Fixed: idles high now, only pulsed low momentarily by
`rom_emu.c` once a byte is on the bus.

**`firmware/avr-1284p/src/rom_emu.c`/`.h`** (new): the ROM-emulation poll
loop. plan.md called for hand-written assembly here; used plain C instead
since risk #1 in the same document says the timing is explicitly not a
hard deadline (`_WAIT` can be held low indefinitely, static RAM, no
refresh hazard) -- revisit only if bench measurement shows an actual
throughput problem. Logic: poll `_MREQ`/`_RD`, on both-low index into the
ROM buffer (masked to its size -- see below), drive `DATA_PORT`, pulse
`wait_rel`, wait for the Z80 to move on before polling again; checks for
a UART byte each iteration so the user can abort back to the monitor
(re-asserting `_RESET` first, so the Z80 is left stopped, not wedged
mid-cycle) since otherwise there would be no way back except a power
cycle. Reports (doesn't yet act on) the magic address (0x1FF0) if fetched
-- that's Phase 5.

Caught and fixed a real inconsistency between `memory-map.md`'s wording
("indexes with A0-A13 only") and the ROM buffer actually being 8K (13
bits) while A0-A13 spans 16K: masking with the *buffer size* (`rom_mask =
ROM_BUF_SIZE-1 = 0x1FFF`), not the raw 14-bit address, so a fetch in
0x2000-0x3FFF aliases the same 8K image instead of indexing past the end
of the buffer.

`monitor.c`'s `s` command now actually calls `rom_emu_run(rom_buf,
ROM_BUF_SIZE-1)` instead of the old "not available yet" stub.

**Verification**: build clean, zero warnings, `.text` 5906->6210 bytes,
RAM unchanged. `rom_emu_run` kept its own symbol (external linkage, so
`-Os` didn't inline it away like the fully-inlined monitor.c commands),
which let this get disassembly-traced instruction-by-instruction against
the C source rather than just source-reviewed, given how correctness-
critical this loop is: confirmed the UART-abort check, the short-circuit
`_MREQ`/`_RD` poll (matches C's `||` semantics exactly via two `sbic`
skips), the address read/mask/pointer-arithmetic sequence, the
`DATA_PORT` write, the 2-NOP delay, the `wait_rel` pulse (clear/nop/set),
the magic-address compare, and the "wait for cycle end" loop (matches
C's `&&` semantics via `sbic`/`sbis` skip pairs) all match intent exactly.

**`docs/373-gates-sram-wiring.md`** (new): pin-by-pin breadboard map for
the 74LS373 (data latch), the 74LS32/74LS08/74LS04 gate network computing
`_S`/`M1`/`R-W`/`mode_clk`, and the SRAM -- companion to
`74ls74a-wiring.md` (flip-flops, already documented). 74LS373 and SRAM
pinouts checked directly against their datasheets; a genuinely easy
mistake to make and worth calling out explicitly: **the 373's C/LE pin
(11) must be tied to VCC permanently** -- `gate-equations.md` describes
the desired behavior in words but never states this tie explicitly, and
getting it backwards (tied low or floating) would make the chip latch
stale data instead of passing reads through live, a silent-failure mode
rather than an obviously-broken one. The 74LS32/08/04 gate pinouts were
NOT checked against a local datasheet -- none were collected in Phase 0
-- flagged clearly in both the wiring doc and `bom.csv` rather than
presented with false certainty; they're given from the standard,
decades-unchanged 7400-family arrangement, but should be cross-checked
against the physical parts' actual datasheets before wiring.

**Status**: firmware written, disassembly-verified, builds clean; wiring
fully documented. Nothing has been bench-tested yet -- see next section
for the hardware checklist and test procedure.

### Hardware checklist to actually get here (not done by this session)

Per plan.md Phase 4, in order:
1. Populate 74LS373 (`373-gates-sram-wiring.md`), the gate network
   (2x 74LS32, 1x 74LS08, 1x 74LS04, same doc), and the WAIT/mode-latch
   flip-flops (`74ls74a-wiring.md`, if not already breadboarded from
   earlier phases).
2. Decoupling caps at every chip (100nF, right at the pins).
3. Double-check the four pull-ups (`_WR`/`_IORQ`/`_MREQ`/`_RD`) are
   in place -- this is the first phase where `_MREQ`/`_RD` actually
   matter electrically beyond just being sensed.

### Test procedure

1. Build + flash: `scripts/build_all.sh` then `scripts/program_avr.sh`.
2. Connect, `d` a few bytes of internal SRAM as a sanity check the
   monitor still works.
3. `x`, send `firmware/z80-boot-rom/test-progs/nop_loop.bin` (3 bytes:
   `C3 00 00` = `JP $0000`, an easily-scoped infinite loop) via
   XMODEM-CRC. Confirm the reported CRC.
4. `rd 0000 10` -- confirm the first 3 bytes read back `C3 00 00`.
5. `s` -- releases Z80 `_RESET` and enters the ROM-emulation loop.
6. Logic analyzer on the Z80 address bus: expect it cycling `0000, 0001,
   0002, 0000, 0001, 0002, ...` repeatedly (the `JP $0000` 3-byte fetch
   sequence) -- this is the actual Phase 4 exit criterion per plan.md,
   not just the monitor accepting the upload.
7. Scope the `_WAIT` line over an extended run (minutes, thousands+ of
   fetches): confirm it always asserts and always releases -- a single
   missed release hangs the Z80 permanently, and per plan.md this class
   of bug may only surface intermittently.
8. Send any byte over the serial link to abort back to the monitor
   prompt; confirm the Z80 stops (address bus goes idle/stable again).

## Phase 4 — 74LS74A pin 11/12 correction (2026-09-02)

User question ("do you have D and CLK reversed on FF#2?") caught a real
bug: `gate-equations.md` §1 and `74ls74a-wiring.md` had pins 11 and 12
swapped for FF#2 (D2/CLK2), on a table that had previously been marked
"verified, FindIC + datasheet." Confirmed by reading the actual datasheet
image directly (`pdftotext` garbled this particular PDF's text layer, so
used the rendered page instead) — real pinout is pin 11 = 2CLK, pin 12 =
2D. FF#1's pins (1-6) were correct; only FF#2 (8-13) had the swap, and
only pins 11/12 specifically (8,9,10,13,14 were right).

Impact if wired as previously documented: chip 1's mode latch would not
have worked. The doc told the user to tie pin 11 to VCC (intending the D
input) and route `mode_clk` to pin 12 (intending the clock) — with the
real pinout, that ties the *actual* clock permanently to VCC (no rising
edge, ever) while `mode_clk` drives the *actual* D input instead. `mode`
would never latch. Chip 2's FF#2 is unused (both pins tied to GND either
way), so that one was mislabeled but not electrically wrong.

Fixed in `gate-equations.md` §1/§2, `74ls74a-wiring.md` (pin table, both
ASCII diagrams, all prose, the signal-source table), and the two
references in `373-gates-sram-wiring.md`. All three files cross-referenced
with dated correction notes so anyone who wired chip 1 before 2026-09-02
knows to swap the two jumpers on pins 11 and 12.

**If you've already breadboarded chip 1's FF#2 (mode latch) per the old
diagram: swap the pin 11 and pin 12 connections before proceeding to
Phase 5 mode-switch testing** — VCC should go to pin 12, `mode_clk` to
pin 11.

**Independent cross-check, same day**: user pointed out the local KiCad
install (`/usr/share/kicad/symbols/74xx.kicad_sym`) can be read directly
as a pinout source (plain S-expression text). Extracted pin data for
74LS74's unit 2 (FF#2) from it: `pin 12: D`, `pin 11: C`, `pin 10: ~S`,
`pin 13: ~R`, `pin 9: Q`, `pin 8: ~Q` -- matches the datasheet-image-based
correction above exactly, from a completely independent source. Also used
it to close the "not locally verified" caveat on 74LS32/74LS08/74LS04
(`373-gates-sram-wiring.md`, `bom.csv`) -- pin data extracted matches what
was already documented for all three.

## Phase 4 — mode-latch power-on-reset gap found and fixed (2026-09-02)

User question ("but how does [the mode latch] get to Q=0 in the first
place") surfaced a real, previously-unexamined design gap: nothing in the
circuit ever actively drove the mode latch's `_CLR2` low. D2 is hardwired
to VCC (so any clock edge only ever produces `Q=1`), and both `_PRE2` and
`_CLR2` were tied permanently inactive -- meaning this flip-flop's actual
power-on `Q` value was never anything the hardware guaranteed, contrary to
what `gate-equations.md`/`74ls74a-wiring.md` previously (incorrectly)
asserted ("Power-up: Q2 = 0"). A 74LS74A's power-on state before anything
has actively clocked or cleared it is genuinely undefined silicon
behavior, not a documented reset value -- the datasheet's function table
only covers PRE/CLR/CLK/D responses once those are actively driven.

**Real consequence if left unfixed**: if the mode latch happened to power
up as `Q=1` (SRAM-execution mode) by chance, the entire ROM-emulation
bootstrap would be silently skipped -- Z80 reads directly from
uninitialized SRAM from address 0 instead of the emulated ROM. Since this
depends on silicon power-on bias, it's the nasty kind of bug that could
work on some power-cycles and not others rather than failing consistently
-- likely a very confusing one to chase blind.

Checked the WAIT-generator FF for the same issue (same "`_CLR` tied
inactive" pattern) -- turns out that one is self-correcting: its clock
(`NOT _S`) gets a genuine, well-timed rising edge at the very start of
the Z80's first real fetch cycle, before the Z80 ever samples `_WAIT` at
end of T2, reliably loading D=0 (hardwired to GND) regardless of prior
garbage state. So only the mode latch actually needed a fix. Also
confirmed the clock-divide FF needs nothing -- free-running toggle, Z80
doesn't care about starting phase.

**Fix**: a dedicated RC power-on-reset (POR) network (~10k/~1uF, diode
for fast-discharge on brief power dips recommended), independent of any
AVR firmware timing, feeding both flip-flops' `_CLR` pins (mode latch's
`_CLR2` because it needs it; WAIT FF's `_CLR1` too, for free, now that the
network exists). Deliberately *not* derived from the AVR's Z80-`_RESET`
pin -- that net floats (high-impedance input, no pull-up) until AVR
firmware configures and drives it, which would just relocate the same
undefined-state race into a different window rather than solve it. Full
writeup, including why the AVR itself doesn't have this problem (built-in
POR detector, which discrete 74LS logic lacks), is in `gate-equations.md`'s
new "Power-on reset (POR) network" section.

Updated: `gate-equations.md` (§2, §3, new POR section), `74ls74a-wiring.md`
(both diagrams' `_CLR` pins, both chips' prose, signal-source table,
rewrote the "Power-up note" section which had made the same unexamined
claim), `bom.csv` (added POR capacitor + diode; the resistor reuses the
"spare" 10k already in the BOM), `open-questions.md` (#8, exact R/C value
needs bench verification).

**Not yet built or bench-tested** -- this is a documentation/design fix
only. Add the POR network before wiring the mode latch's `_CLR2` (or if
already wired to VCC per the old docs, rewire it to the POR net instead).

## Phase 4/5 -- WAIT/mode-switch redesign: mode latch -> 8255, chip count 6->4 (2026-09-02)

User proposed replacing the `_S`-derived WAIT flip-flop clock and the
flip-flop-based mode latch with something simpler, to cut chip count.
What followed was an extended, fully plan-mode design session -- worth
logging in detail since the final design differs substantially from
everything documented before it, and because two real dead ends were
found and corrected along the way (both caught by the user, not by me
proactively).

**Verified against real sources at each step, not assumed:**
- Z80 UM Figure 6 (rendered the actual page image -- `pdftotext`'s text
  layer is garbled for this PDF): `_RD`/`_MREQ` fall at T1's falling
  edge; the CPU "samples the WAIT line... during T2 and every subsequent
  Tw... with the falling edge of Clock" (UM's own wording). Confirms the
  new WAIT-FF (CLK=Z80 clock, D=`_RD`) loads `_WAIT` a full T-state
  before the Z80 checks it.
- TC551001 SRAM datasheet's Operating Mode table (`CE1=H -> High-Z
  regardless of OE/CE2/R-W`) and Write Cycle section ("Write Cycle 2
  (CE1 Controlled Write)" diagram, `tCW` parameter): both confirm that
  SRAM's `CE1` (already wired to `_MREQ`) independently gates reads *and*
  writes, making the old `_S`/`_G`-derived `_MREQ` terms in both the SRAM
  `_OE` and `R/W` formulas redundant -- `_OE` simplifies to a 2-input
  NAND on `mode_pin`/`_RD` alone, and `R/W` becomes a plain wire to `_WR`,
  no gate at all.
- 74LS00 and 74LS02 pinouts checked against the local KiCad symbol
  library, **including each pin's electrical type** (input vs output),
  not just pin-number groupings -- this specifically caught that 74LS02
  has a different arrangement than 74LS00 (gates 1-2 put the output on
  the *low*-numbered pin, backwards from 74LS00's convention), a
  well-known but easy-to-miss 7400-family gotcha.

**Final design** (full derivation in `gate-equations.md`, physical wiring
in `74ls74a-wiring.md` and `373-gates-sram-wiring.md`):
- WAIT flip-flop: now FF#2 of the *same* 74LS74A chip as the clock
  divider (was its own second chip). CLK=Z80 CPU clock, D=`_RD`,
  PRESET=`wait_rel` (unchanged AVR pin/pulse, no firmware change),
  CLEAR=shared `POR` pull-down net.
- Mode signal: one 8255 GPIO pin (`mode_pin`), externally pulled up.
  Defaults HIGH (ROM mode, 8255 ports reset to input) -- **not yet
  datasheet-verified locally**, no 8255 datasheet collected. Software
  later drives it LOW for SRAM-execution. No longer hardware-enforced
  one-way, unlike the old flip-flop -- a software convention now.
- `SRAM _OE = NAND(NOT(mode_pin), NOT(_RD))`, `SRAM R/W` = direct wire to
  `_WR`. `373 _OE = NAND(mode_pin, NOT(_RD))`.
- POR: retired the RC network from the previous log entry above, in
  favor of a plain pull-down resistor on the shared Z80-`_RESET`/PD2 net
  (also feeds the WAIT FF's `_CLR` and, via inverter, the 8255's
  `RESET`) -- simpler, and closes a gap the RC fix never covered (the
  Z80's own `_RESET` pin floating during the AVR's startup window, not
  just the flip-flops).
- New 8255 `_CS = _IORQ` (direct wire, active-low, entire IO space for
  now) and `RESET = NOT(POR)` (one 74LS02 gate).

**Two dead ends found and fixed before any hardware was built** (both by
the user, worth recording precisely since they're the kind of mistake
that's easy to repeat):
1. First `_CS` version also gated on `mode_pin`
   (`NOR(_IORQ, mode_pin)` then inverted) -- creates a hard deadlock:
   `_CS` only ever asserts once `mode_pin` is *already* low, but
   `mode_pin` can only become low via a successful write *to* the 8255,
   which itself needs `_CS` asserted. No way to ever get the first write
   through. Simplified to `_CS` depending on `_IORQ` only.
2. That simplification was first written as `_CS = NOT(_IORQ)` -- wrong
   polarity, since `_CS` is active-low (same as `_IORQ` and every other
   `_`-prefixed signal in this design) and needs no inversion at all;
   `NOT(_IORQ)` would have *deselected* the 8255 exactly when IO is
   active. Corrected to a direct wire, `_CS = _IORQ`.

**Two limitations accepted deliberately, not solved** -- see
`gate-equations.md` §4 for full reasoning, flagged prominently rather
than left as footnotes since they matter for every later phase touching
IO:
1. AVR-virtualized IO (373-served reads, e.g. a future UART) stops
   working entirely once `mode_pin` goes low. No design exists yet for
   this once Phase 7 needs it.
2. `IN` (not `OUT` -- verified separately that `_RD` staying high through
   any write cycle makes `OUT` categorically safe) from the 8255 while
   still in ROM-emulation mode causes real bus contention between the
   373 and the 8255. Accepted as a hard boot-ROM constraint (never read
   the 8255 before the mode switch) for now.

**Chip-count accounting** (the actual point of the exercise): 74LS74A
2->1, 74LS32 2->0 (eliminated), 74LS08 1->0 (eliminated), 74LS04 1->0
(eliminated), +74LS00 (1, new), +74LS02 (1, new, only 1 of 4 gates
used), +8255 (1, new, 40-pin). Net: 6 chips -> 4, a genuine reduction
despite adding the 8255 -- found incrementally, each piece of the old
`_S`/`_G` network turning out redundant with SRAM's own `CE1` once
traced against the real datasheet rather than assumed.

**Also surfaced, not yet resolved**: the existing 74LS138/`io-map.md`
Phase-7 IO-decode scheme now conflicts with the 8255's unconditional
`_CS = _IORQ` (claims the whole IO space, no address decode). Flagged in
`gate-equations.md` §7 and `open-questions.md` #10, deferred to whenever
Phase 7 is actually designed.

**Status**: fully documented (`gate-equations.md`, `74ls74a-wiring.md`,
`373-gates-sram-wiring.md`, `pin-map.md`, `bom.csv`, `open-questions.md`
all updated), truth-table-verifiable but not yet re-verified against a
full operating-condition table the way the original `_S` table was (see
`open-questions.md`'s "Verification" note in the approved plan). No
hardware built or bench-tested for any of this yet -- next step is
physically wiring it, plus pulling a real 8255 datasheet before doing so.

## Phase 4 -- FIRST REAL BENCH TEST, and a real bug found + fixed (2026-09-03)

User's first breadboard test of the redesigned WAIT mechanism (reduced
config: clock/2 + WAIT-gen 74LS74A, 1284P-to-Z80 wiring, 373 gated by the
74LS00's `373_OE` output only, SRAM physically present but `_CE` tied
high/disabled for this test). Result: **first two ROM fetches worked
completely correctly** (`_MREQ`/`_RD`/`_WAIT` assert, `wait_rel` pulses,
next cycle begins) -- real, working, on-hardware confirmation of the new
WAIT-FF design, the AVR poll/serve/pulse loop, and address reading, all
together for the first time. Third fetch hung permanently: `_WAIT`
asserted, `wait_rel` never pulsed.

**Root cause, diagnosed correctly by the user in real time and confirmed
against the Z80 UM**: `rom_emu_run()`'s "wait for `_MREQ`/`_RD` to go high
before polling again" loop (added when the loop was first written, to
avoid re-serving an in-progress request) relied on sampling a guaranteed-
high gap between consecutive read cycles. That gap only reliably exists
after an **M1 (opcode fetch)** cycle -- confirmed via the UM: *"Clock
state T3 and T4 of a fetch cycle are used to refresh dynamic memories...
An RD signal is not generated during refresh time"* -- meaning `_RD`
stays high for a full 2 T-states (250 ns @ 8 MHz) after M1 specifically.
Plain memory-read M-cycles (operand fetches, no refresh) have no such
mandated gap. The test ROM (`nop_loop.bin`, `JP $0000`) fetches
opcode(M1)/operand-lo(M2)/operand-hi(M3) -- the M1->M2 gap (fetch 1->2)
was wide and easy to catch; the M2->M3 gap (fetch 2->3) had no refresh
cushion and was evidently narrower than the AVR's poll granularity, so
the wait-loop never sampled a high value and spun forever, never
returning to the top of the poll to serve the next (already-started)
request.

**Fix**: removed the wait-loop entirely rather than trying to make it
faster. Traced that it's not actually needed for correctness -- if the
loop returns straight to the top of the poll after releasing `_WAIT`, an
in-progress cycle just gets harmlessly re-served (same address, same
byte, idempotent `wait_rel` pulse) until the Z80 genuinely advances, at
which point the poll naturally picks up the new address on its own --
never relies on observing a transition at all, so a missed/narrow gap
between cycles can't hang it. Only cost: the magic-address print could
in principle fire more than once for the same event if the Z80 takes a
few extra AVR iterations to move on -- cosmetic, not yet relevant
(Phase 5). Disassembly-verified (matching this project's standard for
this file): both exit paths (magic address matched or not) now jump
straight back to the top of the poll, nothing else in the loop changed.

**Also removed**, same session: the `nop` between the `wait_rel`
clear/set pair. Checked against the actual datasheet
(`hardware/datasheets/sn74ls74a.pdf`, recommended operating conditions
table) rather than assumed: minimum `PRE`/`CLR` low pulse width is 30 ns;
`cbi`/`sbi` are each 2 AVR clock cycles, so back-to-back (no `nop`) the
pulse is still a full 125 ns @ 16 MHz -- over 4x the datasheet minimum.
Disassembly-confirmed the two instructions are now genuinely back-to-back
(no instruction between them) and that the separate pre-pulse settle
delay (2 `nop`s before the pulse, for the 373's propagation margin) is
untouched.

Build: clean, zero warnings, `.text` 6210->6200 bytes (two instructions
removed net). Not yet re-tested on the bench with these fixes -- next
step is reflashing and confirming the Z80 gets past fetch 3 and continues
looping through the `nop_loop` test ROM indefinitely.

## Phase 4 -- CONFIRMED WORKING on the bench, plus first IO-write test (2026-09-03)

Reflashed with the wait-loop removal and the `nop`-free `wait_rel` pulse.
**Confirmed working**: the Z80 now runs `nop_loop.bin` indefinitely,
looping through fetches 1/2/3 repeatedly with no hang -- the wait-loop
race condition diagnosed and fixed above is resolved on real hardware,
not just in theory.

**Measured timing** (logic analyzer): `_RD` low for 2-2.5us per ROM byte
(AVR poll+serve+pulse overhead) -- extrapolates to ~16-20ms for a full 8K
ROM copy, comfortably inside the "well under one frame" budget plan.md's
risk #1 called for, nothing to act on. `wait_rel` pulse measured at
~120ns -- matches the disassembly-based prediction from removing the
inter-pulse `nop` (2 back-to-back 2-cycle `cbi`/`sbi` @ 16MHz = 125ns
predicted) almost exactly.

**First hardware IO-write test**: wired a 74LS174 off `_IORQ` (clocked
directly, no address decode) with an LED on Q0, and ran a new test
program, `firmware/z80-boot-rom/test-progs/blink.asm` -- toggles the
accumulator between 0/1 and does `OUT ($00),A` in a loop with a ~65536-
iteration `DEC HL` delay between toggles. LED blinks visibly. This is
**pure hardware** -- `OUT` drives `_IORQ`+`_WR` (never `_MREQ`/`_RD`), so
`rom_emu_run()`'s poll correctly ignores it entirely (its guard clause
requires `_MREQ` or `_RD` low, both stay high through any write cycle) --
first confirmation that Z80-driven IO writes work end-to-end on this
board, entirely independent of the ROM-emulation path and not touching
the AVR at all, exactly matching the design's "writes never go through
the AVR" intent.

Briefly suspected (wrongly) that the blinking might be a spurious
interrupt-acknowledge cycle rather than real `OUT` activity -- confirmed
from the Z80 UM that IACK cycles do assert `_IORQ`+`M1` together and
would look similar on this 174 (no address decode to distinguish them),
but the suspicion was based on the wrong test program (`nop_loop.bin`,
which has no `OUT` at all) -- once `blink.asm`'s actual content was
checked, the blinking was fully expected. Worth remembering as a real
future hazard regardless: **user confirmed `_INT` and `_NMI` already have
pull-ups populated on the breadboard** -- not documented anywhere in this
project before now (neither pin had been discussed at all), added to
`gate-equations.md`'s Signals and Pull-up tables and `bom.csv` to close
that gap.

**Status**: Phase 4's core mechanism (ROM emulation via WAIT-stalled
reads) is now bench-confirmed working, plus a first successful hardware
IO-write test. Not yet done: SRAM re-enabled (currently `_CE` tied high/
disabled for this test), 8255/mode-switch hardware (Phase 5), and the
formal Phase 4 exit criteria from plan.md (extended `_WAIT` soak test,
full `nop_loop` address-sequence logic-analyzer capture).

## Phase 5 -- 8255 wired, real bench finding on mode_pin polarity, MSX-style IO decode (2026-09-04)

User wired the 8255 and hit a genuine hardware gotcha before it caused a
real bug: configuring an 8255 port as an output is documented behavior to
force that port's pins **low** immediately, regardless of whatever an
external pull-up was holding them at. The original `mode_pin` scheme
(HIGH via pull-up = ROM default, reconfigure-to-output implicitly forces
LOW = SRAM mode) meant merely *preparing* to switch modes (reconfiguring
the port, a necessary first step before ever intentionally driving it)
already triggered SRAM mode -- before the boot ROM had copied anything or
done any real setup. **Fixed by flipping the convention**: `mode_pin` LOW
= ROM mode, HIGH = SRAM mode. The forced-low state on reconfiguration is
now harmless (still reads as ROM mode); an actual switch needs a
deliberate follow-up write driving the pin HIGH. Confirmed the SRAM/373
`_OE` NAND formulas need swapping (which gate gets `mode_pin` raw vs.
inverted) to match -- **not yet applied to `gate-equations.md`**, pending
confirmation on whether the external resistor was also changed from
pull-up to pull-down (required for the fix to hold at power-on, before
the 8255 is even configured -- see `open-questions.md` #11).

**Also wired**: a 74LS138 for IO decode, modeled on real MSX hardware's
8255/PPI address assignment. `A`/`B`/`C` = Z80 `A3`/`A4`/`A5`, the two
active-low enables = `_IORQ` and Z80 `A6`, the one active-high enable =
Z80 `A7`, `O5` -> 8255 `_CS`. Verified the resulting address range by
deriving it from the gate-level wiring rather than just trusting the MSX
comparison: `1010_1xxx` = `0xA8`-`0xAF`, matches exactly. Verified the
74LS138 pinout against the local KiCad library while documenting this,
which caught a **real error in this project's earlier (unbuilt, Phase-7-
placeholder) 74LS138 section**: pin 6 had been labeled as an active-low
enable; it's actually the chip's one active-high enable, backwards.
Moot now since that section is fully superseded, but worth knowing the
old one was never actually correct, not just outdated.

This also resolves (for real, not just by fiat) the "8255 `_CS` claims
the whole IO space, conflicting with the 74LS138-based Phase 7 scheme"
item flagged 2026-09-02 -- the 8255 now has genuine address-qualified
`_CS`. Surfaced a different, still-open item in its place though:
`io-map.md` was written around an older, different (A8-A10-based,
16-bit-IO-style) decode scheme that doesn't match this new MSX-style
8-bit-port convention at all -- not yet reconciled.

Updated: `gate-equations.md` §7 (full rewrite) and §8 (`_CS` now via the
138), `373-gates-sram-wiring.md` (new 74LS138 wiring section, `_CS` row
updated), `bom.csv`, `open-questions.md` (#10 partially closed, #11 new
-- the pull-resistor question). **Not yet updated**: `gate-equations.md`
§2/§4/§5's `mode_pin` polarity and NAND formulas, pending the pull-
resistor confirmation above.

## Phase 6 prep -- magic-address exit, HSYNC/VSYNC timers (2026-09-04)

`memtest-plus-blink.asm` confirmed working on the bench (3 short blinks,
pause, repeat -- all 32K of SRAM verified good). Moving on to video
generation prep, per plan.md Phase 6a/6b:

- **Magic address changed `0x1FF0` -> `0x3FFF`** (`rom_emu.h`): the top
  of the full 14-bit address range instead of "top of the current 8K
  buffer" -- can't collide with a real ROM image's own addresses no
  matter how big that image grows. `rom_emu_run()` now actually returns
  (`rom_emu_exit_t`: `ROM_EMU_EXIT_ABORT` / `ROM_EMU_EXIT_MAGIC`) instead
  of just logging and looping forever; `monitor.c`'s `cmd_start()`
  dispatches into a new `video_run()` (`video.c`) on the magic exit.
  `memory-map.md` updated to match.

- **Self-caught bug**: `pin-map.md`'s HSYNC timer table had `OCR1A =
  63999` for a claimed 64.000us period at a ÷16-prescaled 1MHz clock --
  a 1000x error (that's 64ms), *and* ÷16 isn't a valid Timer1
  CS12:CS11:CS10 option at all (checked the real datasheet Table 17-7:
  only ÷1/8/64/256/1024 exist). Fixed.

- **User-raised concern, and it was right**: does a plain compare-match
  ISR toggle actually hit the pin at a consistent cycle count, or is
  AVR interrupt latency itself jittery? It's jittery -- confirmed via
  the datasheet (Sec. 8.8.1: 4 cycles minimum + 3 more for the vector
  table's `JMP` on this device, plus whatever instruction was mid-
  flight). User pointed at the Uzebox AVR-console project's technique
  (read the timer's own counter at ISR entry to measure exactly how
  much latency already happened, then burn a compensating delay before
  touching the output pin) as the applicable fix -- implemented it:

  - Timer1 now runs **unprescaled** (16 MHz, `OCR1A=1023` for the same
    64.000us period) instead of ÷8, so `TCNT1` has single-cycle
    resolution. The ISR reads `TCNT1L` as its very first act -- this
    measures 100% of the elapsed jitter (both the datasheet minimum and
    the compiler's own ~19-cycle register-save prologue, which turned
    out to matter far more than the interrupt latency itself) as one
    number, then dispatches into a 40-entry NOP sled via a computed
    `ijmp` (single-cycle-resolution runtime delay) to always reach the
    PC6 toggle at a fixed, constant `SYNC_TARGET=48` cycles after the
    true hardware edge. Full design/reasoning in `sync.c`'s header
    comment.
  - **Caught my own arithmetic slip while verifying this**: the fixed
    "cycles after the TCNT1 read" constant (`SYNC_REMAINDER`) was first
    hand-counted as 6, forgetting the `pad` computation's own 2 cycles
    (`ldi`+`sub`) -- corrected to 8 after cross-checking instruction-by-
    instruction against this file's own compiled `avr-objdump` output,
    not just re-deriving it by hand again. Exactly the kind of slip the
    project's disassembly-verification habit exists to catch.
  - User separately noted VSYNC doesn't need this rigor, only HSYNC
    does. Already true of the design as built: VSYNC is no longer a
    second independent timer at all (see next point), it's derived
    from the same already-corrected ISR's own line counter, so it
    inherits HSYNC's precision for free without needing any of its own.
  - **Also fixed a real design bug this surfaced, independent of
    jitter**: the original two-timer version drove VSYNC off a free-
    running Timer3 (20.000ms), fully independent of Timer1/HSYNC. Even
    with both exact, two unsynchronized timers can't guarantee an
    integer line count per frame -- VSYNC could land mid-line and drift
    frame to frame (a rolling-picture bug). `plan.md` already said the
    right thing ("VSYNC position ... set by firmware counting HSYNC
    interrupts") but `sync.c` didn't actually do that yet. Fixed: no
    Timer3 at all now, a 312-line counter inside the Timer1 ISR toggles
    PC7 at line 0 and line 156.
  - **Still NOT bench-verified** -- the whole cycle count above is
    hand-derived + disassembly-cross-checked, not measured. Once this
    is on real hardware, check HSYNC edge-to-edge jitter on a logic
    analyzer (should be ~1-2 cycles / 125ns, not the several-hundred-ns
    a naive ISR would show) before trusting it further.

- **Flagged, not yet designed**: the Phase 6a/6b pixel-fetch "wait for
  HSYNC" trigger (the loop that decides exactly when to assert `_BUSRQ`
  and start the 80-byte address burst) should poll the hardware compare
  flag/`TCNT1` directly rather than sample the ISR-toggled PC6 pin --
  that sidesteps needing any jitter correction there at all, since the
  flag is set by hardware on the exact true edge with zero software
  latency in between. Not yet implemented; `_BUSRQ` timing, the
  80x500ns address loop, and SH_LD generation for the 74LS166 are all
  still open (plan.md Phase 6a/6b, open-questions.md).

New files: `sync.c`/`sync.h` (HSYNC/VSYNC generation), `video.c`/
`video.h` (Phase 6 entry point from `rom_emu_run()`'s magic-address
exit -- currently just starts sync generation and idles, no video steal
yet; the Z80 keeps running freely, e.g. `memtest-plus-blink.asm` keeps
blinking its own LED independent of this). Next bench milestone: flash
this, run `s`, confirm HSYNC (PC6) and VSYNC (PC7) are stable on a
scope while the Z80's LED keeps blinking -- exactly the test the user
asked for.

### "Fat pixel" visual jitter test (2026-09-05)

User suggested a much better bench test than trusting a scope trace of
PC6 alone: actually exercise `_BUSRQ` (like the real design will) and
feed a stable/unstable pulse into the composite video stage directly --
a visible jiggle is far easier to judge than reading edge jitter off a
scope. Added to the same (already jitter-cancelled) Timer1 ISR, gated
to the first 200 lines per frame: assert `_BUSRQ` for a fixed 40us
window in the middle of the line, pulse PD3 high-then-low at a fixed
point inside that window, release `_BUSRQ`. No address bus / `_MREQ` /
`_RD` involvement -- not Phase 6a's real video steal, purely a test
aid. PD3 reused as the pulse output (normally the WAIT flip-flop's
PRESET, see rom_emu.c) -- verified safe: while `_BUSRQ` is asserted the
Z80 has released the bus and isn't sampling `_WAIT`, so this can't
affect Z80 behavior. plan.md had flagged reusing this pin during video
mode as needing "a wiring/timing check, not just an assumption" -- this
is that check, and it holds.

All three delays (`_BUSRQ` assert, pulse point, `_BUSRQ` release) are
`__builtin_avr_delay_cycles()` compile-time constants anchored off the
already-corrected HSYNC toggle -- verified this AVR-GCC builtin
produces exactly the requested cycle count (test-compiled a standalone
case, checked the disassembly: `144` cycles requested, `144` cycles of
`ldi`+`dec`/`brne` generated, exact). Since everything downstream of a
fixed point is deterministic cycle counting with zero further runtime
variance, none of this needs its own jitter correction -- it inherits
HSYNC's precision automatically.

Checked the total ISR cycle budget against the 1024-cycle (64us) line
period by hand-counting the full compiled disassembly (worst case: full
40-cycle sled + the `_BUSRQ`/pulse block active) -- roughly 900 cycles,
~120 cycles (7.5us) of margin. Not dangerously tight but not huge
either; noted in sync.c as the first place to trim if headroom is ever
needed (the sled's realistic typical case is ~12-14 cycles, not the
40-cycle worst case budgeted for).

Next bench milestone (supersedes the plain-scope one above): flash, run
`s`, feed PD3 into the video/composite stage, and look for a single
stable ~200-line-high white bar -- any jiggle means jitter is escaping
the correction.

### Real hang bug found and fixed before ever reaching the bench (2026-09-05)

While writing `video-test1.asm` (the first Z80-side test of the magic-
address exit), traced through what actually happens electrically right
after `rom_emu_run()` returns and found a genuine bug: the WAIT flip-flop
(gate-equations.md §3, redesigned 2026-09-02) has `D` tied straight to
`_RD`, unconditionally -- no `mode_pin` gating. `plan.md`'s original
architecture recap already called this gating "critical... without it
the Z80 would WAIT-stall on every fetch once running from SRAM, with
nothing left to release it", but the redesign dropped it, and it was
never caught because the *previous* `rom_emu_run()` ran forever
regardless of the magic address -- it kept blindly pulsing `wait_rel`
for every observed read, ROM or SRAM, for as long as the Z80 ran, which
had the same net effect by accident. Once last turn's change made that
loop actually exit on the magic address, the gap became real: the very
next Z80 instruction fetch, whatever mode it's in, would latch `_WAIT`
low with nothing left running to release it -- a permanent hang.

First instinct was a hardware fix (add an OR gate so `D = OR(_RD,
mode_pin)`, forcing D high in SRAM mode). User pointed at a much better
one: since `wait_rel` is the FF's async PRESET, `rom_emu_run()` can just
drive it low **and leave it there** on the magic-address exit path,
instead of restoring it high. Holding PRESET asserted forces `_WAIT`
permanently released regardless of `_RD`/CLK from then on -- electrically
equivalent to mode-gating D, but zero extra gates, firmware-only. Fixed
in `rom_emu.c`; `gate-equations.md` §3 updated to document the mechanism
(and the near-miss). Also confirmed this doesn't conflict with `sync.c`'s
reuse of the same pin for the "fat pixel" test pulse -- that pulse always
returns to low, preserving the new invariant, and happens deep inside the
`_BUSRQ` window where `_RD` is passively pulled high anyway (Z80 has
already released the bus), so there's no window where a real read could
get mis-latched during the brief high blip.

Added `test-progs/video-test1.asm`: copies itself to SRAM, switches to
SRAM mode, blinks the LED 3 times (proves SRAM execution), reads the
magic address, then does a plain 50% duty slow blink forever -- if the
LED keeps blinking past the initial 3, the fix is working; a hang right
there means it isn't. Assembled to 75 bytes, no CALL/RET/PUSH/POP,
every jump target hand-traced against the `z80dasm` output (loop1,
b3_delay_on/off, blink3 via DJNZ, sb_delay, slowblink), magic-address
operand confirmed as raw bytes `3a ff 3f` = `LD A,($3FFF)`. Not yet
bench-tested -- this is the next thing to flash and try.

### First real bench result on video-test1.asm: HSYNC period bug (2026-09-05)

User flashed and ran it. LED behavior not reported yet either way, but
the wait_rel-held-low fix must have worked well enough for `video_run()`
to actually start, because the user measured the sync outputs: **HSYNC
64us low / 64us high (128us period, not the intended 64us); VSYNC 10ms
low / 10ms high.**

HSYNC: a real, clean bug, not a measurement artifact -- the ISR *toggled*
PC6 (wrote 1 to the PINx bit) once per call, and it's called once per
64us line. Toggling at that rate necessarily produces a signal whose
period is 2x the calling interval (each phase lasts one full interval),
not a wave "at the right frequency" as this file's own header comment
claimed -- that claim was simply wrong, an error in the original design
reasoning, not something that could have been caught without a bench
measurement. 64us low + 64us high matches the bug exactly (each phase =
one ISR interval).

VSYNC: almost certainly *not* a distinct bug -- its period comes from
*counting* ISR calls (toggle at line 0 and line 156 of 312), and the ISR
itself does fire at the correct 64us rate regardless of what the HSYNC
output bug did to PC6's waveform. 156 lines x 64us = 9.984ms per half,
19.968ms total -- "10ms low, 10ms high" reads as a natural rounding of
that on a scope, not a 20.000ms-exact measurement. Flagged to the user
as the working theory; revisit if a more precise re-measurement disagrees.

**Fix** (`sync.c`): stopped toggling. Each ISR call now explicitly drives
HSYNC low at the line start (the existing jitter-cancelled point) and
high again at the line's ~32us midpoint -- every line produces its own
complete low-then-high pulse instead of relying on state carried across
separate calls. The high edge is folded into the *existing* ~32us
checkpoint already used for the `_BUSRQ`/fat-pixel work (lines 0-199),
costing zero extra ISR cycle budget; a new, simpler single-delay `else`
branch gives lines 200-311 the same high edge at the same point, since
they don't do the `_BUSRQ` work. Re-verified all four delay constants
(144/318/314/462 cycles) against the recompiled disassembly, exact
matches; the `else` branch correctly rejoins the shared VSYNC/line-
counter tail rather than duplicating it.

### Second bench round: right period, wrong shape (2026-09-05)

User reflashed and re-measured: HSYNC period was now correct (~32-34us
low/high, ~64us period -- the round-1 fix worked), but "not a short low
pulse", i.e. still a 50% square wave, not a usable sync waveform. VSYNC
unchanged, still 10ms/10ms.

Right call -- a 50% duty square wave doesn't do anything useful for a
real sync separator; both signals need to be a short LOW pulse (relative
to their own period), not a symmetric wave. This wasn't a bug in round
1's fix (which only targeted the *period*, exactly as reported at the
time) -- it's a second, deliberate simplification from the original
2026-09-04 design ("plain 50% duty square wave... not PAL-accurate
narrow sync pulses") that turned out to need fixing sooner than
"eventually, in Phase 6b" once real bench testing started.

Fixed properly this time, not just retuned:
- **HSYNC**: short ~4.7us LOW pulse at the line start (matches real PAL/
  CCIR horizontal sync timing, ITU-R BT.470 -- not required for this
  project's own display, but free to match and more likely to lock a
  real sync separator than an arbitrary width), HIGH for the rest of the
  64us line. The high edge is now on its own dedicated fixed delay,
  decoupled from the `_BUSRQ`/fat-pixel checkpoint it used to share
  (that work still starts around 12us in, long after this pulse ends).
- **VSYNC**: broad LOW pulse across the first `VSYNC_PULSE_LINES` (3)
  lines of the frame (~192us), HIGH otherwise -- replaces the toggle-at-
  line-0-and-156 50% wave entirely. Simplified stand-in for real PAL's
  ~2.5-line broad vsync pulse (no equalizing pulses), same "not
  broadcast-exact but not arbitrary either" standard as HSYNC's width.

Re-verified every delay constant against the recompiled disassembly
(pulse-width delay 73, then 67/318/316 for the `_BUSRQ` chain, all exact
matches) and confirmed the VSYNC line==0/line==3 transitions compile to
the expected `sbiw`+`brne` checks with no unconditional cost added for
lines outside 0-199 (the `_BUSRQ` work) or 0/3 (the VSYNC edges). ISR
worst-case budget re-estimated at ~906 of 1024 cycles by hand count --
essentially unchanged from before, still ~7.4us of margin.

Not yet re-tested on the bench -- next step is reflashing and checking:
HSYNC should now show a short (~4.7us) low pulse then ~59us high per
64us line; VSYNC should show a ~192us low pulse then ~19.8ms high per
~19.968ms frame.

### Third bench round: HSYNC/VSYNC shape confirmed good, fat-pixel window wrong (2026-09-05)

User confirmed HSYNC and VSYNC now look right. But the fat-pixel test
pulse was firing "from the start of the vsync low pulse, possibly for
200 lines from there" -- a real bug: the `_BUSRQ`/fat-pixel block was
still gated on raw `line < 200` (frame-relative), so it started right at
the VSYNC pulse instead of after a proper front porch, with no back
porch at the end either.

Added vertical blanking: 56 lines before the active region, 200 active,
56 after = 312 exact (the VSYNC pulse's 3 lines fall within the first
56). Changed the gate to `(uint16_t)(line - ACTIVE_LINE_START) < 200u` --
unsigned-wraparound range check, one comparison covers both ends of the
window. Verified via disassembly: compiles to `sbiw r24,0x38` (56) then
compares the result against 200, exactly as intended. No other bits of
the ISR needed to change -- the fat-pixel/`_BUSRQ` timing *within* an
active line was already correct, only *which* lines counted as active
was wrong.

Not yet re-tested on the bench -- next step is reflashing and confirming
the fat-pixel bar now appears only during the 200 active lines, starting
well after the VSYNC pulse and front porch.

### Fourth bench round: stable but zigzagging fat-pixel bar -- real jitter-correction bug found (2026-09-05)

User confirmed the image is stable and the fat-pixel bar's vertical
window is now correct, but the bar itself zigzags left/right by 1-2
pixels on alternating lines, perfectly stable (not random/moving) --
"like a zipper". Logic-analyzer follow-up nailed it precisely: HSYNC's
own period alternates between 64.14us and 63.88us, line to line (average
dead-on 64.000us -- confirms Timer1's underlying hardware period is
exact; only the *distribution* between adjacent lines was off).

Root cause: a genuine sign-inversion bug in the jitter-cancellation NOP
sled (sync.c), present since it was first written this session and never
actually caught by any of the disassembly checks so far -- those only
verified dispatch *cost* (cycles to reach the sled), never *which
direction* `pad` moved the resulting delay. The sled's label sat at the
sled's *start*, with `Z = start + pad` -- landing `pad` words in and
executing the *remaining* `(SLED_LEN - pad)` NOPs, not `pad` of them.
That's backwards: a larger `j` (meaning more interrupt latency had
already elapsed) produced a smaller `pad`, which under the bug meant
*more* NOPs ran, not fewer -- so instead of canceling variation in `j`,
this doubled it. If the idle loop's own period has a small, repeatable
phase relationship with the 1024-cycle timer interval (very plausible --
a short, fixed-length poll loop that doesn't evenly divide 1024 will
settle into a short repeating cycle of phases), doubling a ~1-cycle
natural variation gives almost exactly the ~4-cycle (250ns) peak-to-peak
swing measured on the bench, and explains why it was a clean, *stable*
alternation rather than random jitter -- a deterministic bug applied to
a deterministic (if unaccounted-for) input.

Fixed: moved the label to the sled's *end* and changed the dispatch from
`add`/`adc` to `sub`/`sbc`, so `Z = end - pad` -- pad=0 lands right after
the last NOP (0 executed), pad=SLED_LEN lands on the first one (all
SLED_LEN executed), the right way round. Dispatch cost is unchanged (sub/
sbc are the same 1-cycle cost as add/adc), so SYNC_TARGET/SYNC_REMAINDER
needed no changes. Verified via disassembly: the computed base address
(`ldi r30,0x5B` / `r31,0x0B` -> word 0x0B5B -> byte 0x16B6) lands exactly
on the instruction immediately following the 40-NOP sled, confirming
pad=0 now means zero delay, in the intended direction.

Not yet re-tested on the bench -- next step is reflashing and confirming
the fat-pixel bar is now a straight, non-zigzagging vertical line, and
that HSYNC's period is uniform line-to-line on the logic analyzer rather
than alternating 64.14/63.88us.

**Confirmed working (2026-09-05).** User: "it works!" -- straight,
stable fat-pixel bar, no zigzag. Closes out this milestone: HSYNC/VSYNC
generation (correct period, real pulse shapes, proper vertical blanking)
and the TCNT1-based jitter-cancellation scheme are bench-verified, not
just disassembly-verified. `video_run()`'s magic-address-exit path
(rom_emu.c's wait_rel-held-low fix) is implicitly confirmed too, since
none of this would run at all if the Z80 had hung on the handoff.

Next up (plan.md Phase 6a/6b, still open, not started): the real
pixel-fetch address loop (`_BUSRQ` already proven; still need the
80x500ns address ramp into the 74LS166 and a resolved SH_LD source),
and the "wait for HSYNC" primitive for that loop should poll the
hardware compare flag/`TCNT1` directly rather than the ISR-toggled pin,
per the note in sync.c/open-questions.md -- sidesteps needing any
jitter correction for that consumer at all.

### SH_LD design decided: software-pulsed, not a hardware divider (2026-09-05)

Worked out the actual per-byte AVR cycle budget before picking between
plan.md's two long-standing candidates (hardware divider chip vs.
software-pulsed `wait_rel` reuse): the unavoidable per-byte work (16-bit
address increment + writing both address ports) is `adiw`(2)+`out`x2(2)
= 4 of the 8 available cycles (500ns @ 16MHz), leaving 4 spare -- enough
for a `cbi`+`sbi` SH_LD pulse (4 more cycles), landing at exactly 8
cycles, zero margin. Initially recommended the hardware-divider option
instead, given the zero-cycle-budget margin; user chose the software
route anyway (no extra chip).

Checked whether "zero margin" actually means "broken" by rendering the
real `sn74ls166a.pdf` (text layer garbled like other datasheets in this
project) -- its function table shows SH/LD is re-evaluated on *every*
CLK rising edge, not latched once. User independently confirmed the
same behavior. This matters a lot: holding SH_LD low across the 2 edges
a `cbi`+`sbi` pair guarantees (125ns) means even if the first edge lands
before the TC551001's ~70ns access time has elapsed, the second edge
(125ns after the address changed) reloads with the by-then-settled data
and overwrites the first result -- the zero-cycle-budget design is safe
specifically *because* of this re-latching behavior, not despite it.

Also found and fixed a real, pre-existing pinout error in
`gate-equations.md` §6 while writing this up -- that section had never
actually been checked against a datasheet (predates this session's
redesigns) and had CLK on the wrong pin (11, actually a data input),
CLR on the wrong pin (1, actually SER), and claimed a "QH' active-low
output" on pin 16 that doesn't exist (that's VCC; the part has only one,
non-inverted, QH output at pin 13). Corrected against the real
datasheet. Also worth knowing for wiring: the 8 parallel data inputs
aren't contiguous pins (A-D are 2-5, E-H are 10/11/12/14).

Design finalized in gate-equations.md §6 / open-questions.md #3: priming
step (loads byte 0, not cycle-constrained) + 79-iteration main loop
(loads byte i while byte i-1 shifts out, exactly 8 cycles/iteration,
fully unrolled -- no loop overhead survives the budget) + one trailing
8-cycle window (lets byte 79 finish shifting after the loop ends). Not
yet implemented -- that's Phase 6a's next concrete step, along with the
80x500ns address-ramp code itself.

### Address-ramp + SH_LD implemented (2026-09-05)

New files `video_fetch.c`/`.h`: `video_fetch_line(addr14)`, Phase 6a's
isolated test unit (plan.md: validate the ramp against a known-good SRAM
pattern before wiring into the real per-line HSYNC/`_BUSRQ` machinery --
this is *not* called from sync.c's ISR yet). Hooked up to a new monitor
command, `vf [addr14]`, so it's independently bench-testable and (since
`--gc-sections` would otherwise discard an uncalled function) actually
linked into the image to disassemble.

Implementation matches the design exactly: assert `_BUSRQ`, a 16-cycle
safe delay (double `open-questions.md` #1's derived ~500ns worst case,
not yet empirically confirmed), glitch-free `_MREQ`/`_RD` takeover (PORT
bit set high before DDR flips to output, then driven low), address-bus
DDR takeover, the live HSYNC/VSYNC bits (PORTC 6-7) packed into the
address's high byte once, then the priming/79-iteration/trailing-window
pipeline from open-questions.md #3, then a full symmetric release.

Verified byte-for-byte against the compiled disassembly, not just
hand-derived: 16-cycle initial delay exact (`ldi r18,5` + loop + nop);
`video_fetch_burst` (marked `static`, single call site) got inlined by
GCC rather than staying a separate symbol -- confirmed present via
`avr-size` growing by ~1200 bytes and `grep`-counting the inlined body
directly; exactly 79 occurrences of the main-loop's `adiw r24,0x01`
(matching `VIDEO_BYTES_PER_LINE-1`) with zero gap between priming's
`sbi`/`cbi` and the first iteration's `adiw` (the alignment the pipeline
design depends on); the elided disassembly gaps both measure exactly 16
bytes = 8 NOPs (priming's settle delay and the trailing window); the
epilogue reverses every setup step in the correct order. Added
`_Static_assert`s guarding the hand-coded I/O addresses/bit used inside
the asm block against `pins.h` ever changing silently underneath them.

Not yet bench-tested -- next step is flashing, running `vf`, and
checking on a logic analyzer that the address bus increments every
500ns and SH_LD pulses land where expected relative to each change.
Correctness of the *shifted-out data* still needs either a known SRAM
pattern pre-written by the Z80 first, or a scope on `QH`.

### Wired the real 166, moving to a full-screen content test (2026-09-05)

User has the 166 on the breadboard and is ready for the real test:
Z80-side known pattern (alternating 8-line $AA/$55 bands) + AVR-side
full 200-line sweep, checked against expectation rather than just
timing. Found and fixed a real conflict before this could work:

- **sync.c's old "fat pixel" test would have corrupted the real
  sweep.** It never took over the address bus, so its independent,
  ISR-driven `_BUSRQ`/PD3 activity on every active line would leave the
  address bus floating right as `video_fetch_line()` (called from the
  main loop) is also driving `_BUSRQ`/PD3 for real -- a floating address
  during the old test's window would get sampled as a spurious garbage
  SH_LD pulse mixed into the real pixel stream. Removed it entirely
  (its job -- bench-confirming jitter cancellation -- is done); `sync.c`
  is back to pure HSYNC/VSYNC generation, ISR budget dropped from ~906
  to ~190 cycles.
- **`video_fetch_line()` needed interrupt protection it didn't have.**
  Same root issue from the other side: nothing stopped sync.c's Timer1
  ISR from firing mid-burst, which would have blown the cycle-exact
  8-cycles/byte budget and raced with the ISR's own PORTC writes (HSYNC)
  against the burst's PORTC writes (address bits 0-5 + preserved sync
  bits 6-7 in the same byte). Wrapped the whole function body in
  `ATOMIC_BLOCK(ATOMIC_RESTORESTATE)`. Re-verified via disassembly that
  this didn't disturb anything: still exactly 79 main-loop iterations,
  prologue now visibly saves SREG + `cli`s, epilogue restores SREG then
  `ret`s.
- **`video_run()` now actually sweeps the real buffer**: replaced the
  "just idle, polling for abort" loop with one that calls
  `video_fetch_line()` for all 200 lines, repeating, addressed as
  `(line*80) & 0x3FFF` (Z80 $C000+line*80, which the AVR never actually
  drives -- A14/A15 pulled high externally). Still not real-time /
  HSYNC-synchronized (Phase 6b work) -- bursts run back-to-back from the
  main loop, just no longer corrupted by the old test.
- **User asked directly whether `_BUSRQ`-to-safe-drive timing was
  actually right, not just assumed.** Good catch to press on --
  `open-questions.md` #1 had been carrying a guessed "4 T-states" with
  no source. Verified against the real Z80 UM instead: BUSRQ is sampled
  once per machine cycle, worst case is "the length of a machine cycle"
  (the UM's own words) -- not a fixed T-state count. Scanned every
  M-cycle T-state value in the UM's own instruction timing tables for
  the actual longest one rather than assume: 6 T-states (`LD SP,IX`/`IY`
  and `INC`/`DEC IX`/`IY`'s second M-cycle -- also matches the interrupt-
  acknowledge cycle's 2 automatic wait states). At 8MHz that's 750ns =
  12 AVR cycles; `video_fetch.c`'s existing `BUSRQ_SAFE_CYCLES=16`
  already covered it with ~33% margin, so no value change, just a real
  citation replacing the old guess.

Added `test-progs/video-test2.asm`: extends video-test1.asm with a
prefill of the entire video buffer ($C000-$FE7F, 200 lines x 80 bytes)
in 8-line bands alternating $AA/$55 starting with $AA -- 200 isn't a
multiple of 16 so the last 8 lines repeat $AA rather than completing a
$55 band, same as the first. Assembled to 115 bytes, no CALL/RET/PUSH/
POP, all jump targets hand-traced (fill_aa/fill_55/fill_pair via DJNZ/
fill_last_aa/b3_delay_on/off/blink3 via DJNZ/sb_delay/slowblink), copy-
loop bound (`ld bc,00073h`=115) matches the file size exactly, fill
loop bounds (640 x3) and pair count (12) verified to total exactly
16000 bytes. Added to the Makefile (was missing for video-test1.bin
too until now, both added together).

Not yet bench-tested -- next step is flashing both binaries, running
video-test2.asm, and checking (scope on `QH`, or the actual composite
output once wired) for a clean 8-line-banded striped pattern across all
200 lines with no garbage/discontinuities at line or band boundaries.

### Real crash found: video_run() running Timer1 + the sweep together (2026-09-05)

User flashed and ran video-test2.asm: LED blinked at a steady rate
(the Z80's own slowblink loop, unaffected) but *no* HSYNC/VSYNC output
at all -- pointed at the AVR itself having stopped doing anything
useful, not a wiring problem, since the Z80 clearly kept running fine
on its own.

Root cause: `video_run()` still called `sync_init()`+`sei()` before the
sweep loop (leftover from when it was the HSYNC/VSYNC test), so Timer1's
ISR was live and enabled the *whole* time `video_fetch_line()` was also
running -- each call masking interrupts for its whole ~45us burst
(`ATOMIC_BLOCK`), called 200 times nearly back-to-back. Timer1's
hardware counter keeps counting regardless of masking, so by the time
its ISR finally got a chance to run (in the sliver of time between
bursts), `TCNT1L` could read *any* value 0-255 with no relationship to
recent jitter -- the jitter-cancellation math (`pad = TARGET-REMAINDER-
j`) had no defense against `j` exceeding the ~40-cycle budget it was
built for, so `pad` underflowed to a huge `uint8_t` and the sled's
computed jump landed in essentially random program memory. Not a
missing-signal bug, an outright crash -- consistent with everything
observed: HSYNC/VSYNC stops (the AVR is off in the weeds), the Z80 keeps
going (nothing it does depends on the AVR once `_BUSRQ` happens to be
released, which it evidently was when the crash hit).

Two fixes, one defensive and one structural:
- **sync.c's ISR now clamps instead of trusting a stale `j`**: if `j` is
  already past the correction budget, the true edge this call was meant
  to respond to is history regardless of what happens next, so skip the
  sled (`pad=0`) and do the work immediately rather than compute a
  nonsense delay. Verified via disassembly: compiles to a `cpi`+`brcs`
  guard around the existing `sub`, exactly the intended `(j<40) ? 40-j :
  0`. This is real defense-in-depth, useful beyond today.
- **video_run() no longer starts Timer1 at all.** Running a genuine,
  scheduled per-line HSYNC alongside the address ramp was never actually
  designed, just assumed fine -- that's real Phase 6b work (the "wait
  for HSYNC" primitive noted in open-questions.md), not something this
  isolated content-sweep test needs. Removed `sync_init()`/`sei()`/
  `TIMSK1` from video_run() entirely; confirmed via `avr-nm` that
  `sync_init` is no longer even linked into the image (nothing calls it
  now) and video_run()'s only calls are `usart_puts_P`/`usart_getc`/
  `video_fetch_line`. Banner message updated to say plainly that no
  HSYNC/VSYNC output is expected during this test, by design.

Not yet re-tested on the bench -- next step is reflashing and re-running
video-test2.asm: expect the same 3-blinks-then-steady-slowblink Z80
behavior as before, but now the AVR should keep running the sweep
indefinitely (UART banner printed once, no crash) rather than going
silent. Still no HSYNC/VSYNC during this test -- that's expected now,
not a symptom to chase.

### User confirmed the fix, then asked for the real thing (2026-09-05)

User reflashed: `_BUSRQ` toggling, no HSYNC/VSYNC -- exactly as expected
for this deliberately-isolated test, confirming the crash fix held.
Then asked to skip further incremental bench checks and "just do the
full video output driver" -- i.e. actually integrate video_fetch_line()
with real per-line HSYNC timing (Phase 6b), not keep it as an isolated,
unsynchronized sweep.

**The integration**: moved the call to video_fetch_line() from
video_run()'s main loop into sync.c's Timer1 ISR itself, right after the
HSYNC pulse, for lines in the active window (same
ACTIVE_LINE_START/COUNT range the old fat-pixel test used). This
sidesteps the earlier crash's root cause entirely rather than working
around it: there's no separate interrupt context to race against
Timer1, because the fetch now runs *as* the interrupt -- interrupts are
already off (standard `ISR()` semantics), so video_fetch_line()'s own
`ATOMIC_BLOCK` becomes a harmless no-op, and the fetch is automatically
anchored to the same jitter-cancelled point as HSYNC's own pulse instead
of a separately-scheduled, unsynchronized main-loop call.
`video_run()`'s only job now is `sync_init()`+`sei()`+idle -- the real
sweep happens automatically, driven by Timer1's own 64us schedule.

**A second real bug, found by deliberately re-checking rather than
assuming the old numbers still held**: calling video_fetch_line() from
inside the ISR means the compiler now preserves far more registers
across it (16 vs. the old set), growing the prologue from a measured 19
cycles to 35. That alone pushes the baseline interrupt-latency `j` to
~42 -- which already *exceeded* the old SYNC_TARGET=48/SYNC_REMAINDER=8
budget's 40-cycle ceiling. Below that ceiling the jitter-cancellation
sled works as designed; at or above it, the previous clamp fix kicks in
on essentially *every* call instead of just rare late ones -- silently
disabling the exact correction that fixed the original "zigzag" bug,
with no crash or other symptom to notice it by. Caught only by
deliberately recomputing the baseline against the new disassembly
instead of trusting the old comment. Fixed: raised SYNC_TARGET to 64
(was 48) and SYNC_SLED_LEN to 56 (was 40) to restore a real margin over
the new baseline.

**A third issue, this time in my own verification process**: the first
cycle-budget recount (to check the raised sled still fit in the
1024-cycle line) used a plain `avr-objdump -d`, which elides long runs
of identical bytes as "..." -- silently dropping video_fetch_line()'s
priming/trailing 8-NOP blocks (16 cycles) from the count. Re-ran with
`-z` (elision disabled) and got a materially different, trustworthy
number. Final, carefully cross-checked total for an active line, worst
case (full-length sled): **975 of 1024 cycles, 49 cycles (~3.06us,
~4.8%) margin.** Trimmed two purely-internal safety margins to get
there -- SYNC_TARGET's margin over baseline (~20 cycles in the original
design down to 14 here) and `video_fetch.c`'s BUSRQ_SAFE_CYCLES (16 down
to 14, still 2 cycles above the verified 12-cycle hard requirement, not
touching that one much since it's a real Z80 bus-timing number, not
internal slop). This margin is real but thin -- documented plainly in
sync.c's header rather than declared safe, and flagged as needing a
logic analyzer check (does the *next* line's HSYNC ever measurably
slip?) before being trusted further. Blanking lines (no fetch call) are
far under budget and not a concern.

Not yet bench-tested -- next step is reflashing and re-running
video-test2.asm: this time expect real HSYNC/VSYNC output *and* the
video sweep running together, continuously, driven entirely by Timer1.
Check HSYNC's period is still a clean, stable 64.000us (the real test of
whether the 49-cycle margin actually holds up) before trusting the pixel
content on `QH`.

### User confirmed stable sync, but a real, serious bug underneath (2026-09-05)

User reflashed: HSYNC/VSYNC stable (confirms the 49-cycle margin held),
but no pixels, and `_MREQ` observed low continuously while `_BUSRQ` was
high. Re-verified the release ordering against the actual compiled
epilogue (not just the C source) -- confirmed correct, `_MREQ`/`_RD`
driven high then switched to input, then the address bus, then `_BUSRQ`
released last, no branch skips any of it. Initially floated "maybe this
is just the Z80 legitimately running its own code in the brief released
window" as an explanation, and asked whether the low period had brief
high blips (which normal Z80 execution would show between M-cycles).

User's answers: the low period during blanking was **7ms exactly**, and
**truly continuous with zero blips**. The 7ms is a real clue, not noise
-- 112 blanking lines x 64us = 7.168ms, matching almost exactly. But
"zero blips for the whole window" ruled out "Z80 running normally" (that
would show gaps between M-cycles) and pointed at "Z80 stuck mid-read."
User then confirmed the LED doesn't blink at all anymore -- fully
hung, not just slowed.

**Root cause, a real design conflict introduced when SH_LD was put on
PD3**: `rom_emu.c`'s magic-address exit drives `wait_rel` (PD3) low and
leaves it low *permanently*, holding the WAIT flip-flop's async PRESET
asserted forever -- necessary because that FF has no `mode_pin` gating
(`D=_RD` unconditionally, gate-equations.md §3) and would otherwise
latch `_WAIT` low on every read with nothing to release it. SH_LD
pulsing needs the opposite resting state: every pulse ends with `sbi`
(high), since the 166 must sit in "shift" mode between loads. So the
very first video-fetch burst leaves PD3 high when it returns -- for the
first time since ROM emulation exited, de-asserting the WAIT FF's
preset. The Z80's next read (immediately, regaining the bus) latches
`_WAIT` low and hangs -- permanently, since nothing else pulses
`wait_rel` again except the *next* burst's own incidental SH_LD
activity, which frees it for an instant before the very next fetch
re-hangs it. Explains both symptoms exactly: 7.168ms of unbroken
`_MREQ` low during blanking (Z80 stuck mid-read the whole blanking
period, no bursts running to even accidentally free it), and no pixels
(a Z80 stuck mid-Tw-state may never reach the "last T-state of the
current machine cycle" the Z80 UM says `_BUSRQ` is sampled at, so later
bursts' `_BUSRQ` may go unacknowledged -- real bus contention between
the Z80, still driving, and the AVR, also now driving, would corrupt
the address ramp).

This was a genuine gap in the earlier "is reusing this pin safe"
analysis -- that analysis only checked safety *during* the `_BUSRQ`
window (correct: the Z80 isn't sampling `_WAIT` then) and never
considered the pin's *resting state* once the window ends, or its
effect on the WAIT FF once the Z80 regains the bus. The fat-pixel test
that originally validated the reuse happened to end its own pulse
LOW->HIGH... no, checked: it pulsed HIGH-then-LOW (opposite order from
SH_LD's LOW-then-HIGH), so it always left the pin low and preserved the
invariant by accident -- SH_LD's requirement (rest high, pulse low) is
the one arrangement that breaks it, and that's exactly what got built.

Fixed: `video_fetch_burst()` now forces `wait_rel` back to low itself,
once, immediately after the trailing window and before returning --
restoring the invariant before the Z80 ever gets the bus back. Verified
via disassembly: the new `cbi` lands exactly between the last SH_LD
pulse's trailing NOPs and the start of the `_MREQ`/`_RD` release
sequence, before anything that could let the Z80 resume. Costs 2 more
cycles (977/1024 total now, 47 margin, down from 975/49 -- sync.c's
header comment updated).

Not yet re-tested on the bench -- next step is reflashing and
confirming the LED resumes blinking (proving the Z80 no longer hangs)
before re-checking for actual pixel content on `QH`.

### The wait_rel fix wasn't the real fix -- SH_LD moved off PD3 entirely (2026-09-05)

User reflashed: LED blinks again, HSYNC/VSYNC good, steady SH_LD
pulses -- but correctly identified that the previous fix just moved the
conflict rather than resolving it. Forcing `wait_rel` low at the end of
every burst fixed the WAIT-FF hang, but left SH_LD resting *low*
between bursts instead of high -- "load" mode on the 166, not "shift".
Since CLK (`clk16`) never stops, SH_LD low the whole inter-burst/
blanking period means the 166 keeps re-loading whatever floats onto the
shared data bus on every clock edge, continuously emitting garbage on
`QH` that has nothing to do with real pixel data. PD3/`wait_rel` and
SH_LD fundamentally want *opposite* idle states (low vs. high) and
can't share one pin no matter what order things happen in -- the
previous fix treated this as an ordering bug when it was actually a
resource conflict.

User's fix: move SH_LD to PD5 (the 1284p's `_IORQ`-sensing pin, unused
since Phase 7 IO virtualization was never implemented), and go further
than just repurposing it during bursts -- **physically disconnect PD5
from the Z80's `_IORQ` net on the breadboard and remove its pull-up**,
dedicating it entirely and permanently to SH_LD. No more competing
role, no reliance on the Z80 tristating anything during `_BUSRQ`, no
per-burst DDR take-over/release needed at all -- PD5 is configured as
a plain output once at boot (main.c), idling high, exactly like any
ordinary dedicated GPIO. `video_fetch_burst()`'s cbi/sbi pulses are
otherwise unchanged.

Implementation: renamed `BIT_IORQ` to `BIT_SH_LD` in pins.h (checked
first that nothing else in the codebase referenced the old name --
video_fetch.c was the only user), added it to main.c's one-time DDR/
PORT setup, and removed all the take-over/release logic for this bit
from `video_fetch_line()` (steps 2 and 5 -- it's a permanent output
now, nothing to take over). PD3/`wait_rel` goes back to being untouched
by video fetch entirely -- both of the last two fixes to it are now
moot, cleanly reverted rather than left as dead code.

Re-verified cycle-neutral via disassembly: `video_fetch_line()` still
totals exactly 708 cycles (same as before the now-abandoned wait_rel-
restore `cbi`, since removing the DDR take-over for this bit didn't
remove any instructions from steps 2/5 -- they just went back to
their original 2-bit `_MREQ`/`_RD`-only masks, same instruction shapes,
same cost as pre-SH_LD-sharing code). ISR total back to 975/1024 (49
cycles margin, same as the original figure before either wait_rel fix
attempt) -- `sync.c`'s header comment corrected to stop citing the
now-gone 977/47.

Docs updated: pin-map.md (PD5's row and the OC-pin table), gate-
equations.md §6 (SH_LD source, full history of both wrong attempts)
and its pull-up table (flagged, not assumed, whether the 74LS138's own
`_IORQ` enable-input pull-up is the same physical resistor as the one
just removed -- can't tell from docs alone, needs a real-board check),
bom.csv (same flag). `_IORQ` into the 74LS138's IO decode (§7/§8) is
an entirely separate, unaffected net -- that's Z80 `_IORQ` wired
directly to the 138, never routed through the AVR at all; only the
AVR's own now-removed sensing branch was ever affected by this change.

Not yet bench-tested -- next step is reflashing and checking that SH_LD
sits cleanly high for the entire inter-burst/blanking period (no more
floating-bus garbage loads) and that real pixel content finally shows
up on `QH`.

### Real pixels on screen, but shifted left off-screen -- split into two Timer1 ISRs (2026-09-05)

User confirmed the SH_LD fix worked: blinking LED, HSYNC, VSYNC, and the
AA/55 pattern actually visible on a real monitor -- first time real
pixel content has shown up. Two remaining issues: vertical lines "quite
thin and blur a bit" (likely the composite mixing stage's bandwidth,
Phase 6b work not yet done -- set aside for now), and the visible 640px
region "shifted way to the left", leftmost pixels possibly off-screen.

Root cause of the shift: no deliberate back porch. The video-fetch burst
started almost immediately after HSYNC's own pulse ended, with no gap
for the display to settle after retrace before active video begins.

User's suggestion, and the right one: rather than add a software busy-
wait inside the single existing ISR (which would eat directly into an
already-thin 49-cycle margin), use Timer1's *second* independent
compare unit (`OCR1B`) to fire a completely separate interrupt later in
the same line, purely by hardware -- the gap between the two interrupts
becomes genuine idle CPU time, not a spin-wait, and is exact regardless
of jitter in the first ISR.

Split `sync.c` into `TIMER1_COMPA_vect` (HSYNC pulse + VSYNC bookkeeping
only -- no more `video_fetch_line()` call) and `TIMER1_COMPB_vect` (the
video-fetch trigger, armed via `OCR1B`, with its own full jitter-
cancellation sled). One real subtlety: `TCNT1` only resets to 0 at the
`OCR1A` match (that's what CTC "TOP" means) -- an `OCR1B` match doesn't
reset anything, so COMPB can't read `TCNT1L` directly the way COMPA
does (that would measure cycles-since-last-reset, not cycles-since-the-
true-OCR1B-match). COMPB instead computes `TCNT1L - OCR1B` to recover
the right quantity, then applies the identical sled technique from
there.

Caught two real mistakes while implementing, both before they reached
the bench:
- Initially reused COMPA's old TARGET/SLED_LEN (48/40, sized for its
  now-much-smaller prologue) for COMPB too. But COMPB still calls
  `video_fetch_line()`, needing the same larger register set (measured
  ~35-cycle prologue) the old combined ISR did -- baseline `j`~42
  already exceeds a 40-cycle budget. Exact same silent-jitter-
  cancellation-disabling mistake as the ISR-split-video_fetch_line
  regression earlier in this file's history, caught the same way:
  recomputing from the real disassembly instead of assuming old numbers
  transfer.
- First OCR1B choice (160, aiming for a close-to-real-PAL ~5.7us back
  porch) would have overrun the line entirely: COMPB's own worst-case
  runtime (measured precisely off the real disassembly, correcting for
  embedded delay loops the same way this file always has to) is ~886-
  891 cycles -- splitting into two interrupts doesn't create extra
  total cycles, the combined work still has to fit in 1024, and
  `video_fetch_line()` alone is expensive enough that there's very
  little room left over for a deliberate gap. Settled on OCR1B=100:
  ~41 cycles (~2.6us) of back porch after HSYNC ends, ISR completing
  with ~26 cycles (~1.6us) of real margin. Modest, not textbook-PAL-
  sized, and thin rather than comfortable -- documented plainly in
  sync.c rather than oversold. If more back porch is ever needed later,
  it has to come from shrinking `video_fetch_line()`'s own cost (the
  address multiply is the next-cheapest target), not from raising
  OCR1B_VALUE further -- there's no spare margin left to spend that way.

Not yet bench-tested -- next step is reflashing and checking whether
~2.6us of back porch is enough to bring the 640px region on-screen, or
whether it needs to be pushed further right (which would require
freeing up more of the budget first, not just nudging OCR1B_VALUE).

### COMPA/COMPB split reverted -- real ~62.5ns period-3 jitter traced to an AVR RETI quirk (2026-09-05)

User confirmed the back porch helped (image no longer hard left, "not
quite centre" but acceptable) but reported something new: measuring
HSYNC's rising edge to the first SH_LD pulse on a logic analyser gave
two discrete values, ~9.94-9.95us and ~10.01-10.02us, in a period-3
pattern (two lines at the higher value, one at the lower, repeating) --
persisting even at 100MHz LA resolution, ruling out a sampling-rate
artifact (the initial hypothesis, since the first, lower-resolution
capture's ~80ns delta wasn't a clean multiple of one AVR cycle; the
100MHz recapture's ~60ns delta is much closer to the true 62.5ns/cycle
figure once quantization is accounted for).

Re-traced every instruction between HSYNC's rising edge and the first
SH_LD pulse from a fresh disassembly -- COMPA's own clamp-branch
(checked cycle-by-cycle both ways), COMPB's clamp-branch, the dispatch
sequence, the active-line range check, the address multiply (AVR `mul`
is a fixed 2-cycle hardware multiply, not data-dependent) -- found zero
data-dependent branches or arithmetic anywhere in that path. Every
active line should execute bit-identical code.

That pushed the investigation toward a genuine hardware timing question
instead: computed COMPA's *actual* total runtime from its own
disassembly (true edge to `reti`) by hand, cycle by cycle -- 155 cycles
-- and compared it against `OCR1B_VALUE` (100). **COMPB's compare-match
flag was going pending ~55 cycles before COMPA even finished
executing**, every single line -- not an occasional overlap, a
structural one, since COMPA's own HSYNC pulse-width busy-wait (73 of
those 155 cycles, a real hardware timing requirement, not overhead)
can't be shortened.

That overlap hits a real, documented AVR core behaviour the jitter-
cancellation sled has no visibility into: after `RETI` (same rule as
`SEI`), the core is guaranteed to execute at least one more instruction
of the code being returned to -- here, `video_run()`'s UART-poll loop --
before it will honour a newly-pending interrupt. The poll loop mixes a
2-cycle `lds`, a 1-cycle `sbrs` (not taken, no data on the wire during a
video test), and a 2-cycle `rjmp`. Whichever of those the main loop
happens to be sitting on when COMPA's `reti` fires -- a function of
where the asynchronous main loop is relative to the synchronous 64us
line timer, unrelated to it -- directly shifts COMPB's real dispatch
time by that instruction's own cycle count. This happens in the gap
between COMPA's `reti` and COMPB's own ISR entry, entirely outside
COMPB's TCNT1-based jitter measurement, so nothing in either sled could
ever cancel it. The period-3 pattern (rather than a clean 2-line
alternation) is the beat between the poll loop's own short period and
the 1024-cycle line period -- not a simple ratio, hence "not quite
alternating."

Checked whether OCR1B could just be pushed out past COMPA's 155-cycle
finish instead of removing the split: no room -- COMPB's own worst-case
cost (sled + active-line check + multiply + `video_fetch_line()`) caps
`OCR1B_VALUE` around 133 within the 1024-cycle line, which is short of
155 regardless of how OCR1B_VALUE is tuned. The overlap was unavoidable
as split, not a tuning mistake -- confirmed by computing the actual
numbers rather than assuming there was headroom.

**Fix: reverted to a single `TIMER1_COMPA_vect`, dropped OCR1B/COMPB
entirely, and got the back porch from a plain `_delay_cycles()` gap
between HSYNC returning high and calling `video_fetch_line()`, both in
the same ISR.** A single interrupt source firing per line can't hit this
class of bug -- there's no sibling ISR for a newly-pending flag to wait
behind. This isn't a compromise: the original *undivided* ISR (this
file's own earlier history, before the split ever existed) already
measured 975 of 1024 cycles/line with no back porch at all -- 49 cycles
of genuine spare capacity, comfortably enough to fit a real back-porch
delay directly. The "split frees up real main-loop time" reasoning that
motivated trying two ISRs only matters once there's actual work
competing for that gap (a future Phase 7 IO/UART virtualisation, say);
`video_run()`'s poll loop has nothing to lose by waiting a few extra
microseconds. Re-verified against a fresh `avr-objdump -d -z` after
rebuilding (not assumed): worst-case total per line is 977 cycles (64
dispatch + 77 HSYNC pulse + 12 VSYNC check + 40 back porch + 9 active
check + 9 multiply + call/`video_fetch_line()`'s own 708 + 15
increment/wraparound + 39 epilogue), leaving **47 cycles (~2.9us) of
margin** -- more comfortable than the split design's 26, and a
back-porch of 40 cycles (~2.5us), similar to what the split briefly
achieved.

Not yet bench-tested. Next: reflash and confirm the period-3 jitter is
actually gone (not just theorized away), and that HSYNC/VSYNC/image
position are otherwise unaffected by the revert.

### Jitter confirmed fixed; trimmed per-line overhead for more back porch instead of a one-big-burst redesign (2026-09-05)

User confirmed the period-3 jitter is gone after the single-ISR revert.
Remaining problem: image still shifted left (not centred), and there
wasn't much margin left (34-47 cycles depending on the exact design) to
just grow `BACK_PORCH_CYCLES` further without risking the 1024-cycle
line.

User asked directly: should the design instead fetch all 200 active
lines in one continuous `_BUSRQ` takeover, rather than per-line? Traced
through what that would actually cost: it would free substantial real
margin (removing all per-line ISR prologue/epilogue, dispatch, and the
per-line `_BUSRQ` assert/release/re-takeover, ~50-60+ cycles by itself)
-- but it would also mean holding `_BUSRQ` continuously for the entire
~12.8ms visible frame instead of releasing it every line, starving the
Z80 of any run time until vertical blanking. CLAUDE.md's own design
explicitly calls for the Z80 to get interleaved run time on *every*
active line ("the z80 keeps going for a few microseconds" between each
line's fetch), not just during blanking -- this would be a real
behaviour change, not just an internal refactor. Presented this tradeoff
to the user rather than deciding it unilaterally; user chose to keep the
per-line design and trim its overhead instead.

Trim applied: (1) gated the VSYNC-bookkeeping check (only ever relevant
on lines 0/`VSYNC_PULSE_LINES`, deep in blanking) behind the "not
active" branch, so it no longer costs anything on the 200 active lines;
(2) replaced the per-line `video_line * VIDEO_BYTES_PER_LINE` multiply
with `video_addr`, a running total advanced by `VIDEO_BYTES_PER_LINE`
each active line and reset once when entering the active region --
cheaper than recomputing from `line` every time.

First estimate of the savings (~20-35 cycles, from removing a 9-cycle
multiply and an unconditional 12-cycle VSYNC check) turned out to be
too optimistic once checked against the real disassembly: tracking
`video_addr` persistently costs its own real overhead (a reset check
every active line, an increment-and-store every active line) that ate
back most of the projected gain. Cross-checked the new total against
this file's own already bench-verified 977-cycle baseline (not
recomputed blind) by itemizing the exact instruction-level deltas from
a fresh `avr-objdump -d -z` -- actual net savings were only ~6-7 cycles,
not ~20. Corrected course before landing on a value: an initial
`BACK_PORCH_CYCLES=66` (chasing closer to real PAL's ~5.7us spec) would
have left only 24-28 cycles of margin, thinner than intended; settled on
`BACK_PORCH_CYCLES=56` instead, verified via the same delta method:
worst case (the one active line per frame that also pays the
`video_addr` reset) is 990 of 1024 cycles, 34 cycles (~2.1us) margin;
every other active line is 987, 37 cycles (~2.3us) margin -- both
confirmed by directly locating and decoding the delay loop's actual
encoded constant in the fresh disassembly, not just trusted from the
`#define`.

Net effect: back porch grew from 40 to 56 cycles (~2.5us to ~3.5us),
margin shrank from 47 to 34-37 -- both real, both smaller than initially
promised. Documented plainly in sync.c's header (including the smaller-
than-expected savings) rather than overstating the win. Not yet enough
back porch to fully centre the image per the user's last report; this
is close to the safe limit of what the per-line-ISR structure can give
without finding more real overhead to cut, or revisiting the one-big-
burst tradeoff above.

Not yet bench-tested -- next step is reflashing and checking how much
closer to centred the image is, and whether 34-37 cycles of margin
holds up with no new jitter or glitches.

### Bench found a real first-line pixel-shift bug in the trim; pushed back porch much further (2026-09-05)

User reflashed: stable picture, jitter still gone, but two new
observations -- (1) the very first active line of every frame is
pushed about one pixel to the right compared to the rest, and (2) the
image still looks just as far left as before -- "doesn't look like it's
moved at all" despite the 40->56 back-porch increase.

(1) was a real bug in the previous entry's trim, not a display quirk.
The `video_addr` reset (`if (line == ACTIVE_LINE_START) video_addr = 0;`)
lived on the *active-line* path, where every cycle is timing-critical.
Checked its compiled cost both ways: the branch's two outcomes take a
different number of cycles (7 when it resets vs. 4 when it doesn't --
confirmed via disassembly, matching the general pattern this file has
hit before with clamp/reset branches, except this time the two paths
were *not* equalized). Since 1 AVR cycle = 1 pixel exactly at this
pixel clock (8 pixels/byte, 8 cycles/byte), that 3-cycle difference is a
real, deterministic 3-pixel shift on precisely the one line where the
reset fires each frame -- matches "the very first line is pushed...to
the right" exactly (close enough for a rough visual read). Fixed by
moving the reset off the active path entirely, onto the last blanking
line before active video starts (`line == ACTIVE_LINE_START - 1`) --
blanking lines have no timing-critical work, so a branch there costs
nothing visible. Every active line now runs byte-for-byte identical
code, confirmed via a fresh disassembly (no more per-line variability
at all, not just "probably fine").

(2) is a real question about how much a back-porch change needs to be
to register visually. Reasoned about it directly: 40->56 was +16
cycles, ~1us, on a 640-pixel-wide image -- about 2.5% of the screen
width, which may simply not read as "moved" to the eye, or the display
itself may have some tolerance for small horizontal-position changes.
Rather than nudge again by a similarly small amount, pushed
`BACK_PORCH_CYCLES` to 80 -- a much bigger, harder-to-miss step -- so
the test actually distinguishes "no effect" from "too small to see."
Verified via a fresh `avr-objdump -d -z`, cross-checking every
instruction on the (now uniform) active path directly rather than by
delta from a previous total: worst case is 1003 of 1024 cycles, 21
cycles (~1.3us) margin -- thinner than the 05c value's 34-37, a
deliberate tradeoff for a real, testable back-porch change plus the bug
fix, not carelessness. Flagged as not yet bench-confirmed and worth
revisiting if 21 cycles proves too tight in practice.

Not yet bench-tested. Next: reflash and check (a) the first-line shift
is gone, (b) whether an 80-cycle (~5us) back porch is now clearly
visible/enough to move the image off the left edge, and (c) no new
jitter or glitches from the thinner margin.

### Back-porch tuning paused -- left-shift likely not a sync-timing problem at all (2026-09-05)

User reflashed: first-line pixel shift confirmed fixed. The 56->80
back-porch increase produced only a marginal change ("possibly a bit
more to the right, but its still too far left").

Key diagnostic point from the user, made with the logic analyser rather
than by further guessing on this end: measured where the 40us active
window actually falls within the 64us line, and it looks *roughly
centred* between HSYNC's pulse and the next line's HSYNC -- i.e. back
porch and front porch look approximately balanced on the wire -- yet
the physical monitor still shows the picture shifted left. That
combination (digital timing looking centred, physical display still
off) points away from `BACK_PORCH_CYCLES` as the remaining lever: the
software here only controls *when* the AVR starts driving pixel data
relative to its own HSYNC pulse, and that relationship is now
demonstrably reasonable. A further left-shift with correct-looking
digital timing is more consistent with something downstream of this
file entirely -- most likely the raw TTL-level HSYNC/VSYNC being fed to
the monitor without the composite sync-mixing/attenuation network this
project's plan.md has always flagged as separate "Phase 6b" work
(signal levels/impedance a sync separator wasn't designed for can shift
where it *thinks* the line starts independent of the true digital
timing), or some characteristic of the specific monitor's own sync
separator.

User asked to pause here and research independently rather than keep
adjusting `BACK_PORCH_CYCLES` -- noted as the last action on this
thread. `BACK_PORCH_CYCLES` stays at 80 (verified 1003/1024 cycles,
~21 cycle margin, uniform across active lines) since it's a real,
bench-confirmed improvement over the original 0, even though it wasn't
the fix for the remaining shift.

### Added test-progs/video-nmi-vsync-benchmark.asm: real-world slowdown measurement (2026-09-06)

User is wiring VSYNC to the Z80's `_NMI` pin (external hardware change,
not yet reflected in any schematic doc) to get a real, hardware-timed
wall-clock reference independent of the Z80's own (possibly slowed-down)
instruction stream, in order to measure the actual net Z80 slowdown
caused by the per-line `_BUSRQ` video-fetch steals.

Added `test-progs/video-nmi-vsync-benchmark.asm`: unlike every other
test-progs/*.asm, this one needs a real interrupt vector table (NMI is
non-maskable and always vectors to `$0066`), which changes a few things
from this project's usual test-program conventions:
- `SP` is set as the very first instruction (before the rom-copy loop),
  not after the mode switch like every other test -- needed so an NMI
  landing during the copy phase pushes PC somewhere valid. Reasoned
  through why this is actually safe given mode 0's "write always goes to
  sram" semantics, and separately confirmed VSYNC physically cannot
  pulse that early anyway (main.c holds it high at boot; sync_init()
  only arms once video_run() starts, long after this program's own
  mode switch) -- so the early SP is defense in depth, not closing a
  real live gap, and said so explicitly in the file rather than
  overstating the risk.
- The rom-copy loop copies from address 0 (`vectors`), not from `init`,
  so the vector table itself lands in real SRAM too.
- `z80asm`'s `org` directive does not itself emit bytes (confirmed via
  a throwaway sandbox assembly + `xxd` before relying on it) -- the gap
  up to `$0066` and on to `$0100` is real, explicit `defs $addr-$,0`
  padding, not an assumption about how `org` behaves.

Benchmark body: a closed-form 24 x 65536-iteration delay loop with a
precisely known cost (computed, not estimated) -- 40,894,898 T-states,
5.1119s at a true unslowed 8MHz, chosen so a zero-slowdown run would
tick almost exactly 256.0 times on the VSYNC/NMI counter (19.968ms/tick,
312-line frames) -- a deliberately clean, memorable reference number.
Whatever the real hardware prints, divided by 256, is the actual
slowdown factor.

NMI handler increments a 16-bit tick counter; `PUSH AF` kept even though
no instruction in the handler currently touches flags, specifically
because NMI can land between this file's own `OR L` and `JR NZ` in the
benchmark loop, and a future edit to the handler touching flags without
that safety net would silently corrupt that exact jump. `RETN` used (not
`RET`) per Z80 NMI convention.

Result printed via a 16-bit-to-decimal routine (the standard `ADD
HL,BC`-with-negated-divisor technique, hand-verified against a worked
example -- 25000/10000 -> digit 2, remainder 5000 -- before trusting it)
and the same `write_msg` routine reused verbatim from video-test3.asm,
per the user's request. Whole file checked against a full `z80dasm`
disassembly, not just assembled cleanly and assumed correct: vector
table jumps, the rom-copy length (`$0A68` = 2664 = the real file size),
the mode switch, the magic-address read's position relative to the
counter reset, the benchmark loop's own backward jump targets, both
`write_msg` calls' row/column arguments, and `get_digit`'s carry/`SBC`
logic all confirmed byte-for-byte against what was intended. Added to
the Makefile's `all` target. Not yet bench-tested (needs the VSYNC-to-
`_NMI` wiring in place first) -- next step is wiring it up, flashing,
and reading the printed tick count.

### CP/M planning session (2026-09-06): banked memory design, then Phase 9 hardware docs

Read `CPM.md` (extend the machine into a full CP/M 2.2 host, run Zork 1)
and worked through its open questions into `cpm-plan.md`, a full phased
plan (continuing `plan.md`'s numbering from Phase 8): native
keyboard+video console, a 2-NAND memory-bank-switch circuit (verified
via truth table -- `A16 = (bank AND A15) OR busrq_asserted`), a
low-32K bank-flip trampoline for the CBIOS's screen-output routine
(discussed and rejected mirroring the same code at the top of memory
instead, to avoid a two-copies-in-sync maintenance hazard), a small
ROM-resident bootstrap loading a disk-resident CP/M system image
(checked the numbers: CCP+BDOS alone is 5632 bytes, too tight against
the AVR's 8K ROM-emulation window to also fit a full custom BIOS),
an MSX-style matrix keyboard, bit-banged-SPI SD card storage, and the
classic IBM 8" SSSD disk geometry with a verified DPB. User confirmed:
conventional (not relocated) stack placement, discipline-based safety
for the bank-flip window instead; the VSYNC-`_NMI` wiring will be
disconnected for the CP/M build. See `cpm-plan.md` for the full
reasoning and settled design -- not reproduced here.

Starting Phase 9 (bank-switch hardware) surfaced a real, useful side
discovery: verifying the 8255's pinout/reset-behavior (previously
flagged in `open-questions.md` #9 as an unclosed gap, blocking on "no
datasheet collected") against the standard 8255A datasheet confirmed
`RESET` is genuinely active-high and ports genuinely default to input
on reset (both previously "assumed standard, not verified" in
`gate-equations.md`), *and* surfaced a real, load-bearing fact that
directly shapes the new `bank` pin's design: **writing any 8255
mode-set control word resets *all* of that port's output latches to
zero, not just the bit(s) whose direction actually changed.** Since
`mode_pin` (`PA0`) and the new `bank` (`PA1`) share Port A, the very
first control-word write (configuring Port A as an output, to drive
`mode_pin`) will force `bank` to 0 in the same instant regardless of
whatever its pull resistor was doing beforehand -- decided to pull
`bank` down (not up) so the pre- and post-configuration defaults agree,
matching `mode_pin`'s own precedent and `bank=0`'s role as CP/M's
steady state, rather than picking a resistor that would read one value
for a moment and then snap to a different one. Also found and fixed a
real, pre-existing inconsistency while in this area: `gate-equations.md`
§8 said `mode_pin` was "pulled up," directly contradicting §2's own
(correct, and already bench-implemented per earlier log entries)
pull-*down* design -- a stale reference that never got updated when the
polarity flipped 2026-09-04, now corrected. `open-questions.md` #9
closed accordingly.

Wrote the full bank-switch circuit documentation before any wiring:
`gate-equations.md` §9 (the gate equations + truth table), a new
`bank-switch-wiring.md` (pin-by-pin 74LS00 #2 diagram, matching the
existing chip's DIP-14 gate-1/gate-2 "normal" pin order so gates 3/4
stay untouched and spare), updated `memory-map.md` (flags that `A16` is
no longer grounded, points at `cpm-plan.md` §2 for the resulting
physical map), and `hardware/bom.csv` (new 74LS00 #2 line, corrected
8255 line, split the pull-up/pull-down resistor lines so `mode_pin` and
`bank` are both correctly listed as pull-downs instead of `mode_pin`
being miscategorized as a pull-up). Not yet wired on the real
breadboard -- next step is physically building this circuit per
`bank-switch-wiring.md`, then flashing the new Phase 9 test program to
confirm the two banks are genuinely independent SRAM before pointing
any real CP/M content at either of them.

Wrote `test-progs/bank-switch-test.asm` (user confirmed `PA1` for
`bank`, matching the pin already assigned above): Test 1 writes `$A5`
to five addresses spread across `$8000-$BFFF` under `bank=0`, flips to
`bank=1`, writes `$5A` to the same addresses, flips back and confirms
`$A5` survived, flips again and confirms `$5A` survived -- proves the
banks are genuinely independent SRAM, not aliased, without touching
video RAM at all (`$8000-$BFFF` is never video in either bank, only
`$C000-$FFFF` under `bank=1` is). On success, fills the video buffer
with a box + "BANK TEST OK" message (only reachable under `bank=1`),
triggers the magic-address exit into video generation, then
continuously toggles `bank` forever while video runs -- a rock-solid
display through that loop is the pass condition for the circuit's
claimed video/`bank` isolation; any flicker or corruption means it
isn't real. LED fast-blinks forever (never reaching video) on a Test 1
failure, so a failure is unambiguous. Hit one real assembly bug on the
first pass -- `JR NZ,test_fail` out of `z80asm`'s +/-127-byte relative
range (134 bytes away) -- fixed by switching those two branches to `JP
NZ,test_fail`. Verified via `z80dasm` afterward, not just a clean
assemble: confirmed the rom-copy length (`0x97D` = 2429 = the real file
size), both bank-flip `OUT` values (`$01`/`$03`), the `test_fail` jump
target lands exactly on its `POP BC` (address `0xE1`), and the
`write_msg` call target (`0x114`) lands exactly where `ok_msg`'s 13
bytes end, byte for byte matching what was intended rather than assumed
correct. Added to the Makefile's `all` target. Not yet bench-tested --
needs the bank-switch-wiring.md circuit built first.

### `bank` pull-down: dropped on paper, restored after a real bench finding (2026-09-06)

User asked whether the `bank` pull-down was actually necessary, pointing
out the system boots into the lower 32K and configures Port A as an
output almost immediately. Traced through why `mode_pin`'s pull-down is
genuinely load-bearing (it gates the 373/SRAM output-enable logic, live
from the very first instruction fetch at address 0 onward) while
`bank`'s situation is different (only affects `A16`, which only matters
for `0x8000-0xFFFF`, untouched until after Port A is already configured
and has deterministically forced `bank` to 0 regardless of the
pre-configuration float) -- concluded the pull-down wasn't functionally
necessary given this project's actual boot-code structure, and removed
it from `gate-equations.md` §8, `373-gates-sram-wiring.md`, and
`bank-switch-wiring.md` at the user's request.

User then wired the bank-switch circuit and flashed
`bank-switch-test.bin`: complete hang, no LED activity at all (not even
the fast-blink failure path) -- pointing at something more fundamental
than the test program's own logic. Asked whether a previously-working
program still ran with the new circuit wired in, to isolate "the whole
system is broken" from "something specific to the new test." User's
answer: old tests work OK, **but** they'd had to change `video-test3.asm`'s
`SP` from `$8000` to `$7FFF` first -- it was "unreliable" at `$8000`.

This is a real, informative bench result that overturns the "not
necessary" conclusion, even though the logical reasoning behind it was
sound as far as it went: it correctly established that the
*software-visible* value of `bank` becomes deterministic quickly, but
didn't account for a genuinely floating LS-TTL input being electrically
noisy (capacitive coupling from nearby switching signals, not just "an
arbitrary but stable wrong value") for however long it takes software to
reach that deterministic state. `video-test3.asm` never touches `bank`
at all, yet became unreliable specifically tied to addresses at/above
`0x8000` (`A15=1`) -- exactly the condition under which an unpulled
`bank` feeding `NAND(bank, A15)` would make `A16` electrically noisy,
independent of what `bank`'s logical value "is" at that moment.
Restored the pull-down in all three docs (`gate-equations.md` §8,
`373-gates-sram-wiring.md`, `bank-switch-wiring.md`, the last now with
an explicit "do not omit" note) -- `hardware/bom.csv` was never actually
edited to remove it, so no BOM change was needed. One resistor is cheap
insurance against a real, intermittent failure mode; the "not strictly
necessary" argument, while logically defensible, wasn't worth the
electrical risk in practice.

Not yet confirmed whether restoring the pull-down actually fixes
`bank-switch-test.bin` itself (the program that matters) -- `video-test3
.asm`'s `SP` symptom is suggestive but not proof of the same root cause
in the actual test. Next step: rewire the pull-down, reflash
`bank-switch-test.bin`, and check whether it now reaches the LED-blink/
video stage instead of hanging completely.

### Pull-down wasn't the (whole) story: a pre-existing, wrong SRAM pin number in the docs (2026-09-06)

User restored the pull-down as recommended above. Still a total hang --
no picture, no LED blink at all, identical to before.

Since the pull-down didn't fix it and the hang is total (not just
bank-specific data corruption), re-examined the assumption that `A16`
even landed on the right physical pin. Pulled `tc551001cp.pdf`'s actual
pinout image directly (not re-checked old notes) and found a real,
significant, **pre-existing** documentation error: `373-gates-sram-
wiring.md`'s SRAM pin table has been wrong for `CE1`, `CE2`, `OE̅`, and
`R/W` (and, critically, `A16`) since long before this session, despite
that section's own "Pinout datasheet-verified in Phase 1" header. Real
pins: `A16`=2, `CE1`=22, `CE2`=30, `OE̅`=24, `R/W`=29 -- the old table
said 10, 31, 6, 32, 5 respectively, none of them correct.

`CE1`/`CE2`/`OE̅`/`R/W` have obviously been wired to the *real* pins on
the actual breadboard all along (SRAM reads/writes have worked through
every phase up to now) -- the table simply never matched reality, and
nothing had occasion to catch it until brand-new wiring (`A16`, for CP/M
banking) needed a pin number from this exact table for the first time
and got a wrong one: the old table's "10" is really `A2` -- a real,
heavily-used address line, not a spare like the true `A16` (pin 2). If
the new gate's output landed on pin 10 instead, it would fight the
Z80/AVR for control of `A2` on every single memory access the instant
`bank` is asserted, not just within the banked region -- a strong,
concrete explanation for a total, immediate hang that has nothing to do
with the pull-down question at all. Corrected the pin table in
`373-gates-sram-wiring.md` and added an explicit, verified pin number
(2, with a "double-check this is really pin 2, not 10" warning) to
`bank-switch-wiring.md`, which previously just said "the SRAM's A16
pin" generically without a number of its own.

Asked the user to check which physical pin their new gate's output
actually landed on before assuming anything else is wrong -- awaiting
confirmation.

### plh.asm: bank/A16 ruled out entirely; a real, verified firmware bug found instead (2026-09-06)

Follow-up bench results with a cut-down "just print Hello" test
(`plh.asm`) moved the investigation away from the bank-switch circuit
entirely: hardwiring SRAM `A16` straight to +5V (bypassing the new
74LS00 completely, `bank` electrically irrelevant) did **not** fix the
symptom, and `video-test3.bin` was "perfect and consistent" under the
exact same hardwired condition -- ruling out both the pin-10-vs-pin-2
mixup and the pull-down question as explanations for *this* symptom
(both real fixes from earlier, just not the cause of this one).

Symptom, precisely: "Hello" sometimes doesn't render at all (screen
black, though HSYNC/VSYNC sync visibly active -- so the magic-address
handoff and video generation genuinely started); when it does render,
random single-pixel flecks appear elsewhere on screen, in *different*
positions on different power cycles -- the classic signature of SRAM
bytes that were never actually written (no defined power-on state,
genuinely different garbage each cycle), not a deterministic logic bug.
Then, with a 3-blink delay added, a stranger variant: "Hello" rendered
*twice* on the same line, the second copy shifted ~3 character cells
right, with corruption on part of one letter -- the user's own
diagnosis ("like an address line floats midway through a write") was
exactly the right shape of theory.

Ruled out a control-flow explanation first, via disassembly rather than
assumption: confirmed `busy: JR busy` really does jump to its own
address (`0x56` -> `0x56`), not falling through into the file's
leftover dead Test-1/Test-2 code (which still physically contains a
second, unreachable `LD A,($3FFF)` that a linear disassembler dutifully
shows but the CPU never executes).

Then the user asked directly: could something strange happen to the
instruction that follows the magic-address access? Reading rom_emu.c's
actual current source (not from memory of it) found a real, concrete
bug matching exactly that shape: the magic-address exit path calls
`usart_puts_P()` (a blocking, ~20ms-at-38400-baud print) **before**
driving `wait_rel` permanently low, not after. Since the WAIT flip-flop
has no mode_pin gating (`D` tied straight to `_RD`, gate-equations.md
§3) and the per-byte pulse just before this leaves `wait_rel` idle-high
(not yet preset-held), the Z80's very next instruction fetch -- whatever
comes right after `LD A,($3FFF)` -- latches `_WAIT` low exactly as
normal, with nothing polling to release it (the AVR is blocked in the
print, not looping) until the print finishes and the permanent
drive-low finally executes. Every single program that has ever hit the
magic address has been eating an unintended ~20ms WAIT-stall on its
first post-magic instruction, invisibly, the whole time. Found the
identical pattern in `video.c`'s `video_run()` too: a ~50ms banner print
sequenced before `sync_init()`/`sei()` instead of after.

**Honest caveat, stated plainly rather than oversold**: both bugs stall
*any* program's post-magic-address instruction identically (fixed
strings, fixed baud rate), so neither one by itself explains why
`plh.asm` specifically showed corruption while `video-test3.bin` didn't
-- that asymmetry is still unexplained. Fixed both anyway (reordered so
the real hardware transition -- permanent WAIT release, then separately
`sync_init()`+`sei()` -- completes before anything blocks on UART I/O
for the human's benefit) since they're real, unconditional bugs
regardless of whether they're *the* explanation for the specific
duplication symptom. Rebuilt clean (`text=8072`).

Not yet bench-tested. Next: reflash and see whether the duplication/
flecks are gone, reduced, or unaffected -- any of those three outcomes
is informative at this point.

### Root cause found and fixed: the bank-switch circuit used `_BUSRQ` instead of `_BUSACK` (2026-09-07)

The two fixes above didn't resolve it. User reported the WAIT-release
fix didn't help either, tried swapping the new 74LS00 for a 74HCT00
(ruling out a CMOS-input-threshold explanation), and tried dropping the
Z80 to 4MHz (ruling out a simple "not enough margin relative to the
Z80's own clock period" explanation) -- neither changed anything.
Reported the one fact that stayed true through all of it: tying `A16`
to a fixed level, either high *or* low, made everything work reliably;
only the gate-driven version ever failed. Both fixed levels working
equally well was the key clue -- it pointed away from "A16 settles to
the wrong voltage/value" and toward "A16 changing state at all is the
problem," which none of the electrical theories tried so far actually
explained.

User then worked out the real mechanism directly: gate 2 of the
bank-switch circuit was gated on `_BUSRQ`, on the assumption that
`_BUSRQ` asserted means the Z80 has already released the bus. This
project's own Z80 UM lookup -- done earlier this session for the
unrelated WAIT-flip-flop race question -- already had the answer on
file without anyone connecting it back to this circuit: "BUSREQ... is
always recognized at the end of the current machine cycle." There's a
real window, up to one full machine cycle, between the AVR asserting
`_BUSRQ` and the Z80 actually tristating, during which the Z80 is still
fully active -- still fetching, still driving the address bus for its
own, unrelated purposes. With `_BUSRQ` gating the circuit, that window
forced `A16=1` regardless, corrupting whatever real memory access was
genuinely in flight (e.g. a live instruction fetch reading from the
wrong physical bank) -- at a rate tied to the AVR's video timing (200
`_BUSRQ` assertions/frame, 50 frames/sec), not the Z80's own clock,
which is exactly why neither the 74HCT swap nor the 4MHz test touched
it, and exactly why a hardwired `A16` (immune to `_BUSRQ` entirely, at
either level) fixed it completely.

Fix: gate 2's second input is `_BUSACK` (Z80 pin 23, verified against
the real Z80 UM pinout diagram), not `_BUSRQ`. `_BUSACK` is the Z80's
own hardware confirmation that it has *actually* relinquished the bus
("indicates to the requesting device that the CPU address bus, data
bus, and control signals... have entered their high-impedance states"),
not merely been asked to release it. This was chosen over the
alternative considered (delaying `_BUSRQ` by roughly
`BUSRQ_SAFE_CYCLES` before it reaches the gate) because it's the real
event rather than an estimate of how long the event takes -- can't be
"too short" for some worst-case instruction the way a fixed delay
always risks being. Costs nothing pin-wise: `_BUSACK` was already
dropped from the *AVR's* firmware pin budget in the base design
(`plan.md`, Phase 6b decided not to sense it in firmware and rely on
`BUSRQ_SAFE_CYCLES` instead for the AVR's own bus takeover) -- wiring it
into this gate is a pure hardware connection that never touches the AVR
at all, so that earlier decision is unaffected.

Updated `gate-equations.md` §9, `bank-switch-wiring.md`,
`cpm-plan.md` §2, and `hardware/bom.csv` to reflect the corrected
wiring and record why, prominently, rather than just silently fixing
the pin.

**User confirmed on the real bench**: both `plh.asm` (the cut-down
"print Hello" test) and `bank-switch-test.bin` (the actual Phase 9 SRAM-
independence + video-isolation test) now pass reliably. This closes out
Phase 9's hardware bring-up -- the two-NAND bank-switch circuit is
confirmed working as designed, with the corrected `_BUSACK` wiring.

**Final confirmation**: user put the Z80 clock back to its real 8MHz
target (had been dropped to 4MHz purely as an earlier diagnostic step)
and swapped the gate chip back to a plain 74LS00 (had been swapped to a
74HCT00 mid-investigation, chasing the now-disproven CMOS-input-
threshold theory) -- both still work reliably. This retires the 74HCT00
detour for good: it was never the actual fix, just a plausible-looking
theory that happened to get tried around the same time as other real
progress, and the bench now confirms plain 74LS00 at full 8MHz is
sufficient with the `_BUSACK` correction in place. `bom.csv` and
`bank-switch-wiring.md` already specified plain 74LS00 throughout (the
74HCT00 swap was only ever a bench experiment, never written into the
docs as the part to use), so no further correction needed there.
Phase 9 is done, verified at the real target clock speed with the real
target parts.

### Phase 10: keyboard interface -- MSX-style matrix, matched to real MSX pin convention (2026-09-07)

Designed and wrote up `docs/keyboard-wiring.md` (74LS145 pinout,
verified against a secondary source rather than assumed) and
`test-progs/keyboard-scan-test.asm`: continuously scans all 10 rows,
reports whichever `(row, col)` it finds pressed via `write_msg`, or
"NO KEY". First pass put row-select on Port A (`PA2`-`PA5`, alongside
the existing `mode_pin`/`bank`) to avoid any new 8255 control-word
configuration.

User pointed out real MSX hardware puts row-select on Port C's lower
nibble instead, with Port B for columns (matching this design's column
choice already), and asked whether there was a blocker for Phase 11's
SD card SPI before switching to match it. Traced through it before
answering rather than guessing: moving row-select off Port A actually
leaves *more* room for the SD SPI than the original layout did -- Port
A keeps 6 free bits (enough for the 3 SPI output lines, no
reconfiguration needed since Port A's already an output) versus the
original layout's 2 spare bits, one short of what 3 SPI outputs need.
No blocker; switched to match the real convention.

This does need one real 8255 configuration change every other
test-progs/*.asm doesn't: control word `$8A` instead of `$8B` (bit 0
flips Port C's lower nibble from input to output; Port A/B/Port-C-upper
directions all unchanged). Also simplified the scan code in the
process: since row-select no longer shares a byte with `mode_pin`/
`bank`, the row value goes straight to Port C with no shift-and-merge
needed, and Port A only needs writing once at boot instead of on every
row-scan iteration.

Re-verified the whole program via a fresh disassembly after the switch,
not just after the first version: control word value, the direct
`OUT ($AA),A` row write, every branch target (`key_found`, `row_loop`,
`scan_loop`, `find_col`/`col_done`), and both digit-conversion writes
landing exactly on their placeholder bytes in the status string. Added
to the Makefile, builds clean. `hardware/bom.csv` updated (74LS145 +
8 column pull-ups). Not yet bench-tested -- needs the 74LS145 wired per
`keyboard-wiring.md` (a single pushbutton between one row output and
one column input is enough for initial bring-up, no full keyboard
required yet).

**Real bug found before ever reaching the bench**: user asked directly
how this test could possibly work given the screen lives in the "2nd
bank." It couldn't have -- the file used `MODE_SRAM = $01` (mode=1,
**bank=0**) and never touched `bank` again, but per Phase 9's own
design (`cpm-plan.md` §2, `gate-equations.md` §9), `$C000+` is only the
AVR's actual video RAM under `bank=1`; under `bank=0` the same Z80
addresses land in the *other* physical bank, invisible to the AVR's
video fetch. Every screen write this program made -- the clear, the
title, every status update -- would have silently gone nowhere, right
after this project had just spent an entire session getting exactly
this bank/video relationship right for Phase 9. Fixed: `MODE_SRAM = $03`
(bank=1, fixed for the whole run, matching `plh.asm`'s own approach --
this test never needs bank=0 at all). Reassembled and reverified via
disassembly that the mode/bank write is now `$03`, not `$01`.

**Bench-confirmed working**: user flashed the corrected build --
"NO KEY" shown at rest, correct differing `(row, col)` reported for
different keys/switches pressed. Closes out Phase 10's basic bring-up:
the 74LS145 row decoder, the `PC0`-`PC3`/`$8A`-control-word row-select,
and the `PB0`-`PB7` column read are all confirmed working together on
real hardware.

**Upgraded to real key names, also bench-confirmed.** Raw `ROW=r COL=c`
was only ever meant to validate the matrix wiring itself; replaced with
a `(row,col)`-indexed pointer table of key-name strings matching the
confirmed rows-0-8 map in `keyboard-wiring.md` (this keyboard has no
numeric keypad, closing out the earlier-flagged 74LS145
row-9/row-10-output concern as moot -- only rows 0-8 are ever wired).
Display field is a fixed 8 characters, space-padded, so a short name
never leaves stale characters from a longer previous one. Verified
against the actual assembled binary, not just the source: fresh
`z80dasm -g0` disassembly (the earlier `-g` default of `0x100` doesn't
match this project's `org 0`, worth remembering next time) traced every
branch target and pointer load, and a direct hex dump of the table and
string data was cross-checked byte-for-byte against the source's
row/col assignments. User flashed and confirmed on real hardware: key
names show up correctly on-screen. Phase 10 is now fully closed out.

## Phase 11: SD card SPI interface -- wiring, driver, and test written; not yet bench-tested (2026-09-07)

Pin assignment finalized: `CS`=`PA2`, `SCK`=`PA3`, `MOSI`=`PA4` (Port A
free bits, already output under the existing `$8A` control word),
`MISO`=`PC4` (Port C upper nibble, already input under the same word)
-- **zero 8255 control-word changes needed** on top of what the
keyboard interface already introduced, both peripherals' pins landing
on bits that were already configured the right direction. Assumes a
common 5V-tolerant microSD breakout module (onboard regulator + level
shifting), per the user's confirmation -- `docs/sdcard-wiring.md` has
the fallback discrete-level-shifting design flagged in case the actual
hardware turns out to be a bare socket instead.

Also found and fixed two real, pre-existing documentation
inconsistencies while wiring this: `373-gates-sram-wiring.md`'s 8255
pin table still said `mode_pin` was pulled *up* in three places,
contradicting `gate-equations.md` §2/§8's settled pull-*down* design --
a stale leftover from an early draft that a previous session's summary
believed had already been fixed here but hadn't been; and
`hardware/bom.csv`'s 74LS145 row still cited the superseded
row-select-on-Port-A pin layout (`PA2`-`PA5`) instead of the real,
built `PC0`-`PC3` layout. Both corrected.

`test-progs/sdcard-test.asm` implements a full SPI-mode SD/SDHC/SDXC
bring-up sequence (>=74 power-up clocks, `CMD0`, `CMD8` version check,
`CMD55`+`ACMD41` init loop, `CMD58` CCS check -- SDSC/MMC cards are a
documented, deliberate non-goal, see `sdcard-wiring.md`), then a full
on-device round trip: fills a 512-byte buffer with a known pattern,
writes it to `TEST_SECTOR` (`CMD24`), reads it back (`CMD17`), and
compares the two without needing a PC to judge pass/fail. Separately
reads sector 0 (the MBR, read-only, safe on any card) and hex-dumps its
first 16 bytes on screen so the result can be cross-checked against
what a PC shows for the same card's real sector 0 -- satisfies
`cpm-plan.md`'s Phase 11 criteria ("verify against known content
written from a PC") two ways at once.

Since the 8255 can only write Port A a full byte at a time, and `CS`/
`SCK`/`MOSI` share that byte with `mode_pin`/`bank`, every SPI bit
toggle goes through a RAM shadow (`porta_shadow`) rather than ever
being constructed from scratch -- same discipline the earlier
Port-A-based keyboard draft needed before it moved to Port C. Adopted a
project-wide (for this file) convention up front to avoid the kind of
register-clobber bug this driver's call depth invites: **carry SET
means failure** throughout, and `spi_xfer`/`send_cmd`/`read_r1`/
`wait_token` all explicitly preserve `BC` and `HL` across every call
(each wraps its body in `PUSH`/`POP`), which is what lets `sd_init`'s
outer `ACMD41` retry loop keep its `B` counter alive across nested
calls into all four of those routines without a special case, and lets
`read_block`/`write_block` use `BC` as their own byte counters and
(after the transfer loop) reuse it again as a busy-wait timeout, all
safely.

Verified against the actual assembled binary, not just re-read as
source, the same way Phase 10's key-name table was: `z80asm` built it
clean (4396 bytes, comfortably inside the 8K ROM window), then a full
`z80dasm -g0` disassembly was traced instruction-by-instruction --
every `JR`/`DJNZ`/`JP` target in `sd_init`, `spi_xfer`, `send_cmd`,
`read_r1`, `wait_token`, `read_block`, `write_block`, and all six
`build_*`/`compare_buffers`/`fill_test_pattern`/`dump_hex16` helpers
checked by hand against its intended label, and the RAM layout
(`porta_shadow`, `cmd_buf`, `hexline`, `sd_wbuf`, `sd_rbuf`, each
computed from the previous one's declared size) cross-checked against
every `LD HL,`/`LD DE,` immediate the disassembly actually contains --
all matched exactly. Five `JR`s initially came back "out of range"
during assembly (this file's routines ended up spanning further than
any previous test-progs file) and were switched to `JP`; nothing else
needed correcting after that.

**Not yet bench-tested.** Next step: wire the breakout module per
`sdcard-wiring.md`, flash `sdcard-test.bin`, and report what the
`SD INIT:`/`ROUNDTRIP:`/`MBR[0..15]=` lines show.

**First real bench result: "SD INIT: FAILED", no further detail.**
Every one of `sd_init`'s five failure points (`CMD0` no/bad response,
`CMD8` illegal-command or echo mismatch, `ACMD41` never going ready,
`CMD58` rejected, `CMD58` OK but `CCS=0`) collapsed to the same generic
message -- not enough to diagnose from, so before guessing at hardware
causes, added real instrumentation: each failure path now tags a stage
number (1-6) and stashes the associated response/echo/OCR byte to two
new RAM variables (`sdi_stage`/`sdi_info`) right before falling into
the shared `sdi_fail_tag`/`sdi_fail` return, and `init_failed` now
prints a second line, `STAGE=n INFO=$xx`, built from them.

Re-verified via disassembly the same way as everything else in this
file: traced all six new stage-tagging branches (`sd_init` now spans
0x168-0x238) against their intended targets, and caught one real bug of
my own introducing this -- the `CCS=0` (stage 6) path captured OCR byte
1 *after* `AND $40` had already masked it down to `$00`/`$40`, so a
stage-6 report would always have shown `INFO=$00` regardless of the
card's actual OCR byte. Fixed by stashing `D` (the raw byte) before the
`AND`, re-verified against the fresh disassembly.

Next step (still pending real hardware): reflash the updated
`sdcard-test.bin` and report the `STAGE=`/`INFO=` line -- that pins
down which of the six init steps is actually failing before any further
hardware changes are considered.

**Second bench result: `STAGE=1 INFO=$17`.** `CMD0`'s R1 came back
`$17` -- decoded as an R1 byte that's several unrelated status bits set
simultaneously (idle+erase-reset+illegal-command+erase-sequence-error
all at once), not anything a real card would ever send for `CMD0`.
User asked directly whether the 8255 outputs need pull-ups/buffering.
Diagnosis: **`CS`/`SCK`/`MOSI` (8255 outputs) don't need anything --
actively driven both directions the whole time once Port A is
configured.** `MISO` (the one 8255 *input* in this interface) does:
per the SD SPI spec a card only drives `MISO` while `CS` is asserted
(high-Z the rest of the time), and some cards need it at a defined
level to complete their own power-on sequence; `$17`'s shape -- several
unrelated bits, no coherent cause -- matches a floating CMOS input
picking up coupling from the adjacent, actively-toggling `SCK`/`MOSI`
lines, not a real response. Added a 10k pull-up, `MISO` to +5V, to
`sdcard-wiring.md` and `bom.csv` (standard practice -- the Z80 Retro!
reference driver already cited for the init sequence uses one too).

**Not yet confirmed on real hardware** -- this is a hardware-only
change (no firmware involved), pending the user adding the resistor
and re-running the existing `sdcard-test.bin` unchanged.

**Third bench result: identical `STAGE=1 INFO=$17` even with the
pull-up added, and -- the key new data point -- identical again with
the SD card physically removed.** VCC/GND/pull-up placement all
independently confirmed good; user also tried buffering `SCK` through
two 74HC inverters for a cleaner edge, no change. Removing the card
entirely and still getting the exact same non-`$FF`, non-trivial byte
proves the card/module play no part in this reading at all -- rules
out both remaining card/module-side theories (unpowered module,
card-side init quirk) outright.

This also retroactively answers a question worth asking explicitly:
`keyboard-scan-test.asm` already proves the 8255's address decode for
`$AA` (Port C) is correct on real hardware -- it *writes* Port C's
lower nibble through that exact address and real row-selection is
bench-confirmed working. Since `MISO` is just the upper nibble of that
same register, the Z80-to-8255 address wiring itself isn't in
question; whatever's producing `$17` is either in the bit-bang driver
itself or in wiring specific to `PA4`/`PC4`.

Added `test-progs/spi-loopback-test.asm`: a dedicated diagnostic that
removes the SD card/module from the picture entirely. Wire a single
jumper from `PA4` (`MOSI`) straight to `PC4` (`MISO`) and it sends 10
bytes (`$00,$FF,$A5,$5A,$3C,$C3,$01,$80,$AA,$55` -- deliberately
including alternating-bit patterns, since every SD test so far only
ever sent `$FF`, a degenerate case where `MOSI` never actually changes
mid-byte) through the identical `spi_xfer` routine and checks each
comes back unchanged. A clean pass proves the driver and the 8255
wiring for both pins are correct, independent of the SD card/module's
own uncertainties (power, compatibility, whatever it's actually doing)
-- narrows the persistent, card-independent `$17` down to "not this"
either way it comes out.

Verified via disassembly the same way as every other file here:
`test_loop`'s per-byte flow (index-based, not a register-resident
counter, specifically because `write_msg` clobbers `HL`/`DE`/`BC`/`IX`
internally and doesn't preserve any of them -- confirmed by re-reading
its own code -- so anything that must survive a `write_msg` call
mid-loop has to live in memory, not registers), the pass/fail tag
selection, and `copy_str`'s line-building all traced against their
intended addresses; `spi_xfer` itself is untouched from `sdcard-
test.asm`'s already-verified version. Built clean, 2632 bytes.

Next step: wire the `PA4`-`PC4` jumper and flash `spi-loopback-test.bin`
-- if it reports `ALL TESTS PASSED`, the bug is somewhere between the
8255's `PA4`/`PC4` pins and the SD module (a wiring/module problem
after all, just not the ones already ruled out); if it shows mismatches
too, the bug is in the driver or 8255 wiring itself and this pins down
exactly which byte(s) fail.

**Fourth bench result: `spi-loopback-test.bin` shows `SENT=$00
GOT=$00 OK`, then every remaining test `GOT=$00 FAIL` regardless of
what was sent.** A much cleaner symptom than `$17` was: `PC4`/`MISO`
reads as a hard, constant 0 during the test, full stop -- not noise,
not a mix of bits. Computed that after the test completes and the
program sits in its final `halt` loop, `PA4`/`MOSI` is left at a known
static logic-1 (last byte sent was `$55`, whose LSB is `1`) -- asked
the user to multimeter-probe both `PA4` (8255 pin 40) and `PC4` (pin
13) in that static state. **Both read 5V.** That's a real
contradiction worth recording plainly: the wire is proven good, the
pin is proven to actually carry 5V, yet the running program's own read
of that exact bit says 0.

This also rules out something worth naming explicitly: Phase 10's
`keyboard-scan-test.asm` already proves 8255 IO reads work correctly
in general (`IN A,($A9)`, Port B columns, bench-confirmed) *while*
video generation is active -- so this isn't a general "IO reads are
broken" or "video steal corrupts IO" problem. What's specifically never
been exercised by any test before this one is reading Port C's *upper*
nibble (`PC4`-`PC7`) as input -- every previous use of Port C
(keyboard row-select) only ever wrote its *lower* nibble.

Added `test-progs/portc-probe-test.asm`: strips out the SPI
protocol/timing entirely and just loops `IN A,($AA)` forever, drawing
all 8 bits live on screen as ASCII `0`/`1` (MSB..LSB) under a static
`76543210` label row. Lets the user touch pin 13 directly to GND/+5V
with a spare wire and watch, in real time, whether the on-screen bit4
character actually tracks it -- a test with zero bit-bang timing
involved at all, isolating whether the 8255/Z80 can see live changes
on that specific physical pin under any circumstances. Verified via
disassembly (`probe_loop`/`byte_to_binary` branch targets all traced
and correct); built clean, 2317 bytes.

Next step: flash `portc-probe-test.bin` and report what happens to the
live bit4 character while manually toggling pin 13.

**Fifth bench result: `portc-probe-test.bin`'s bit4 correctly tracks a
manual GND/+5V jumper on pin 13 in real time, exactly as expected.**
This proves the 8255's `PC4` input path, the `IN A,($AA)`/`BIT 4,A`
read logic, and the physical pin itself are all completely sound on
their own -- the fault is specific to something the failing
`spi-loopback-test.bin` does that this test doesn't.

The one thing `portc-probe-test.asm` never exercises: it never writes
Port A at all in its loop, just repeatedly reads Port C. `spi_xfer`,
by contrast, does an 8255 Port A *write* (setting `MOSI`/`SCK`)
*immediately* followed by an 8255 Port C *read* (sampling `MISO`) --
every single bit, every single byte. That specific interaction --
write-then-immediately-read, across two different ports on the same
chip -- had never actually been isolated before.

Added `test-progs/porta-write-portc-read-test.asm` to isolate exactly
that, with everything else stripped away (no SPI protocol, no
bit-shifting, no `CS`/`SCK`): in a tight loop, write Port A with `PA4`
alternating 0/1 (mode/bank bits held fixed), immediately read Port C
back after each write, and display both lines live. Keeps the same
`PA4`-`PC4` jumper from `spi-loopback-test.asm`. If this shows `PC4`
correctly tracking `PA4` (0 then 1, continuously), the bug is
somewhere in `spi_xfer`'s specific multi-step sequence rather than
this write-then-read pattern itself; if `PC4` stays stuck at 0 in both
lines despite `PA4` alternating, this exact write-then-read
interaction is the reproducible root cause.

Verified via disassembly (both `PA4=0`/`PA4=1` branches, `byte_to_
binary`, all `write_msg` calls traced to their correct row/message);
built clean, 2422 bytes.

Next step: flash `porta-write-portc-read-test.bin` and report whether
the two live bit4 characters track `PA4`'s alternation or stay stuck.

**Root cause found -- by the user, reading the code directly.** Before
running the write/read isolation test, the user asked directly:
"Won't the `SLA` affect the zero flag?", pointing at `spi_xfer`'s
```
    BIT  MISO_BIT,A
    SLA  C
    JR   Z,sx_miso0
```
Yes -- and this is the real, complete, sole root cause of every SD
symptom this whole phase, from the very first `$17` onward. `SLA` sets
`Z` from its *own* shifted result; executing it immediately after
`BIT` clobbers the flag `BIT` just set, before `JR Z` ever tests it.
Worse: once that happens, `SET 0,C` becomes conditioned on "is the
shifted accumulator zero," not on the real sampled bit at all -- the
`IN A,($AA)`/`BIT` result is computed and then thrown away unused.
Traced the consequence precisely: `C` starts at 0 (`LD C,0`), and
`SLA` of `0` is `0`, which sets `Z`, which skips `SET 0,C` -- every
iteration, forever, since `C` can therefore never become anything but
`0`. **`spi_xfer` was mathematically guaranteed to return `$00` on
every single call, completely independent of the real `MISO` signal.**
This is exactly what `spi-loopback-test.bin` showed (`GOT=$00` for
every byte except the trivial `$00` case), and explains why the two
probe tests (`portc-probe-test.asm`, `porta-write-portc-read-test.asm`)
both worked correctly -- neither uses this buggy sequence at all,
`byte_to_binary` extracts bits with a completely different, correct
method (`AND $80`/`RLCA`).

This retroactively closes out the entire diagnostic arc: the `$17`
from the original `sdcard-test.asm` run remains not fully explained
bit-for-bit by this analysis alone (the bug as derived predicts a clean
`$00`, not `$17`), and is presumed to trace back to some now-moot
detail of that earlier binary/upload state rather than a second,
separate bug -- not chased further given the real, disassembly-proven
root cause is now found and fixed, and every hardware theory
along the way (MISO pull-up, module power, 8255 pin health, Port
A-write/Port C-read timing) was independently verified sound by the
probe tests regardless.

**Fixed** in both `sdcard-test.asm` and `spi-loopback-test.asm`: swap
the order so `SLA C` executes *before* `BIT MISO_BIT,A`, not after --
`BIT` is then the last flag-setting instruction before `JR Z`, so
nothing clobbers it. Re-verified via disassembly in both files
(`sla c` immediately followed by `bit 4,a` immediately followed by
`jr z,$+4`, correct target in both cases). `portc-probe-test.asm` and
`porta-write-portc-read-test.asm` needed no change -- they never had
this bug.

Not yet re-confirmed on real hardware -- next step: reflash the fixed
`sdcard-test.bin` (or `spi-loopback-test.bin` again, as a first, purely
software-side confirmation with the `PA4`-`PC4` jumper still in place)
and report the result.

**`spi-loopback-test.bin` confirmed `ALL TESTS PASSED` with the jumper
in place** -- real, hardware-validated proof the driver fix is
correct. But `sdcard-test.bin`, against the real module, still showed
the exact same `STAGE=1 INFO=$17` -- unchanged by the driver fix, by
trying different cards, or by re-checking wiring (all independently
verified good by this point). User asked directly whether there might
be another coding error, prompting a closer re-read.

**Second real bug found, and it's the actual explanation for `$17` the
whole time.** In `sd_init`'s CMD0 check: `CALL sd_cs_deassert` ran
*before* `LD (sdi_info),A` -- but `sd_cs_deassert` itself clobbers `A`
(`LD A,(porta_shadow)` / set the CS bit / write it out). So `sdi_info`
was never capturing `read_r1`'s real response at all -- it was
capturing `sd_cs_deassert`'s own leftover shadow byte. Worked out the
exact arithmetic: after CMD0's polling, `porta_shadow` holds mode=1,
bank=1, CS=0 (still asserted), SCK=0, MOSI=1 (last bit of the `$FF`
polling byte) = `$13`; `sd_cs_deassert` then sets the CS bit, giving
`$17` -- an exact match, and completely explains why the value never
budged regardless of card, wiring, pull-up, or the earlier driver fix:
**it had nothing to do with the SD card at all.**

Checked every other failure branch for the same ordering mistake and
found one more, this time a real *functional* bug rather than just a
wrong diagnostic byte: the `ACMD41` ready-check (`OR A` / `JR Z,
sdi_ready`) also ran after its own `sd_cs_deassert` call, meaning
"ready" could never actually be detected -- it would always test the
deassert call's own leftover shadow byte (never zero), forcing every
run to exhaust all 256 retries and report stage 4 regardless of what
the card actually said. Hadn't been observed yet only because CMD0
failed first every time.

**Fixed both** by moving the comparison (`CP $01` / `OR A`) and the
`sdi_info` stash to run immediately after `read_r1`, before
`sd_cs_deassert` -- relying on the fact that `sd_cs_deassert`'s own
instructions (`LD`/`SET`/`OUT`) don't touch the flags on a Z80, so a
flag set beforehand survives the call intact even though `A` itself
gets clobbered. The other four failure branches (CMD8's two, CMD58's
two) were already correct -- they reload from `D`/`E`, registers
`sd_cs_deassert` never touches, rather than relying on `A` surviving.

Re-verified via disassembly: `sdi_info`'s store and the `CP`/`OR A`
test both now precede the `sd_cs_deassert` call in both the CMD0 and
ACMD41 sections, with all branch targets re-traced and correct.

Not yet re-confirmed on real hardware -- next step: reflash
`sdcard-test.bin` and report what `SD INIT:` shows now.

**Sixth bench result: real progress -- `STAGE=2 INFO=$00`.** CMD0 now
genuinely succeeds (real communication established for the first time
this whole phase). Stage 2 is CMD8's R1 coming back as `$00` instead
of `$01` -- an odd value on its own terms (bit0/idle clear, right
after CMD0 correctly left the card idle) but confirmed, via the same
disassembly-tracing standard as everything else, NOT a repeat of the
info-capture bug (CMD8's branch reloads from `D`, a register
`sd_cs_deassert` never touches, so this one really is CMD8's genuine
response).

Added a common, well-documented SD-over-SPI practice this driver was
missing: **one extra trailing clock byte after every `read_r1` call,
regardless of outcome.** Real cards need a little settling/completion
time (a few more clock edges) after sending a response before they're
ready for the next command. CMD0 -- the very first command, nothing
precedes it -- worked without this; CMD8 is the first command that
follows directly after another command's response with no gap, which
matches the failure shape exactly. Implemented inside `read_r1` itself
(one place, benefits every call site) via `PUSH AF` / dummy `spi_xfer`
/ `POP AF`, preserving the real response across the extra clock so
every caller's existing flag/register-based checks still see the
genuine byte.

Re-verified via disassembly: the extra `push af`/dummy `spi_xfer`/
`pop af` sequence sits correctly between the polling loop's exit and
the final `pop bc`/`ret`, in the one and only copy of `read_r1`.

Not yet re-confirmed on real hardware -- next step: reflash
`sdcard-test.bin` and report what `SD INIT:` shows now.

**Seventh bench result: the trailing-clock fix had zero effect --
`STAGE=2 INFO=$00`, bit for bit identical.** That a real, disassembly-
verified change to the actual SPI sequence produced no change at all
was itself the key clue: it meant the true cause couldn't be timing/
protocol-related, and had to be another deterministic, hardware-
independent bug, same category as the earlier `$17` one. Traced it
down on a fresh re-read: CMD8's `LD D,A` right after `read_r1` captures
R1 correctly at that instant, but `D` is `spi_xfer`'s *own* internal
bit-counter register (documented in its own header comment: "clobbers
D and E") -- unconditionally overwritten, always left at exactly `0`,
by every single call to it. Immediately after stashing R1 in `D`, the
code makes 4 *more* `spi_xfer` calls (for the R7 payload bytes), each
one clobbering `D` again. By the time `LD A,D` finally read it back
(after `sd_cs_deassert`), `D` had been `0` for a while -- `LD A,0` is
exactly `$00`, completely independent of the card's real response,
which is exactly what a fix to the real protocol timing could never
have touched.

Checked for the same pattern elsewhere and found one more, in CMD58's
CCS check: `LD D,A` capturing OCR byte 1, followed by 3 more
`spi_xfer` calls (the remaining OCR bytes) before `D` was read back --
identically broken, just not yet reached (CMD8 always failed first).
Both would have always evaluated as "response was `$00`"/"CCS=0"
regardless of the real card.

**Fixed** by adding a `spi_tmp` scratch byte in RAM and stashing both
values there instead of in `D` -- memory (or `BC`/`HL`, which
`spi_xfer` does preserve) is required for anything that needs to
survive more than one `spi_xfer` call; `D`/`E` cannot be used for that,
only for a value read and consumed with no `spi_xfer` call in between
(which is why the CMD8 echo byte's use of `E` was always fine -- it's
set once, right before its only use, with nothing calling `spi_xfer`
in between). Re-verified via disassembly: both stashes now happen
immediately after their `read_r1`/`spi_xfer` call, both reloads happen
from memory (not a register) after the intervening calls, addresses
consistent (`spi_tmp` sits right after `sdi_info`, both used
correctly).

Not yet re-confirmed on real hardware -- next step: reflash
`sdcard-test.bin` and report what `SD INIT:` shows now.

**Eighth bench result, and the earlier fix's own follow-on bug:
`STAGE=3 INFO=$FF`.** The `D`-register fix worked -- CMD8's R1 now
correctly reads `$01` for the first time. But the echo-pattern check
(stage 3) failed with `$FF`, and this pointed straight back at the
trailing-clock addition from a few results ago: that clock runs
*inside* `read_r1`, so for CMD0 (nothing follows R1) it was harmless,
but for CMD8 -- whose R1 is immediately followed by 4 more R7 payload
bytes -- it silently consumed what should have been R7 byte 1, shifting
every subsequent read by one and leaving the echo-byte check reading
past the end of the real response (`$FF` = nothing left to clock out).

Since the trailing clock was based on a diagnosis (inter-command
settling time) that turned out to be wrong -- the real CMD8 bug was
always the `D`-register clobber, fixed separately -- **removed the
trailing clock from `read_r1` entirely**, restoring it to clock exactly
one byte per response with no side effects on whatever follows.
Re-verified via disassembly: `read_r1` is back to its original,
byte-aligned shape (`push bc`/loop/`pop bc`/`ret`, no extra `spi_xfer`
call).

Not yet re-confirmed on real hardware -- next step: reflash
`sdcard-test.bin` and report what `SD INIT:` shows now. Per the wiring
doc's warning, `TEST_SECTOR` (default 5000) will be overwritten -- use
a scratch or blank card.

**Ninth bench result, and confirmation the settling clock really is
needed: `STAGE=2 INFO=$C1`.** Removing the trailing clock fixed CMD8's
own echo-byte alignment (previous result), but broke CMD8's R1 again
-- `$C1` isn't even a syntactically valid R1 (bit 7 must always be 0
per spec). So the settling clock genuinely does something real between
CMD0 and CMD8; the earlier implementation's mistake was only *where*
it ran (inside `read_r1`, overlapping the very payload it should have
waited for).

**Redesigned properly**: added a dedicated `sd_settle` routine (clocks
one settling byte, preserves `A` and all flags via `PUSH`/`POP AF`)
and call it once per command, right before that command's own
`sd_cs_deassert` -- i.e. after its *entire* response including any
payload has already been read, never overlapping payload bytes
regardless of how many a given command has. Inserted before all 12
`sd_cs_deassert` call sites mechanically, then checked every single
one by hand for what it actually needs to survive the call:

- Flag-only dependencies (CMD0's `CP $01`, the `ACMD41` ready-check,
  every carry-flag check in the round-trip/sector0 code) are all safe
  -- `sd_settle`'s `PUSH AF`/`POP AF` preserves the *entire* F
  register, carry included, not just Z.
- Memory-stashed values (`spi_tmp`, `sdi_info`) are all safe --
  `sd_settle` doesn't touch RAM other than `porta_shadow`.
- **Found one real bug this same insertion introduced**: CMD8's echo
  byte was held in `E` (`LD E,A`) with nothing between setting and
  using it -- safe on its own, but `sd_settle` now sits in that gap,
  and it calls `spi_xfer` internally, which clobbers `D`/`E`
  unconditionally, same as every other instance of this bug class this
  phase. Fixed by adding a second scratch byte, `spi_tmp2`, and stashing
  the echo byte there instead of in `E`.

Re-verified via disassembly, tracing the entire `sd_init` routine start
to finish this time (not just the changed spots): every `sd_settle`/
`sd_cs_deassert` pair, every stage's branch target, every memory
address (`porta_shadow`, `sdi_stage`, `sdi_info`, `spi_tmp`,
`spi_tmp2`) referenced consistently everywhere it's used. All correct.

Not yet re-confirmed on real hardware -- next step: reflash
`sdcard-test.bin` and report what `SD INIT:` shows now.

**Tenth bench result: full success. `SD INIT: OK`, `ROUNDTRIP: PASS`,
and a real `MBR[0..15]=` hex dump on screen.** Phase 11 is closed out
-- all three of `sdcard-test.asm`'s checks (init through `CMD58`,
on-device write/read-back self-test, and a read-only sector-0 dump for
external cross-checking against a PC) confirmed on real hardware.

Four distinct bugs were found and fixed to get here, all in software,
none in the hardware itself despite an extensive early detour through
pull-ups, level-shifter theories, card swaps, and wiring re-checks --
see `cpm-plan.md`'s Phase 11 entry for the summary list, this log's
entries above for the full blow-by-blow. Worth restating the
throughline: every one of the four was a *deterministic* bug (wrong
regardless of what the real hardware was doing), and the diagnostic
tests built along the way (`spi-loopback-test.asm`, `portc-probe-
test.asm`, `porta-write-portc-read-test.asm`) each correctly proved
their own narrow claim (the driver's bit-level correctness, the 8255's
raw read path, the write-then-read interaction) even while the overall
SD test kept failing for unrelated reasons further up the stack --
isolating variables one layer at a time is what eventually cut through
it, rather than any single insight.

Phase 12 (CP/M 2.2 port) is next per `cpm-plan.md`, whenever ready to
start it.

**External cross-check confirmed**: the on-screen `MBR[0..15]=` hex
dump matches a `dd` read of the same card's first sector taken
independently from a PC. This was the one piece the on-device
`ROUNDTRIP: PASS` self-test couldn't cover by itself (it only proves
write and read are *consistent with each other*, not that either one
matches externally-known-good data) -- with this, both the write path
and the read path are now verified against ground truth, not just
against each other. Phase 11 is done.

## Phase 12: CP/M port started (2026-09-07)

**CCP+BDOS sourced and address-verified.** Vendored Clark Calkins'
"reconstructed from memory" CP/M 2.2 source
(`firmware/z80-boot-rom/cpm/cpm22.asm`, via
[Z80-Retro/cpm-2.2](https://github.com/Z80-Retro/cpm-2.2), rights basis
documented in the file's own header) with `MEM EQU 64` set. Confirmed
via `z80asm` that this file assembles with this project's toolchain
exactly as-is -- the only errors before supplying `MEM` and a BIOS are
the two *expected* classes (undefined `MEM`, unresolved BIOS labels),
no dialect issues. One real syntax quirk found and worked around along
the way: `z80asm` rejected a colon-less `MEM EQU 64` outright
("command or comment expected") even though nothing in its own man page
says a label needs a trailing colon -- adding one (`MEM: EQU 64`) fixed
it immediately; every other label in this file already happened to use
one, so this had never been exercised before.

Built a throwaway stub-BIOS (17 `RET`-vectors) smoke test to verify
`MEM=64` actually produces the addresses this plan committed to,
empirically rather than by formula alone: `z80asm`'s own label-file
output confirms `CBASE` (CCP) `= $E400`, `FBASE` (the real BDOS entry
point `CALL 5` gets pointed at) `= $EC06`, and the BIOS vector table
`= $FA00` -- an exact match on all three, and matching the real,
working Z80 Retro! system's own proven `CPM_BASE+0x1600` formula for
this exact source+`MEM` combination.

**Console driver (`CONST`/`CONIN`/`CONOUT`) designed, built, and
disassembly-verified** as a standalone test
(`test-progs/console-io-test.asm`) -- see `cpm-plan.md`'s Phase 12
entry for the full design (streaming `CONOUT` with cursor tracking,
wrap, and scroll via `LDIR`; debounced matrix-scan `CONST`/`CONIN`
with a depth-1 pending-character buffer so peek and consume have
correct, separate contracts; `CTRL`-to-control-code transform; `SHIFT`
deliberately not yet implemented). Caught and fixed one real bug via
disassembly before it ever reached a bench: the column-finding bit-scan
returned with whatever flags `SRL` happened to leave rather than an
explicit "found" signal, which -- unlike in the older
`keyboard-scan-test.asm`, which never branched on it -- silently
misreported "no key" whenever the found column was the matrix's last
one (column 7), since the shifted accumulator is always exactly 0 in
that specific case. Fixed with an explicit `OR 1` before returning.
Full disassembly re-verification after the fix confirmed all downstream
addresses shifted consistently and every branch target still resolves
correctly.

Not yet bench-tested -- next step: flash `console-io-test.bin`, type on
the real keyboard, and confirm echo, wrapping, scrolling, backspace,
and `CTRL-C` all behave correctly.

**Bench result: letters echo correctly.** User didn't test scrolling
or `CTRL-C` specifically but confirmed it's working well enough to
move on. Separately noted Enter doesn't visually drop to a new line --
this is correct CP/M behavior, not a bug: `CR` and `LF` are genuinely
separate characters in the DR model, and real CCP always sends both
together for an actual newline (it does its own line-ending after
reading a command; `CONOUT` pairing them itself would be wrong). This
test's dumb echo loop just doesn't do that pairing, since it isn't CCP
-- nothing to fix here.

**CBIOS disk driver built and disassembly-verified**
(`test-progs/cbios-disk-test.asm`) -- see `cpm-plan.md` section 7 for
the full design (`SELDSK`/`SETTRK`/`SETSEC`/`SETDMA`/`READ`/`WRITE`/
`HOME`/`SECTRAN` on top of Phase 11's proven SD driver, reused
verbatim; `compute_lba_and_offset` maps CP/M's 128-byte logical
sectors onto the SD card's 512-byte physical blocks via a one-block
read cache and full read-modify-write on every `WRITE`). Verified two
ways: full disassembly trace of every branch (`SELDSK`'s drive-0/
drive-1 split, the cache hit/miss merge points in both `READ` and
`WRITE`, the RMW sequence, `compute_lba_and_offset`'s 26x multiply via
shift-add), and a direct dump of the assembled binary's DPH/DPB tables
and quarter-offset lookup table against the values `cpm-plan.md`
already specifies -- both matched exactly (`SPT=26 BSH=3 BLM=7 EXM=0
DSM=242 DRM=63 AL0=$C0 AL1=$00 CKS=16 OFF=2`, offsets `0,128,256,384`).

Test exercises `SELDSK(0)` (expect a real DPH), `SELDSK(1)` (expect 0
-- only drive A exists so far), then a full write/read-back round trip
through `SETTRK`/`SETSEC`/`SETDMA`/`WRITE`/`READ` at
`(track=2,sector=0)`, comparing on-device -- the same round-trip
philosophy Phase 11 already proved out, now exercised through the full
translation+cache+RMW pipeline rather than talking to the SD driver
directly. Built clean, 4635 bytes.

Not yet bench-tested -- next step: flash `cbios-disk-test.bin` and
report what `SELDSK`/`ROUNDTRIP` show.

**Bench result: `SD INIT: OK`, both `SELDSK` checks pass, but
`ROUNDTRIP: FAIL`.** Since `WRITE` and `READ` both reported success (A=0)
and only the final comparison failed, the bug had to be in code the
proven SD driver never touches -- `WRITE`/`READ` themselves already
correctly use `LD BC,128` for their own copies, so a passing WRITE/READ
with a failing compare pointed straight at `fill_test_pattern`/
`compare_buffers`, not the driver.

**Found it**: both used `LD B,0` -- the standard DJNZ idiom for 256
iterations, correct for Phase 11's 512-byte (2x256) buffers, but
`disk_wbuf`/`disk_rbuf` here are only 128 bytes each. `fill_test_
pattern`'s overflow spilled harmlessly into `disk_rbuf`'s own space
(later legitimately overwritten by `READ`), but `compare_buffers`'
overflow compared `disk_wbuf[128..255]` (really `disk_rbuf`'s space)
against `disk_rbuf[128..255]` (whatever memory comes right after
`disk_rbuf` -- `write_msg`'s own code), which will essentially never
match -- causing a reported FAIL regardless of whether the real,
meaningful 128 bytes round-tripped correctly. Fixed: both now use
`LD B,128`. Re-verified via disassembly: both loops run exactly 128
iterations, and `disk_rbuf`'s address is confirmed to be exactly
`disk_wbuf`+128, consistent with the declared buffer sizes.

Not yet re-confirmed on real hardware -- next step: reflash
`cbios-disk-test.bin` and report what `ROUNDTRIP` shows now.

**Confirmed: `ROUNDTRIP: PASS`.** The CBIOS disk driver
(`SELDSK`/`SETTRK`/`SETSEC`/`SETDMA`/`READ`/`WRITE`/`HOME`/`SECTRAN`,
the 128-byte/512-byte translation, and the one-block read cache with
full read-modify-write on `WRITE`) is now bench-confirmed working end
to end on real hardware. Phase 12's disk side is done.

## Course correction: `MEM=64` doesn't leave enough room for this BIOS

Before combining the console and disk drivers into one real BIOS,
sized up how much room the `$FA00`-`$FFFF` (`MEM=64`) BIOS region
actually has: 1536 bytes. Counted the real driver code already built
and bench-confirmed (`console-io-test.asm`'s `CONST`/`CONIN`/`CONOUT`
logic, `cbios-disk-test.asm`'s full disk driver + DPB/DPH tables +
SD SPI driver) -- correctly *excluding* the 2048-byte font, which was
always going to live in the bank=1-only `$8000`-`$BFFF` region per
this plan's own section 2, not in the BIOS region at all -- and came
to a bit under 1800 bytes. More than 1536.

Two ways to fix this: also relocate disk-driver data (the 512-byte
sector cache, the DPB/DPH/CSV/ALV tables) into the bank=1 region
alongside the font, which would work but adds a second bank-flip-
discipline surface (the same "no `PUSH`/`POP` pair may straddle a bank
flip" rule section 3 already holds `CONOUT` to) for no real benefit;
or give the BIOS region more room in the first place by choosing a
smaller `MEM`. Took the second, simpler path: reverted `MEM` from 64
to 62 -- this vendored source's *own* original, author-tested default
("for a 62k system, TS802 TEST -- WORKS OK"), not an arbitrary new
pick. Re-verified the same way as before (a throwaway stub-BIOS smoke
test, `z80asm`'s own label-file output): `CBASE`(CCP)`=$DC00`,
`FBASE`(BDOS entry)`=$E406`, `BOOT`(BIOS vector table)`=$F200` --
leaving 3584 bytes for BIOS, comfortably covering the ~1800-byte need
with real margin.

**Every address this plan and this log previously stated as
`$E400`/`$EC06`/`$FA00` is now `$DC00`/`$E406`/`$F200`** --
`cpm-plan.md` updated throughout, including the verification section
that previously (correctly, at the time) celebrated the `$E400`/
`$EC06`/`$FA00` match as exact. Also caught and fixed a naming
mismatch while touching this: `cpm-plan.md` had been calling one BIOS
entry `LISTST` (a name DR's generic BIOS documentation elsewhere uses
for the same slot), but this exact vendored source calls it `PRSTAT` --
confirmed directly from `cpm22.asm`'s own unresolved-reference list
when assembled standalone. Updated to match what the code actually
calls.

No firmware behavior changed by this -- `console-io-test.asm` and
`cbios-disk-test.asm` are both self-contained standalone tests with
their own `org 0` layout, referencing none of these addresses
directly, so both remain valid and bench-confirmed as-is. This only
affects how they'll be combined into the real, integrated BIOS next.

## Integrated BIOS built: `firmware/z80-boot-rom/cpm/bios.asm`

Combined `console-io-test.asm`'s console driver and `cbios-disk-
test.asm`'s disk driver with `cpm22.asm` into one real file, assembled
together via a new `cpm/Makefile`. Address layout fully verified via
`z80asm`'s label output: `BOOT`=`$F200` through `end`=`$FA78` (2168 of
the 3584 bytes `MEM=62` leaves used, comfortable margin to spare).

**Real constraint the standalone tests never had to face**: `CONOUT`'s
character blit touches video RAM, which only exists under `bank=1` --
but the entire BIOS region (`$F200`+) is itself inside the bank-
switched address range. Any code that must keep executing correctly
*while* `bank=1` is briefly active cannot live there -- the instant
the bank flips, that address range resolves to different physical
bytes entirely, and the CPU would immediately execute garbage. Same
for any data that must survive the flip (`porta_shadow`, since
flipping the bank bit at all means reading and rewriting it; `cur_row`/
`cur_col`, needed to compute where to blit). Traced this out fully
before writing anything, including confirming `write_msg` itself (not
just a thin wrapper around it) needed to be wherever this logic lived,
since its own instructions must also keep fetching correctly through
the flip.

First draft put the entire blit/scroll logic in low memory (~185
bytes: two flip helpers, `video_blit`/`video_scroll`, and a relocated
`write_msg`). **User suggested a real improvement mid-build**: since
`bank=1` is already what's wanted active during the blit/scroll
anyway, the actual CODE can live in the bank=1-only region too --
right after the font -- with low memory holding only a tiny flip-and-
`JP` stub per operation. Reworked to this: `video_blit`/`video_scroll`
(low memory, ~13 bytes each) set up parameters, flip the bank bit, and
`JP` (not `CALL`) into `video_blit_impl`/`video_scroll_impl` (bank=1-
resident, living right after the font at `$8800` onward), which do the
real work and themselves flip back to `bank=0` before `RET`urning
straight to `CONOUT`'s original caller. Safe because the only stack
activity throughout is the original `CALL`-into-the-stub's own return
address, pushed before the flip and popped only after flipping back --
never straddling it, satisfying section 3's own push/pop discipline
rule. Cuts the low-memory (TPA-exposed) footprint from ~185 bytes to
~30.

Re-verified via disassembly after the rework: `video_blit_impl` lands
at exactly `$8800` (immediately after the 2048-byte font, which is now
directly `incbin`'d into this same file for verification purposes,
copied into `cpm/msxfont.img`), `video_scroll_impl` immediately after
it at `$8873`, both confirmed by extracting the right byte ranges from
the assembled binary and disassembling with the correct origin (the
file itself is compact/non-contiguous across `org` jumps, so a plain
`z80dasm -g0x7c00` over the whole file mislabels addresses past the
first `org` boundary -- not a bug, just a disassembly-tool quirk with
gapless multi-org files, worth remembering next time). Both routines'
bank-flip-back-then-`RET` endings confirmed correct.

**Not yet runnable on real hardware** -- `bios.asm` has no way to be
loaded and executed standalone the way every test-progs/*.asm file
does; it needs the stage-1 bootstrap (not started) to load its three
separate chunks (low-memory trampoline, the combined bank=1 font+
blit-code region, and the main CCP+BDOS+BIOS block, each under the
right bank setting) and jump to `BOOT`. That, plus building the actual
CP/M disk image (system tracks + Zork), are what's left of Phase 12.

## Low-memory trampoline refined (user's suggestion) + DPB `OFF` revised

**User suggested a real improvement** to the bank-flip design mid-
build: since `bank=1` is already what's wanted active during the blit/
scroll anyway, the actual blit/scroll CODE can live in the bank=1-only
region too (right after the font), with low memory holding only a
tiny flip-and-`JP` stub per operation. Reworked `bios.asm` accordingly
-- `video_blit`/`video_scroll` (low memory, ~13 bytes each) set up
parameters, flip the bank bit, and `JP` (not `CALL`) into
`video_blit_impl`/`video_scroll_impl` (bank=1-resident, at `$8800`
onward, right after the font), which do the real work and flip back to
`bank=0` before `RET`urning straight to `CONOUT`'s original caller --
safe under section 3's push/pop discipline since the only stack
activity is the original `CALL`-into-the-stub's own return address,
pushed before the flip and popped only after flipping back. Cuts the
low-memory (TPA-exposed) footprint from ~185 bytes to ~30. Re-verified
via disassembly after the rework: `video_blit_impl` at exactly `$8800`
(immediately after the font), `video_scroll_impl` immediately after it.

**Sizing up the actual chunks needed for the stage-1 bootstrap surfaced
a real DPB problem**: the reserved boot area (`OFF=2` tracks = 6656
bytes) isn't big enough for the ~10035 bytes the three chunks (low-
memory trampoline + font/blit-code + CCP/BDOS/BIOS) actually need.
Revised `OFF` from 2 to 5 (16640 bytes reserved, comfortable margin) --
checked before adopting it, not assumed: divides evenly into `DSM`
with no fractional remainder (234.0 exactly, cleaner than `OFF=2`'s own
243.75, by coincidence not design). `DSM` recomputed to 233, `ALV`
size recomputed to 30 (was 31). `cpm-plan.md` section 7 and `bios.asm`'s
own DPB both updated with the full reasoning.

## Stage-1 bootstrap written and verified: `stage1.asm`

Loads three fixed, block-aligned chunks from raw SD blocks (not
through the CP/M DPB/`SELDSK` mechanism -- no filesystem concept
exists yet at this point) into their correct destinations under the
right bank setting each needs, then flips to SRAM-exec (permanent) and
jumps to `BOOT` (`$F200`):

- Chunk 1 (LBA 0, 1 block): low-memory trampoline -> `$7C00`, bank=0.
- Chunk 2 (LBA 1, 5 blocks): font + blit/scroll code -> `$8000`, bank=1.
- Chunk 3 (LBA 6, 16 blocks): CCP+BDOS+BIOS -> `$DC00`, bank=0.

Reuses Phase 11's SD SPI driver verbatim. Follows the same "copy self
to SRAM before flipping mode_pin" idiom every other test-progs/*.asm
file already uses, and deliberately does NOT try to skip it as an
"unnecessary" optimization -- traced through why it's still required
even for a program that only needs one more instruction after the
flip: that one instruction still has to be *fetched*, and once
`mode_pin=1`, fetches come from real SRAM at whatever address the
program counter happens to be, not from the AVR's ROM emulation
regardless of intent. Skipping the copy would have been a real, subtle
bug, not a valid simplification. Built clean, 733 bytes -- comfortably
inside the 8K ROM-emulation window. Verified via disassembly: the full
chunk-loading sequence (`load_blocks`'s `EX DE,HL` juggling between
`build_rw_cmd`'s need for `HL=LBA` and the destination pointer needing
`HL=dest` for `read_block`'s own advancing contract), every bank-bit
set/clear between chunks, and the final flip-and-jump to `BOOT`, all
traced and confirmed correct.

## Image-building script + full one-shot build

Added `build-boot-image.py`: extracts the three chunks from the
assembled `bios.bin` and assembles them into one block-aligned raw
image (`boot.img`, 22 blocks/11264 bytes) ready to `dd` onto an SD
card at LBA 0. Reads the chunk boundaries out of `bios.sym` (two new
zero-cost marker labels, `trampoline_end` and `bank1_end`, added
specifically so this script doesn't have to assume or empirically
re-derive them) rather than hardcoding addresses, so it stays correct
if `bios.asm`'s layout shifts -- though the block *counts* it pads to
still have to matched by hand against `stage1.asm`'s own
`CHUNK*_BLOCKS` constants, documented clearly in both files.

Worked out the exact file-layout model behind this from first
principles, verified empirically rather than assumed: `z80asm` does
NOT auto-fill the byte gap when an `org` jumps forward unless an
explicit `ds` follows it -- confirmed by checking that the font's own
bytes land in `bios.bin` exactly 42 bytes in (matching the low-memory
trampoline's real size, with *no* padding cost for the logical
`$7c2a`-`$8000` gap between the low-memory and bank=1 `org` sections),
while the bank=1-region-to-`CPM_BASE` gap, which `bios.asm` pads
explicitly via `ds CPM_BASE-$,0`, *does* consume real file bytes
matching its full logical size. Verified the final extracted chunks
directly: `chunk3`'s first 3 bytes are a valid `JP` instruction sitting
exactly at `CBASE`, `chunk1`'s bytes match `video_blit`'s real
instructions, `chunk2` matches `msxfont.img` byte-for-byte.

`cpm/Makefile`'s `all` target now runs the whole pipeline
(`bios.bin` -> `bios.sym` -> `boot.img`, plus `stage1.bin`) in one
`make` invocation.

**Not yet tested on real hardware.** Next step: upload `stage1.bin` via
xmodem in place of a normal test-progs ROM image, write `boot.img` to
the SD card at LBA 0 (`dd if=cpm/boot.img of=<device> bs=512 seek=0
conv=notrunc`), then "start rom emulation" as usual and see what
happens. **Worth flagging explicitly**: `cbios-disk-test.asm`'s own
round-trip test writes to `(track=2, sector=0)`, which computes to
LBA 13 -- squarely inside the new boot image's own LBA 0-21 footprint.
Re-running that test's destructive write on the same card after
writing `boot.img` would corrupt part of the loaded CCP+BDOS+BIOS
chunk; use a different card, or a `TEST_TRACK`/`TEST_SECTOR` outside
LBA 0-21, if the disk driver needs re-checking after this point.

**First real hardware attempt: no screen output at all.** Real, design-
level bug found on review: `stage1.asm` never read the magic address
(`$3FFF`) anywhere -- every single test-progs/*.asm file does this to
tell the AVR "stop emulating ROM, switch to video generation," and it
got missed designing the new multi-chunk loader. Without it, the AVR
just stays in its ROM-emulation polling loop forever -- which explains
the exact symptom precisely: that loop still releases `_WAIT` on every
read regardless of what's being read, so the Z80 side likely keeps
running fine, it's specifically video that never starts. Added the
read to `BOOT` (`bios.asm`) as system-initialization's job, not the
bootstrap's -- re-verified `BOOT` still lands at `$F200`.

**Second attempt, same result.** This means execution likely isn't
even reaching `BOOT` -- something in `stage1.asm` itself (SD init, one
of the three chunk loads) is failing first, and `stage1.asm` had no
way to show anything before jumping away, with every failure path
silently halting. Added a diagnostic-only visual progress indicator
directly to `stage1.asm`, since it can't use real `CONOUT` (no font/
BIOS loaded yet at that point): `show_progress` flips to bank=1, clears
the whole screen, fills the top `(checkpoint/6)` of it white, flips
back -- called at 5 points (after the magic-address trigger; after
each of the 3 chunk loads; right before the final jump to `BOOT`).
Moved the magic-address read earlier (right into `stage1.asm` itself,
before `sd_init`) specifically so this diagnostic can show anything at
all -- confirmed the AVR's magic-address detection doesn't depend on
`mode_pin`, only on the specific address being read, so this is safe
to do before the real mode-flip. Whichever checkpoint the screen gets
stuck at (a static top fraction white, screen going fully white and
staying there, or nothing at all) pins down which stage failed.
Verified via disassembly: the checkpoint-size lookup table, the fill/
clear loops, and every call site's stage number all confirmed correct.

Built clean (834 bytes). Not yet re-tested on real hardware -- next
step: re-upload the new `stage1.bin` (changed; `boot.img` did not) and
report what fraction of the screen turns white, if any.

**Third report: "screen is all black."** Not even checkpoint 1 (the
first `show_progress` call, right after the early magic-address read)
rendered. Two extra data points from the user pinned this down fast:
video sync WAS present (the AVR genuinely left ROM-emulation and
entered video generation), and the AVR's own serial monitor printed
its `"magic address served -- exiting ROM emulation, WAIT disabled
permanently"` message -- so the magic-address trigger itself
definitely worked. The bug had to be in what happened to the Z80
*immediately after* that read, while `mode_pin` was still 0.

Read `rom_emu.c`'s `rom_emu_run()` in full to check, rather than
assume. Its own comments spell out exactly why this breaks: serving
the magic-address read is a **one-way trip** -- once served, the AVR
drives `wait_rel` low and *leaves it there permanently* (not a pulse,
unlike every normal ROM read), because nothing is left running on the
AVR side to service any *future* ROM-emulation read once this function
returns, and `_WAIT`'s own D input has no `mode_pin` gating, so leaving
`wait_rel` high would otherwise deadlock the very next fetch. The
user immediately spotted the real implication before I'd finished
tracing it through: **you have to be in SRAM mode before flipping the
magic address.** With `mode_pin` still 0 at the moment of that read (as
the previous "diagnostic" version of `stage1.asm` did it, specifically
to get video up before SD loading), every subsequent instruction fetch
is still nominally routed through the 373 (mode_pin=0 = "read from
rom"), but nothing is left driving it and `_WAIT` can no longer stall
to cover for that -- the Z80 free-runs on a dead/floating bus. That's
exactly consistent with everything observed: the trigger fires, video
genuinely starts, and then the Z80 executes garbage and never reaches
`show_progress`'s real code, hence a black screen.

**Fix**: reordered `stage1.asm` so the mode-flip (`mode_pin=1`) and the
magic-address read happen together, once, immediately after the
copy-self-to-SRAM step -- before `sd_init` and all three chunk loads,
not after. This matches the same pattern every prior test-progs/*.asm
file already used (flip mode, then read `$3FFF`, then keep running);
the only difference here is that "keep running" now includes the SD
loading logic instead of being the end of the program. Bank-switching
for the chunk destinations, and the SD driver itself, are unaffected --
both are IO-based (8255 accesses) and don't depend on `mode_pin` at
all, and writes always go to SRAM regardless of `mode_pin`, so nothing
about the loading logic itself needed to change. Removed the now-
redundant magic-address read from `bios.asm`'s `boot_init` (added in
the first fix attempt above) -- `stage1.asm` now does this exactly
once, safely, before `BOOT` is ever reached; a second read there would
just be a harmless plain SRAM read, not a second real trigger, so
removed for clarity rather than left as confusing dead logic.

Verified via disassembly of the rebuilt `stage1.bin`: `OR 001h` (set
mode_pin) at `$0020`, immediately followed by `LD A,($3FFF)` at
`$002a`, immediately followed by `CALL sd_init` at `$0032` -- the
required order. Built clean. Not yet re-tested on real hardware.

**Root cause found by the user, not by me — a real read-while-in-ROM-
mode hazard.** Reviewing `stage1.asm`'s mode-flip block directly, the
user spotted: `LD A,(porta_shadow)` immediately before `OR $01`/setting
`mode_pin` executes *while `mode_pin` is still 0* -- meaning that read
is serviced by the AVR's ROM-emulation path (the byte statically
present in the uploaded image at that file offset), not by the `$04`
this same code had just written into real SRAM a few instructions
earlier. Writes always land in SRAM regardless of `mode_pin` (per the
base hardware design), but *reads* don't reflect that until `mode_pin`
actually flips -- so this read-modify-write pattern was building its
`OR`'d result on top of stale/wrong data, not the real accumulated
port state, for this one specific transition. In hindsight this is
exactly the pattern the already-working reference tests avoid:
`cbios-disk-test.asm`'s `SHADOW_INIT` and `video-test3.asm`'s mode+bank
write are both plain literals for this specific transition, never a
read-modify-write -- neither test had ever needed a `LD A,(porta_
shadow)` before `mode_pin` was already 1.

Fixed by replacing the read-modify-write with a literal (`LD A,$05` --
the previously-written `$04` with `mode_pin`'s bit set), removing the
hazard entirely rather than reasoning about what the stale value
happens to combine to. No other `porta_shadow` read in `stage1.asm`
has this problem -- checked every occurrence; all the others execute
after this literal write, once `mode_pin` is genuinely 1.

Also isolated two earlier, now-superseded diagnostic steps while
chasing this: (1) a minimal, straight-line (`no CALL/RET/loop`) write
of `$FF` to `$C000` right after the mode-flip, to rule out
`show_progress`'s own `CALL`/loop/`PUSH`/`POP` logic as a variable --
still showed nothing, ruling those out; (2) reordering that write to
happen *before* the magic-address read (matching `video-test3.asm`'s
and `cbios-disk-test.asm`'s proven structure exactly) -- both changes
are still in `stage1.asm` as of this fix, kept since they match the
proven-working pattern and don't hurt. Along the way, confirmed via
`video-test3.bin` (an old, already-working binary, re-uploaded and
tested directly) that the video/magic-address/bank-switch mechanism
itself is completely sound on the current hardware -- correctly
narrowing the search to `stage1.asm`'s own code rather than a hardware
regression. Built clean (856 bytes). Not yet re-tested on real
hardware.

**User found and fixed two more real bugs directly on the bench** while
continuing to iterate on `stage1.asm`: (1) `show_progress`'s `sp_clear`
loop had `XOR A` *before* the loop instead of inside it -- `LD A,B` /
`OR C` (the loop's own counter test) clobbers `A` every iteration, so
every byte after the first was writing whatever that comparison left
in `A`, not 0. Fixed by moving `XOR A` inside the loop body. (2)
`load_blocks`, even after the earlier `push`/`pop hl`/`de` fix, still
lost track of the LBA partway through any multi-block chunk -- result:
chunks 2/3 (5 and 16 blocks) showed progress then went unstable
("maybe 4 or 5 chunks flicker before the screen just goes black"),
while chunk 1 (1 block, no second iteration ever needed) was fine.

Root cause, found while reviewing the user's fix: `spi_xfer` (`LD
E,A` / `LD D,8`) unconditionally clobbers `D`/`E` as its own scratch
registers, and it runs -- via `send_cmd`/`read_r1`/`read_block`/
`sd_settle` -- at *every* stage of `load_blocks`'s loop body,
including *after* the `pop de` that had just restored `DE`=LBA for the
`EX DE,HL` before `read_block`. By the time `INC DE` ran at
`lb_read_ok`, `DE` was whatever `spi_xfer`'s last bit-loop left behind,
not the real LBA -- so every LBA after the first in a multi-block
chunk was wrong, silently loading the wrong 512-byte sectors into
`$8000`/`$DC00`.

Fixed by moving all of `load_blocks`'s working state (destination
pointer, current LBA, remaining block count) into memory
(`lb_dest`/`lb_lba`/`lb_count`) instead of trying to keep it alive in
registers across calls -- sidesteps needing to know (or keep
re-verifying) exactly which registers each callee happens to preserve,
rather than patching each individual clobber as it's found. Verified
via a targeted disassembly of the rebuilt `load_blocks` (extracted to
its own blob and disassembled from its real origin, since the
preceding data table throws off z80dasm's linear byte alignment):
confirmed dest/LBA/count are stored to memory at entry, LBA is
reloaded from memory before every `build_rw_cmd`, dest is reloaded
before and re-saved after every `read_block`, and LBA/count are
reloaded, updated, and re-saved at the loop tail -- no register
assumed to survive any call. Built clean (890 bytes). Not yet
re-tested on real hardware.

**Re-tested after the `load_blocks` fix -- same symptom persists**
("3 chunks, then sort of maybe 4 or 5 chunks that flicker and then
goes to black screen"). Reconsidered: the "flicker" between checkpoints
is plausibly just this diagnostic's own clear-then-fill visual (every
`show_progress` call clears to black before filling proportionally
white -- two checkpoints firing close together naturally looks like a
flicker even when nothing is wrong), so the one real signal left is
"ends up black and stays there." That's consistent with checkpoint 6
completing (briefly, as part of the flicker) and something failing
right at or after `JP BOOT_ENTRY` -- pointing at `bios.asm`'s own
`boot_init`, not `stage1.asm`.

Found it there: `boot_init` (and `wboot_init`) opened with the exact
same 8255 control-word initialization every test-progs/*.asm file's
own *first-ever* startup uses (`LD A,$8A` / `OUT ($AB),A`) -- copied
without noticing this specific instance now runs *long after*
`mode_pin` was already established and made permanent by `stage1.asm`.
A mode-set control-word write is documented 8255 behavior to force
*all* of that port's outputs to 0 immediately (the same fact
`gate-equations.md` §2 already relies on for `mode_pin`'s power-up-safe
default) -- including `mode_pin` itself, for the brief window until the
next instructions re-establish it via the plain `OUT ($A8)` a few
lines later. By the time `BOOT_ENTRY` is ever reached, `_WAIT` has
*also* been permanently disabled (the magic-address one-way trip,
triggered back in `stage1.asm`, long before this point) -- so nothing
stalls the Z80 if even one instruction fetch during that glitch window
lands on the now-completely-dead 373 path instead of real SRAM. A
crash right as `BOOT_ENTRY` is reached, not a theoretical risk.

Fixed by removing the control-word rewrite from both `boot_init` and
`wboot_init` -- the 8255 was already configured once, by `stage1.asm`,
before `mode_pin` ever mattered, and never needs reconfiguring again.
The plain `OUT ($A8)` write right after (setting the shadow to
`SHADOW_BASELINE`) is unaffected and still needed -- a data-port write
has no "reset everything" side effect, unlike the control register.
Checked the rest of `bios.asm` for the same `$AB`/`$8A` pattern --
this was the only occurrence (now two, both removed). Rebuilt clean
end to end (`make clean && make`): `chunk3` shrank from 7799 to 7791
bytes (exactly the 8 bytes removed, 4 per site), `BOOT` still verified
at `$F200`. Not yet re-tested on real hardware.

**Root cause found: CCPSTACK lands inside the bank=1-mapped video RAM
range.** Bisected methodically after the directory-format theory
produced zero change: disabled `CONST` (no change), hung `CONIN`
forever (no change -- ruling out cpm22.asm's own BDOS disk-error retry
path, which calls `CONIN` via `GETCHAR`, as a red herring), then tested
whether `bios.asm` was even reached at all by having `stage1.asm` halt
right after checkpoint 6 instead of jumping to `BOOT_ENTRY` -- this
produced a completely different, clean result (normal checkpoint
progression, no bar, no flicker), proving `bios.asm`'s code *does* run
and *is* responsible. Then isolated an unconditional `video_blit` call
(drawing "TEST") immediately after `boot_init`'s state setup, halting
right after it so nothing later could overwrite the result -- and the
exact same "8-10 row white bar + flickering pixels" reappeared, with
the Z80 provably frozen afterward in a trivial infinite loop. Since
nothing was executing, the corruption had to already be sitting in
video RAM by the time `video_blit` finished running.

Checked `CCPSTACK` (`cpm22.asm`'s own conventional CCP-stack location,
`EQU $` at the tail end of the CCP source) against the real assembled
address: `$E3AB`. That's squarely inside `$C000-$FFFF` -- the range
that maps to **real, live video RAM** whenever `bank=1` is set.
`video_blit_impl` runs entirely with `bank=1` active and does its own
internal `PUSH HL`/`PUSH IX`/`POP IX`/`POP HL` to save registers across
its glyph-blit logic -- every one of those pushes writes the saved
register pair directly into the video buffer at CCPSTACK's offset
(computed: `(0xE3AB-0xC000)/80 ≈ row 114 of 200`, roughly 57% down the
screen -- close enough to "2/3 or more down" given rough visual
estimation, and a good match for the observed flicker's position).

This is a real gap in the original design reasoning
(`cpm-plan.md` §3, this file's own header comment): the stated
discipline -- "any push/pop pair that executes while bank=1 is set must
complete entirely before flipping back to bank=0" -- correctly protects
the *return address* pushed by the original `CALL video_blit` (that
push happens under bank=0, before the trampoline ever flips, and is
popped under bank=0 too, after `vbi_exit` flips back) but never
considered a *different* hazard: even a fully self-consistent internal
push/pop pair, if it executes while bank=1 and the stack pointer's
numeric value happens to fall in `$C000-$FFFF`, still corrupts live
video RAM content on every push, regardless of whether the pair itself
is balanced. `CCPSTACK` living in conventional high memory (deliberately
kept there per that same design discussion, precisely to avoid a
different, then-considered risk) turned out to be exactly such a
value -- nobody had checked its actual assembled address against the
video-RAM range until now.

Fixed by giving `video_blit_impl` its own small (16-byte), dedicated,
low-memory (bank-invariant) scratch stack: the `video_blit` trampoline
now saves the real (CCPSTACK-based) `SP` to `blit_saved_sp` and
switches to `blit_scratch_top` before flipping to bank=1 and jumping
in; `vbi_exit` restores the real `SP` from `blit_saved_sp` *after*
flipping back to bank=0, so the final `RET` still pops the original
caller's return address from where it actually is. `video_scroll_impl`
was checked too and needs no equivalent fix -- it does no `PUSH`/`POP`
at all internally. Verified the real max nesting depth in
`video_blit_impl` (`PUSH HL` + `PUSH IX`, 2 words) is comfortably
covered by the 16-byte scratch allocation, not just assumed sufficient.

All four temporary diagnostics from this bisection (`CONST` disabled,
`CONIN` hung, the isolated `video_blit`+halt test, `stage1.asm`'s
halt-before-`BOOT_ENTRY`) were reverted once the real cause was found.
Rebuilt clean end to end: `chunk1` (trampoline) grew from 42 to 67
bytes (the scratch-stack switch/restore code + the 18 bytes of new
state), `chunk3` back to its pre-diagnostic 7791 bytes, `BOOT` still
verified at `$F200`. Not yet re-tested on real hardware.

## Phase 12 -- the SD "corruption" was a stale card, not a driver bug

Multi-day hunt, worth recording in full because almost every step of
the reasoning was locally sound and still pointed the wrong way.

**Symptom.** After the CCPSTACK fix above, `stage1.asm` loaded its
three chunks from SD and the machine never reached `BOOT`. Hex dumps
of the loaded chunk1 showed data that was recognisably *close* to
`boot.img` but not equal to it: 5 leading zero bytes where `boot.img`
has 23, and `JP $8873` where the current build has `video_scroll_impl`
at `$8877`.

**What it actually was.** The SD card physically held the *previous*
build's image. The write from the development laptop never reached
the flash. `dd` + `sync` + a readback + `md5sum` all agreed with each
other because both the write and the readback were served from the
Linux page cache; the card underneath was never updated. `iflag=direct`
on the readback did **not** catch it either. What finally proved it was
writing a unique marker (`printf 'ZZTOP' | dd ... seek=0`), confirming
it read back on the laptop, then reading the same physical card **on a
different machine** -- where the marker was absent.

**Why the wrong data looked so plausible.** The discrepancy was exactly
18 bytes, which is precisely what the CCPSTACK fix added to the
trampoline's variable block (`blit_saved_sp` 2 + `blit_scratch` 16).
So the stale image was not corrupt at all -- it was the immediately
previous build, differing only by the most recent change. That made it
look like a byte-drop in the SPI read path rather than an old file, and
it is why reconstructing the pre-fix trampoline and padding it to 512
bytes reproduced the observed checksum (`$0EA0`) exactly.

**Why every experiment mislead.** Because the read path was always
correct, changing SPI timing, inter-byte delays, MISO settling, CS
clock padding, the destination bank/A16, and BUSRQ/video interaction
all produced *no change* -- correctly. Each null result was read as
"not that either", when it was really "the read was never the problem".
Two different cards gave two different wrong values (different vintages
of the image), which was read as flaky hardware. chunk2 always looked
fine because its first bytes are font data, unchanged between builds.

**The lesson that generalises.** A destination that is never written
reads back as whatever the previous session left in SRAM, which on this
machine is highly plausible-looking data. Diagnostics must distinguish
"wrong value" from "no value". Poisoning each destination with `$AA`
immediately before its load settled in one test what days of timing
experiments could not: all three checksums came back as the exact
poison sums (`5400`/`A400`/`4000` for 512/2560/8192 bytes of `$AA`),
proving nothing had been stored at all. Equally: a silent `JP
C,boot_halt` on `sd_init` failure is indistinguishable from broken
display code, and cost real time -- failures were temporarily routed to
an on-screen status byte instead.

**Real bugs found and fixed along the way** (all genuine, none of them
the cause):

- `sd_cs_assert` clobbered `BC` via its `LD BC,4096` busy-wait,
  destroying `sd_init`'s ACMD41 `DJNZ` retry counter. Every other
  routine in the driver preserves `BC`. Now push/popped.
- `read_r1` tested `CP $FF`, which accepts any MSB-set byte as an R1
  response; R1 is *defined* by MSB=0. It also allowed only 8 retries
  when Ncr can legitimately reach 8 byte-times. Now `AND $80` with 240
  retries, matching the SD spec and the 2063-Z80-cpm reference. Note
  our `spi_xfer`, unlike that reference's `spi_read8`, leaves no copy
  of the received byte in `E` (E ends back at the *sent* byte after 8
  `RLC E`), so the byte is held in `C`.
- `wait_token` scanned indefinitely for `$FE`, so it would skip past an
  error token and could latch onto any payload byte equal to `$FE`,
  then store 512 bytes from an arbitrary offset. It now requires the
  first non-`$FF` byte to *be* the token.
- `load_blocks` lost its LBA across iterations: `spi_xfer` uses D/E as
  scratch at every stage, so push/pop of DE around the body is not
  enough. Rewritten to keep dest/LBA/count in memory.
- `sp_clear` and `verify_chunk` each had a `LD A,<const>` hoisted out
  of a loop whose own `LD A,B`/`OR C` clobbers `A` every iteration.

**Result.** With a correctly written card, all three chunks verify:
`1149` / `6DFC` / `9C62`, status clean. The checksum verification has
been kept in the production boot path (a mismatch paints progress bar 2
and halts) specifically so a stale or truncated image announces itself
immediately instead of presenting as an inexplicable downstream crash.
`CHUNK*_CKSUM` must therefore be recomputed from `boot.img` whenever
`bios.asm` changes, or the machine will refuse to boot.

## Phase 12 -- CP/M 2.2 boots; the bank-bit execution rule

**Result: CP/M 2.2 boots to a prompt.** CCP runs, reads the matrix
keyboard, echoes typed input, parses command lines, and returns `?` for
unknown commands. `DIR` reads and parses all 64 directory entries.

### The bug that blocked it: flipping the bank bit from banked code

After the stale-card issue above was resolved and all three chunks
verified, the machine printed exactly **one** character and died. The
symptom was extremely misleading -- one character then silence looks
like a console-driver fault, or like CCP emitting a prompt and blocking
in `CONIN`. Both were investigated first, and both were wrong.

The actual cause: `video_blit_impl` and `video_scroll_impl` flipped
back to bank=0 *themselves*, with the sequence

    OUT  ($A8),A        ; bank bit cleared here
    LD   SP,(blit_saved_sp)
    RET

But those routines live at `$8000-$88xx`, and `$8000-$BFFF` maps to
**different physical memory in each bank** (`A16 = (bank AND A15) OR
busack`, cpm-plan.md section 2). The instant that `OUT` takes effect the
routine ceases to exist; the next instruction fetch comes from whatever
occupies that address in the bank=0 TPA. The character already blitted
correctly, so exactly one character appeared before the Z80 ran off into
garbage.

This was written into `bios.asm`'s own header as a *safe* design, with a
correct-sounding justification about stack discipline across the flip.
The stack reasoning was fine. The instruction-fetch consequence was
simply never considered.

**The rule, now stated in `bios.asm`'s header: any change of the bank
bit must be executed from code below `$8000`.** Fixed by adding
`vbi_return`/`vsi_return`, low-memory stubs that the impls `JP` to while
still bank=1; those stubs do the flip, restore `SP`, and `RET`. The `JP`
is made from bank=1 into bank-invariant memory, so it lands on code that
reads identically in both banks and survives its own flip.

This also retroactively explains the earlier "white bar and flickering
pixels" -- the same routine dying at the same instruction, with
different garbage downstream.

**What actually found it** was the user's suggestion to print each load
stage's name and checksum rather than progress bars. That put stage1's
`write_msg` on screen rendering long strings perfectly *from low
memory*, while the CBIOS managed exactly one character *from the banked
region*. The contrast between two code paths over the same font, doing
the same job from different memory, was the whole answer. Worth
remembering as a technique: when something fails, get a known-good
implementation of the same operation running beside it.

A `CONOUT` test driven directly from `boot_init`, before CCP ever ran,
separated "the driver can only emit one character" from "CCP only asks
for one" -- it printed the same single character, which localised the
fault to the blit path and away from CCP/BDOS entirely. Removed once
console output was trusted.

### cpm22.asm's lowercase prompt

The prompt rendered as `a>`. Not a font or BIOS fault: `cpm22.asm` line
683 does `ADD A,'a'` when printing the current drive, while lines 880
and 1374 use `'A'`. An internal inconsistency in this reconstructed
source; real CP/M 2.2 shows `A>`. Changed to `'A'`.

### Directory formatting

`DIR` initially listed 16 lines of `A:   :   :   :` -- 64 blank entries.
That is 64 = `DRM`+1, i.e. the whole directory was read and parsed
correctly; the area was simply filled with `$00` rather than `$E5`.
CP/M treats `$E5` in an entry's first byte as "never used"; `$00` reads
as user 0 with a blank filename, so every entry looked like a nameless
file.

Worth noting as a positive result: had the `OFF=5` track offset been
applied wrongly, the read would have landed in `boot.img` and shown
garbage filenames. Blank entries proved the addressing was right.

Directory location, derived from the DPB and `compute_lba_and_offset`
rather than by hand: first directory logical sector = `OFF*SPT` = 130,
so LBA 130>>2 = **32, byte offset 256**; size `(DRM+1)*32` = **2048
bytes** (2 x 1K blocks, matching `AL0=$C0`). Absolute bytes
**16640-18687**, which is `OFF*SPT*128` as expected. Note this is *not*
512-byte aligned, so it cannot be written with a whole-block `seek`.

`dirinit.img` (2048 bytes of `$E5`) is generated for this. It is kept
deliberately **separate** from `boot.img` rather than folded into it:
merging them would mean every card rewrite silently re-formatted the
directory and destroyed any files on the disk.

## Phase 12 complete: Zork 1 running on real hardware

With the bank-bit fix and directory formatting above, the machine
boots CP/M 2.2, and the full BDOS disk path was verified from the CCP
prompt itself: `SAVE 1 TEST.COM` (write + directory allocation), `DIR`
(directory search), `REN TEST2.COM=TEST.COM` (directory update), and
`TYPE TEST2.COM` (read-back) all confirmed working before ever touching
disk-resident user data.

**Getting Zork 1 onto the disk.** No in-CP/M transfer tool exists yet
(no working UART/PIP path), so `cpm_put.py` was written: a host-side
tool that computes CP/M directory entries and allocation blocks
directly from `bios.asm`'s own DPB (`SPT=26 BSH=3 DSM=233 DRM=63
OFF=5`) and writes a file's content + directory entry into a disk-image
file, without going through CP/M at all. Verified against a synthetic
image before use: a 3-extent, 40KB test file round-tripped byte-exact,
duplicate-name writes are refused, and free-block/free-slot scanning
correctly avoids blocks already used by real files already on the
card. It edits an image file only -- writing that back to the card is
a separate, explicit `dd` step, on purpose.

`ZORK1.COM` (8704 bytes, 1 extent) and `ZORK1.DAT` (84992 bytes, 6
extents) were injected this way into a snapshot of the live card
(taken with `dd` first, since the card already held `TEST2.COM` from
the CCP tests above) and written back. **Result: `ZORK1` loads and
plays from the CP/M prompt on real hardware.** This is Phase 12's
stated goal (`cpm-plan.md` Phase 12's test criteria) -- met in full.

### Keyboard key-repeat: contact bounce on release, not auto-repeat

Separately reported after Zork 1 was running: keys occasionally
registered twice from one physical press. `get_key_event` already
suppressed genuine auto-repeat correctly (a key held across scans
matches `last_row`/`last_col` and is not re-reported) -- the bug was in
detecting *release*. A single `find_key` scan can read "nothing
pressed" for one poll due to mechanical contact bounce, even while the
key is still physically held. The old code cleared `last_row`/
`last_col` on that first empty scan, so the very next (correct) scan of
the same still-held key looked like a brand-new keypress.

Fixed with a release-debounce counter (`release_cnt`): `gke_none` now
requires `DEBOUNCE_N` (40, untuned starting guess -- see its own
comment in `bios.asm`) *consecutive* empty scans before committing to
"released"; any real key detection resets the counter to 0 immediately,
so normal typing gains no added latency, only the release does.
Verified by disassembling the built `bios.bin`/`boot.img` directly
(matching `DEBOUNCE_N=$28`, `release_cnt=$F3AC`, `last_row=$F3AA`,
`last_col=$F3AB` against the symbol table) before shipping it to the
bench. **Confirmed fixed on hardware.**

### Remaining bring-up scaffolding, not yet reverted

- `stage1.asm` still prints a one-time per-stage load report (name +
  checksum + OK/BAD) instead of a silent boot, and clears the screen
  once for it.
- `boot_init` still starts CP/M's own output at row 6 instead of row 0,
  to keep that report visible above it.
- `cpm22.asm`'s `CMMND1` prints the drive letter as `'A'` (was `'a'`,
  an inconsistency in this reconstructed source vs. its own lines
  880/1374) -- this one is a real fix, not scaffolding, and should stay.

None of these block further work; flagged here so a future session
doesn't mistake the row-6 offset or the load report for permanent
design.

## Multi-drive SD layout: MBR partitioning + a 100 MiB drive B

Implements cpm-plan.md §8. Full design discussion (MBR vs. plain fixed
offsets, floppy-class vs. hard-disk-style drive B, the real CP/M 2.2
1 GiB ceiling) happened before any code was written -- summarized in
cpm-plan.md itself, not repeated here.

**A real, previously-unknown build-tooling bug found before it ever
reached hardware.** `bios.asm`'s new `alv1: ds 800` (drive B's
allocation vector) was placed in what looked like a free 896-byte gap
between the low-memory trampoline and the bank=1 font region
(`$7C80-$7FFF`, confirmed via `trampoline_end`). It isn't actually
free in the sense that mattered: `build-boot-image.py` assumed that
whole gap contributed zero bytes to `bios.bin`'s own linear file
layout, based on a real but narrower fact -- z80asm doesn't emit bytes
for a bare `org` jump with nothing declared in between. A `ds`
directive is not that; it genuinely emits its bytes into the file, so
`alv1` silently shifted every byte of chunk2 and chunk3's *extraction*
by 800 bytes relative to what the script assumed, without changing a
single real Z80 address. This was caught by a five-line sanity check
before ever considering the build trustworthy: search `bios.bin` for
the literal byte pattern of `JP boot_init` (`C3` + its real address,
little-endian) and confirm it lands where the `.sym` file says `BOOT`
is. It didn't -- off by exactly 800 bytes, immediately implicating the
new `ds`. Fixed by adding an explicit `alv1_end` symbol and having the
script account for that one real gap explicitly, the same way it
already does for the `CPM_BASE` gap. Re-verified with the same
byte-pattern search until it matched exactly.

**Every new/changed `bios.asm` routine was then disassembled from the
rebuilt `boot.img` and checked instruction-by-instruction against
intent** -- not just "it assembled cleanly." This caught nothing
further (everything matched on the first pass once the build-tooling
bug above was fixed), but is worth recording as the standard this work
was held to: `seldsk_impl`/`settrk_impl`/`setsec_impl`'s branch
targets, `compute_lba_and_offset`'s drive-A path confirmed byte-
identical to the original proven code with only the new base-add
appended, drive B's 32-bit `track<<5` shift chain (5 iterations of
`SLA L/RL H/RL C/RL B`, confirmed by counting instruction groups in
the disassembly), the `quarter_offsets` table's raw bytes, both DPBs'
raw bytes decoded field-by-field (`dpb0` unchanged, `dpb1` matching
the derived `SPT=128 BSH=7 BLM=127 EXM=7 DSM=6399 DRM=1023 CKS=0
OFF=0` exactly), `build_rw_cmd`'s big-endian reconstruction from the
new little-endian `new_lba`, and `boot_init`'s cache-sentinel
initialization (`cur_drive=0`, `cached_lba`=4x`$FF`,
`cached_drive`=`$FF`).

**`write_mbr.py`** was verified against real `fdisk -l` output on the
generated image, not just self-consistency -- `file` correctly
identifies it as a "DOS/MBR boot sector" and `fdisk` parses both
partitions with the exact expected LBA/size/type.

**`cpm_put.py`'s rewrite** was regression-tested by literally diffing
its output byte-for-byte against the pre-rewrite tool's own output on
the same drive-A input (`cmp` reported identical) -- both right after
the geometry-profile refactor and again after the EX/RC fix below, to
confirm neither change altered drive A's already-working behavior.

**A real correctness bug found in the 2-byte allocation-pointer
packing (`DSM>255`, drive B only), caught before it reached
hardware**: the natural-looking approach -- treat each physical
directory entry's own sequential index as its `EX` field, and cap `RC`
at 128 -- is wrong whenever `EXM>0` lets one physical entry span
multiple logical (16K) extents at once. Checked against `cpm22.asm`'s
own `OPENIT1`/`OPENIT2` BDOS source directly rather than trusting
memory of the DR spec: `EX` must be the *logical* extent number (not a
physical-entry index), specifically the highest logical extent a given
physical entry covers, and `RC` is only ever meaningful for that one
top logical extent -- BDOS's own open logic hardcodes `RC=128` for any
lower logical extent within the same physical entry, never reading the
stored byte for those. Fixed and verified three ways: hand-computed
`EX`/`S2`/`RC` for a 300000-byte, 3-extent test file matched the
tool's actual output exactly; the fix reduces to the original,
already-proven formula exactly when `EXM=0` (drive A), confirmed via
the same byte-for-byte diff mentioned above; a full BDOS read-back
(`TYPE` of a real multi-extent file on drive B) is still the pending
real-hardware confirmation.

**A second, independent, pre-existing bug found** (not introduced by
this work, exposed by `import-dir` relying on it): `cpm_name()`
truncated an over-length name to 8 characters *before* checking its
length against 8, so the length check could never fire -- a filename
like `verylongfilename.txt` silently became `VERYLONGF` truncated to
`VERYLONG` with no error, which is a real, silent collision risk
during a batch import (two different long names could truncate to the
same 8.3 name with no warning). Fixed to check length before
truncating; re-verified the fix aborts the whole batch (no partial
writes) before any file is touched.

**Result**: 100 MiB drive B (`DSM=6399`, Tier 1 of the ~1GiB plan)
built, `cpm_put.py` extended with a bulk `import-dir` mode, `write_mbr.py`
added -- all verified as above. Not yet re-tested on real hardware
(the plan's own stated verification order applies: re-confirm drive A
first, since its physical LBA placement moved, before trusting drive B
at all).

## Multi-drive layout: confirmed on real hardware

Full verification order from the plan completed, in order:

1. Drive A re-flashed at its new LBA 2048 location: checksum report
   passed, `DIR`/`SAVE`/`REN`/`TYPE` round-tripped correctly.
2. **Real, unrelated regression hit and fixed along the way**: bumping
   `CHUNK3_BLOCKS` from 16 to 20 (to fix a genuine but much smaller
   margin problem after the SHIFT-key fix below) silently wrapped the
   Z80's 16-bit address space -- `CHUNK3_DEST($DC00) + 20*512` exceeds
   `$10000`, so the load's last 1024 bytes landed at `$0000-$03FF`,
   corrupting stage1's own running code mid-load. Symptom: boot hung
   before ever printing the CHUNK3 report line, with no error -- the
   checksum guard couldn't catch it either, since the corruption is a
   Z80-runtime address-space fact, invisible to a file-level checksum
   over already-correct bytes. Fixed to the true maximum (18 blocks --
   `$DC00+18*512=$10000` exactly, verified by direct calculation before
   trusting it a second time) with a comment flagging this as a hard
   ceiling distinct from the softer `OFF=5`/32-block reservation.
3. Drive B (100 MiB, `import-dir`-populated with a 3-extent test file
   plus `ZORK1.COM`/`ZORK1.DAT`) confirmed on hardware: `DIR B:` lists
   all three files; `TYPE BIGTEST.TXT` scrolled its full ~4100 lines
   and ended on exactly the expected tail line (`04109`) -- real,
   on-hardware confirmation of the EX/RC fix for `DSM>255` multi-extent
   files, not just the earlier Python-side verification. `ZORK1` ran
   directly from drive B for an extended play session.

**SHIFT key implemented** (was previously a known, deliberately
deferred gap -- became a hard blocker mid-testing since `:` needed for
`B:` is a shifted character and couldn't be typed at all). Added
`shift_table` (standard US/MSX punctuation pairing; letters -> lowercase,
matching this hardware's already-uppercase unshifted convention) and
`check_shift` (same idiom as the existing `check_ctrl`, row 6 col 0).
Disassembly-verified (`BIT 0,A` for `check_shift` vs `BIT 1,A` for
`check_ctrl`, `shift_table`'s raw bytes matching the intended mapping
exactly). **Not yet bench-verified key-by-key** -- the punctuation
pairing is standard convention, not confirmed against this specific
keyboard's actual key legends.

**Parked, not yet investigated**: during Zork 1 play, the screen went
black partway through and never recovered (video sync kept running --
HSYNC/VSYNC come from the AVR's own independent timers -- but no
further content ever appeared). Follow-up detail: happened right
around "drop knife, take sword" in a standard walkthrough -- an early,
specific, well-known game location, not deep/accumulated play. That
weakens (without ruling out) the original "TPA grows over many turns"
framing and opens a real alternative given this session's separate SD
card degradation: a corrupted read of `ZORK1.DAT` at the specific byte
offset for that story location would produce exactly this symptom too,
deterministically, tied to game location rather than turn count. Good
discriminating test for later: does it crash at the exact same point
every time (favors a memory boundary or one specific bad sector) or
does it vary (favors a flaky read)?

**Update: the corrupted-stored-file hypothesis is now ruled out.**
Built `cksum.asm`, a small CP/M utility reading a file via the real
BDOS sequential-read path (OPENFIL/READSEQ) and accumulating this
project's own standard 16-bit sum-of-bytes checksum -- see its own
file for the two real bugs found and fixed via disassembly before it
ran (a wrong FCB address, and an assembler tokenizer quirk silently
turning `LD C,C_WRITE` into a no-op). On real hardware, `CKSUM
ZORK1.DAT` returned `A8E0`, an exact match against the host-computed
reference. `ZORK1.DAT`'s stored content is confirmed byte-for-byte
correct on the card -- the black-screen crash is not a corrupted
stored file or a bad sector. This also doubles as a real, on-hardware
confirmation that drive B's whole file-read chain (directory lookup,
extent walking, `compute_lba_and_offset`, the sector cache) is correct
for a genuine BDOS sequential read, not just the raw block-level
checks done earlier.

This leaves the memory-collision hypothesis (and the FBASE-shrink fix
identified below, still not implemented) as the more likely remaining
lead.

**Design discussion, not yet implemented (held off pending active
investigation)**: whether the low-memory video-blit trampoline
(`$7C00-$7C7F`) and drive B's `alv1` (`$7C80-$7FA0`) could be moved
lower in memory to reduce collision risk with a large program's own
memory use. Found: this trade-off cuts both ways, not a clear win --
a program's own code+static data (loaded at `$0100`, growing upward)
is *safer* the higher this reservation sits (more headroom, which is
why it's placed near `$8000` today); a downward-growing stack starting
near the reported top-of-memory is *safer* the lower it sits. Moving
it lower helps one direction and hurts the other, with no way to know
which direction Zork's own interpreter actually stresses without
disassembling it.

**A more robust fix identified, also not yet implemented**: CP/M's own
standard convention for exactly this situation is the word at address
`$0006-$0007` (`set_page0_vectors` currently writes the real `FBASE`,
`$E406`, there) -- programs are meant to read it as "top of my
available memory" when sizing their own dynamic stack/buffers. `CALL
5` (the real BDOS entry every program actually uses) is a separate,
fixed vector, unaffected by this value. Reporting a smaller ceiling
(e.g. `$7C00` itself) instead of the real `FBASE` would make any
well-behaved program -- respecting a convention that professionally
distributed CP/M software needed to honor to run correctly across the
wildly varying real-world TPA sizes of actual 1980s machines -- never
legitimately place anything at or above `$7C00` at all, protecting
against both collision directions at once rather than trading one for
the other. Caveat: only helps if Zork's specific interpreter actually
respects this convention rather than assuming a fixed size; not
verified either way.

**Also raised this session, not yet acted on**: user reports the SD
card that had been working perfectly stopped functioning correctly,
while a previously-broken card started working -- suspected supply
droop during SD write current pulses corrupting the card (a 100nF
cap alone is far too small to ride out a sustained write-current
pulse, only fast switching noise). Mitigation already applied: a
dedicated VCC+GND wire pair run directly from the power entry point
to the SD adapter, plus a 270uF bulk electrolytic capacitor added
locally at the adapter's VCC/GND. Not yet confirmed whether this
resolves the card-degradation pattern -- worth revisiting if it
recurs.

## RunCPM as a diagnostic tool for the parked Zork black-screen issue

User already had RunCPM (an open-source, C-source-available CP/M
emulator) with Zork 1 set up, and asked whether it could help diagnose
the crash. Real caveat stated up front: RunCPM uses an entirely
different memory map (no bank switching, different TPA layout/size),
so it can't be asked "does this touch our $7C00" directly -- addresses
don't transfer between platforms.

What DOES transfer, at least approximately: a small, permanent
instrumentation patch to RunCPM's `cpu1.h` (hooking the single, central
`PUSH` macro every stack push routes through) tracks the deepest the
Z80 stack ever reaches during a session and writes it to
`/tmp/runcpm_minsp.txt` on every new record -- no `-DDEBUG` rebuild or
preset breakpoint needed. `stack_bytes_used` (distance from the top of
TPA) is directly comparable to our own hardware's real headroom (26539
bytes between `CCPSTACK` and the low-memory trampoline at `$7C00`).

Ran it directly (this build's stdin isn't tied to a real TTY, so a
full walkthrough can be piped in non-interactively): playing through
lamp+sword+cellar showed `stack_bytes_used=61223` -- implausibly deep
for genuine call nesting in a text parser (tens of thousands of nested
2-byte pushes). A controlled follow-up test (start Zork, `QUIT`
immediately, 0 moves) showed the *identical* value and `PC`. This
proves the deep dip is a one-time event during `ZORK1.COM`'s own
startup (very likely a deliberate SP-as-data-pointer trick for a fast
bulk load of the story file, a known Z80 idiom), not something that
grows with sustained gameplay -- real gameplay through "take sword, go
down" added zero additional depth beyond what mere startup already
reaches. Doesn't settle the hardware question (different memory map),
but narrows what kind of event to suspect if this is picked back up:
a one-time load-time event, not per-turn/per-command growth.

## SD SPI: MISO moved from PC4 to PC7, two spi_xfer optimizations

Real, measured (not estimated) speedup found by inspecting the actual
compiled `spi_xfer` before and after: with MISO on `PC7` instead of
`PC4`, the branch-based MISO read (`IN`/`SLA C`/`BIT`/`JR Z`/`SET 0,C`,
39-42 T-states depending on the bit) becomes a fixed `IN`/`RLA`/`RL C`
(23 T-states, no branch) -- `RLA` moves bit 7 of the just-read port
byte into carry, `RL C` shifts that into `C`'s bit 0, exactly
replicating the old behavior. Separately, the bit counter moved from
`D` (`DEC D`/`JR NZ`, 16T taken/11T not) to `B` (`DJNZ`, 13T/8T) --
`B` was unused inside the routine, still preserved for the caller via
the same `PUSH BC`/`POP BC`. Combined: ~164 fewer T-states per byte
transferred (~11-12% off `spi_xfer`'s total cost), and the routine is
6 bytes *smaller* (49 -> 43 bytes), not larger -- confirmed by direct
disassembly of the built `boot.img`/`stage1.bin`, matching a
byte-for-byte hand count before trusting it.

Full loop-unrolling was also analyzed and deliberately rejected: it
would save a further ~106 T-states/byte (~8-9%) but cost roughly
+200 bytes in the same `$F200-$FFFF` BIOS region whose margin had to
be fixed (`CHUNK3_BLOCKS`) earlier this same session -- a poor trade
for this specific codebase's current constraints, not a general
rejection of unrolling.

**Real hardware consequence, not just a software change**: since MISO
is a physical pin, moving it is a wire (and its pull-up resistor)
move, not just a constant edit -- and it had to be applied to BOTH
`bios.asm`'s and `stage1.asm`'s independent copies of `spi_xfer`
together, since both read the same physical pin at different times
(stage1 during boot, the CBIOS afterward). Updating only one would
have broken SD access entirely the moment the wire moved, not just
slowed it down. `docs/sdcard-wiring.md` and `hardware/bom.csv` updated
to match; the historical `test-progs/*.asm` files that also hardcode
`MISO_BIT=4`/`PC4` were deliberately left alone (Phase 11 snapshots,
not part of the active boot chain) rather than churned for no live
benefit.

**Confirmed on real hardware**: MISO wire and pull-up moved to `PC7`,
`boot.img`/`stage1.bin` reflashed, all three chunk checksums
(`2BDA`/`6522`/`30D7`) matched. Both the physical rewire and the
optimized `spi_xfer` (`RLA`/`RL C` + `DJNZ`) are confirmed working, not
just disassembly-verified.

## FBASE-shrink attempt: a real design mistake, found on the bench and reverted

Tried the FBASE-shrink idea from the design discussion above -- report
`porta_shadow` ($7C00) instead of the real `FBASE` ($E406) at the
standard "top of my available memory" word, page-zero bytes 6-7, on
the theory that programs respecting that convention would then never
place anything at or above the low-memory trampoline/`alv1`.

**Broke boot entirely**: hung right after `JUMPING TO BOOT`, never
reaching CCP's prompt. The design was based on a genuine
misunderstanding, not a coding slip: bytes 6-7 are not a separate
convention that happens to share an address with the `JP BDOS`
instruction at address 5 -- they ARE that instruction's own operand
bytes. `CALL 5` (which everything in the system uses to reach BDOS,
including CCP's own startup sequence) works by literally executing
`JP <bytes 6-7>`. Writing a fake, shrunk address there doesn't just
change what a program *believes* about memory size -- it makes every
single `CALL 5` in the system jump to that fake address instead of
real BDOS code, failing immediately. Confirmed by grepping both
`bios.asm` and the unmodified `cpm22.asm` for reads of address 6
*before* trying this (found none) -- correctly showing nothing reads
it as data, while missing that CCP still depends on it being
*executed* as part of the jump instruction it's embedded in.

Reverted to the real `FBASE`; confirmed via disassembly this exactly
matches the last known-working build (`CHUNK3_CKSUM` identical to the
pre-attempt value). **Real conclusion**: there is no lightweight
page-zero trick that reports a smaller TPA without breaking the real
BDOS vector -- they're the same bytes. The only real way to shrink
what a program sees is to actually shrink `MEM` (moving `FBASE`/
`CBASE` down for real), which is the already-scoped, separate ~1GiB
drive-B Tier-2 follow-up (cpm-plan.md §8), not a small, safe
experiment. The parked Zork black-screen investigation is back to
where it stood before this detour, with this approach now ruled out
rather than merely untried.

## Zork black-screen: two hypotheses ruled out on the bench

Two targeted, disassembly-verified diagnostics, each isolating one
candidate mechanism for the "screen goes black after `take sword`,
system totally unresponsive" hang:

- **`vbi_guard`**: capped `video_blit_impl`'s `char_buf` NUL-terminator
  scan at 4 iterations (real usage is always exactly 1 character), to
  test whether a corrupted terminator was driving an effectively
  unbounded scan. **Result: no change** -- "just goes black after you
  type take sword," identical to before. Rules out the
  corrupted-terminator/unbounded-scan mechanism.
- **`hb_toggle`**: XORs the first video-RAM byte (`video_base`=$C000)
  on every single `CONOUT` call, independent of `char_buf`/
  `video_blit_impl` entirely, with no `PUSH`/`POP` (so no stack-safety
  concern even if it runs with `bank=1` set). If `CONOUT` were still
  being called after the hang, this would show as visible flicker in
  the top-left corner regardless of anything else being broken.
  **Result: whole screen black, no flickering at all.** `CONOUT` is
  definitively not being called after the hang -- this is strong
  evidence of a genuine CPU-level lockup (a wild jump into non-code
  memory, or an executed `HALT` with nothing to wake it -- this system
  has no Z80 interrupts wired for wake-up), not a narrower
  video-specific bug with the rest of CP/M still running underneath.

Both diagnostics are still present in `bios.asm` (harmless, cheap, and
not worth reverting) but the mechanisms they tested for are now ruled
out rather than open.

## AVR-side address-bus monitor: new diagnostic tool for the Zork hang

Since `hb_toggle` pointed at a genuine CPU lockup rather than a
video-specific bug, the next useful question is the most basic one:
is the Z80 still fetching instructions at all when it happens, and if
so, roughly where? The AVR can see `_MREQ`/`_RD` and the low 14 bits
of the address bus at all times (even while the Z80 runs completely
free, outside ROM emulation) -- previously this was only ever sampled
on demand (the `a` monitor command), never captured around a specific
moment.

New module `firmware/avr-1284p/src/busmon.c`/`busmon.h`, wired into
`video.c`'s existing UART-poll loop (already the hook point `video_run()`
uses to detect "send any byte to stop"): the loop now dispatches on the
received byte's value. `BUSMON_TRIGGER` (`'m'`) suspends video
generation (`TIMSK1 = 0`, same mechanism the old unconditional-stop path
already used) and calls `busmon_run()` instead of returning to the
monitor; any other byte keeps the original behavior unchanged.

`busmon_run()` tight-loops sampling `_MREQ`/`_RD` and
`z80_read_addr()` into a 128-entry `uint16_t` circular buffer, with
*zero* printing during capture (so as not to disturb whatever timing
is under investigation), until any UART byte arrives, then dumps the
buffer in chronological order. The polling technique deliberately
copies `rom_emu.c`'s own hard-won lesson: no "wait for `_MREQ`/`_RD`
to go high" step between samples, since back-to-back plain
memory-read M-cycles have no guaranteed high gap (only an M1/
opcode-fetch cycle's T3/T4 refresh states produce one) -- an
edge-detecting loop can hang forever waiting for a gap that a run of
non-M1 cycles will never produce. Instead it just unconditionally
re-checks and re-samples every iteration, tolerating runs of identical
consecutive samples (many AVR loop iterations happen per Z80 M-cycle)
as an expected, harmless artifact rather than a bug.

**Intended workflow** (per the user's design): press `s` to start ROM
emulation -> video generation; play up to, but do not yet execute, the
suspect input (`take sword`); send `m` over UART to the AVR, which
suspends video and starts silently capturing; execute the suspect
input on the Z80's own keyboard; if/when it hangs, send any other byte
over UART to stop the capture and print the last 128 samples.

**Caveat, called out explicitly in both the code and here**: A14/A15
are not wired to the AVR at all (`monitor.c`'s own header comment) --
every sample is really one of 4 possible physical 16K-aligned
addresses (`value`, `value+0x4000`, `value+0x8000`, `value+0xC000`),
not an unambiguous 16-bit address. Interpreting a dump needs the known
code layout as context: TPA starts `$0100`, the bank-invariant
trampoline/font/blit code lives `$7C00`-`$BFFF`, CCP/BDOS/BIOS live
`$DC00` up.

Verified via disassembly before handing off (not just "it compiled"):
confirmed the `_MREQ`/`sbic` and `_RD`/`sbic` checks have the correct
polarity and order, confirmed `z80_read_addr()`'s inline masking
(`andi r25,0x3F`) correctly excludes the HSYNC/VSYNC bits sharing
`PORTC` before storing the high byte, confirmed the circular-buffer
wrap (`andi r28/r29,0x7F`) is correct, confirmed `TIMSK1=0` (`sts
0x6F,r1`) happens unconditionally before the `busmon_run()` dispatch
check (not just on the trigger byte), and confirmed the dump loop
starts from the oldest sample (`idx`, the slot one past the last
write) for chronological output. Clean build, no warnings
(`-Wall -Wextra`); adds 256 bytes of `bss` (the new static circular
buffer) on top of the existing 8260, well within the 1284P's 16KB
SRAM. **Not yet tested on real hardware** -- next step is flashing
this build and running the workflow above against the live Zork 1
hang.

## First busmon capture: a coherent SD-driver call chain, not a wild jump

First real capture, 128 samples, taken by playing up to `take sword`,
starting the monitor, then pressing Enter and waiting before stopping
it. Cross-referenced every sample against `bios.sym` under each of the
4 possible A14/A15 guesses (script, not by hand) -- the `A14=A15=1`
case (add `0xC000`) fit essentially every sample to a real, named
routine, strong evidence the +0xC000 guess is right (matches `bank=1`,
SRAM-execution mode, as expected once past boot) and that this is not
a wild jump into garbage memory:

- The low values (`0x0002`-`0x007E`) are `video_base`($C000)+offset --
  video-RAM *reads*, not page-zero code, consistent with `CONOUT`
  scrolling/writing the screen as the game echoes/prints text.
- The rest trace one continuous, in-order call chain: BDOS file-
  position/directory bookkeeping (`FINDFST`/`TRKSEC1-4`/`DOREAD`/
  `AUTOSEL`) -> BIOS disk positioning (`home_impl`/`settrk_impl`/
  `SECTRN`) -> `read_impl` -> `compute_lba_and_offset`+`clo_driveB`
  (**drive B** -- where the Zork files live) -> `build_rw_cmd` ->
  `sd_cs_assert`, which is where the 128-sample window ends.

**Read cautiously, not as a conclusion**: this looks like a completely
normal BDOS random-read sequence for drive B, caught mid-flight, most
likely triggered by Zork paging in data for `take sword` -- there is
no sign of a small repeating loop (which a wild jump or a tiny stuck
loop would show as a handful of addresses dominating the dump). But
128 samples is a very short real-time window (very roughly a few
hundred microseconds of Z80 execution at 8MHz) -- nowhere near enough
to distinguish "captured mid-flight of an ordinary, slightly slow
disk read" from "captured the last instants before it got stuck a
little further on, e.g. in the SD driver's own unbounded busy-wait
loops (`read_r1`'s `r1_loop`, `wait_token`'s `wt_loop`, `write_block`'s
`wb_busy`) if the card never returns the expected response for this
specific read." Also flagging a real bug found while writing this up
(not the capture's fault): the "last N samples" banner printed `N` via
`usart_puthex8`, so 128 (`0x80`) displayed as "80" with no indication
it was hex -- cosmetic, but worth fixing before it causes real
confusion later.

**Follow-up, done same session**: `BUSMON_DEPTH` raised 128 -> 1024
(2KB, still cheap against the 1284P's 16KB SRAM -- `bss` now 10308 of
16384, ~6KB free for stack), giving an 8x longer capture window at the
same sampling rate. The dump was also changed to run-length-encode
consecutive identical samples (`value` or `value xN`, N in hex) instead
of printing all 1024 raw values -- makes a genuinely stuck loop
obvious at a glance (a few addresses with very large N dominating the
output) instead of requiring another manual symbol-table
cross-reference to notice. The "last N samples" banner is now a fixed
string instead of a hex-printed byte, fixing the display bug above.
Verified via disassembly (not just re-reading the C): the 10-bit
wraparound mask is correctly split across the 16-bit index's high/low
bytes, the run-length inner loop's break/continue and 16-bit run
counter are correct, and the outer loop's "advance i by run" and
line-wrap-every-8-*printed-groups* (not every 8 raw samples, so
wrapping stays readable regardless of run lengths) both checked
against the actual generated instructions. Clean build, no warnings.
**Not yet re-tested on real hardware with the deeper buffer** -- next
step is retrying the same `take sword` capture and seeing whether the
longer window still shows this same clean, non-repeating call chain,
or resolves into a dominant repeated run somewhere in the SD driver.

## Two bench observations while re-testing with the deeper buffer

- **`hb_toggle`'s cosmetic side effect explained**: intermittent
  corruption of the top-left character (self-correcting after a few
  seconds) during otherwise-normal operation is `hb_toggle`
  (`conout_impl`, `bios.asm`) still XORing `video_base` on every
  `CONOUT` call -- expected given it's still wired in, not a new bug.
  Whether the corruption is visible at any instant just depends on the
  parity of characters printed since the last time that byte happened
  to land right; it self-corrects as more text prints/scrolls. Left in
  place for now since it's still the working proof that `CONOUT` stops
  being called at the actual hang -- candidate for removal once the
  hang itself is found, not before.
- **The hang's location in the walkthrough moves if you retype a
  command** (observed: an accidental `PPUT PAINTING INSIDE CASE`
  typo, corrected, then hung -- at a different point than the usual
  clean `PUT PAINTING INSIDE CASE, DROP KNIFE, TAKE SWORD` sequence).
  This argues against a fixed-PC/timing bug (which would hang at the
  same instruction regardless of history) and toward something
  data-dependent -- consistent with the busmon capture above landing
  deep in `compute_lba_and_offset`/`clo_driveB`/`build_rw_cmd`
  (computing *which* SD block to fetch): a different interaction
  history changes the Z-machine's internal state and how much text has
  printed, plausibly shifting which sector of `ZORK1.DAT` gets
  requested next. If the real bug is tied to a specific block number
  or extent boundary (drive B's 2-byte `DSM>255` allocation-pointer
  packing is new, unexercised-until-now code -- cpm-plan.md's own
  multi-drive plan flags this exact code path as never bench-verified
  before this session), a shifted sector would show up exactly like
  this: same class of hang, different trigger point.

## Investigation retraction: cpm_put.py's multi-entry packing is correct

While chasing the PIP write hang, `BIGTEST.TXT`'s on-disk directory
entries (3 physical entries, `EX=7/15/18`) initially looked wrong
compared to a quick re-run of `put_file()` -- but that comparison used
the wrong assumed file size (297 records, from naively summing `RC`
across entries, which is only valid for a single-entry file). Once the
real size was reconstructed properly (2345 records, ~300KB, correctly
needing 3 physical entries per DR CP/M's own group-of-`EXM+1` rule),
re-running `put_file()` against the *actual* full content reproduced
the on-disk structure exactly, byte for byte. **No bug here** --
`cpm_put.py`'s packing is correct; this was a false lead caused by my
own wrong size assumption, not a real defect. Logged so this specific
dead end isn't re-investigated.

`CKSUM BIGTEST.TXT` (`CKSUM=23D1`) then completed quickly and cleanly
-- confirming the multi-entry-crossing *read* path (`GETNEXT`, the
group-boundary logic, the SD read path across ~300KB) all work
correctly. Since PIP additionally *creates and writes* a new file --
the first time ever that live BDOS code has allocated a fresh block on
drive B (every prior file arrived via `cpm_put.py`, bypassing
allocation entirely) -- the remaining suspect area is squarely
block/directory-entry allocation (`GETEMPTY`/`BITMAP`/`SETFILE`/
`CKBITMAP`/`STBITMAP`). Manually re-derived and cross-checked
`GETBLOCK` (block-within-extent index formula), `SETFILE` (the
differential-decrement trick that makes one counter serve both 1-byte
and 2-byte pointer widths), `BITMAP` (800-byte ALV size for `DSM=6399`,
confirmed correct), and `CKBITMAP`/`STBITMAP` (bit-position arithmetic)
against drive A's own known-working case -- all correct, no bug found
in any of them either.

`GETEMPTY` does appear in the busmon trace of the stuck PIP run
(consistently at the same offset, its own `RET Z` early-exit
instruction) -- but that instruction's *address* is identical whether
the branch is taken (allocation failed) or not (succeeded continues to
allocate), since that depends on data content the address bus alone
can't reveal. This is a real limit of address-only tracing, not a dead
end in the investigation -- recommended (and the user is doing) a
direct empirical check instead: reset and `DIR B:` to see whether
`TEST.TXT`'s directory entry exists at all after a hung attempt.

**Separately noted, explained, not a bug**: the CP/M prompt reverting
to `A>` after running `CKSUM` from `B:` is expected, current behavior
-- `bios.asm`'s `wboot_init` unconditionally does `LD C,0 / JP CBASE`
on every warm boot (which happens after *any* transient program
returns, not just on errors), and `cpm22.asm`'s own `COMMAND` entry
point uses `C`'s low nibble as the drive to select with no separate
"preserve the previous drive" path. A real, easy, worth-fixing UX gap
for later, but unrelated to the PIP hang itself -- a single successful
warm boot behaving this way is expected, not evidence of a stuck loop.

## AVR bug found and fixed: ROM emulation couldn't be restarted without a power cycle

While investigating the drive-B hang, the user separately noticed a
never-before-tested workflow -- start ROM emulation, upload, halt,
reset, start again -- simply didn't work ("can't get it to reboot
again into rom emulation"). Real, confirmed bug, found by re-reading
`rom_emu.c`'s own header comment against what the code actually does:

The magic-address exit path drives `wait_rel` (PD3, the WAIT
flip-flop's async PRESET, active low) low **and leaves it there
permanently** -- documented, deliberate, and correct for that specific
transition (SRAM-execution mode needs `_WAIT` permanently released).
But grepping every `BIT_WAITREL` reference in the codebase confirmed
nothing *ever* drives it back high afterward -- `main.c` only sets it
once, at true AVR power-on. So a second `s` (start ROM emulation) in
the same monitor session left the WAIT flip-flop's PRESET still
asserted from the previous session's exit: `_WAIT` could never be
pulled low again, meaning the Z80 ran completely unthrottled from its
very first fetch, never giving `rom_emu_run()`'s loop a chance to serve
even one byte of the freshly-uploaded ROM. A full AVR power cycle
masked this entirely (power-on re-arms it once), which is exactly why
it went unnoticed until this specific sequence was tried for the first
time this session.

Also very plausibly explains a second symptom reported in the same
session: after fighting to get ROM emulation to restart, the Z80
reported `SD INIT FAILED` on stage1 -- consistent with the Z80 racing
through partially-garbled execution (never correctly loading/running
the real uploaded stage1 image) rather than a real SD/hardware fault.

**Fix**: `rom_emu_run()` now explicitly re-arms `wait_rel` high itself,
immediately before releasing the Z80 from reset, rather than assuming
it's already in the right state. Verified via disassembly: `sbi
PORTD,3` (wait_rel high) executes immediately before `sbi PORTD,2`
(release reset) -- a clean 2-instruction, 4-cycle addition. Clean
build, no warnings. **Not yet re-tested on hardware** -- next step is
reflashing the AVR and re-running the full upload/start/halt/reset/
start-again sequence to confirm both symptoms are actually resolved.

## PIP hang narrowed further: TEST2.$$$ has zero allocated blocks

Dumped drive B off the card after a hung `PIP B:TEST2.TXT=B:BIGTEST.TXT`
and inspected it directly (not just via CP/M-level `DIR`/`TYPE`, which
gave ambiguous/unhelpful answers -- plain `DIR` never showed sizes at
all, and `TYPE B:TEST2.$$$` printed nothing, which turned out to be
directly explained rather than mysterious): the directory entry for
`TEST2.$$$` (PIP's own temp-name-before-rename convention) exists --
`RC=0`, `AL=[0,0,0,0,0,0,0,0]`. File *creation* succeeded; not a single
data block was ever allocated or written. This rules out "hangs near
the end, during close/rename" (the `.$$$` name alone doesn't prove
that -- rename is always the last step regardless of how much data got
written) and points at the very first `WTSEQ`/block-allocation instead.

Cross-checked the busmon trace from that same hang against every
write-side symbol (`WTSEQ`, `FNDSPACE`, `BITMAP`, `CKBITMAP`/
`STBITMAP`, `write_impl`, `write_block`, `FCBSET`, `UPDATE`): **none of
them appear anywhere in the trace.** Only `SELECT`/`AUTOSEL` (run on
every single BDOS call, read or write alike) and `READSEQ`/`read_impl`/
`GETBLOCK`-family addresses show up -- and those are ambiguous, since
directory-block reads (paging through drive B's 1024-entry directory
while searching for a free slot) run through the *exact same*
instructions as ordinary file-data reads. So the trace is consistent
with being stuck somewhere in `OPEN`/directory-search, before a single
write is ever attempted -- not conclusive on its own, since the trace
predates the WAIT-flip-flop fix above and may not even be the same hang
instance.

Manually re-derived and cross-checked against drive A's own proven
formulas (not just re-read, actually traced register-by-register):
`GETBLOCK`'s block-within-extent index formula (an off-by-one in how a
decrement-and-test loop counts iterations that took a second, careful
pass to get right -- first pass mis-read it as computing `SAVEXT<<1`
for drive B when it actually computes `SAVEXT<<0`, i.e. `SAVEXT`
unshifted, exactly the expected result), `SETFILE`'s differential-
decrement trick (one shared counter correctly yields 16 iterations for
1-byte pointers and 8 for 2-byte pointers), `BITMAP`'s 800-byte ALV
size for `DSM=6399`, `CKBITMAP`/`STBITMAP`'s bit-position arithmetic,
`FNDSPACE`'s free-block search (confirmed its "skip the backward-search
when starting from block 0" behavior is intentional, not a bug -- block
0 is always pre-marked used by the directory reservation anyway), and
`NXENTRY`/`CKFILPOS`/`STFILPOS`/`MOREFLS`/`CHKNMBR`/`FINDFST`/`FINDNXT`
(directory pagination, all confirmed 16-bit-safe, no assumption that
breaks for `DIRSIZE=1024` vs drive A's 64). All correct. `TRKSEC`'s own
track/sector math is additionally already proven correct for values far
larger than any directory scan would need, since `CKSUM`'s own
successful 2345-record read already exercises it that far.

**Also retracted a false lead from earlier in this same investigation**
(see above): `BIGTEST.TXT`'s 3-directory-entry structure initially
looked wrong but is actually correct DR CP/M multi-group packing for
its real ~300KB size -- re-verified by reconstructing the real record
count instead of naively summing `RC`, then re-running `put_file()`
against the actual content, which reproduced the on-disk bytes exactly.

**New diagnostic tool**: `cpydbg.asm`/`cpydbg.com` (`firmware/z80-boot-
rom/cpm/`) -- a minimal, from-scratch copy utility (real `PIP.COM` is a
RunCPM binary with no source to instrument) that prints `REC=nnnnn
BLK=nnnnn` after every single record copied, specifically so a mid-copy
hang leaves the exact record/block number frozen on screen. Usage:
`CPYDBG destname sourcename` (space-separated, not PIP's own
`dest=source` syntax) -- deliberately matches `cpm22.asm`'s own
`UNKWN4` two-filename handling (verified directly against that code):
the first filename becomes the standard, fully-zeroed default FCB at
`$5C`; a second filename's drive+name+type (12 raw bytes, nothing else)
gets written at `$5C+16=$6C`, deliberately overlaid on FCB1's own
AL-array region (harmless -- `OPEN`/`MAKE` overwrite AL from the
directory regardless) -- so `cpydbg` builds its own full 36-byte source
FCB from those 12 bytes, zeroing the rest itself, since CCP doesn't.
Deliberately simplified vs. real PIP: no `.$$$`-then-rename, just a
direct `MAKE` on the given destination name (re-running against the
same destination name will create a duplicate directory entry --
`ERA` it first). BDOS function numbers (15/16/20/21/22/26/2/9)
re-verified directly against `cpm22.asm`'s own `FUNCTNS` table, not
assumed. Verified via disassembly before shipping: every `JR`/`JP`
target checked against its real label address, all message strings
confirmed present and `$`-terminated at the addresses the code
references, `F_DMAOFF`/`F_OPEN`/`F_MAKE`/`F_READ`/`F_WRITE`/`F_CLOSE`
constants all encode correctly (this project's own tokenizer gotcha
that silently broke `C_WRITE`-style names in `cksum.asm` was
specifically checked for and confirmed absent here). Added to
`driveB.img` (`CPYDBG.COM`, block 44 -- the first genuinely free block,
matching hand-verification of the allocator's own free-block search).
**Not yet run on hardware.**

## CPYDBG.COM succeeded completely on real hardware -- drive B's sequential write path is sound

Real hardware result: `CPYDBG TEST3.TXT B:BIGTEST.TXT` ran to
completion -- `REC=02344 BLK=00018`, then `DONE`, then `DIR B:` shows
`TEST3.TXT`. This is a genuine, decisive, positive result: it created a
brand-new ~300KB file from scratch, correctly allocating new blocks
and crossing all 3 of the directory-entry-group boundaries `BIGTEST.
TXT`'s own structure has (records 0-1023, 1024-2047, 2048-2344).
Combined with the earlier manual audit (`GETBLOCK`/`SETFILE`/`BITMAP`/
`CKBITMAP`/`STBITMAP`/`FNDSPACE`/`NXENTRY`/`GETEMPTY`/`GETNEXT`/
`OPENIT`/`CLOSEIT`, all individually checked against drive A's proven
formulas), this closes the "is drive B's write/allocation path
fundamentally broken" question for good: **it is not.** Sequential
read+write, including fresh multi-block, multi-extent-group file
creation, is proven correct end to end.

This reframes the whole investigation: whatever makes real `PIP.COM`
(and, presumably, Zork's own story-file paging) hang must be something
those programs do that `cpydbg` doesn't. The one concrete difference
found in `PIP.COM`'s own disassembly (`RunCPM/A/0/PIP.COM`, no source
available): its BDOS function-call wrapper table includes stubs for
`READRAND`/`WRITERAND`/`SETRAN` (functions 33/34/36) -- random-access
I/O, a code path neither `cpydbg` nor `cksum` has ever exercised. Full
static tracing of PIP's actual call sequence wasn't possible (it
dispatches through an indirect call table `z80dasm`'s linear/recursive
sweep doesn't follow), but the wrapper stubs' mere presence is a real
signal.

Manually audited `POSITION`/`COMPRAND` (`cpm22.asm`) -- the routine
that converts a 3-byte FCB "random record number" (`r0`/`r1`/`r2`,
offsets 33/34/35) into the `EX`/`S2`/`CR` fields sequential access
uses. The bit arithmetic is correct for any value within CP/M 2.2's
documented 8MB-per-file random-access ceiling (`r2` nonzero is treated
as an immediate out-of-range error -- a real, standard, well-known CP/M
2.2 limitation, not a bug, and nowhere near relevant at our actual file
sizes). It ultimately calls the same `CLOSEIT`/`OPENIT`/`GETEMPTY`
primitives sequential access does, so if there's a bug specific to
random access, it's more likely triggered by *when*/*how* those get
invoked via an explicit seek than in fundamentally different code.

**New diagnostic tool**: `cpyrand.asm`/`cpyrand.com` -- a near-identical
variant of `cpydbg.asm`, differing only in how it writes the
destination: pokes the current record number directly into the FCB's
`r0`/`r1` bytes (`FCB1+33`/`+34`, little-endian; `r2` stays zero, well
under the 8MB ceiling) and calls `WRITERAND` (BDOS 34, verified against
`cpm22.asm`'s own `FUNCTNS` table) instead of plain sequential
`WRITESEQ`. No `SETRAN` call needed -- that function only *computes*
`r0`/`r1`/`r2` from an existing sequential position for a program
switching access modes mid-stream; here the target record number is
already known (it's the loop counter), so it can be written directly.
Source read stays sequential, matching the likely real-world shape (PIP
reading a source file straight through while writing the destination
via random access). Verified via disassembly before shipping: the `R0`
poke lands at the correct address (`$5C+33=$7D`), `WRITERAND`'s
function number (34) encodes correctly, and the rest of the control
flow (identical to `cpydbg`'s already-verified structure) re-checked
end to end. Added to `driveB.img` (`CPYRAND.COM`, block 45). **Not yet
run on hardware** -- next step is testing whether switching only the
write side to random-access I/O reproduces the hang `cpydbg`'s
sequential version didn't.

## Root cause found (PIP/Zork hang): the trampoline sat in transient-program buffer space -- relocated $7C00 -> page zero

The user found real PIP.COM's own DR-published PL/M source
(`PIP.PLM`). Two facts from it, together, are the whole bug:

```plm
MAXB  ADDRESS EXTERNAL,     /* ADDR FIELD OF JMP BDOS */
MEMSIZE LITERALLY 'MAXB',
SIZE$MEMORY: PROCEDURE;
    SBASE = .MEMORY + SHR(MEMSIZE - .MEMORY,1);
    SBLEN, DBLEN = SHR((MEMSIZE - .MEMORY) AND 0FF00H,1);
```

PIP reads `MAXB` -- literally the address operand of the `JP BDOS`
instruction at page-zero 5-7, i.e. `FBASE`=`$E406` on this system --
and splits *everything* between its own end (~`$1E80`) and there into
two working buffers, ~24KB each. That span runs straight through
`$7C00-$7FFF`, where this project's bank-flip trampoline lived
(`porta_shadow`, `char_buf`, the flip stubs, `alv1` -- drive B's
800-byte allocation vector). PIP tramples it the instant it starts
filling buffers, before a single real disk record is touched -- which
is exactly the observed symptom: `PIP` dies in seconds with `TEST2.$$$`
left holding `RC=0`/no blocks; `CPYDBG`/`CKSUM` (fixed 128-byte
buffers, nowhere near `$7C00`) run the identical BDOS calls to
completion. A stock CP/M machine has nothing special at `$7C00`, so
PIP's memory logic -- correct, standard, decades-proven -- has no way
to know. Zork's own memory-hungry interpreter is a very plausible
second victim of the same mechanism (its `take sword` hang was never
explained by anything else, and "hang moves when you mistype a
command" fits buffer contents shifting).

This also vindicates the instinct behind the earlier reverted
"FBASE-shrink" attempt -- that was the right idea (protect the
trampoline by keeping transient programs out of its memory), just
aimed at the wrong mechanism (bytes 6-7 *are* the `JP BDOS` operand,
not a separate field, so faking them broke `CALL 5`).

**Fix: shrink the trampoline and move it to page zero.** Worked
through, register-by-register, which pieces genuinely must be
bank-invariant (dereferenced by address on both sides of a flip, or
the flip code itself) vs. which just happened to live there:

- `porta_shadow` (1) -- read-modify-written on both sides of every
  flip. Stays.
- `char_buf` (2) -- written by CONOUT (bank=0), dereferenced by
  `video_blit_impl` (bank=1). Stays.
- `cur_row`/`cur_col` -- read into `B`/`C` *before* the flip and
  carried across in registers (bank switching touches only the memory
  map, not CPU registers). Moved to BIOS scratch.
- `blit_saved_sp` -- written before the flip, read after flipping back;
  always bank=0 context. Folded into a shared `saved_sp` in page zero
  (needed there because `leave_bank1` reads it right after the
  flip-back `OUT`).
- `blit_scratch` (16, the nested-call stack) + `vbi_guard` (1) -- only
  ever touched from inside bank=1 code, and `$8000+` is just as
  consistently mapped throughout that window. Moved up into the bank=1
  region.
- `alv1` (800) -- read only during ordinary bank=0 BDOS execution;
  only ever down there for spare room. Moved to BIOS scratch (`end` now
  `$FF2D`, ~210 bytes under the ceiling).

`enter_bank1`/`leave_bank1` also replace four near-identical flip
sequences (video_blit/scroll/cls/hb_toggle's own copies + vbi_return/
vsi_return) with one shared pair; `video_cls` and `hb_toggle`'s real
work moved up into the bank=1 region alongside video_blit_impl/
video_scroll_impl, so the shared exit stub has one calling convention
to serve. `video_blit`/`video_scroll`/`video_cls`/`hb_toggle` are now
tiny bank=0 caller stubs living with the rest of the BIOS ($F29B+) --
they run entirely before the flip, so they never needed to be
bank-invariant either. `video_blit_impl` now does its own `LD
HL,char_buf` as its first instruction, since `HL` is `enter_bank1`'s
jump-target register now.

**Result: 38 bytes** (`$0008-$002D`), down from 158, relocated to the
`$0008-$005B` page-zero gap (cpm22.asm claims only `IOBYTE`(3)/
`TDRIVE`(4)/`ENTRY`(5-7)/`TFCB`($5C)/`TBUFF`($80) there -- grepped, not
assumed). Page zero is safe in a way `$7C00` never was: `TBASE`=`$0100`
is where every program's own code loads, so no compliant program's
buffer math can generate an address below it -- structural, not
conventional, and independent of what `MAXB` reports.

`stage1.asm` loads chunk 1 to a `$7C00` scratch pad (`load_blocks`
works in 512-byte units, far more than the page-zero gap holds) and
`LDIR`s the 38 bytes down to `$0008` just before `JP BOOT_ENTRY` --
safe even though stage1 runs from `org 0`, because that LDIR and the
JP both sit well above `$002D` and the bytes being overwritten are
stage1's own already-executed startup code. `build-boot-image.py`
needed no logic change (chunk 1 is still file offset 0, just smaller);
`CHUNK1/2/3_CKSUM` recomputed (`$0CD5`/`$7473`/`$46D1`).

Verified via disassembly of the assembled `bios.bin`/`stage1.bin`:
the 38-byte trampoline (`enter_bank1` swaps SP + flips + `JP (HL)`;
`leave_bank1` flips back + restores SP + `RET`), all four bank=1 impls
ending `JP leave_bank1` (`$001F`), the four bank=0 caller stubs
(`$F29B`/`$F2A9`/`$F2AF`/`$F2B5` -> `JP enter_bank1` at `$000D`),
`video_blit_impl`'s new leading `LD HL,char_buf` (`$0009`),
`conout_impl`'s `CALL hb_toggle` resolving to the new stub, `BOOT`
still `$F200`, `end` `$FF2D` under the `$10000` ceiling, and stage1's
relocation `LDIR` at `$00C6` (above `$002D`). Clean builds, no
warnings. **Not yet run on hardware** -- next step is reflashing
`boot.img` + `stage1.bin` and confirming (a) normal boot to `A>` +
video/CONOUT still work, (b) `CPYDBG` still completes, and (c) real
`PIP B:x=B:BIGTEST.TXT` now works.

## CONFIRMED ON HARDWARE: both PIP and Zork now work

Reflashed `boot.img` + `stage1.bin` + `stage1.bin`-to-AVR with the
trampoline relocation:

- **`PIP B:TEST7.TXT=B:BIGTEST.TXT` completes** (creates the file,
  `TYPE` back reads correct). Takes ~15-20 min -- expected, not a
  concern: PIP's large double-buffering scheme does a lot of I/O over
  bit-banged SPI on an 8MHz Z80 for a ~300KB file. Correctness is the
  point; throughput is a separate question for much later, if ever.
- **Zork 1 reaches `take sword` without hanging.** This was the parked
  black-screen investigation running across multiple sessions -- same
  root cause as the PIP hang (a memory-hungry program trampling the
  bank-flip trampoline in what it treats as its own buffer space), so
  one relocation closed both.

**`hb_toggle` removed.** It served its full purpose during the hunt
(it's what established `CONOUT` stops being called at a true CPU
lockup, ruling out a video-only fault). It was also the source of the
constant top-left-corner corruption the user saw during normal use.
Gone from `conout_impl` (the `PUSH BC`/`CALL hb_toggle`/`POP BC`), the
bank=0 stub, and `hb_toggle_impl` in the bank=1 region. `vbi_guard`
(the bounded `char_buf` scan in `video_blit_impl`) is kept -- it's
genuinely defensive, costs almost nothing, and is invisible.
`CHUNK2/3_CKSUM` recomputed (`$6FB8`/`$5149`); `bank1_end` `$88BB`,
`end` `$FF22`.

## Input cursor (solid block, glyph $FF)

User added a cursor-block glyph at font position `$FF` in `msxfont.img`
(`fc fc fc fc fc fc fc 00` -- 6x7 block, leaving a 1px gap right and
bottom for cell separation). Hooked into **CONIN**, not CONOUT:
`conin_impl` draws glyph `$FF` at `(cur_row,cur_col)` via the normal
`video_blit` path (new `draw_cursor`, no cursor advance), waits for a
key, then `erase_cursor` (blits `$20`) before returning so CCP's echo
lands on clean video RAM. Cursor therefore appears exactly while the
system waits for input and follows your typing, and costs nothing
during bulk output (Zork text, `TYPE`, `DIR`). `cur_row/cur_col` can't
move during the wait -- only `poll_key` runs. Verified via disassembly.
`CHUNK2_CKSUM` `$769C` (new font), `CHUNK3_CKSUM` `$1672`; `end` `$FF38`.

## Drive B rebuilt (Zork + Turbo Pascal); VT52 terminal in CONOUT

**driveB.img** rebuilt from `drive-b/` (moved there by the user) plus
`PIP.COM` and `CKSUM.COM` (essential CP/M tooling, weren't in the
folder): CKSUM, PIP, TURBO/TINST/TDEBUG (Turbo Pascal 3.0 for CP/M-80),
ZORK1/2/3. `TOUCH.EXE` excluded -- it's an MS-DOS `MZ` executable,
can't run on the Z80. `BIGTEST.TXT` and the `CPYDBG`/`CPYRAND`/`CPYREN`
debug tools dropped (trampoline hunt is closed). All files round-trip
byte-exact; each fits a single directory entry; 592 KiB of 100 MiB
used. `/drive-b/` gitignored (copyrighted binaries, same as the
root-level ZORK entries).

**Keyboard Ctrl**: works. `get_key_event` turns Ctrl + any letter A-Z
into control codes `$01-$1A` (`Ctrl-K` -> `$0B`), which is what Turbo
Pascal's editor needs. Ctrl is keyboard-matrix row 6 col 1 -- same row
as Shift (col 0), which is confirmed working. No key auto-repeat
(holding a key = one event).

**VT52-subset terminal added to CONOUT** so TP's full-screen editor
works (previously CONOUT was a glass TTY that dropped ESC and every
other non-CR/LF/BS control char). Handled:
- `ESC Y <row+32> <col+32>` -- direct cursor address (clamped 0-24 /
  0-79)
- `ESC E` -- clear screen + home
- `ESC H` -- home
- `ESC K` -- erase to end of line (new `eeol_impl` in the bank=1
  region, reusing video_blit_impl's row*640+col math)
- unknown `ESC <letter>` -- swallowed
- everything else unchanged (CR/LF/BS/printable)

`term_state` (0/1/2/3) parser state byte, zeroed in boot_init.
`ESC A/B/C/D` (relative cursor moves) deliberately NOT handled -- TP
positions with ESC Y, not relative moves, and the bank=0 region is
right against its `$10000` ceiling: **`end` is now `$FFCC`, only 52
bytes of headroom**. Future BIOS growth will need to free space or
push code into the bank=1 region. (A first attempt with A/B/C/D
included wrapped past `$10000` -- z80asm silently wrapped `end` to
`$0006` and build-boot-image.py produced a zero-length chunk 3; caught
by the `end < $10000` / non-zero CHUNK3_CKSUM check.)

TINST config for the editor: pick VT52, or custom -- cursor lead-in
`ESC Y`, row then col, offset 32; clear-screen `ESC E`; clear-EOL
`ESC K`. Verified via disassembly (state machine transitions, clamps,
eeol_impl's address math and 8-scanline clear, `JP leave_bank1`).
`CHUNK2_CKSUM $8577`, `CHUNK3_CKSUM $6EE7`. Clean build. Not yet run on
hardware.

## Cursor: destructive block -> non-destructive XOR block

First hardware test of the TP 3.0 editor: cursor moved but "always
erases the character it's over", and moving away then back lost the
line's contents. Root cause: the cursor drew a solid glyph and "erased"
by blitting a space -- fine at end-of-line, but a full-screen editor
positions the cursor over existing text (ESC Y) and never rewrites
cells it thinks are unchanged, so every cell the cursor passed over got
permanently blanked.

Fix: `cursor_xor_impl` (bank=1) -- XOR `$FF` into all 8 scanlines of
the one cell. Self-inverse, so show and hide are the identical call;
hide restores the exact character underneath. `show_cursor`/
`hide_cursor` keep the same idempotent flag gating and register-
preserving wrapper (`CALL enter_bank1` with the return consumed by
`leave_bank1`'s RET, same pattern the old `blit_at_cursor` used). Font
glyph `$FF` is now unused but left in place. `end` still `$FFCC`
(bank=0 net-neutral -- removed `blit_at_cursor`, added `cursor_xor`);
`bank1_end` `$8917`. `CHUNK2_CKSUM $8F07`, `CHUNK3_CKSUM $70DF`.
Verified via disassembly. Also this session: arrow keys mapped to the
WordStar diamond `^S/^E/^X/^D` (were unmapped -> dead in the editor).

Still open from the same test: (1) `ESC L`/`ESC M` (insert/delete line,
which the built-in "Zenith" TINST definition uses) aren't implemented
-- recommended clearing those two fields in TINST so the editor
repaints instead; (2) a keyboard-map question -- backspace was
reported producing 'M' in the editor though it works at the `A>`
prompt, needs a `keyboard-scan-test` run to get the real matrix
positions for the non-alphanumeric keys.

## Turbo Pascal exit crash root-caused + fixed (WBOOT now reloads CCP+BDOS); VT52 ESC L / ESC M implemented

### The crash: quitting Turbo Pascal locked the machine

Reported: quit the TP environment with `Q`, answer `N` to "save?", and
the whole system hangs -- never returns to `A>`.

Root cause, found by disassembling `TURBO.COM` and cross-reading
`cpm22.asm`:

- TP sets its stack pointer to `MAXB` (the word at $0006 = FBASE =
  $E406) and grows it **straight down through CCP's image**
  (`sub_20e6h`: `LD HL,(0006h) / LD SP,HL`). Its editor text buffer
  also spans CCP.
- CCP ($DC00-$E405) ends with six serial-number bytes at `PATTRN2`
  ($E400-$E405), immediately below FBASE. TP's very first few pushes
  land on exactly those bytes.
- On the next command that isn't one of CCP's six built-ins, CCP's
  `UNKNOWN` handler calls `VERIFY`, which compares `PATTRN1` (inside
  CCP's code body, untouched) against `PATTRN2` -- mismatch -> `JP
  HALT` -> `DI / HLT`. Machine dead, no prompt.

This is the risk the `wboot_init` header comment had flagged as "not
addressed yet": our WBOOT was a v1 shortcut that only re-wrote the
page-zero vectors and did `JP CBASE`, never reloading CCP+BDOS the way
the DR 2.2 Alteration Guide specifies. PIP survives the same era
because its stack sits low ($1DF2, inside its own image) and a plain
2-file disk copy fills only its low buffer -- it never writes into
CCP's region. TP's high stack is what makes it fatal.

### Fix: `wboot_reload` -- WBOOT re-reads CCP+BDOS from the boot partition

New `wboot_reload` in `bios.asm`: reads the 11 sectors
($F200-$DC00 = $1600 = 11*512, exact -- CCP+BDOS, stopping right at the
running BIOS) from `RELOAD_LBA` (= 2048+6, hand-synced with
`stage1.asm`'s `CHUNK3_LBA`, same no-single-source-of-truth caveat as
`CHUNK*_LBA`/`OFF`) into $DC00, restoring CCP's code **and** PATTRN2
every warm boot. Best-effort: a failed sector read is skipped, not
retried (a dead card already broke disk I/O). `wboot_init` runs it on
a scratch stack (`sector_cache+512`) because `CCPSTACK` ($E3AB) sits
inside the image being overwritten. `wboot_init` also now zeroes
`cursor_shown` / `term_state` (only `boot_init` did before) so a
transient that exits mid-ESC-sequence or with a half-drawn cursor
doesn't glitch CCP's first output.

To make room in the against-the-$10000-ceiling BIOS region for this:

- **`build_cmd0/8/55/acmd41/58` -> table-driven.** The five near-
  identical `LD`-immediate SD command builders (~141 bytes) became five
  6-byte frames + one shared `LDIR` copy (`build_cmd_copy`, ~63 bytes).
  Frame bytes verified byte-for-byte against the old code by
  disassembly. `build_cmd_copy` does `PUSH BC/POP BC` -- the old code
  only ever touched `A`, and `sdi_acmd41`'s retry counter lives in `B`.
- **`read_raw_sector` factored out of `rd_miss`.** `read_impl`'s and
  `write_impl`'s identical CMD17 single-block-read sequences (and now
  `wboot_reload`'s) all call one routine. Collapsed the old r1-fail
  (return 1) vs data-token-fail (return 2) distinction into a single
  nonzero return -- BDOS treats every nonzero read result the same and
  the split was only ever diagnostic.

Net BIOS size: `end` back to `$FFCC` (52 bytes of headroom), i.e. the
CCP reload + ESC L/M cost was fully absorbed by the two refactors.

### VT52 ESC L / ESC M (insert / delete line)

The TP editor's "Zenith" terminal definition emits `ESC L` (insert
blank line at cursor row, rows below scroll down, bottom row lost) and
`ESC M` (delete cursor row, rows below scroll up, bottom row cleared)
-- a Zenith H19 extension, not base VT52. Previously swallowed, which
left the editor's screen out of sync with reality (the "most of the
line reappears when I type" symptom).

New `lineop_impl` (bank=1): whole-row (640-byte) moves via `LDDR`
(insert) / `LDIR` (delete), then one row cleared. Cursor row/col left
unchanged -- the editor repositions with `ESC Y` afterward. Bank=0
dispatch in `co_esc_cmd`: `CP 'L'`/`CP 'M'` -> load op flag into C,
cursor row into B, `JP enter_bank1`. Shared `row_addr` helper
(A = row -> HL = video_base + row*640) added to the bank=1 region and
`cursor_xor_impl` / `eeol_impl` refactored onto it (they each had the
same 10-`ADD` multiply inline).

`bank1_end` `$896d` (147 bytes headroom in chunk 2). `CHUNK2_CKSUM
$B75E`, `CHUNK3_CKSUM $6DBB`. Clean build, all new code verified via
disassembly (command frames, `read_raw_sector` vs old `rd_miss`,
`wboot_reload` loop bounds, `lineop_impl` LDDR/LDIR address math and
the row=24 edge, bank=0 dispatch JR targets). Not yet run on hardware.

TINST: the built-in "Zenith" definition should now work as-is (ESC Y /
ESC E / ESC K / ESC L / ESC M all handled). Relative moves ESC A/B/C/D
are still not implemented -- TP uses ESC Y.

## Hardware test: ESC L/M fixed the stray 'M'; Backspace-in-editor is authentic TP behavior

Flashed the WBOOT-reload + ESC L/M build. "A lot better." The stray
capital `M` that used to appear in the editor is **gone** -- it was
`ESC M` (delete line) falling through the terminal unhandled and being
printed literally; now that `co_esc_cmd` handles `L`/`M` it's consumed.

Remaining observation: in the TP editor the Backspace key just moves
the cursor left (no delete), while `DEL` does a destructive
delete-left. **This is genuine Turbo Pascal 3.0 behaviour, not a
keyboard or terminal bug** -- verified in `TURBO.COM`'s editor command
table (`l434bh`, file offset $434b-$100): it contains `01 08` (the BS
key) as command entry #2, and that entry's jump-table slot ($43da)
holds `66 39` = `$3966` -- the *same* handler as entry #1, `^S`
(cursor-left). TP 3.0 deliberately binds `^H`/BS to cursor-left; `DEL`
($7F) is the only delete-left key. WordStar-era convention.

Our keyboard/terminal are delivering the right codes ($08 for BS, $7F
for DEL, both confirmed working correctly at the `A>` prompt where
BDOS's own `BACKUP` does the visual erase for $08 and echoes a rubout
for $7F). No change made. If a single "Backspace deletes everywhere"
key is wanted later, the only options are (a) use DEL in the editor,
(b) patch TURBO.COM's command table so $08 -> the delete handler, or
(c) map the BS key to $7F in the BIOS and accept old-teletype
rubout-echo at the CP/M prompt -- none clearly better than leaving it.

## CONFIRMED ON HARDWARE: Turbo Pascal exits cleanly to A>

User: "I can also confirm that TURBO does not crash on exit." The
`wboot_reload` fix (WBOOT re-reads CCP+BDOS from the boot partition
every warm boot) works -- quitting TP with `Q` / `N` now returns to the
`A>` prompt instead of locking the machine on CCP's `VERIFY` -> `DI/HLT`.

This closes the last open item from the TP bring-up. Full editor is
usable (VT52 + ESC L/M terminal, cursor keys, Ctrl, non-destructive
cursor); DEL is the delete-left key (TP 3.0 convention); exit is clean.

Also still-good on this same build: the SD refactor (`read_raw_sector`
shared by read/write/reload, table-driven `build_cmd*`) didn't regress
disk I/O -- CP/M boots, drives A and B both work, TP loads/saves.

## Autoboot: stage1.bin baked into AVR flash, selected by a PD0 (RXD) strap

The AVR no longer *has* to be driven from a serial terminal to bring the
Z80 up. A copy of `firmware/z80-boot-rom/cpm/stage1.bin` (the CP/M
bootstrap, 3418 bytes incl. its embedded font) is now compiled into the
AVR flash image and can be autobooted with no host attached.

**Mechanism (deliberately minimal -- `rom_emu_run()` and all the
WAIT / `wait_rel` / magic-address machinery are byte-for-byte
unchanged):**
- `tools/bin2c.py` turns `stage1.bin` into `firmware/avr-1284p/src/stage1_rom.h`
  -- `static const uint8_t stage1_rom[] PROGMEM` + `STAGE1_ROM_SIZE`, plus
  a `_Static_assert(<= 8192)` so an over-8K stage1 is a compile error, not
  a silent address-wrap. Generated file is gitignored (pure derived
  artifact; the AVR build now needs `z80asm`, already a project dep).
- `firmware/avr-1284p/Makefile` recurses into `../z80-boot-rom/cpm` for
  `stage1.bin` (FORCE idiom -- sub-make every build, but the `.bin` mtime
  only moves when `stage1.asm` changed, so the header + `monitor.o` stay
  incremental) and regenerates the header via `bin2c.py`.
- `monitor.c` `start_from_stage1()`: `memcpy_P(rom_buf, stage1_rom, ...)`
  (~1.6 ms, Z80 still in reset) then the *existing*
  `rom_emu_run(rom_buf, ROM_BUF_SIZE-1)` + `video_run()` on MAGIC. Prints
  the embedded size + CRC16 first as a staleness check against the SD
  build.
- New `sb` monitor command = `start_from_stage1()` on demand, for testing
  the embedded blob with a terminal attached.

**Boot-mode selector -- PD0 / RXD strap** (chosen over an EEPROM flag: no
fuse change, survives every reflash, "laptop plugged in = monitor" falls
out automatically):
- `main.c` enables PD0's internal pull-up, waits 20 us, reads it *once*
  before `usart_init()`, drops the pull-up, passes a bool to
  `monitor_run(uint8_t autoboot)`.
- Hardware: a permanent **~3.3 k (2.2 k-4.7 k) resistor, RXD pin -> GND**.
  No serial adapter driving the line -> PD0 low -> autoboot. Adapter
  connected (push-pull TX idles high, ~150-300 ohm out, overrides the
  resistor) or bare pin -> PD0 high -> monitor.
  Divider vs the worst-case 20 k internal pull-up: 5 V*3.3/23.3 ~= 0.71 V
  < V_IL 1.5 V. Datasheet Atmel-42719C ("Reading the Pin Value"): PINxn
  readable regardless of DDxn / RXEN0; `RPU` 20-50 k.
- Escape hatch once the strap is fitted: connect the serial adapter and
  power-cycle. The `rom_emu_run` keypress-abort is only reachable during
  stage1's brief ROM->SRAM copy (it reads `$3FFF` before touching the SD
  card, `stage1.asm:229`), same as today's `s`.

**Build result:** clean `make -C firmware/avr-1284p`; `.text` 8938 ->
12974 (9.9 % of 128 K); the full 3418-byte `stage1.bin` verified present
byte-exact in the linked flash image (`avr-objcopy -O binary` + `find`).
Incremental rebuild confirmed a near no-op.

**CONFIRMED ON HARDWARE** (user, with the ~3.3k RXD->GND pull-down
fitted): USB-serial adapter *not* plugged into a PC -> power-on -> the
Z80 boots, video generation starts automatically, CP/M comes up to the
prompt, no host involved. Adapter plugged into the PC -> power-on -> no
video, normal monitor prompt on the serial terminal, and the existing
`x` (upload stage1.bin) + `s` path still works. Both strap directions
behave exactly as designed.

## WBOOT now preserves the logged drive across warm boot

User noticed: `B:`, run a transient, exit -> prompt back at `A>`.
`wboot_init` hardcoded `LD C,0`. Real CP/M 2.2 passes page-zero byte 4
(TDRIVE, BDOS's own `(uuuudddd)` record) in C to CBASE/COMMAND;
`wboot_reload` / `set_page0_vectors` leave byte 4 alone so it survives.
Fix: `wboot_init` `LD C,0` -> `LD A,(4) / LD C,A` (cold `boot_init` keeps
`LD C,0` -- byte 4 is uninitialised at cold boot). +2 bytes,
CHUNK3_CKSUM $6DBB -> $7060. Same class as the earlier CCP-reload gap.
**CONFIRMED ON HARDWARE**: CP/M retains the selected drive after running
a program.

## Knight Lore port started -- Phase KL-1 (static room render, not yet hardware-tested)

New experimental sub-project: porting *Knight Lore* (1984, Ultimate Play
the Game)'s isometric engine to this CP/M 2.2 system, working from a
third-party ZX Spectrum SkoolKit disassembly the user dropped into
`zx-spectrum-games/` (gitignored, nested git clone, not project source --
tcdev's disassembly, skool-converted by Michael R. Cook). Real precedent
exists: a 2020 hobbyist ("Habi Soft"/habisoft.com -- confirmed, despite
the name, NOT a 1980s publisher) ported Knight Lore's Amstrad CPC edition
to the classic Amstrad PCW (also Z80/CP/M, monochrome, paged video RAM),
using a broadly similar cross-assemble-and-transfer workflow to this
project's own.

**Data format, reverse-engineered directly from the disassembly's own
code** (not guessed -- traced `retrieve_screen`/`find_screen`/
`found_screen`/`next_bg_obj*`/`next_fg_obj*`, `$D3C6`-`$D4F8`, and
`calc_pixel_XY` at `$D6C9`, byte by byte): room records (id, size, attr
-> room_size_tbl index), a background-object chain (index -> a list of
absolute 8-byte placements terminated by a zero sprite byte), a
foreground "block/count + packed-nibble-xyz" list resolved through
`block_type_tbl`, and the isometric projection itself
(`pixelX=X+Y-128`, `pixelY=((Y-X+128)>>1)+Z-104`, pure arithmetic, no
Spectrum coupling). **New tool `tools/kl_extract.py`** parses the real
`.skool` file and decodes this mechanically -- verified against room 0:
33 objects, architecturally sensible (two archways, a rectangular wall
perimeter, a 3x3 block platform cluster), and one independent
cross-check landed exactly: block-index `$0A` resolved to sprite `$B5`
(181 decimal), matching the disassembly's own comment "sprite b5
(fire)" verbatim.

**Two things flagged as inferred-not-proven** (documented in
`knight-lore/README.md` and the extractor's own docstring, not silently
assumed): the exact repeat semantics of a placement's `count>1` field,
and whether `block_type_tbl` targets are chained multi-record lists
(inferred by analogy with the confirmed background-object chain, and
because the "block" record's own trailing zero byte is otherwise
unexplained).

**Rendering**: chose native 1:1 pixel scale (Spectrum canvas 256x192 vs.
this system's 640x200), centered (192px/24-byte horizontal offset, 4px
vertical) -- both cheap since the new blit routine addresses raw
scanlines directly, not the BIOS's 8x8-cell text helpers. At native
scale the sprite bitmaps need no re-authoring, only mechanical
extraction. Centering leaves two full-height 192px/24-column side panels
free for a future text-based status/inventory display.

**Zero `bios.asm`/`stage1.asm` changes needed** -- the key design
finding: this system's `enter_bank1`/`leave_bank1` trampoline ($000D/
$001F) accepts a target address anywhere, not just >=$8000, because
$0000-$7FFF is bank-invariant. So the whole masked-sprite-blit routine
lives entirely inside the port's own `.COM` (`firmware/z80-boot-rom/cpm/
knight-lore/kl.asm`), calling the *existing* trampoline exactly the way
`bios.asm`'s own `eeol_impl`/`lineop_impl` do, just relocated. (Noted:
those two addresses are bios.asm-internal implementation details today,
not a formally documented external API -- stable across this session's
last several BIOS revisions, but worth hardening if more ported programs
come to depend on them.)

Built and disassembly-verified (this project's own standing practice):
`kl.com` assembles cleanly, the projection arithmetic and the masked
shift-composite blit match their intended design exactly when read back
out of the compiled binary. Round-trip-verified onto `driveB.img` via
`cpm_put.py import-dir` (byte-exact, block 45, dir slot 26, alongside
the existing Zork/Turbo Pascal/PIP/CKSUM content, undisturbed).

**Not yet run on real hardware.** Roadmap (input, collision, room
transitions, all 127 rooms, sound) deferred to later phases once this
one is confirmed on the bench.

## Knight Lore Phase KL-1 confirmed on hardware (with two expected, documented gaps)

After the row-advance fix: `KL.COM` renders **recognizable Knight Lore
artwork** -- real tiles/sprites from the extracted room 0 data, not
garbage -- and the system recovers cleanly afterward (keypress -> warm
boot -> `B>` -- drive preserved, fully interactive).

Diagnosed via `KLTEST.COM` first (round 2, unambiguous shapes): a solid
rectangle byte-aligned and shifted both rendered as clean, correctly-
sized solid blocks -- confirms the shift/spillover/masking logic is
sound. Bit convention cross-checked against `msxfont.img` itself (the
letters L/F/P decode correctly bit7-first) -- bit7=leftmost is the
right convention and matches what the blit code already assumed.

Two things the user noticed are real but **expected, not bugs**:
- **"Vertically stretched" tiles**: this system's 640x200 framebuffer
  has non-square pixels (~0.42:1 width:height on a similar-aspect
  display), whereas the Spectrum's native 256x192 canvas is square-
  pixel by design (256x192 over a 4:3 CRT). Phase KL-1 renders at
  native 1:1 pixel scale with no aspect correction (a deliberate
  simplification, not accounted for at design time) -- Spectrum art
  will always look vertically stretched here unless a future pass adds
  aspect-ratio scaling.
- **"Not the first level"**: there is no such thing -- verified in the
  disassembly's own `main` routine ($AF88): it explicitly calls
  "randomise player start location" ($D1B1) on every new game. Room 0
  (an arbitrary internal id, not a designated "level 1") is exactly as
  valid a choice as any other room.

**Still open, unconfirmed**: the "jumbled" look is most likely the
*other* known Phase KL-1 gap -- no Z-order/occlusion sorting is
implemented yet, objects draw in extraction order rather than the
original's back-to-front painter's-algorithm resolution -- but the
extractor's two flagged inferred-not-proven mechanisms (`count>1`
repeat semantics, `block_type_tbl` chaining) could also be contributing
real placement errors. Not yet distinguished between the two.

## Knight Lore data decode: proven correct via real Z80 emulation (found + fixed a real bug)

Following the "tiles don't line up" report, verified the extractor
against ground truth instead of continuing to reason about it by hand:
installed `z80` (PyPI, github.com/kosarev/z80 -- a real, cycle-accurate
Z80 core), assembled the disassembly's OWN `retrieve_screen` routine and
its full dependency chain ($D3C6-$D50D, 213 instruction lines) straight
from the skool file's instruction text with `z80asm` (every operand in
the disassembly is already a literal address, so this needed no label
resolution -- just strip the address/comment columns and add one `org`),
spliced the resulting 328 bytes into a full 64K memory image built from
`kl_extract.py`'s own `load_bytes()`, and **actually executed the real
game's own room-decoding code** with a fake "player" object's screen
field set to the room under test, breakpointing right after all real
objects for that screen are written.

Diffed the result against `kl_extract.py`'s Python decode for room 0:
**found a real bug** -- `block_lo` (the index into `block_type_tbl`) was
computed as `(byte>>2)&0x1F`, one bit short of the real code's
`RRCA;RRCA;AND $3E`, which is `(byte>>3)&0x1F`. This silently pointed
one `block_type_tbl` slot early for every placement using the `count>1`
repeat mechanism, corrupting sprite/width/depth while leaving position/
height/flags coincidentally correct -- exactly why it wasn't obvious
from the room's rendered shape alone (16 of room 0's 33 objects were
affected: sprite 176/181 instead of the real 7/91, with real 8x8 block
dimensions reported as a wrong 6x6). Fixed; **all 33 objects in room 0
now match the real CPU's output exactly**, and four more rooms (1, 8,
33, 34) were spot-checked the same way with zero diffs. The `count`
repeat mechanism and the `block_type_tbl` chain inference -- both
flagged as "inferred, not proven" until now -- are also fully confirmed
correct by this same run (both were exercised by the rooms tested).

Reloaded the corrected `KL.COM` onto `driveB.img` (round-trip verified).
Two things reported on the previous hardware run remain genuinely
expected, unrelated to this bug (already logged above): the vertical
aspect stretch (non-square pixels, no scaling implemented), and no
Z-order/occlusion sorting yet (Phase KL-1 draws objects in extraction
order, not back-to-front) -- the "jumbled" look may still owe something
to the latter even with correct data. Not yet re-tested on hardware
with the fix.

## Knight Lore: sprite H/V-flip implemented + emulator-verified

After the block_type_tbl fix, room 0 still didn't resemble a real room
("recognisable tiles... does not resemble a room"). Found the missing
piece by reading further in the disassembly: the real engine calls a
flip step (`flip_sprite` $D6EF -> `vflip_sprite_data` $D865 -> its
H-flip half at $D8A2) before drawing *every* sprite, driven by each
object's own `flags` bits 6 (Hflip, $40) and 7 (Vflip, $80) -- e.g. the
same "arch" sprite (id 2/3) is reused for both the room's N-S and E-W
archways purely via this flip, not two separate sprite bitmaps. Phase
KL-1 extracts `flags` but had never applied it.

Rather than replicate the original's stateful, in-place, shared-buffer
mutation (a Spectrum memory-saving trick with no reason to carry over
here), `kl_extract.py` now does the flip once per (sprite, hflip, vflip)
combination at **Python build time** (`apply_flip`), emitting each
needed variant as its own `kl_sprite_<id>_h<0|1>v<0|1>` table, with each
object record pointing directly at the correct one -- no runtime flip
code needed in `kl.asm` at all.

Verified against the real CPU rather than trusted from reading the
code: assembled `build_lookup_tbls` ($D69E, builds the real $F100-$F1FF
bit-reversal table used by the Hflip transform) and the full flip
routine chain through `$D8DD`, ran them under the same `z80` emulator
setup used for the room-data verification. The real $F100-$F1FF table
came back byte-for-byte identical to Python's `_BITREV`, and running
the actual `flip_sprite` on a real sprite (id 15) with all four
flag combinations (none, H, V, H+V) matched `apply_flip`'s output
exactly in every case. (One dead end on the way: an incomplete
`build_lookup_tbls` run -- its very long $F200+ shift-table-building
tail wasn't needed and wasn't given enough emulated ticks to finish --
left stale state that briefly looked like the flip was zeroing sprite
data; resolved by populating the bit-reversal table directly instead of
depending on that routine's unrelated tail finishing.)

Reloaded the corrected `KL.COM` onto `driveB.img` (16 sprite variants
for room 0, round-trip verified). Not yet re-tested on hardware.

## Knight Lore: still "no change" after the flip fix -- ruled out stale SD card, added approximate Z-order

User confirmed the fix genuinely reached the card (imaged from two
different computers -- not the known "dev laptop doesn't flush SD
writes" issue this session hit earlier in Phase 12). "No change at all"
with a verified-correct fix pointed at the remaining known gap
dominating the whole picture: **no Z-order/occlusion sort** -- Phase
KL-1 has always drawn objects in raw extraction order, so overlapping
isometric blocks paint over each other arbitrarily regardless of
whether their individual position/orientation is now correct.

The real algorithm (`calc_display_order_and_render` $CEBB /
`process_remaining_objs` $CEC3) does genuine pairwise 3D bounding-box
occlusion resolution between every object pair -- a real topological
sort, not a simple key sort, and (unlike the last two fixes) would need
`print_sprite`'s own self-modifying, SP-as-data-pointer JIT-compiled
blit code running correctly to trace via emulation, a much bigger lift.
Tried the cheap standard approximation first: `kl_extract.py`'s new
`approx_depth_sort()` sorts objects by their own projected screen Y
(`calc_pixel_XY`'s formula, reproduced in Python) and draws back-to-
front. Explicitly flagged in the code as an approximation, not the real
algorithm -- cheap to test before investing in the exact pairwise
algorithm (which would need its own emulator-trace verification pass).

Also adopted a process improvement (user's suggestion): stop overwriting
`KL.COM` on `driveB.img` each iteration (which required manually erasing
the old directory entry first) -- use incrementing filenames (`KL2.COM`
this round) instead, so a stale card is trivially distinguishable from a
fresh one by name alone, without needing the erase dance or a 2-machine
imaging cross-check.

`KL2.COM` loaded onto `driveB.img` (round-trip verified) alongside the
still-present `KL.COM`. Not yet tested on hardware.

User tested `KL2.COM` on real hardware: "the screen output is the same
as the previous attempts. ie. no change" (system returned cleanly to
`B>` afterward, `DIR` confirmed `KL2.COM` genuinely ran -- not a stale
load). At this point the only way to make further progress without
guessing was to stop reasoning about the disassembly by eye and
actually *run* the port's own compiled code and look at pixels, per the
user's own suggestion: "given you have a python z80 emulator, how hard
is it to extend it into a simple emulator of this platform with a
640x200 linear pixel map. you could then run things in the emulator,
screenshot and check."

Built `kl_hw_emu.py` (scratchpad, not part of the repo): loads the
actual compiled `kl.bin` at $0100, loads the real 38-byte BIOS
trampoline (`enter_bank1`/`leave_bank1`, extracted from `boot.img`'s
first 38 bytes) at $0008 so `CALL $000D` lands on real code instead of
wandering into empty memory, runs it under the real `z80` PyPI CPU core
to the `draw_done` breakpoint, and dumps the emulated $C000 framebuffer
as a 640x200 PNG. Two test-harness bugs surfaced and were fixed along
the way (both in the scratchpad script, not in `kl.asm`): a misdiagnosed
non-issue around breakpoint/CALL-skip stack handling, and a real bug --
setting `pc` directly to `draw_loop` skipped over `start:`'s own
`LD HL,kl_room_objects+1`, leaving `HL` uninitialized and making
`draw_loop` read garbage as if it were object records (this fully
explains the "noise bands" seen in the very first screenshot attempt).
Fixing `HL` alongside `pc` made a companion trace tool
(`kl_trace.py`) show all 33 room-0 objects reading correct, sensible,
non-repeating data with 100% matching pixel/row/col/shift math against
an independent Python recomputation -- conclusively proving `kl.asm`'s
own compiled logic (data decode, flip selection, projection, blit
addressing) is correct.

Re-ran `kl_hw_emu.py` with both fixes applied: clean run, stopped
exactly at the expected breakpoint, 1696/16000 nonzero framebuffer
bytes. **The resulting screenshot visually matches the independent
Python reference render (`kl_room0_reference.png`, built by
reimplementing the same blit/composite algorithm in pure Python against
the same twice-verified-correct extracted data) shape-for-shape**: same
main block cluster, same disconnected U-shaped archway, same scattered
brick fragments at the bottom -- both renders show recognizable Knight
Lore brick art that doesn't yet cohere into a legible room. This is the
conclusive result the whole investigation was narrowing toward: **the
actual Z80 code path is correct end-to-end** (data extraction, flip
selection, projection math, masked blit, bank=1 addressing all verified
against a real Z80 CPU or matching a from-scratch Python
reimplementation); the "doesn't look like a room" complaint is fully
explained by the one gap that was flagged from the start and
deliberately deferred -- **no real Z-order/occlusion sort**.
`approx_depth_sort()`'s simple projected-Y sort is not a substitute for
the original's genuine pairwise 3D bounding-box occlusion algorithm
(`calc_display_order_and_render` $CEBB), which is why `KL2.COM` looked
no different from `KL.COM` on hardware despite being correct data drawn
in a different order -- a Y-sort doesn't fix objects overlapping the
*wrong* silhouette, only which one paints last among vertically-ordered
ones.

Phase KL-1 conclusion: everything except the real occlusion algorithm is
now verified correct via real Z80 CPU emulation, not just reasoned
about. Implementing `calc_display_order_and_render`/
`process_remaining_objs` faithfully is a larger, separate piece of work
(their dependency on `print_sprite`'s self-modifying JIT-style code
means it can't be traced/verified as cheaply as the fixes so far) --
scoped as the next concrete step rather than attempted speculatively.

## Phase KL-2: real Z-order/occlusion (KL3.COM)

Scoped in `kl-zorder-plan.md`, then implemented per that plan: ported
`calc_display_order_and_render` ($CEBB)/`process_remaining_objs`
($CEC3) to Python (`real_depth_sort` in `kl_extract.py`) rather than to
Z80 runtime code, since Phase KL-1/KL-2 have no moving objects -- a
room's correct draw order is a fixed value, computed once at build
time, same as `approx_depth_sort` already did. Avoided needing
`print_sprite`'s self-modifying JIT blit code entirely: verified against
a real Z80 CPU by assembling the real routine straight from the skool
text (`zorder_a`/`zorder_b`/`get_ptr_object`/`jump_to_tbl`, four
contiguous code ranges, no label resolution needed) and stubbing the
real blit call ($D704) with a breakpoint that just records which object
index was being rendered and manually pops the return address (no Z80
code needed for the stub at all -- the breakpoint fires before $D704's
real bytes would execute, and the `CALL` already pushed the return
address, so "returning immediately" is just popping it into `pc`).

Result: **byte-for-byte identical render order to the real CPU for all
5 rooms this project has decoded data for** (0, 1, 8, 33, 34 -- object
counts 29-36), including the dependency-chain ("defer") mechanism
(observed chains up to 5 deep in room 33, safely under the real 8-slot
`render_list` limit) and the "already deferred once, break the cycle"
path. None of the 5 rooms' data happens to trigger the `objs_coincide`
(fully-overlapping-bounding-box) special case, so that branch's visual
side effect (twinkle-sprite substitution) is treated as a no-op
(matches `continue`) rather than implemented -- flagged in the code in
case a future room's data exercises it.

Rebuilt with `real_depth_sort` replacing `approx_depth_sort`; screenshot-
checked in the hardware-faithful emulator before touching real hardware
(per the now-established workflow). The new screenshot is **not**
identical to the old approximate-sort one -- 806 of 128000 framebuffer
bytes differ, confirming the reordering does have a real, visible
effect on which object paints on top where silhouettes overlap -- but
the room still reads as scattered brick fragments plus a floating
U-shaped archway, same overall impression as before.

Before assuming a further bug, fetched a real Knight Lore screenshot
(zxart.ee) to check what the original actually looks like, since
neither of us had a ground-truth reference in view up to this point.
**The real game's own rooms look substantially like this**: brick walls
of varying height forming a stepped platform, a free-standing U-shaped
archway that isn't flush against the main structure, tufts of
decoration on top of walls -- Knight Lore's isometric rooms are
genuinely built from separate chunky pieces with real gaps between
them (you jump between platforms), not one seamless solid shape. This
substantially undercuts the working assumption that "doesn't look like
a room" meant a further undiscovered bug -- it may simply have been an
uncalibrated expectation of what this game's rooms look like. `KL3.COM`
loaded onto `driveB.img` (cpm_put.py reported the expected 3697-byte,
single-file write); hardware confirmation with the real screenshot
available for side-by-side comparison is the next concrete step, not
another round of blind "does it look different" guessing.

## Testing the "is the display upside down" hypothesis

User tested `KL3.COM` on hardware: "It looks much the same as previous
attempts. One thought I had is whether the display is simply upside
down. The arch bits look more like U's or V's" -- a sharp, specific,
testable hypothesis (a real archway should read as an upside-down U/an
arch shape, not a valley).

First check: the AVR firmware's own video generation
(`firmware/avr-1284p/src/sync.c`) resets `video_addr` (the framebuffer
read offset) to 0 at `ACTIVE_LINE_START` and only increments it as the
frame's `line` counter advances -- and PAL/CRT scanning is inherently
top-to-bottom as `line` counts up. This rules out a hardware-level
global flip: framebuffer offset 0 is provably the physically topmost
scanline, not the bottom.

Second check, informal: flipped the existing `kl_hw_screenshot.png`
vertically as a quick visual experiment -- the result looked more like
a recognizable arch. This was suggestive but not proof (a raster-level
flip conflates "sprite placement should mirror" with "sprite bitmaps
should read in reverse row order" and could easily just be pattern-
matching bias), so it prompted a decisive follow-up rather than being
taken as confirmation.

Decisive test: rather than keep hand-tracing `print_sprite`'s
self-modifying JIT code (error-prone, per this project's own standing
practice of preferring execution over manual tracing), built a harness
that runs the **actual, unmodified, real disassembled engine** end to
end -- `retrieve_screen` (real) to populate `graphic_objs_tbl`,
`calc_display_order_and_render`/`process_remaining_objs` (real, not
stubbed this time) for Z-order, and `calc_pixel_XY`/`flip_sprite`/
`print_sprite`/`calc_vidbuf_addr` (all real) to actually render every
object into the real linear off-screen bitmap buffer at $D8F3 -- zero
port code involved anywhere in this pipeline. Two harness bugs surfaced
and were fixed along the way (both mine, not the game's): the stack
pointer was placed at $FFF0, colliding with `build_lookup_tbls`'s own
$FF00-$FFFF table-writing range and silently corrupting the return
address; and the first code-extraction pass stopped at $D826 without
realizing `flip_sprite` falls through into `vflip_sprite_data`/the
Hflip routine at $D865-$D8DD, well past that cutoff, so the CPU ran off
into unassembled (zero/NOP) memory. Also independently confirmed, as a
side effect of finally executing it: `build_lookup_tbls`'s real
$F100-$F1FF bit-reversal table matches this project's own Python
`_BITREV` table byte-for-byte.

Result, with both fixed: the real engine's own render of room 0's
distinctive cube structure comes out in the **same orientation** as
this port's `KL3.COM` render, not flipped -- and a pixel-level
comparison against the port's own screenshot (cropped to the same
256x192 native region) found 93% of the real engine's own lit pixels
land on a lit pixel in the port's render at the exact same coordinate
(4224/4526). The real-engine render is incomplete (881/6144 nonzero
bitmap-buffer bytes vs. the port's 1697/16000 -- a few objects with
edge-case shift amounts or screen-bottom clipping didn't render cleanly
in this quick harness, not worth chasing further since the question at
hand is orientation, not full fidelity), but the coincidence rate on
what *did* render is strong, direct evidence against a vertical-flip
bug anywhere in the pipeline.

**Conclusion: no vertical flip found, in the hardware, in the port, or
in the real engine's own rendering.** The earlier "flipping the image
looks more like an arch" observation was most likely pattern-matching
bias, not a real signal. The room's remaining "doesn't cohere" quality
is still most consistent with the real-screenshot-comparison finding
above: Knight Lore's actual rooms are built from separate, gapped
chunks, not a smoking-gun bug. Reported back to the user with this
finding plus the real-engine-render screenshot as evidence, rather than
another guess.

## A real positional bug found, then a second real reference: the PCW port

Re-examined the full 33-object fuse render against our port's render at
the pixel level (not just visually): found the real engine draws
content reaching all the way to native y=0, while our own extracted
object list's topmost item starts at y=47 -- a genuine, unexplained
discrepancy. Attempts to isolate single objects for cleaner debugging
(building a `.sna` with just one entry in `objects_to_draw`) produced
three mutually-inconsistent results across three different test
methods, indicating the single-object-isolation technique itself has a
methodological flaw (most likely: truncating the list breaks some
order/state dependency in `calc_display_order_and_render` that the full
33-object list doesn't hit) rather than reflecting a real per-object
bug -- flagged as unresolved, not chased further given the cost so far.

At this point the user pointed at a much stronger source of ground
truth already in the repo: `Knight Lore.dsk`, a 2020 Amstrad PCW port
(Habi, per its own title screen) -- a real, shipped port that already
solved the exact problem this project is solving (adapt the isometric
renderer from the Spectrum's screen memory to a different, linear
framebuffer -- PCW's is 720x256 monochrome, non-interleaved, closer in
spirit to this project's own 640x200 buffer than the Spectrum's own
screen ever was).

Extracted it directly (no `cpmtools` available, no root to install it):
wrote a from-scratch Extended-DSK parser plus a PCW-CP/M 180K directory/
allocation reader, pulled `KNIGHT.EMS` (loader) and `PG0-PG3.BIN` (four
16K banked pages -- the PCW used the same page-per-16K-bank approach as
this project's own hardware), reverse-engineered the loader's own RLE
scheme from its disassembly, and decompressed all four pages to real,
runnable memory content. Confirmed accuracy by finding the loader's own
`JP $C400` entry into the paged bank and verifying real, sensible code
starts exactly there.

Rather than reverse-engineer the PCW port's screen code cold (a
substantial undertaking with no existing disassembly to build on,
unlike the Spectrum version), ran the actual port: the user had a
working `joyce` PCW emulator (`joyce-2.4.2`, `bin/xjoyce`) already
compiled. Got it running headless (Xvfb + `SDL_VIDEODRIVER=x11` --
without that env var the SDL1.2 build silently created no window at
all under Xvfb; also needed a minimal window manager, `fluxbox`, running
*before* launch for keyboard focus/input to reach the app -- synthetic
key events via `python-xlib`'s XTest extension otherwise went nowhere)
and captured real screenshots via ImageMagick's `import -window root`.

Result: the real port boots to its own title screen ("PCW PORT (c) 2020
HABI"), through the real Knight Lore control-config menu, into actual
gameplay -- two different rooms captured (the game randomises start
position, confirmed independently earlier this session), **both
showing archways rendering as proper right-side-up domes**, never a
valley/U-shape, and both reading as coherent, legible rooms with
correctly composed brick walls, corner pieces, and furniture (tables in
one room). This independently confirms, via a second completely
different real Z80 codebase, exactly what the fuse/Spectrum-original
render already showed: our port's "U"-shaped archway is a real,
confirmed rendering bug, not a display-convention question or a
misjudged expectation of the game's style.

Net position: two independent, real, working references now agree on
what correct looks like. The specific mechanism inside our own
`kl_extract.py`/`kl.asm` pipeline that produces the wrong shape is still
not pinned down (the y=0 discrepancy investigation above was inconclu-
sive due to the single-object isolation issue) -- next step is to
resume that comparison using only full-room renders (no isolation) now
that there's no doubt about what the correct target looks like.

## Instrumenting joyce itself to locate the PCW port's blit routine

User asked two things: whether joyce could be used (directly, or via
source modification) to narrow down the PCW port's rendering code, and
how feasible patching that code to target this system's own 640x200
screen would be. Answered both by actually doing the first.

joyce's Z80 core (`joyce-2.4.2/bin/Z80j.cxx` + `ImcZ80j.hxx`) turned out
to have a single, clean hook point: `store(addr, val)`, a small inline
function every Z80 memory write passes through (`PCWWR[addr>>14][addr]
= val`), already textually included into `ImcZ80::mainloop()`'s opcode
dispatch via `z80ops.hxx`. Added:
- A memory-write tracer in `store()`: logs `(PC, logical addr, value,
  physical offset into the 2MB PCWRAM pool)` for every write, gated by
  a frame countdown (`g_traceFramesLeft`) so it can be bounded to a
  specific short window instead of dumping the whole run.
- A one-shot **file-based trigger** (`/tmp/joyce_trace_trigger`) instead
  of a hardcoded frame number, checked once per frame -- lets an
  external script fire tracing at exactly the right real-time moment
  (right before sending a movement keypress that causes a redraw),
  which a frame-count guess never could have hit reliably.
- A one-shot **live memory dump** of all 4 currently-mapped 16K bank
  windows at trigger time, so any PC seen in the trace can be
  disassembled against the *actual* runtime bank mapping rather than
  the static PG0-3 dump from the DSK (gameplay re-pages banks
  differently from the loader's own initial layout).
- A targeted **register snapshot** logged whenever PC reaches a
  specific address of interest (added after the first pass located
  that address), giving the exact AF/BC/DE/HL/IX/IY/SP at entry.

This worked cleanly on the first real attempt. Filtering the write
trace for non-zero values (all-zero writes are the sprite-wipe/erase
pass, not interesting) landed directly on a real masked-blit routine at
**$C200** with no blind pattern-guessing -- a night-and-day difference
from the earlier static-analysis attempts on the Spectrum disassembly.

What's now known about $C200: it's **self-modifying** (a computed-jump
trick via `JP (IY)`, IY patched by code at $c203-$c20e based on input
parameters -- structurally similar in spirit to the Spectrum original's
own `print_sprite`, but a distinct implementation) and **column-major**
(the unrolled inner loop is `LD A,(DE); INC E; LD (HL),A; ADD HL,BC`,
walking *down* one column across rows via a fixed-stride `ADD HL,BC`,
then advancing to the next column -- the opposite structure from this
project's own row-major `kl_blit_impl`). Traced two supporting helper
routines: $3186 (`HL >>= 2; HL += $9000` -- a row-to-address conversion,
this port's equivalent of `calc_vidbuf_addr`, revealing the linear
off-screen buffer's own base address, $9000) and $3195 (a further
address refinement using a word-lookup table at $FB80 indexed by one
coordinate byte, combined with a masked/carry-adjusted transform of
another -- not yet fully decoded).

Calling convention, partially decoded via the register-snapshot hook:
`IX` stays constant across different objects ($00F3, evidently a fixed
workspace pointer, not a per-object parameter -- notably different from
both the Spectrum original's and this project's own convention of
`IX`/an object pointer carrying per-object data). `DE` and `HL` vary
meaningfully between different sprite draws (most likely a sprite-data
source pointer and a coordinate-derived value respectively); `BC`
carries what look like packed dimension bytes ($1807 / $1007 seen for
two different objects). `IY`'s value at entry is leftover self-modified
state from the routine's own previous invocation, not a real input --
initially misread as a possible parameter until the pattern (values
landing inside $C200's own address range) gave it away.

Conclusion on the two original questions: **joyce-based debugging is
not just feasible but demonstrably the most effective technique used on
this whole investigation so far** -- real answers in a few instrumented
runs versus hours of static disassembly guessing. **Patching $C200 to
target this system's screen is plausible but not "simple"**: it is a
self-contained, single ~100-byte routine (tractable, unlike the
Spectrum's more sprawling `print_sprite`+lookup-table machinery), but
its column-major structure, self-modifying jump, and not-yet-fully-
decoded parameter semantics ($3195's table-based row addressing
especially) mean a direct byte-patch isn't ready to attempt yet --
doing so safely needs the parameter convention pinned down first,
which is a bounded, continuable task now that the tracer exists.

## Following up: $3195's table, and why patching isn't actually a shortcut

Continued decoding with the same tracer. Added a physical (bank-
independent) `PCWRAM` dump taken *after* the traced writes complete
(`Z80j.cxx`, alongside the existing logical-window dump taken at
trigger time) -- needed because the write trace's physical offsets
turned out to span 100-80000, too wide to be one small per-sprite
buffer, and the two dumps needed to agree on what's actually at those
addresses regardless of which bank happened to be paged in at either
moment.

Tried the fast empirical route first: render the suspected buffer
region (physical and logical, several candidate row-strides: 8, 16, 22,
28, 32, 45, 64, 90, 128) directly as a 1bpp bitmap and look for
something resembling the known room screenshot. All strides produced
noise, not a coherent image -- the expected result once the routine's
column-major nature is taken seriously: consecutive bytes in memory
are consecutive *rows of one column*, not consecutive x-positions in a
row, so no row-major stride could ever line the pixels up correctly.

Went back to register-level tracing instead. Confirmed precisely: right
before `CALL $3195`, `C = (IX+$16)` and `B = (IX+$17)+23` -- both
per-object stored fields (a Y-coordinate-like value, offset by a fixed
constant) -- feed the real lookup. Dumped the table at $FB80 directly
(32 words checked): addresses *decrease by exactly 1* across each
consecutive run of 8 entries, then *jump by exactly 617* to the next
group of 8 -- a genuine non-linear, banded addressing scheme, in the
same spirit as (though numerically unrelated to) the Spectrum's own
famous non-linear screen memory layout. Only *after* this lookup does
the code reload `BC` with a small literal constant for the actual
`CALL $C200` -- a completely separate use of the same register pair,
which is what had made the two look like one confusing signal earlier.

**This changes the "how feasible to patch" answer, in a good way for
this project, not a bad one.** The PCW port's $C200/$3186/$3195 chain
is elaborate specifically because it solves a *harder* addressing
problem than this system has: a non-linear, banded destination buffer,
the same category of complexity that makes the Spectrum original's own
`print_sprite` intricate. This system's own framebuffer is already
plain linear (`video_base + row*80 + col`) -- exactly the case the PCW
code's complexity exists to avoid needing. So there is no shortcut to
be had by porting $C200's address arithmetic: it would be strictly
*more* complex than `kl_blit_impl`'s own three-line address calc, not
less, because it's solving a problem this project's own simpler
hardware doesn't have. The PCW port's real, lasting value to this
investigation was always as a **correctness reference** (two
independent working ports, both showing right-side-up archways) --
confirmed already -- not as a source of code to directly reuse.

Conclusion: stop pursuing the PCW patch angle; it would cost more than
it could save. The productive next step returns to the one already
identified before this detour -- compare this port's own full-room
render against the fuse ground truth region by region (no single-object
isolation, which was shown to have its own artifacts) to find the
actual, remaining bug in `kl_extract.py`/`kl.asm`, now with complete
confidence about what correct looks like from two independent real
implementations.

## 74LS373 → 74HC595 data-latch swap: analyzed, implemented, firmware-verified (not yet bench-wired)

User asked to explore replacing the 74LS373 (parallel data-bus latch,
1284P→Z80 reads) with a 74HC595 (serial-in/parallel-out shift register)
to free up GPIO, having run into a hard "32 of 32 allocated, zero spare"
wall during an earlier, separate V20-swap feasibility pass this session.

**Feasibility check first** (`74HC595-plan.md`), grounded in the actual
code rather than assumption: grepped `video_fetch.c`/`sync.c` for any
reference to the data-bus port and found zero -- the video-fetch burst
(the one genuinely cycle-exact, hard-real-time path in this whole
design) never touches the data latch at all; the pixel byte flows
SRAM→74LS166 directly, bypassing the AVR/latch path entirely. The only
two callers of a "present this byte" primitive are ROM emulation
(`rom_emu.c`, whose own header already says timing here is *not* a hard
deadline) and virtual IO reads (already documented as tolerating ~20ms
worst case). So a serial interface, ~25x slower per byte than the old
single parallel `OUT`, costs boot-time and IO latency, never
correctness, and never touches video generation. Also confirmed the
AVR's hardware SPI peripheral (on the very pins already used for the
parallel data bus, `PB5`/`PB7` = `MOSI`/`SCK`) sits completely unused
today -- the SD card is bit-banged through the 8255, not this
peripheral -- so there's no conflict adopting it.

**Implementation**: `pins.h` now defines `DATA_SPI_PORT`/`DATA_SPI_DDR`/
`BIT_MOSI`(`PB5`)/`BIT_SCK`(`PB7`)/`BIT_RCLK`(`PB4`), replacing the old
8-pin `DATA_PORT`/`DATA_DDR`/`DATA_MASK` (all of `PORTB`). New
`databus.c`/`databus.h`: `databus_init()` sets up the three pins as
outputs and puts the AVR's SPI peripheral into master mode at its
fastest rate (`SPI2X`, `F_CPU/2`); `databus_send(byte)` writes `SPDR`,
polls `SPIF`, then pulses `RCLK` to move the shifted byte into the 595's
output register. `main.c` and `rom_emu.c` updated to call these instead
of writing `DATA_PORT` directly. This frees 5 AVR pins (`PB0`-`PB3`,
`PB6`) -- `pin-map.md`'s header now reads "27 of 32 GPIOs allocated, 5
free" instead of "32 of 32, zero spare".

Build verified clean (`make clean && make all`, zero warnings; final
size `text 14392, data 0, bss 10308`). Disassembly-verified both new
functions match the intended design exactly: `databus_init` sets DDR
bits 4/5/7, clears RCLK, writes `SPCR=SPE|MSTR` and `SPSR=SPI2X`;
`databus_send` writes `SPDR`, spins on `SPSR.SPIF`, then does a clean
`sbi`/`cbi` RCLK pulse.

**Not yet done**: this chip has no local datasheet PDF collected (unlike
the 373's `sn74ls373.pdf`), so the pinout used in `373-gates-sram-
wiring.md`'s new 74HC595 section is standard/textbook, not locally
verified -- confirm against a real datasheet before physical wiring, per
this project's own standing practice of catching wrong assumed pinouts
on the bench rather than trusting them blind. No hardware exists yet for
this redesign; only the AVR firmware side has been built and checked.

## CONFIRMED ON HARDWARE: 74HC595 swap works

User wired the 74HC595 in place of the 74LS373 and confirmed the board
works. Updating status from the previous entry's "not yet bench-wired" --
the datasheet-pinout caveat noted there stood up on the real board.

## Bench-measured `_MREQ` low time with the 74HC595: ~5us (was 2-2.5us with the 373)

User measured `_MREQ` low time on a logic analyzer with the 74HC595
wired in, during ROM emulation: ~5us per byte, vs. the 2-2.5us measured
with the old 373 (Phase 4 entry above). Expected, not a bug: worked out
from the real disassembly of `rom_emu_run`/`databus_send`, the 595 path
adds ~30 cycles (~1.9-2us @ 16MHz) of genuinely new overhead per byte --
dominated by the SPI shift itself (8 bits at the fastest available
divider, `SPI2X`+÷2 = 8MHz bit clock = 1us floor, can't go faster on this
crystal) plus a real `call`/`ret` boundary that the old single inlined
`OUT` instruction never paid. 2-2.5us (old) + ~2us (new SPI overhead) =
~4-4.5us predicted, close enough to the measured ~5us (remaining delta
plausibly gate propagation / analyzer threshold, not modeled here).
Only affects ROM-emulation boot-copy throughput and virtual IO latency,
both already documented as having no hard deadline -- doubles the ~16-
20ms full-8K-ROM-copy estimate to ~30-40ms, imperceptible. Does not
affect video generation (that path never calls `databus_send()` at all).

## 74HC595: inlined databus_send() to remove the call/ret overhead

Following the ~5us `_MREQ` bench measurement above, user asked to
remove the `call`/`ret` boundary identified as one of the contributors.
`databus_send()` moved from databus.c into databus.h as `static
inline`, so the compiler folds it directly into `rom_emu_run()`'s poll
loop at its one call site instead of emitting a separate routine.
Disassembly-confirmed: no more `<databus_send>` symbol at all, and
`rom_emu_run`'s loop now goes straight from `out SPDR,r20` to the
`SPIF` poll to the `sbi`/`cbi` RCLK pulse, no `call`/`ret` in between.
`.text` actually shrank slightly (14392->14334 bytes) since the
out-of-line copy is gone. Saves ~8 cycles (~0.5us @ 16MHz) per byte;
expected `_MREQ` low time now ~4.5us, down from the measured ~5us --
not yet re-measured on the bench. Build clean, zero warnings.

## Bench re-measurement after the inline fix: 3.6-3.75us, better than predicted

User re-measured `_MREQ` low time on the logic analyzer after inlining
`databus_send()` (previous entry): **3.6-3.75us**, down from ~5us --
better than the ~4.5us predicted from the `call`/`ret` boundary alone
(~8 cycles, ~0.5us). Comparing the two disassemblies directly explains
the gap: inlining didn't just remove the `call`/`ret` pair, it also let
the compiler keep the MREQ/RD bit values in registers across what used
to be the call boundary, eliminating a spill-to-stack-and-reload
(`std`/`std` before the call, `ldd`/`ldd` after -- 4 instructions @ 2
cycles = 8 more cycles) that existed only to survive that boundary, plus
collapsing a couple of address-computation instructions (a single
`movw` where there were two separate loads before). Real total savings
~16 cycles (~1us), not the ~8 cycles counted from the call/ret alone --
consistent with the measured ~1.25-1.4us drop.
