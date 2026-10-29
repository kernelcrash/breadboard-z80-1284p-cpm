# Z80 Memory Map (64K)

> **2026-09-06: `A16` is no longer grounded.** The map below (and its
> "A16 tied low" notes) describes the machine as built through plan.md's
> Phase 8 — still exactly accurate for that configuration. CP/M work
> (`cpm-plan.md`) adds a bank-switch circuit (`gate-equations.md` §9,
> `wiring.md`) driving SRAM `A16` from a new 8255 output bit
> (`bank`) instead of a ground strap, letting `0x8000-0xFFFF` switch
> between two physical halves of the 128K chip. See `cpm-plan.md` §2 for
> the resulting physical memory map once that circuit is wired — this
> file's map remains the correct description of `bank=0`'s behavior
> (identical to today, per that section), just no longer the *only*
> possible mapping.

```
0x0000 ┌────────────────────────────┐
       │ ROM window (1284P)         │  mode=0: reads → 1284P ROM image (8K)
       │ 0x0000–0x1FFF (8K used)    │  mode=1: reads → SRAM
0x2000 ├────────────────────────────┤
       │ SRAM (TC551001BPL)         │  always writable (mode-independent)
       │ general-purpose            │
0xC000 ├────────────────────────────┤
       │ Video RAM                  │  80 bytes × 200 lines = 16000 bytes
       │ 0xC000–0xFFDF              │  (A14/A15 pulled high; Z80 sees 64K,
       │                            │   A16 tied low)
0xFFE0 ├────────────────────────────┤
       │ unused / free SRAM         │  top 32 bytes (0xFFE0–0xFFFF)
0xFFFF └────────────────────────────┘
```

## ROM window (0x0000–0x1FFF)

- The 1284P emulates only the first **8K** (0x0000–0x1FFF) of address space;
  a ROM image larger than 8K is rejected by the monitor (Xmodem size limit).
- During ROM emulation the 1284P **ignores A14–A15** (spec: "does not matter
  what the two high address pins are") and indexes its internal buffer with
  A0–A13 only. Consequences:
  - Any read of 0x2000–0xBFFF in mode 0 *also* hits the ROM image (aliased).
    Boot code must not rely on reads outside 0x0000–0x1FFF in mode 0.
  - The magic exit address (see below) is a specific A0–A13 value; the boot
    ROM reads it as the final fetch of the copy loop.
- Read-only: writes in mode 0 go to SRAM as usual (the ROM image is in 1284P
  SRAM and never appears on the Z80 write path).

## Video RAM (0xC000–0xFFDF)

- 16,000 bytes = 80 bytes/line × 200 lines, stored linearly:
  line `n` lives at `0xC000 + n*80` (n = 0..199).
- The 1284P's video fetch drives A0–A13 (with A14/A15 pulled high) across
  80 consecutive addresses per line, wrapping A0–A13 continuously between
  lines (the 14-bit counter carries across the 0x4000 boundary, see
  open-questions #2 on stride alignment — 80 is not a power of two).
- The Z80 writes video in the normal way: `LDIR`-style copies into 0xC000+,
  which land in the same SRAM the 1284P reads. No special handling.
- 16,000 < 16,384, so the window fits 0xC000–0xFFFF with 384 bytes of
  headroom; we use exactly 0xC000–0xFFDF and leave 0xFFE0–0xFFFF free.

## Magic exit address

- `0x3FFF` (**changed 2026-09-04, was `0x1FF0`**: the top of the full 14-bit
  address range the ROM window aliases across in mode 0 — A14/A15 don't
  matter — chosen instead of "top of the current 8K buffer" so it can never
  collide with a real ROM image's own copy-loop addresses regardless of how
  big that image grows. `rom_emu.c` compares the full 14-bit address, not
  the buffer-masked one, so this works whether or not the ROM image
  actually fills all 8K.)
- 1284P behavior: serve the byte normally, then exit ROM emulation
  **immediately** (`rom_emu_run()` returns `ROM_EMU_EXIT_MAGIC` as soon as
  it serves this address — no longer just a logged message with the loop
  continuing, see rom_emu.c/rom_emu.h). It will never see another memory
  read again once mode=1, because the Z80 boot code does the magic read,
  configures the 8255 and drives its `mode_pin` low, and jumps into SRAM
  without another ROM-space fetch. **Updated 2026-09-02**: the old design flipped mode
  with any single Z80 `OUT` (a one-way hardware flip-flop latch); the mode
  signal is now an 8255 GPIO pin instead (`gate-equations.md` §2), so the
  boot code must actually configure that 8255 port bit as an output
  before driving it low — a plain `OUT` to an arbitrary port no longer
  does anything. Also no longer hardware-enforced one-way — a software
  convention now, not a physical guarantee.
- Protocol fragility: see open-questions #1 / plan.md risk #5.
