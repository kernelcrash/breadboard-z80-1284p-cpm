# CP/M 2.2 Port — Plan (continues plan.md's Phase 8)

Source spec: `CPM.md`. This plan is the result of working through each of
`CPM.md`'s open questions from first principles against this project's
actual hardware (not assumed from generic CP/M lore) — verifying the real
MSX mapper port numbers, the real CP/M 2.2 BIOS/BDOS structure and
standard memory addresses, a real Z80-cycle-cost comparison between
candidate bank-switch circuits, and a real correctness hazard (stock CP/M
binaries can't cooperate with bank switching mid-execution) that ended up
shaping the final design more than raw chip count did.

## Context

`CPM.md` sets the goal: extend the working Z80/1284p machine (currently
through `plan.md`'s Phase 8 — ROM emulation, mode switch, video
generation, UART virtualization all bring-up-verified) into a real CP/M
2.2 host, concretely able to run Infocom's Zork 1. `CPM.md` itself flags
several open, unexplored questions rather than a fixed design: how to
bank memory so video RAM doesn't permanently cost CP/M 16K of its TPA,
where the stack can safely live if memory is banked, whether to build an
MSX-style matrix keyboard or bit-banged PS/2, how to talk to an SD card,
and which disk image format to use. Every one of those has a concrete,
settled answer below; nothing is left as "TBD" except where explicitly
flagged.

## Architecture decisions

### 1. Console: native keyboard + video, not the existing UART — CONST/CONIN/CONOUT designed and verified, Phase 12 (2026-09-07)

`CONIN`/`CONOUT` talk to new keyboard+video hardware, not Phase 7's
virtual UART. This means the keyboard is in scope for v1 (not deferred),
unlike the alternative of reusing the UART as a serial-terminal console
(which would need zero new hardware but leaves the video/keyboard work
half-used for CP/M's actual purpose). The UART stays available and cheap
to also wire up as CP/M's `LIST` device (see BIOS section) since Phase 7
already provides it — free debug/log path, not required for Zork 1
itself.

**Console driver written and verified in isolation**
(`test-progs/console-io-test.asm`) before wiring into the real BIOS —
new ground none of the earlier fixed-position `write_msg`-based tests
covered:

- **`CONOUT`**: a genuine streaming character console, not a fixed-
  position write. Tracks `(cur_row, cur_col)`; `CR` resets the column,
  `LF` advances a row, `BS` backs up a column; anything printable is
  blitted via `write_msg` fed a 1-character string (no new font-blit
  code needed) and the cursor advances, wrapping at column 80. Past
  the last row (24), the whole 640×200 video buffer scrolls up one
  character row (a single `LDIR` moving 15360 bytes) rather than
  overflowing — genuinely new capability, not exercised by any earlier
  video test.
- **`CONST`/`CONIN`**: matrix-scan based (reusing the proven row-
  select/column-read from `keyboard-scan-test.asm`), with a real
  key-down debounce (a physical press is reported exactly once, not
  once per scan while held) and a depth-1 pending-character buffer so
  `CONST` (peek) and `CONIN` (consume) have the correct, separate
  BDOS-standard contracts — `CONST` must not eat the character `CONIN`
  is about to return. `CTRL` is checked explicitly and transforms a
  letter into its control code. **`SHIFT` is deliberately not
  implemented yet** — every key reports its unshifted symbol
  regardless — matching `wiring.md`'s own note that this was
  deferred to exactly this phase; still to do. Function keys, GRAPH/
  CODE/CAPS, and cursor/editing keys (arrows, HOME, INS) have no plain-
  ASCII meaning and are left unmapped for now — real terminal escape-
  sequence emulation is out of scope.
- **Real bug caught via disassembly before this ever reached a
  bench**: the column-finding bit-scan's exit (`fk_col_done`) relied on
  whatever flags `SRL` happened to leave rather than an explicit
  "found" signal — harmless in the original `keyboard-scan-test.asm`
  (which never branched on it), but here `get_key_event` does branch on
  it, and when the found column is the *last* one (column 7), the
  shifted accumulator is always exactly 0 (nothing above bit 7 to keep
  it nonzero), giving a misleading "not found" that would have silently
  dropped every keypress in a matrix's last column. Fixed with an
  explicit, value-independent flag set (`OR 1`) before returning.

Not yet bench-tested — next step: flash `console-io-test.bin`, type on
the real keyboard, and confirm echo, wrapping, scrolling (type enough
to fill the screen), backspace, and `CTRL-C` (should echo as a control
code, not hang or drop).

### 2. Memory banking: two NAND gates, not a mux/latch network

**The circuit** (verified via truth table before trusting it):

- Gate 1: `NAND(bank, A15)` → call this `X`. `bank` is one new
  Z80-writable IO bit (one more spare 8255 port pin — see §5).
- Gate 2: `NAND(X, _BUSACK)` → this drives the SRAM's `A16` pin directly
  (currently grounded — see `docs/memory-map.md`). **Not `_BUSRQ`** —
  see the note below, this substitution is the result of a real,
  extended debugging session, not the original design.

Truth table (`bank`, `A15`, `_BUSACK`-asserted → `A16`):

| bank | A15 | Z80 has released the bus (`_BUSACK` low) | A16 |
|------|-----|------|-----|
| 0 | 0 | no | 0 |
| 0 | 0 | yes | 1 |
| 0 | 1 | no | 0 |
| 0 | 1 | yes | 1 |
| 1 | 0 | no | 0 |
| 1 | 0 | yes | 1 |
| 1 | 1 | no | **1** |
| 1 | 1 | yes | 1 |

Collapses to `A16 = (bank AND A15) OR busack_asserted` — exactly the two
properties needed: the AVR's video fetch *always* forces `A16=1` once
the Z80 has genuinely released the bus, regardless of `bank` (so video
is reachable at a fixed physical location
no matter what the Z80 last banked), and the Z80 only sees `A16=1` when
it deliberately asks for it (`bank=1`) *and* is addressing the top half
of its own space (`A15=1`).

**Why `_BUSACK`, not `_BUSRQ` (found the hard way, via a real, extended
bench debugging session, 2026-09-07)**: the original circuit used
`_BUSRQ` directly, on the assumption that `_BUSRQ` asserted means the
Z80 has already released the bus. It doesn't — the Z80 UM states
`_BUSRQ` "is always recognized at the end of the current machine
cycle," meaning there's a real window (up to one full machine cycle)
where `_BUSRQ` is asserted but the Z80 is still actively driving the
bus for its own, unrelated purposes. During that window the old circuit
forced `A16=1` regardless, corrupting whatever real memory access the
Z80 had in flight (e.g. a live instruction fetch reading from the wrong
physical bank). Symptoms were exactly what that predicts: intermittent,
worse in code with tight read/write alternation, unaffected by two
plausible-looking fixes that didn't touch the real cause (swapping the
gate chip for a CMOS-threshold-compatible part, slowing the Z80's
clock) — and completely cured by hardwiring `A16` to a fixed level
(which simply can't be affected by a signal it no longer listens to).
`_BUSACK` (Z80 pin 23) is the Z80's own hardware confirmation that it
has *actually* relinquished the bus, not merely been asked to — using
it instead of `_BUSRQ` closes the gap directly rather than papering
over it with a guessed delay margin. Costs nothing pin-wise: `_BUSACK`
was already unused (dropped from the *AVR's* firmware pin budget in the
base design, `plan.md`), and wiring it into this gate is a pure
hardware connection that never touches the AVR at all.

**What this actually maps, precisely** (not just "top half swaps"):

- Z80 `0x0000-0x7FFF` (`A15=0`): **always** physical bytes 0-32767,
  regardless of `bank`. Permanently fixed — this is what makes it safe
  to put anything here that must survive a bank flip.
- Z80 `0x8000-0xFFFF`, `bank=0`: physical bytes 32768-65535 — identical
  to today's memory (same bytes `A16=0`/grounded already gives).
- Z80 `0x8000-0xFFFF`, `bank=1`: physical bytes 98304-131071. Of this,
  the top 16K (physical 114688-131071, Z80 `0xC000-0xFFFF`) is the exact
  fixed region the AVR's video fetch already lands on (its own address
  ramp already fixes `A14=A15=1` via the existing pull-ups, and now also
  forces `A16=1` via this circuit) — so Z80 writes there while `bank=1`
  really are writing video RAM, same as today. The other 16K (physical
  98304-114687, Z80 `0x8000-0xBFFF`) is genuinely new territory,
  previously unreachable — used to hold font data (below).
- Physical bytes 65536-98303 (32K in the middle of the 128K chip) are
  **never reachable by either bank setting** — a real, accepted cost:
  only 96K of the 128K SRAM ends up usable, not the full 128K.

**Operating convention: `bank=0` is CP/M's steady state.** Running with
`bank=0` gives the full, plain 64K (0x0000-0xFFFF, no video visible at
all) — after CCP/BDOS/BIOS overhead this is what actually delivers
`CPM.md`'s original "~60K TPA" goal, not `bank=1` (which reproduces
today's 48K-general+16K-video split with zero net TPA gain). The CBIOS's
character-output routine is the *only* code that ever touches `bank`: it
flips to `bank=1`, blits the character's 8 font bytes into the two
screen rows at the right offset (same interleaved `(IX+0)`/`(IX+0x50)`
pattern already proven in `video-test3.asm`'s/`video-nmi-vsync-
benchmark.asm`'s `write_msg`), flips back to `bank=0`, then returns.

**Font data** lives in `bank=1`'s newly-reachable 16K at Z80
`0x8000-0xBFFF` — reachable exactly when the blit routine has already
flipped to `bank=1` anyway, so no extra flip needed to read it.

**CP/M 2.2 addresses, revised 2026-09-07 (see section 4)**: CCP at
`$DC00`, BDOS entry at `$E406` (the fixed `0x0005` vector `CALL 5`
convention points here), BIOS at `$F200` — `MEM=62`, not the `$E400`/
`$EC06`/`$FA00` (`MEM=64`) addresses an earlier pass through this plan
verified and committed to; that combination didn't leave enough room
for this project's actual BIOS once real driver code was laid out
against it (section 4 has the full account). Nothing about this design
requires relocating CCP/BDOS/BIOS to the bottom of memory — only the
tiny character-output routine needs special placement (next point).

### 3. Bank-flip trampoline lives in the low, always-fixed 32K

Considered two options: (a) mirror a small sliver of the top-of-memory
BIOS region (e.g. the unused 384 bytes above where video RAM ends,
`0xC000+16000=0xFE80` through `0xFFFF`) so it reads identically in both
banks, letting the flip-and-blit routine sit physically inside the
conventional BIOS block; or (b) put that same routine down in the
already-bank-invariant low 32K instead, with the BIOS's `CONOUT` entry
(still at its normal high-memory position) just `JP`-ing down to
it. **Chose (b)**: functionally identical, but avoids the maintenance
hazard of (a) — two copies of the same code that must always be edited
in lockstep, a bug class that only shows up in whichever copy a future
edit forgets to update.

**Refined further, Phase 12 (2026-09-08, user's suggestion)**: only a
tiny flip-and-`JP` stub per operation (~13 bytes each, ~30 bytes total
with the required state bytes) needs to live in low memory at all —
the actual blit/scroll CODE can live in the bank=1-only region too,
immediately after the font (`$8800` onward), since bank=1 is already
what we want active during the blit/scroll regardless. The low-memory
stub sets up parameters, flips the bank bit, and `JP`s (not `CALL`s)
into the bank=1-resident implementation, which does the real work and
itself flips back to `bank=0` before `RET`urning straight to `CONOUT`'s
original caller — safe because the only stack activity throughout is
the original `CALL`-into-the-stub's own return address, pushed before
any flip and popped only after flipping back, never straddling it.
Down from ~185 bytes (an earlier draft kept the full `write_msg`-
equivalent blit logic in low memory) to ~30 — meaningfully shrinks the
TPA-corruption exposure the next paragraph accepts as a soft,
unavoidable-in-classic-CP/M-2.2 risk, without eliminating it outright.
Built and disassembly-verified in `firmware/z80-boot-rom/cpm/bios.asm`
— `video_blit_impl` lands at exactly `$8800` (immediately after the
2048-byte font ends) and `video_scroll_impl` immediately after it at
`$8873`, both confirmed via a fresh disassembly of the assembled
binary, not just the label file.

**Known, accepted limitation** — *no longer accepted; fixed 2026-09-10,
see below*: classic CP/M 2.2 has no hardware memory protection and no
standard mechanism to reserve a chunk of low memory from TPA use — a
program using nearly all of the TPA below this trampoline's address
could in principle overwrite it, though at ~30 bytes the exposure is
about as small as it can practically be made. Placed near the top of
low memory (not the middle of the TPA) to further minimize practical
risk for realistically-sized programs — Zork's own footprint should be
checked against this once it's running.

**This risk turned out to be real, and is now fixed (2026-09-10).**
Real PIP.COM hung immediately on any drive-B copy; tracing its own
DR-published PL/M source (`SIZE$MEMORY`) showed it sizes its working
buffers from `MAXB` (page-zero bytes 6-7, the `JP BDOS` operand) and
splits the *entire* span from its own end up to there into two buffers,
tens of KB each — guaranteed to cross `$7C00`, trampling the trampoline
before any real disk I/O. Zork's memory-hungry interpreter is a
plausible second victim. Fix: the true bank-invariant footprint was
restructured down to **38 bytes** (`enter_bank1`/`leave_bank1` shared
stubs + `porta_shadow`/`char_buf`/`saved_sp`; `cur_row`/`cur_col`, the
blit scratch stack, `vbi_guard` and `alv1` all turned out never to have
needed bank invariance and moved to ordinary BIOS/bank=1 memory) and
**relocated to `$0008-$002d` in page zero**. That's safe in a way `$7C00`
never was: `TBASE`=`$0100` is where every program's own code loads, so
no compliant program's buffer math can ever generate an address below
it — structural, not conventional. stage1 loads chunk 1 to a `$7C00`
scratch pad (`load_blocks` works in 512-byte units) and `LDIR`s it down
to `$0008` just before jumping to BOOT. See bring-up-log.md's
2026-09-10 entry and bios.asm's `org $0008` block for the full
reasoning and the register-vs-memory analysis of what actually had to
stay invariant.

**Stack**: stays in its conventional CP/M location (high memory, near
CCP) rather than being relocated into the low 32K — decided against the
alternative of moving it, in favor of keeping standard placement and
handling the hazard through discipline in the routines that actually
run with `bank=1` active. The rule to hold to: any `PUSH`/`POP` pair
(including `CALL`/`RET`'s automatic ones) that executes *while `bank=1`
is set* must complete entirely before flipping back to `bank=0` — never
let one half of a push/pop pair happen in each bank state. In practice
this means the flip-and-blit routine (and anything it calls while
flipped) should be straight-line, keep its own `CALL`s shallow and fully
resolved before flipping back, and needs deliberate care on every future
edit that touches code running in that window — this is a standing
discipline for that specific code path, not a one-time fix. The VSYNC-
to-`_NMI` wiring (added for the video-steal benchmark test) will be
disconnected for the CP/M build specifically, so an NMI's automatic
PC-push can't land mid-flip and corrupt this independently of anything
the flip routine itself does.

### 4. Boot sequence: small ROM bootstrap, disk-resident CP/M system — CCP+BDOS sourced and verified, Phase 12 (2026-09-07)

**CCP+BDOS source**: vendored Clark Calkins' well-known "reconstructed
from memory" CP/M 2.2 source (`firmware/z80-boot-rom/cpm/cpm22.asm`,
unmodified except setting `MEM`), via
[Z80-Retro/cpm-2.2](https://github.com/Z80-Retro/cpm-2.2) — itself
mirroring the Unofficial CP/M Web Site's archive. Rights basis: DRDOS,
Inc.'s [2022 clarified release](https://github.com/Z80-Retro/cpm-2.2/blob/master/DRI-LicenseAgreement.txt),
"a right to use, distribute, modify, enhance, and otherwise make
available in a nonexclusive manner CP/M and its derivatives" — the
same basis essentially every modern homebrew CP/M 2.2 port already
builds on. Confirmed the file assembles cleanly with this project's
own `z80asm` (aside from the two *expected* classes of error before
`MEM`/the BIOS labels are supplied — no dialect incompatibilities).

**`MEM=64` tried first, verified empirically against a throwaway
stub-BIOS smoke test** (17 `RET`-stub vectors assembled together with
`cpm22.asm`) — `z80asm`'s own label-file output confirmed `CBASE`
(CCP) `= $E400`, `FBASE` (the true BDOS entry the page-zero `CALL 5`
vector points to — `ENTRY EQU 5` is the *fixed* CP/M-wide vector
location, `FBASE` is what gets written there) `= $EC06`, and `BOOT`
(the BIOS vector table) `= $FA00`, matching both this plan's own
addresses at the time and the real, proven Z80 Retro! system's
`CPM_BASE+0x1600` formula for this exact source+`MEM` combination.

**Revised to `MEM=62` once real driver code was laid out against it.**
`MEM=64` only leaves `$FA00`-`$FFFF` = 1536 bytes for the actual custom
BIOS — and this project's BIOS (bit-banged SPI SD driver, matrix-
keyboard scan with debounce and `CTRL` handling, DPB/DPH tables, a
one-block disk cache) doesn't fit in that even with the 2048-byte font
correctly kept out of it (living in the bank=1-only region per this
section's own font placement above, not in the BIOS region at all) —
a careful count of the driver code actually built for Phase 12 (test-
progs/console-io-test.asm, test-progs/cbios-disk-test.asm, both
disassembly-verified and bench-confirmed working) came to a bit under
1800 bytes, more than `MEM=64` leaves. Rather than also relocating
disk-driver data into the bank=1 region to make 1536 bytes stretch
far enough (workable, but adds a second bank-flip-discipline surface
alongside `CONOUT`'s existing one, for no real benefit), reverted to
`MEM=62` — this source's *own* original, author-tested default
("for a 62k system, TS802 TEST — WORKS OK"), not an arbitrary pick.
Re-verified the same way: `CBASE=$DC00`, `FBASE=$E406`,
`BOOT=$F200` — leaving 3584 bytes for BIOS, comfortably inside with
real margin to spare. **Every address in this plan that previously
read `$E400`/`$EC06`/`$FA00` now reads `$DC00`/`$E406`/`$F200`.**

Checked whether CCP+BDOS+a full custom BIOS could simply be baked into
the AVR's existing 8K ROM-emulation window (`docs/memory-map.md`), the
same way every test-progs/*.asm so far has worked. They don't fit
comfortably: CCP+BDOS alone (`$DC00`-`$F200`) is 5632 bytes, leaving
well under 2.5K for a complete custom BIOS (console driver, SD driver,
keyboard driver, bank-flip trampoline) crammed into the remaining ~8K —
tight enough to be a real risk, not a design to build around.

This turns out to match how real (disk-based) CP/M machines actually
worked, rather than being a workaround: historically only a small
bootstrap loader lived in ROM, whose entire job was to read the real
CCP+BDOS+BIOS system image off the boot disk into RAM and jump to it —
CCP/BDOS were meant to be portable across machines and were distributed
as part of the disk's system image, not fused into ROM.

**Adopted**: the AVR-emulated 8K ROM holds only a small stage-1
bootstrap (xmodem-uploaded exactly like every other test program this
project has built — or, since 2026-09-11, baked into the AVR flash
image and autobooted with no host when the PD0 boot-mode strap is
pulled low; same bytes into the same `rom_buf` either way) — initializes
the bit-banged SPI/SD interface (§6),
reads the real CP/M system image (prebuilt CCP+BDOS+custom BIOS,
assembled ahead of time and stored on the SD card's boot disk) into RAM
at `$DC00`+, configures the 8255's `mode_pin` (existing mechanism,
unchanged), and jumps to CCP's cold-boot entry. The actual CP/M system
can then be rebuilt/updated by just re-writing the SD card, without ever
re-uploading anything to the AVR.

### 5. Keyboard: MSX-style matrix — locked in and built, Phase 10 (2026-09-07)

Reuses the same 8255 already needed for `bank`/etc: a 74LS145 (BCD-to-
decimal decoder) drives one of up to 10 row lines from a 4-bit 8255
output, an 8-bit 8255 input reads back the matched columns — standard
MSX keyboard-matrix convention. Chosen over bit-banged PS/2 because it
keeps everything on the one IO chip already in the design and avoids
PS/2's own clock-edge timing/protocol handling.

**Pin assignment** (`docs/wiring.md`, full pin-by-pin diagram):
matches real MSX convention — row select on `PC0`-`PC3` (Port C lower
nibble), column read on all of `PB0`-`PB7` (Port B is already an input
from the control word every test program already writes at boot).
Needs one 8255 control-word change to make Port C's lower nibble an
output: `$8A` instead of the `$8B` every test program has used so far
(bit 0 flips from "Port C lower = input" to "output"; Port A output,
Port C upper input, and Port B input are all unchanged). Checked this
against Phase 11 before committing to it: Port A (`mode_pin`+`bank`,
already an output) keeps 6 fully free bits with row-select off it —
enough for the SD SPI's three output lines with no further
reconfiguration, and the one SPI input (`MISO`) fits Port C's upper
nibble, already input and independent of the lower nibble's direction.
No blocker; if anything more convenient than an earlier Port-A-based
layout this plan briefly considered, which only left 2 free bits.

Standalone test (`test-progs/keyboard-scan-test.asm`) continuously
scans all 10 rows and prints whichever `(row, col)` it currently finds
pressed, or "NO KEY" — verified via disassembly (row-select arithmetic,
branch targets, and the digit-conversion writes landing exactly on
their placeholder bytes in the status string) before ever touching real
hardware, same standard as every other test-progs/*.asm this project
has shipped. Works for bring-up with just a single pushbutton wired
between one 74LS145 output and one 8255 column pin, before a full
keyboard matrix is connected.

### 6. Disk interface: bit-banged SPI SD card via 8255 — locked in and built, Phase 11 (2026-09-07)

Real prior art for exactly this combination (Z80 + simple parallel IO +
bit-banged SPI + CP/M 2.2) exists and is worth referencing during
implementation — e.g. the
[Z80 Retro! project](https://github.com/Z80-Retro/2063-Z80-cpm), a
from-scratch flash-bootloader-plus-CP/M-2.2-BIOS build using a bit-
banged SD driver at a comparable clock speed. Four 8255 pins suffice:
`CS`, `SCLK`, `MOSI` (outputs), `MISO` (input) — standard SD SPI-mode
protocol (`CMD0`/`CMD8`/`CMD41` init sequence, `CMD17`/`CMD24` for
single-block read/write, native 512-byte physical sectors).

**Final pin assignment** (`docs/wiring.md`): `CS`=`PA2`,
`SCK`=`PA3`, `MOSI`=`PA4` (all three already output under the existing
`$8A` control word — Port A was already configured output for
`mode_pin`/`bank`), `MISO`=`PC4` (Port C upper nibble, also already
input under `$8A`). **Zero 8255 control-word changes needed** to add
this on top of the keyboard interface — both peripherals' pins were
already configured the right direction by the one control word the
keyboard interface introduced. Assumes a common 5V-tolerant microSD
breakout module (onboard regulator + level shifting) — see
`wiring.md` for the fallback design if the real hardware turns
out to be a bare socket instead.

### 7. Disk image format: a real classic CP/M geometry, not invented

Per the user's preference, replicate an actual historical CP/M disk
format rather than defining a custom one. Recommend the IBM 3740 8"
SSSD geometry — the canonical, most-cited CP/M reference format (77
tracks x 26 sectors/track x 128 bytes/sector = 256,256 bytes) — with its
real, standard DPB, verified by re-deriving `DSM` from the raw geometry
rather than just copying it:

| Field | Value | Meaning |
|-------|-------|---------|
| SPT | 26 | sectors/track |
| BSH | 3 | block shift (1024-byte allocation blocks) |
| BLM | 7 | block mask |
| EXM | 0 | extent mask |
| DSM | 233 | revised (see below): `(77*26*128 - 5*26*128)/1024 - 1 = 233` |
| DRM | 63 | 64 directory entries |
| AL0/AL1 | 0xC0/0x00 | 2 directory blocks reserved |
| CKS | 16 | removable-media directory checksum vector size |
| OFF | 5 | 5 reserved boot tracks — revised from 2, see below |

**`OFF` revised from 2 to 5, Phase 12 (2026-09-08)**: sizing up the
stage-1 bootstrap's actual three chunks (low-memory trampoline + font/
blit-code + CCP/BDOS/BIOS, ~10035 bytes total — `bring-up-log.md` has
the exact breakdown) against `OFF=2`'s reserved area (6656 bytes) found
it doesn't fit. `OFF=5` reserves 16640 bytes — comfortable margin —
and, checked before adopting it rather than assumed, divides evenly
into `DSM` with no fractional remainder (234.0 exactly, cleaner than
`OFF=2`'s own 243.75, by coincidence not design). `ALV` size in
`bios.asm`'s DPH recomputed to match: `ceil(234/8)=30` (was 31).

**Flagged honestly**: this format is only ~250KB per drive — small
enough that it's worth deciding, once real usage is known, whether drive
B (holding Zork 1's own 76KB data file plus room for other content)
should use a second, *larger* classic geometry (e.g. an 8" DSDD format)
instead of squeezing everything into one 250K volume. Not blocking —
easy to size up later without touching the BIOS's disk-driver logic,
only its DPB table.

**Resolved in §8**: drive B ended up not as another small floppy-class
image but a genuine hard-disk-style volume (100 MiB, `DSM>255`) behind
a real MBR partition table — Zork 1 itself stayed on drive A, which
turned out to have ample room once it was the only thing on that
volume.

**Sector-size mismatch to handle in the driver**: CP/M's logical sectors
here are 128 bytes; the SD card's native sectors are 512 bytes. Standard
technique (used by the prior-art projects above): read one 512-byte
physical block, serve the correct 128-byte quarter based on the low 2
bits of the logical sector number, only re-reading the physical block
when the logical sector's high bits actually change.

**CBIOS disk driver built and disassembly-verified, Phase 12
(2026-09-07)** (`test-progs/cbios-disk-test.asm`) — `SELDSK`/`SETTRK`/
`SETSEC`/`SETDMA`/`READ`/`WRITE`/`HOME`/`SECTRAN`, reusing Phase 11's
proven SD SPI driver verbatim underneath. `SELDSK` returns a real DPH
for drive 0 (only drive implemented so far), 0 for anything else.
`SECTRAN` is a deliberate identity mapping — the classic IBM 3740
sector skew exists purely to give a mechanical floppy drive time to
prepare between sequentially-numbered sectors; an SD card over SPI has
no rotational latency to hide, so there is no reason to reorder sectors
at all (BDOS conventionally skips calling `SECTRAN` when the DPH's
`XLT` field is 0, as this one is, but it's implemented correctly
anyway rather than assumed unreachable). The 128-byte-logical/512-byte-
physical mismatch is handled via `compute_lba_and_offset` (`LBA =
(track*26+sector)/4`, `offset = (track*26+sector mod 4)*128` — the
modulo result is looked up in a 4-entry word table rather than shifted
directly, since `3*128=384` doesn't fit an 8-bit register) plus a
one-block read cache: `READ` only re-fetches from the SD card when the
computed LBA actually changes; `WRITE` always does a full read-modify-
write of the containing 512-byte block (a naive 128-byte write would
destroy the other 3 quarters) and updates the cache in place rather
than invalidating it. Verified via disassembly against real computed
values, not just traced logic: `SELDSK`'s DPH and the DPB it points to
were dumped straight from the assembled binary and match this
section's table exactly (`SPT=26 BSH=3 BLM=7 EXM=0 DSM=242 DRM=63
AL0=$C0 AL1=$00 CKS=16 OFF=2`), and the quarter-offset table's 4 words
were confirmed to be exactly `0,128,256,384`.

**Bench-confirmed 2026-09-07**: `SD INIT: OK`, both `SELDSK` checks,
and `ROUNDTRIP: PASS`, all on real hardware. One real bug found and
fixed along the way — `fill_test_pattern`/`compare_buffers` used the
standard "`LD B,0`" 256-iteration idiom left over from Phase 11's
512-byte buffers, but this test's buffers are only 128 bytes each;
`compare_buffers`' overflow compared 128 bytes of unrelated code
against `disk_rbuf`'s neighbor in memory, reporting FAIL regardless of
whether the real, meaningful 128 bytes actually round-tripped
correctly (which they did — `WRITE`/`READ` themselves were never
wrong, both already correctly used `LD BC,128`). Fixed to `LD B,128`,
re-verified via disassembly (both loops run exactly 128 iterations,
`disk_rbuf` confirmed at exactly `disk_wbuf`+128), and confirmed
passing on hardware. The CBIOS disk driver is done.

### 8. Multi-drive layout: MBR partitioning + a large drive B

This is the "Drive B's exact size/geometry once real space needs are
known" item this section flagged as open above, now resolved. Getting
other CP/M software onto the machine needs more room than drive A's
~232KB and a real bulk-import workflow, not just the one-file-at-a-time
tool that got Zork 1 on board (`cpm_put.py`).

**MBR, host-side convenience only.** The SD card gets a real MBR
partition table so `fdisk`/`parted` can address each drive as
`/dev/sdX1`/`/dev/sdX2` instead of hand-computed byte offsets. The Z80
BIOS never parses it — it keeps a hardcoded per-drive LBA base
(`BASE_LBA_A`/`BASE_LBA_B` in `bios.asm`), hand-synced against the
partition table the same way `CHUNK*_LBA`/`OFF` already are.
`firmware/z80-boot-rom/cpm/write_mbr.py` generates it (verified against
real `fdisk -l` output, not just self-consistency):

| Partition | Start LBA | Size | Contents |
|---|---|---|---|
| 1 | 2048 | 2048 sectors (1 MiB) | boot area + drive A (unchanged geometry, now just relocated) |
| 2 | 4096 | 2,080,768 sectors (1016 MiB) | drive B |

1 MiB alignment matches every modern partitioning tool's own default.
Partition 1 cannot start at LBA0 — a real partition table's own bytes
(offset 446-511) would collide with what used to be chunk1's entire
first block — so `stage1.asm`'s three chunk LBAs (and, correspondingly,
`bios.asm`'s drive-A LBA base) all shifted from 0 to 2048. This is a
real change to the already-proven boot chain's physical placement (not
just additive new code), verified in this order before trusting
anything about drive B: stage1's own on-screen checksum report still
passing, full boot to `A>`, and `DIR`/`SAVE`/`REN`/`TYPE` + Zork 1
re-confirmed on drive A at its new location.

**Drive B's DPB** (`dpb1` in `bios.asm`), derived from scratch like
`dpb0` was, not copied: `SPT=128 BSH=7 BLM=127 EXM=7 DSM=6399 DRM=1023
AL0=$C0 AL1=$00 CKS=0 OFF=0` — 6400 blocks × 16384 bytes = exactly
**100 MiB**. `DSM>255` triggers the real, standard DR CP/M 2.2 rule
that directory allocation pointers switch from 1-byte (16 per entry)
to 2-byte (8 per entry), which is why `EXM` is `BLS/2048-1` here
instead of `dpb0`'s own `BLS/1024-1` — self-checked by confirming the
`DSM<=255` formula reproduces `dpb0`'s real, disassembly-verified
`EXM=0` exactly. `CKS=0` is DR's "fixed disk" convention (the SD card
is never hot-swapped while running) — BDOS skips the directory-changed
check entirely, and no CSV buffer is allocated for drive B at all.
`SPT=128` is a deliberate choice, not inherited from `dpb0`'s
floppy-track fiction: it makes `BLS=SPT*128`, so one "track" is exactly
one block, which also makes the quarter-byte-offset in
`compute_lba_and_offset` depend only on `sector`'s low 2 bits, never on
`track` (128 is a multiple of 4).

**Real CP/M 2.2 ceiling, not arbitrary**: `DSM`'s 16-bit field times
the largest standard block size (`BSH=7`, 16KB) caps any single volume
at exactly 65536×16384 = **1 GiB** — 2GB is not reachable under
standard, unmodified CP/M 2.2 semantics at all. **~1016 MiB (Tier 2)
is a documented, deliberately deferred follow-up**: it needs an
8128-byte allocation vector that doesn't fit in the BIOS's remaining
spare RAM (`$F200-$FFFF` is only 3584 bytes total) without shrinking
`cpm22.asm`'s `MEM` constant — the same class of fix already used once
for CCPSTACK. The 100 MiB Tier 1 built now needs no such change and
carries zero risk to the proven system; `alv1` (800 bytes) originally
lived in an unused low-memory gap (`$7C80` onward) but was moved
2026-09-10 into the BIOS's own high-memory scratch area (near
`cur_drive`/`sector_cache`) as part of the trampoline relocation above
— it never needed bank invariance (BDOS only touches it during
ordinary bank=0 execution), and its old home was inside the range a
large transient program's buffers can trample. The BIOS region has
room: `end` is `$FF2D`, leaving ~210 bytes below the `$10000` ceiling.

**`bios.asm` changes**, all disassembly-verified against the real
assembled `boot.img` before being trusted (matching this section's own
established standard, not just traced logic): a `cur_drive` byte;
`seldsk_impl` branches on it instead of rejecting anything but 0;
`compute_lba_and_offset` keeps drive A's original `×26` arithmetic
byte-for-byte untouched in its own branch, adds a genuine 32-bit
base-LBA add for both drives (drive B's absolute LBAs exceed 2,000,000
— 21+ bits, so `cached_lba` widened from 2 to 4 bytes, plus a
`cached_drive` tag checked alongside it defensively, even though the
partitions can't overlap in practice); drive B's own relative-LBA math
(`track<<5 + sector>>2`) is a genuine 32-bit shift, not a 16-bit one —
`track` up to 6399 already overflows 16 bits once shifted. `cur_track`/
`cur_sector` (drive A, unchanged single-byte storage) are joined by
16-bit `cur_track1`/`cur_sector1` for drive B rather than widening
drive A's own proven fields.

**`cpm_put.py` changes**: rebuilt around a `GEOMETRIES` profile dict
(`driveA`/`driveB`) instead of hardcoded constants, with a new
`import-dir` bulk mode (walks a folder, no recursion — CP/M has no
subdirectories) alongside the original single-file mode, which was
regression-tested byte-for-byte identical against its pre-rewrite
output on drive A before trusting anything new. Packing 2-byte
allocation pointers for `DSM>255` surfaced a real, separate bug found
only by checking `cpm22.asm`'s own `OPENIT1`/`OPENIT2` BDOS logic
directly rather than assuming the DR convention: `EX`/`RC` are LOGICAL
16K-extent numbers, not physical-directory-entry indices — when
`EXM>0` lets one physical entry span multiple logical extents, only
the entry's own *top* logical extent's record count is ever stored
(BDOS's own open logic hardcodes `RC=128` for any lower extent within
the same entry, per `OPENIT1`'s own commented source). Verified by hand
against three real multi-extent directory entries built by the tool,
matching computed `EX`/`S2`/`RC` exactly. A second, independent
pre-existing bug (not introduced by this work) surfaced by
`import-dir`'s reliance on the length check actually firing: the
original `cpm_name()` truncated an over-length name to 8.3 *before*
checking its length, so the check could never trigger — a long
filename silently truncated instead of erroring, risking a silent
collision between two different names during a batch import. Fixed to
check length before truncating.

**`write_mbr.py`**: a small, one-time host-side tool (never touches a
device directly, same philosophy as `cpm_put.py`) that writes the
partition table above to a local image file, verified against real
`fdisk -l` output.

Deferred, explicitly out of scope for this work: the ~1 GiB Tier-2
`MEM` change; a converter that imports files *from* a foreign CP/M
disk image (parsing another system's own, different DPB) rather than
files already on hand; a third/fourth drive (`seldsk_impl`'s branching
structure supports this cheaply later, nothing beyond A/B built now).

## Hardware additions needed

- **1x new 74LS00** (quad NAND) for the bank-switch circuit above — the
  existing 74LS00 is fully used (0 of 4 spare, confirmed against
  `docs/gate-equations.md`'s own gate budget), so this can't reuse it.
  Uses 2 of 4 gates; 2 spare.
- **1x 74LS145** (BCD-to-decimal decoder) for keyboard row select, if the
  MSX-matrix keyboard (§5) is confirmed.
- Bit-banged SD card: a level-shifted (5V↔3.3V) SD/microSD breakout,
  wired to 4 spare 8255 pins.
- 8255 pin budget check: `mode_pin`(1) + `bank`(1) + keyboard row-select
  (4, if MSX matrix) + keyboard column-read (8) + SD SPI (4) = 18 of the
  8255's 24 port pins — comfortable headroom on the one existing chip;
  no second 8255 needed for this feature set.
- **Zero new AVR/1284p GPIO pins** for any of this — deliberate, matches
  the base design's already-zero-spare-pin budget (`plan.md`'s GPIO
  budget table). The bank circuit's `_BUSACK` input is a signal the Z80
  itself already drives (pin 23), previously unused; nothing about
  `video_fetch.c` needs to change, since the AVR never senses or drives
  `A16` itself — it's purely a product of gates fed by signals that
  already exist.

## Firmware needed

**Z80 side** (new):

- Stage-1 ROM bootstrap (`z80-boot-rom/`, xmodem-uploaded like every
  existing test program): SD/SPI init, load CP/M system image, mode
  switch, jump to CCP. **Built and disassembly-verified, Phase 12
  (2026-09-08)**: `firmware/z80-boot-rom/cpm/stage1.asm` — loads three
  fixed, block-aligned raw-SD chunks (low-memory trampoline, font+
  blit-code, CCP+BDOS+BIOS) at LBA 0/1/6 into their correct
  destinations under the right bank setting each needs, then flips to
  SRAM-exec and jumps to `BOOT`. 733 bytes, comfortably inside the 8K
  ROM window. `cpm/build-boot-image.py` extracts the matching chunks
  from the assembled `bios.bin` into one `dd`-able image
  (`cpm/boot.img`, 22 blocks) — `cpm/Makefile`'s `all` target builds
  the whole pipeline in one `make` invocation. **Not yet tested on real
  hardware.**
- Custom CBIOS (assembled as part of the disk-resident CP/M system
  image, not the ROM bootstrap): the 17-entry jump table (`BOOT`,
  `WBOOT`, `CONST`, `CONIN`, `CONOUT`, `LIST`, `PUNCH`, `READER`, `HOME`,
  `SELDSK`, `SETTRK`, `SETSEC`, `SETDMA`, `READ`, `WRITE`, `PRSTAT`,
  `SECTRAN` — `PRSTAT` is this exact vendored source's own name for the
  list-status entry, DR's own generic BIOS docs elsewhere call the same
  slot `LISTST`; matched to what `cpm22.asm` actually calls, confirmed
  by assembling it standalone and reading its unresolved-reference
  list) at `$F200` (revised from an earlier `$FA00`/`MEM=64` — see
  section 4). `CONST`/`CONIN`/`CONOUT` are built and disassembly-
  verified (`test-progs/console-io-test.asm`, section 1) — a genuine
  streaming console with cursor tracking, wrap, and scroll, `CONOUT`'s
  actual character blit living in the low-32K bank-flip trampoline
  (§3). **`CONOUT` grew a VT52-subset terminal (2026-09-10..11)** so
  Turbo Pascal 3.0's full-screen editor works: `ESC Y`/`E`/`H`/`K` and
  the Zenith-H19 `ESC L`/`ESC M` (insert/delete line); a
  non-destructive XOR block cursor; arrow keys mapped to the WordStar
  diamond. **`WBOOT` now reloads CCP+BDOS from the boot partition
  every warm boot** (the DR-spec behaviour, previously a v1 shortcut) —
  Turbo Pascal parks its stack at `MAXB` and grows it down through
  CCP's serial-number bytes, so without the reload CCP's own `VERIFY`
  hit `DI/HLT` on the next command. See `docs/bring-up-log.md`.
  `SELDSK`/`SETTRK`/`SETSEC`/`SETDMA`/`READ`/`WRITE`/`HOME`/
  `SECTRAN` are also built, disassembly-verified, and bench-confirmed
  (`test-progs/cbios-disk-test.asm`, §6/§7) against the DPB table
  above; `LIST`/`PRSTAT` optionally wired to the existing Phase 7
  virtual UART (cheap, not required); `PUNCH`/`READER` stubbed
  (no such devices on this machine).

  **All of the above combined into one real, integrated file,
  2026-09-08**: `firmware/z80-boot-rom/cpm/bios.asm`, assembled
  together with `cpm22.asm` (see `cpm/Makefile`). Address layout fully
  disassembly-verified: `BOOT`=`$F200` through `end`=`$FA78` (2168 of
  the 3584 available bytes used, comfortable margin), `video_blit_impl`
  at exactly `$8800` (immediately after the font) and
  `video_scroll_impl` immediately after that at `$8873`. **Not yet
  runnable on hardware** — needs the stage-1 bootstrap (below) to
  actually load its three separate chunks (low-memory trampoline, the
  combined bank=1 font+blit-code region, and the main CCP+BDOS+BIOS
  block) and jump to `BOOT`; not started yet.
- CCP+BDOS: reuse the standard DR CP/M 2.2 source/binary (available for
  hobbyist use via the
  [Unofficial CP/M Web Site's Lineo-licensed release](http://cpm.z80.de/license.html);
  not public domain, but this is the same well-trodden path essentially
  every modern homebrew CP/M port uses) — reassembled only insofar as
  needed to link against the custom CBIOS at the addresses above. Do
  **not** reimplement CCP/BDOS from scratch; they're hardware-
  independent by design and reuse is the standard, correct approach.

**AVR side**: none anticipated. The video-fetch mechanism needs zero
changes (§2) — this whole feature is Z80/8255/discrete-logic side only.

## Phases (continuing plan.md's own numbering from its Phase 8)

**Phase 9 — Banked video memory (hardware only, no CP/M yet).** Wire the
2-NAND circuit. Test with a standalone Z80 program (not CP/M): write a
known pattern to `0x8000-0xFFFF` under `bank=0`, flip to `bank=1`, write
a *different* pattern, flip back, confirm both patterns independently
survive (read back correctly under their own bank setting) — proves the
banking is real and that the two banks are genuinely independent SRAM
content, not aliased. Separately confirm video output is completely
unaffected by toggling `bank` from Z80 code (proves the `_BUSACK`
override in the circuit is doing its job regardless of Z80 state).

**Phase 10 — Keyboard interface. Bench-confirmed 2026-09-07.** Wired
the 74LS145 + 8255 columns (§5). `test-progs/keyboard-scan-test.asm`
scans the matrix continuously and displays the actual pressed key's
name (e.g. "A", "SPACE", "SELECT"), looked up from a `(row,col)`-indexed
pointer table matching `wiring.md`'s confirmed rows-0-8 map —
upgraded from an earlier raw-`ROW=r COL=c` version once the key map was
confirmed against the user's actual keyboard (no numeric keypad, so
rows 0-8 only; row 9 is guarded in the lookup but never wired). Real bug
caught and fixed along the way: the first version scanned with
`bank=0`, meaning every screen write silently landed in the physical
SRAM bank the AVR's video fetch never reads — fixed by fixing `bank=1`
for the whole test run (see `keyboard-scan-test.asm`'s own comments).
User confirmed on real hardware: "it work.s It says 'NO KEY' and then I
press a key and shows different row/columns."

**Phase 11 — SD card disk interface. Bench-confirmed 2026-09-07.**
Wired the bit-banged SPI lines (§6): `CS`=`PA2`, `SCK`=`PA3`,
`MOSI`=`PA4`, `MISO`=`PC4` (10k pull-up to +5V). `test-progs/
sdcard-test.asm` reports `SD INIT: OK`, `ROUNDTRIP: PASS` (a full
on-device write/read-back self-test against `TEST_SECTOR`), and
hex-dumps sector 0's first 16 bytes for external cross-checking against
a PC — all three confirmed on real hardware, including the external
check itself: the on-screen MBR bytes match a `dd` read of the same
card's first sector taken independently from a PC, so both the write
and the read path are now verified against ground truth, not just
against each other.

Getting here took an unusually long, real debugging arc (`bring-up-
log.md` has the full account) — four distinct bugs, all in software,
none in the hardware:
1. A gate-logic-level bit-accumulation bug in `spi_xfer` (`SLA`
   executed after `BIT`, silently clobbering the flag the `BIT` had
   just set) that made every SPI read mathematically return `$00`
   regardless of the real `MISO` signal — caught by the user reading
   the code directly and asking "won't the `SLA` affect the zero
   flag?"
2. An info-capture-ordering bug (`sd_cs_deassert` clobbers `A`, but was
   being called *before* the code that read `A`) that produced a
   perfectly deterministic, hardware-independent wrong byte (`$17`)
   completely unrelated to the SD card, and a second instance of the
   same bug in the `ACMD41` ready-check that would have been a real
   functional bug (never detecting "ready") had CMD0 not already been
   failing first.
3. A register-clobber bug (`spi_xfer`'s own bit-counter register, `D`,
   used to hold a value that needed to survive several *more*
   `spi_xfer` calls, which unconditionally clobber it) in both CMD8's
   R1 capture and CMD58's OCR-byte capture.
4. A genuine SD-over-SPI protocol requirement (a settling clock between
   a command's complete response and the next command) that the
   original driver was missing, plus a subtlety in fixing it right:
   the settling clock has to run *after* a command's entire response
   including any payload, not right after R1, or it silently eats the
   first payload byte of whatever follows.

Every fix was verified against a fresh disassembly before being
reported as done — this project's standing practice, and what caught
several of the above before they reached the user's bench (and, in one
case, a bug the fix itself introduced).

**Phase 12 — CP/M 2.2 port.** Build CCP+BDOS+custom CBIOS as one linked
system image per the addresses/DPB above; write the stage-1 ROM
bootstrap; write the CP/M system image plus a Zork 1 disk image to the
SD card per the chosen geometry (§7). Test criteria: boots to the `A>`
prompt; standard utilities (`DIR`, `STAT`, `PIP`, etc.) work correctly
against the SD-backed drives; Zork 1 loads and is playable via the
native keyboard/video console.

**Phase 13 (stretch, not currently planned work) — performance.** This
project's own NMI/VSYNC benchmark test (`video-nmi-vsync-
benchmark.asm`) already measured the real video-steal slowdown
precisely: **~1.754x** (effective ~4.56MHz average Z80 throughput out of
the nominal 8MHz), cross-checked against an independent theoretical
estimate (~1.80x) derived from the known `_BUSRQ`-hold duration per
active line. Only worth revisiting if Zork 1 actually feels sluggish in
practice — no specific optimization is planned preemptively.

## Verification approach

Each phase gets its own standalone Z80 test program verified in
isolation before integrating into the full CP/M build, matching this
project's established practice throughout `plan.md`'s Phases 4-7. Extend
the same rigor already applied elsewhere in this project to new claims
before trusting them:

- Truth-table any new gate equation before wiring it (done above for
  the bank-switch NAND pair).
- Collect real datasheets for the 74LS145 and the SD card's electrical/
  command interface before Phase 10/11 bring-up, same standard
  `docs/gate-equations.md` already holds itself to for the 8255
  (currently flagged there as "not yet verified against a local
  datasheet" — resolve that gap before or during Phase 9, since this
  plan's banking circuit depends on the 8255 for the `bank` output
  pin's behavior).
- Verify the CBIOS's disk driver against real sector reads/writes (Phase
  11) before ever pointing it at a real CP/M system image, so a driver
  bug doesn't first show up as "CP/M won't boot" with no isolated way to
  tell disk I/O from everything else that's new at once.

## Open items flagged, not blocking

- ~~Drive B's exact size/geometry once real space needs are known
  (§7)~~ — resolved, §8: a 100 MiB (Tier 1) hard-disk-style volume
  behind a real MBR. The ~1 GiB Tier-2 follow-up (needs a `MEM`
  change) remains open, tracked in §8 itself, not here.
- Keyboard style (§5) is a recommended default, not locked in — cheap to
  swap for PS/2 before Phase 10's hardware is committed.
- 8255 reset/default-input-mode behavior is still not verified against a
  real local datasheet (a pre-existing gap already flagged in
  `docs/gate-equations.md`) — worth closing before Phase 9, since this
  plan's `bank` pin relies on the same assumption `mode_pin` already
  does.
