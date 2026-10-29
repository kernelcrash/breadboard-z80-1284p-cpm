# Timing Analysis

All figures from datasheets in `hardware/datasheets/`; measured values are
recorded in `bring-up-log.md` as phases complete and overwrite the estimates
here.

## Clocks

| Signal | Frequency | Source |
|--------|-----------|--------|
| `clk16` | 16 MHz | oscillator → 1284P XTAL1 (pin 13) + 74LS166 CLK + divide-by-2 FF |
| `clk8` | 8 MHz | 74LS74A toggle of clk16 → Z80 CLK. Z80 T-state = 125 ns |

## Z80 machine cycles (8 MHz)

| Cycle | T-states | Duration |
|-------|----------|----------|
| M1 (fetch) | 4 | 500 ns |
| Read | 3 | 375 ns |
| Write | 4 | 500 ns |
| IO read | 4 | 500 ns |
| IO write | 4 | 500 ns |

WAIT is sampled at the rising edge ending T3 (Z80 UM §Timing): a WAIT held
low during T3 inserts a TW (125 ns) and re-samples — the ROM-emulation loop
exploits this to hold the Z80 indefinitely on one fetch.

## `_BUSRQ` response (risk #3, no `_BUSACK`)

Z80 UM: BUSREQ sampled on the **last rising clock of a machine cycle**; if
active, address/data/control go high-impedance **on the next rising clock**.
Maximum response = 1 T-state (125 ns) after the last T-state edge of the
current machine cycle.

⇒ Conservative safe drive delay after asserting `_BUSRQ`:
**worst case = remaining T-state (125 ns) + sample edge (125 ns) +
tristate edge (125 ns) + SRAM access (70 ns) + margin ≈ 500 ns (4 T-states)**.
Plan: start the 1284P delay loop at 4 T-states (500 ns) = 8 of its own 16 MHz
cycles, and *verify* with the logic analyzer in Phase 6b across different
Z80 instruction timings (a BUSRQ sampled right after a long multi-cycle
instruction is the worst case). If any capture shows contention, increase.

## ROM emulation throughput (Phase 4)

Per served byte, 1284P work at 16 MHz:
- poll detect `_MREQ&RD` low: ~2–4 cycles (poll loop)
- sample 14 address bits (2 port reads): 2 cycles
- lookup + port write: ~3–5 cycles
- latch settle (spec says 1–2 NOPs): 2 cycles
- WAIT release pulse: 2 cycles
- reconfigure D-port direction (if not left as output): 2 cycles

≈ 15–20 cycles/byte = ~1 µs/byte ⇒ 8K ROM copy ≈ 8 ms, well under one 40 ms
frame and under any human time budget. **No hard deadline** — a missed byte
just means a longer WAIT (static RAM, Z80 waits indefinitely). This is the
safest timing path in the design.

## Video (Phase 6)

- HSYNC: 64 µs (PAL line period), Timer1 CTC ÷16, OCR=63999.
- VSYNC: 20 ms (50 Hz), Timer3 CTC ÷64, OCR=4999.
- Active line: 640 px × 62.5 ns = 40 µs of pixel clock within the 64 µs line
  (24 µs spare for front porch + hsync pulse + sync overhead).
- Fetch burst: 80 bytes × 500 ns = 40 µs — **exactly one active-line pixel
  window**. Budget per byte at 16 MHz = 8 cycles:
  - increment 14-bit address (2 ports): 3–4 cycles (16-bit reg pair + 2 out)
  - wait for SRAM settle: SRAM tACC = 70 ns < 500 ns period, so settling is
    free (the 166 loads on a 16 MHz edge well after the address changed)
  - 166 load pulse: 0–2 cycles (software) or 0 (hardware divider)
  ⇒ fits with ~2–4 cycles of margin, *if* the 166 load is software-pulsed;
  the hardware divider option removes that risk entirely (open question #3).
- 200 active lines + 112 blank = 312 lines × 64 µs = 19.97 ms ≈ 20 ms frame.
  VSYNC falls on blanking line 1 (PAL: VSYNC = 1 line, start-of-frame).

## IO virtualization budget (Phase 7)

Blanking window = 112 lines × 64 µs = 7.17 ms per frame, minus VSYNC-line
setup. A full IO service ≈ 30–50 cycles (~3 µs). Even 1000 IO ops/frame
(~3 ms) leaves margin. The constraint is single-frame latency, not total
bandwidth — documented expectation: up to ~20 ms to be serviced.

## Open measurements (fill in `bring-up-log.md`)

1. Actual ROM-emulation per-byte time (Phase 4).
2. Actual 14-bit address increment cost in the video loop (Phase 6a).
3. Empirical `_BUSRQ`-to-tristate margin across instructions (Phase 6b).
4. Pull-up strength check on `_MREQ`/`_RD` falling edges at 500 ns period
   (Phase 6a/6b).
