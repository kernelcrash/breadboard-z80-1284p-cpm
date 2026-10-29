# Open Questions & Decisions

Decisions made (resolved):
- **WAIT generation = edge-triggered D flip-flop (74LS74), not a level
  latch (74LS279).** plan.md specified a 279, which has an S/R both-active
  conflict (release happens while `_MREQ`/`_RD` are still low). See
  `gate-equations.md` §3. This matches the spec's own "a flip-flop will
  clock that" wording. → **closed, documented.**
- **HSYNC/VSYNC = timer CTC match-ISR GPIO toggles**, not hardware OC
  outputs (every OC pin is consumed by the data/address/control buses).
  Jitter is ~0.5 µs, invisible to CRT sync, and doesn't propagate into fetch
  timing because the "wait for HSYNC" loop polls the actual edge. → closed,
  see `pin-map.md`.
- **Magic exit address = 0x1FF0** (within 8K window, top of buffer). →
  closed, see `memory-map.md`.
- **SRAM part = TC551001BPL-70L** (1M×8, 70 ns, DIP-32, A0–A16, CE1/CE2/OE).
  A16 tied low ⇒ 64K. → closed.
- **IO convention: writes ride the address bus via `IN A,(C)`** (byte in
  A0–A7, device in A8–A10); the 1284P never sees `_WR`. → closed, see
  `io-map.md`.
- **JTAG disabled by fuse (HIGH 0xD9, JTAGEN=1/unprogrammed); ISP is the
  only programming path.** Corrected 2026-09-01: JTAGEN is active-low
  (programmed=0 means JTAG *enabled*), so the original 0x91 (JTAGEN=0)
  actually left JTAG on — see `pin-map.md` Fuse settings note for the full
  trace. ISP pins overlap the data-latch interface (RCLK/SER/SRCLK + SS,
  formerly D4–D7 + SS before the 2026-09-16 373→595 swap), so the latch
  must be tri-stated during ISP (it is, by OE gating, with the Z80 in
  reset). → closed, see `pin-map.md`.
- **Fuses for 16 MHz external clock: LOW 0xC0, HIGH 0xD9, EXT 0x05.**
  Corrected 2026-09-01 — the original LOW 0xF0/HIGH 0x91/EXT 0x0F were all
  three wrong (SUT encoded as the reserved 11 instead of 00; JTAGEN=0 left
  JTAG enabled instead of disabling it; BODLEVEL=111 disabled BOD instead
  of selecting 2.7V). → closed, verified against datasheet Tables 10-14,
  10-15, 28-5, 28-6, 28-8, 29-8; full trace in `pin-map.md`.
- **Xmodem/monitor command set specifics (plan.md open question #5):**
  38400 8N1 (0.16% baud error, chosen over faster/higher-error rates);
  XMODEM-CRC, 128-byte blocks; monitor commands `help`/`d`/`w`/`f`/`c`
  (raw internal-SRAM debug, address 0100-40FF) and `rd`/`rw`/`rf`/`rc`
  (ROM buffer, offset 0000-1FFF matching the Z80's own ROM address space),
  plus `x`/`i`/`s`. → closed, see `firmware/avr-1284p/src/monitor.c` and
  `bring-up-log.md` Phase 2.
- **ROM buffer address**: pinned to a fixed real SRAM address (0x1000) via
  a custom linker script (`firmware/avr-1284p/rombuf.ld`), rather than
  wherever the default `.bss` placement happened to put it -- for
  determinism, and so it can't silently drift into the stack's headroom
  as other globals grow. The user-facing addressing that actually matters
  (`rd`/`rw`/`rf`/`rc`) is offset-relative (0000-1FFF) and independent of
  this raw address, which is now purely an internal implementation detail
  -- see `rombuf.ld`'s comment for the full reasoning, including a real
  stack-collision hazard in an earlier version of this placement (buffer
  put right up against `RAMEND`, leaving only 256 bytes before the stack
  would collide with it). → closed.
- **WAIT/mode-switch redesign (2026-09-02): mode latch → 8255 GPIO pin,
  `_S`-clocked WAIT FF → Z80-clock-driven WAIT FF, POR RC network → plain
  pull-down.** Extensive iterative design, verified against real sources
  at each step (Z80 UM Figure 6 timing diagram — rendered the page image,
  its text layer is garbled — and the TC551001 SRAM datasheet's Operating
  Mode and Write Cycle sections), not assumed. Full derivation, two dead
  ends found and corrected along the way, and the complete before/after
  gate-count accounting are in `gate-equations.md`'s top-of-file note and
  `bring-up-log.md`. Headline results:
  - 74LS74A: 2 chips → 1 (mode latch eliminated).
  - 74LS32/74LS08/74LS04: all eliminated entirely (5+2+3 gates used
    before → 0 used after) — nothing in the redesigned network needs an
    OR, AND, or standalone inverter.
  - New: 74LS00 (4 gates, fully used), 74LS02 (1 of 4 gates used), 8255
    PPI (40-pin).
  - Net: 6 chips → 4, despite adding the 8255.
  - `SRAM R/W` is now a direct wire to `_WR` (no gate) and `SRAM _OE`
    needs no `_MREQ` term — both verified redundant with SRAM's own `CE1`
    (already wired to `_MREQ`) via the datasheet, not assumed.
  - **Two deliberately accepted limitations, not bugs** — see
    `gate-equations.md` §4 for the full reasoning: (1) AVR-virtualized IO
    (595-served reads, was 373-served before the 2026-09-16 chip swap)
    stops working entirely once `mode_pin` goes low
    (SRAM-execution) — no path exists yet for a post-switch virtual UART
    (Phase 7). (2) An `IN` (not `OUT` — verified `OUT` is always safe,
    since `_RD` stays high through any write cycle) from the 8255 while
    still in ROM-emulation mode causes real bus contention with the 595.
    Accepted as a hard constraint on the eventual boot ROM (never read
    the 8255 before the mode switch completes) rather than solved now.
  → design closed for Phase 4/5 purposes, implementation not yet built or
  bench-tested (no hardware exists for this redesign yet).
- **74LS138/8255 `_CS` coexistence conflict, resolved 2026-09-04**: the
  item directly above flagged that the 8255's `_CS = _IORQ` claimed the
  entire IO space unconditionally, conflicting with the 74LS138-based
  decode `io-map.md` assumed. Now actually built and bench-wired: the
  74LS138 gives the 8255 a real, address-qualified `_CS` (MSX-style,
  `0xA8`-`0xAF`, decoded from `A3`-`A7`), leaving the rest of IO space
  free. See `gate-equations.md` §7/§8. → closed, though see #10 below —
  closing *this* conflict surfaced a *different* one, `io-map.md`'s
  specific addressing convention vs. what's now on the breadboard.
- **`mode_pin` polarity flipped 2026-09-04** (bench finding, not a design
  choice made in the abstract): configuring an 8255 port as an output is
  documented 8255 behavior to force that port's pins low immediately,
  *regardless* of whatever the external pull-up was holding it at. The
  original scheme (`mode_pin` HIGH via pull-up = ROM mode default,
  reconfigure-to-output implicitly forces LOW = SRAM mode) meant merely
  reconfiguring the port to prepare for the real mode switch *already*
  triggered SRAM mode prematurely, before the boot ROM had done anything
  else. Fixed by inverting the convention: `mode_pin` LOW = ROM mode,
  HIGH = SRAM mode — the forced-low state on port reconfiguration is now
  harmless (still reads as ROM mode), and an actual switch to SRAM mode
  needs a deliberate follow-up write driving the pin HIGH. **Still open**:
  confirming whether the external resistor on `mode_pin` was also
  switched from pull-up to pull-*down* — required for this fix to be
  correct at the very first power-on, before the 8255 is configured at
  all (while the port is still an input, its level should default to
  ROM=LOW under the new convention, which needs a pull-down, not the
  original pull-up). Not yet confirmed with the user; `gate-equations.md`
  §2/§4/§5 not yet updated pending this answer — see also #11 below.

Still open:
1. **`_BUSRQ`-to-safe-drive delay value.** **Verified against the real
   Z80 UM 2026-09-05** (was a guessed "4 T-states", not sourced): the UM's
   Bus Request/Acknowledge section states BUSRQ is sampled once per
   machine cycle (rising edge of its last clock period), and "the
   maximum time for the CPU to respond ... is the length of a machine
   cycle" -- not a fixed T-state count. Scanned every M-cycle T-state
   value in the UM's own instruction timing tables for the real worst
   case: 6 T-states is the longest documented single M-cycle in the
   whole instruction set (`LD SP,IX`/`IY` and `INC`/`DEC IX`/`IY`'s
   second M-cycle; also matches the interrupt-acknowledge cycle's 2
   automatic wait states, covering that edge case too). At 8MHz that's
   750ns = 12 AVR cycles @ 16MHz. `video_fetch.c`'s `BUSRQ_SAFE_CYCLES`
   (16) already covers this with ~33% margin. Still not an actual bench
   measurement (this project's usual bar) -- empirically confirming it
   holds across real running Z80 code is still open, but the number
   itself is now sourced rather than guessed.
2. **Video RAM stride / 14-bit counter carry.** 80 bytes/line is not a power
   of two; the 14-bit video address counter must carry correctly across the
   0x4000 boundary between lines. Validate in Phase 6a.
3. ~~**74LS166 load-pulse source.**~~ **RESOLVED 2026-09-05**: option (b),
   software-pulsed, re-using the WAIT-release pin (PD3) -- decided after
   working out the actual per-byte cycle budget, not just picking on
   principle. Per byte (8 AVR cycles = 500ns @ 16MHz): `adiw` (2, 16-bit
   address increment spanning both port bytes at once) + `out`x2 (1 each,
   address to both ports) + `cbi`+`sbi` (2 each, SH_LD low-then-high) = 8
   cycles exactly, zero spare cycles. Verified against the real
   sn74ls166a.pdf function table (page 1, rendered -- text layer garbled
   like other datasheets in this project) that this is safe despite having
   no explicit settle-time delay: the 166 re-evaluates SH/LD on *every*
   clock rising edge, so holding it low across 2 edges (which `cbi`+`sbi`
   guarantees, 125ns) means even if the first edge is "too early" relative
   to the TC551001's ~70ns access time, the second edge (125ns after the
   address changed) re-loads with the now-settled data and simply
   overwrites the first, later result. User independently confirmed the
   same re-latch-on-every-edge behavior from their own reading of the part.
   Pipeline structure: a priming step (not cycle-constrained) loads byte 0
   before the main loop starts; the main loop runs 79 iterations (not 80)
   loading bytes 1-79 while the *previous* byte shifts out; one trailing
   8-cycle window (no address change) lets byte 79 finish shifting out
   after the loop ends. Needs to be fully unrolled (79 straight-line copies
   of the 5-instruction body, no loop overhead) to hit the exact 8-cycle
   budget -- not yet written, that's Phase 6a's implementation step.
   CLK_INH (pin 6) ties low (always enabled, free-running CLK=clk16); CLR
   (pin 9) ties high (inactive) or to the shared POR net.

   **Superseded, twice over, since this entry was written.** PD3/
   `wait_rel` (above) never actually worked -- bench-found incompatible
   with the WAIT flip-flop's own needs before this was ever wired up for
   real (gate-equations.md §3/§6, bring-up-log.md); `SH_LD` moved to
   PD5 instead (2026-09-05), with the `cbi`/`sbi` recipe above accurate
   for *that* design, not this entry's original PD3 one. Then, 2026-09-21,
   `SH_LD` moved again, off PD5 entirely, onto PB6/OC3A -- generated by
   Timer3's own Fast PWM hardware, not `cbi`/`sbi` at all. See wiring.md/
   pin-map.md for the current pin, gate-equations.md for the current
   recipe.
4. **Pull-up resistor values** on `_WR`/`_IORQ`/`_MREQ`/`_RD`/A14/A15/
   `mode_pin` (8255 port pin, no internal pull-up — added 2026-09-02).
   4.7k–10k assumed; verify against real loading (74LS138 + gate inputs) in
   Phase 6b, including the falling-edge recovery of `_MREQ`/`_RD` when the
   1284p actively drives them every 500 ns during a burst.
5. **DIP-40 vs TQFP for the Z80/SRAM/logic.** DIP-40 confirmed for the
   1284P. Z80A is DIP-40. TC551001BPL is DIP-32. 74LS parts are DIP-14/16/20.
   All DIP per the "DIP chips only" constraint. → closed.
6. **Composite-video sync-mixing network** (resistor summing of HSYNC + VSYNC
   + pixel data into one composite signal for a PAL CRT/TV) — exact resistor
   values / sync-amplitude targets to be worked out in Phase 6b against the
   actual monitor.
~~7. String literals eating RAM they don't need to.~~ **Closed
   2026-09-02**: added `usart_puts_P()` (usart.c/h, uses `pgm_read_byte`)
   and moved every message string in `monitor.c` to `PSTR(...)`; command-
   name comparisons in `dispatch()` switched from `strcmp` to `strcmp_P`
   for the same reason (they were also pulling their literals into RAM).
   Result: `.data` dropped from 1776 bytes to 0, `.bss` (excluding the
   pinned ROM buffer) down to exactly 64 bytes (`line[]`) -- confirmed via
   `avr-nm`/`objdump -s -j .data` (empty) after rebuild. Zero warnings.
8. ~~POR (power-on-reset) network R/C value.~~ **Superseded 2026-09-02**:
   the RC network (resistor+capacitor+diode) was retired in favor of a
   plain pull-down resistor on the shared `POR` net (no capacitor, no
   delay-timing estimate to defend — see `gate-equations.md`'s "Power-on
   reset" section). Simpler bench check now: just confirm the net reads
   solidly low immediately at power-up (before the AVR does anything) and
   that the AVR's later active drive overrides it correctly when reset is
   released — no RC time-constant math involved anymore.
9. ~~**8255 verification gaps**, all stemming from no datasheet being
   collected locally.~~ **Closed 2026-09-06** (CP/M-planning session, in
   preparation for Phase 9's bank-switch circuit): pinout, `RESET`
   active-high polarity, and "ports default to input mode after reset"
   all confirmed against the standard 8255A datasheet/reference material
   — see `wiring.md`'s 8255 section for the full pin
   diagram and `gate-equations.md` §8 for the gate-level consequences.
   No local datasheet PDF was collected (verified via web reference
   instead) — still worth pulling a real PDF into `hardware/datasheets/`
   before final schematic capture, per this project's usual practice,
   but no longer a blocking unknown.
10. ~~74LS138/`io-map.md` Phase 7 IO-decode scheme vs. the 8255's `_CS`.~~
    **Partially closed 2026-09-04**: the 8255 now has a real,
    address-qualified `_CS` via the 74LS138 (MSX-style, `0xA8`-`0xAF`),
    not the unconditional `_IORQ` wire this item originally flagged — see
    `gate-equations.md` §7/§8. **Still open**: `io-map.md` itself (and the
    "virtual UART" register layout `plan.md`'s Phase 7 describes) was
    written around a *different*, older A8-A10-based decode scheme using
    16-bit-style IO addressing (`IN r,(C)`, full `B:C` pair) — the new
    74LS138 wiring is a different, 8-bit-port-style convention (Z80
    `OUT (n),A`/`IN A,(n)`, MSX-like) entirely. `io-map.md` has not been
    rewritten to match what's actually on the breadboard now; needs a
    decision on whether to revise it to this new convention or keep both
    schemes for different purposes.
11. **`mode_pin` external resistor: pull-up or pull-down?** The
    ROM-vs-SRAM mode convention flipped 2026-09-04 (LOW=ROM, HIGH=SRAM
    now — see the "Decisions made" entry above for why) specifically to
    make the 8255's forced-low-on-port-reconfiguration behavior harmless.
    That fix only works if the pin also defaults LOW *before* the 8255 is
    configured at all (i.e. while it's still an input, right after
    reset) — which needs a pull-*down*, not the original pull-up. Not yet
    confirmed with the user whether the physical resistor was also
    changed; `gate-equations.md` §2/§4/§5 not yet updated to state the
    new formulas until this is confirmed.
