/* video_fetch.c -- Phase 6a pixel-fetch burst. See video_fetch.h.
 *
 * 2026-09-21: this file is a debug-only relic, reached solely via the
 * monitor's "vf" command, never from the real ISR (sync.c has its own
 * inline copy of this recipe, the one that actually runs every active
 * line). The SH_LD pulse this file generates (PD5, cbi/sbi, described
 * in detail below) no longer reaches real hardware -- SH_LD moved to
 * PB6/OC3A (hardware Timer3) on that date, and PD5 is now physically
 * disconnected from the 74LS166. Everything below is accurate history
 * for how this file's own debug path worked up to that point; it has
 * not been migrated to the new pin, so "vf"'s own video output is not
 * meaningful until/unless it is.
 *
 * 2026-09-05, SH_LD moved off PD3 (wait_rel) onto its own pin, after two
 * rounds of real bugs on the bench (bring-up-log.md) exposed a
 * fundamental conflict, not just a bad ordering:
 *
 * Round 1: rom_emu.c's magic-address exit drives wait_rel low and
 * leaves it low *permanently*, holding the WAIT flip-flop's async
 * PRESET asserted forever -- necessary because that FF has no mode_pin
 * gating (gate-equations.md §3, D=_RD unconditionally) and would
 * otherwise latch _WAIT low on every read with nothing to release it.
 * SH_LD pulsing needs the *opposite* resting state: every pulse used to
 * end with `sbi` (high), since the 166 needs to sit in "shift" mode
 * between loads -- so the first burst left PD3 high on return, hanging
 * the Z80's very next read. First fix: force wait_rel back low at the
 * end of every burst.
 *
 * Round 2: that fix just moved the conflict rather than resolving it --
 * SH_LD now rested *low* between bursts instead of high, which is
 * "load" mode on the 166, not "shift". Since CLK (clk16) never stops,
 * SH_LD low the whole time between bursts means the 166 keeps
 * re-loading whatever floats onto the shared data bus on every single
 * clock edge for the entire inter-burst/blanking period, continuously
 * emitting garbage on QH that has nothing to do with real pixel data --
 * confirmed on the bench (steady SH_LD pulses, correct HSYNC/VSYNC, but
 * random video noise bleeding into blanking). PD3/wait_rel and SH_LD
 * fundamentally want *opposite* idle states (low vs. high) and can't
 * share one pin no matter what order things happen in.
 *
 * Real fix: SH_LD moved to PD5 instead, on its own dedicated net --
 * physically disconnected from the Z80's _IORQ pin on the breadboard
 * (its pull-up removed too), not just repurposed while still shared.
 * No competing role, no reliance on the Z80 tristating anything, no
 * pull-up to hold an idle state: PD5 is configured as a permanent
 * output once at boot (main.c), idling high (shift mode) between
 * bursts, exactly like a normal dedicated GPIO. video_fetch_line()
 * doesn't touch this pin's DDR at all any more -- only
 * video_fetch_burst()'s own cbi/sbi pulses touch it, same as before.
 * PD3/wait_rel goes back to being untouched by this file entirely,
 * resolved for good rather than juggled.
 *
 * The core routine (video_fetch_burst, below) is hand-written assembly:
 * per byte we get exactly 8 AVR cycles (500ns @ 16MHz, since the AVR and
 * the 74LS166's shift clock share the same 16MHz master) and the recipe
 * uses every one of them (open-questions.md #3):
 *
 *   adiw (2)  -- 16-bit address increment, spanning both port bytes
 *   out   (1)  -- address low byte -> PORTA (A0-A7)
 *   out   (1)  -- address high byte -> PORTC bits 0-5 (A8-A13)
 *   cbi   (2)  -- SH_LD low (PD5, dedicated) -- load this byte
 *   sbi   (2)  -- SH_LD high -- resume shifting
 *   = 8 cycles, zero spare.
 *
 * Verified safe despite zero margin against the real 74LS166 datasheet
 * (sn74ls166a.pdf, function table): SH/LD is re-evaluated on *every*
 * CLK rising edge, not latched once. Holding it low across the 2 edges
 * cbi+sbi guarantees (125ns) means even if the first edge lands before
 * the TC551001's ~70ns access time has elapsed, the second edge (125ns
 * after the address changed) reloads with the by-then-settled data and
 * simply overwrites the first result.
 *
 * Pipeline structure, because loading byte i and shifting out byte i-1
 * happen in the same 8-cycle window:
 *   - priming: write the starting address, a fixed (not cycle-
 *     constrained) settle delay, one SH_LD pulse -- loads byte 0.
 *   - main loop, VIDEO_BYTES_PER_LINE-1 (79) iterations, exactly 8
 *     cycles each, fully unrolled (no loop overhead survives the
 *     budget): iteration i increments to byte i's address, writes it,
 *     and pulses SH_LD to load byte i, while byte i-1 (loaded by the
 *     previous iteration, or by priming for i=1) shifts out.
 *   - trailing window: one more 8-cycle gap, no address/SH_LD change,
 *     so byte 79 (loaded by the last main-loop iteration) finishes
 *     shifting out before the caller releases the bus.
 *
 * `adiw` only ever needs to touch bits 0-5 of the address high byte for
 * this project's actual video buffer (200 lines x 80 bytes = 16000 <
 * 16384 -- the 14-bit address never reaches 16128, the point at which a
 * carry would first reach bit 6). That's what makes it safe to fold the
 * live HSYNC/VSYNC state (PORTC bits 6-7) into the high byte once before
 * the burst and never touch it again -- see video_fetch_line(). This is
 * a real constraint on the video buffer size/line count, not a general
 * guarantee -- revisit this comment if either ever changes.
 *
 * NOT YET BENCH-VERIFIED. Cycle counts below are hand-derived against
 * the AVR instruction set and cross-checked against this file's own
 * compiled disassembly (bring-up-log.md), matching this project's
 * standing convention -- but per that same convention, not trusted
 * until confirmed on real hardware: check with a logic analyzer that
 * the address bus increments every 500ns and that SH_LD pulses land
 * where expected relative to each address change, and that SH_LD sits
 * high for the whole inter-burst/blanking period (should be immediate
 * now that it's a dedicated, permanently-configured output rather than
 * relying on an external pull-up after a DDR release).
 */
#include <avr/io.h>
#include <util/atomic.h>
#include <stdint.h>
#include "pins.h"
#include "video_fetch.h"

/* Cycles to wait after asserting _BUSRQ before assuming the Z80 has
 * actually released the bus. open-questions.md #1, verified against the
 * real Z80 UM (2026-09-05) rather than guessed: "BUSREQ is sampled ...
 * with the rising edge of the last clock period of any machine cycle
 * ... the maximum time for the CPU to respond ... is the length of a
 * machine cycle" (Z80 UM, Bus Request/Acknowledge Cycle). Scanned every
 * M-cycle T-state count in the UM's own instruction timing tables for
 * the actual worst case rather than assume a number: 6 T-states is the
 * longest documented single M-cycle in the whole instruction set (the
 * second M-cycle of `LD SP,IX`/`IY` and `INC`/`DEC IX`/`IY`) -- also
 * matches the interrupt-acknowledge cycle's 2 automatic wait states
 * added to M1's normal 4, so it covers that edge case too even though
 * this project's test programs never enable interrupts. At the Z80's
 * 8MHz clock (16MHz/2) that's 750ns = 12 AVR cycles @ 16MHz.
 *
 * 2026-09-05: trimmed from 16 to 14 (still 2 cycles/125ns of margin over
 * the verified 12-cycle requirement, not the previous ~33%) once this
 * function started being called from inside sync.c's HSYNC ISR for
 * every active line -- the *total* ISR budget turned out to be the
 * tighter constraint (see sync.c's header comment), and this delay is
 * pure margin on top of an already-verified hard number, unlike
 * SYNC_TARGET's margin (softer, covers an estimated rather than
 * measured baseline) -- so it's the safer place to trim first, but only
 * a little. Still not an actual bench measurement of the real Z80 bus-
 * release latency (this project's usual bar); revisit if one ever
 * disagrees. */
#define BUSRQ_SAFE_CYCLES 14

/* Hardcoded I/O addresses/bit used inside the asm block below, matching
 * this project's established practice (sync.c's NOP sled) rather than
 * threading pins.h's SFR macros through inline-asm operand constraints.
 * Guarded by the _Static_assert block below so a future pins.h change
 * can't silently desync the asm from reality. */
#define ASM_ADDR_LO_PORT 0x02 /* PORTA */
#define ASM_ADDR_HI_PORT 0x08 /* PORTC */
#define ASM_Z80_CTRL_PORT 0x0B /* PORTD */
#define ASM_BIT_SH_LD 5 /* PD5, dedicated SH_LD, permanent output (main.c) */

_Static_assert(_SFR_IO_ADDR(ADDR_LO_PORT) == ASM_ADDR_LO_PORT,
               "video_fetch_burst's hardcoded ADDR_LO_PORT address is stale");
_Static_assert(_SFR_IO_ADDR(ADDR_HI_PORT) == ASM_ADDR_HI_PORT,
               "video_fetch_burst's hardcoded ADDR_HI_PORT address is stale");
_Static_assert(_SFR_IO_ADDR(Z80_CTRL_PORT) == ASM_Z80_CTRL_PORT,
               "video_fetch_burst's hardcoded Z80_CTRL_PORT address is stale");
_Static_assert(BIT_SH_LD == ASM_BIT_SH_LD,
               "video_fetch_burst's hardcoded SH_LD bit is stale");

/* The cycle-exact ramp itself. `addr`'s high byte must already have the
 * live HSYNC/VSYNC bits (PORTC 6-7) folded in -- see video_fetch_line().
 * Runs with _BUSRQ/_MREQ/_RD/the address bus already under AVR control;
 * SH_LD (PD5) is a permanent output (main.c) and isn't taken over/
 * released here at all. */
static void video_fetch_burst(uint16_t addr)
{
    asm volatile(
        /* -- priming: load byte 0 -- */
        "out %[lo], %A[a]\n\t"
        "out %[hi], %B[a]\n\t"
        ".rept 8\n\t"              /* settle delay, not cycle-constrained */
        "nop\n\t"
        ".endr\n\t"
        "cbi %[ctrl], %[wr]\n\t"
        "sbi %[ctrl], %[wr]\n\t"
        /* -- main loop: VIDEO_BYTES_PER_LINE-1 iterations, 8 cycles each -- */
        ".rept %[n]\n\t"
        "adiw %A[a], 1\n\t"        /* 2 cycles */
        "out %[lo], %A[a]\n\t"     /* 1 */
        "out %[hi], %B[a]\n\t"     /* 1 */
        "cbi %[ctrl], %[wr]\n\t"   /* 2 -- SH_LD low, load this byte */
        "sbi %[ctrl], %[wr]\n\t"   /* 2 -- SH_LD high, resume shift */
        ".endr\n\t"
        /* -- trailing window: let the last byte finish shifting out,
         * ending with SH_LD high (shift mode) -- the caller releases
         * this pin to input right after, and the external pull-up
         * keeps it high from there, so no explicit "restore" step is
         * needed here the way PD3/wait_rel once did. -- */
        ".rept 8\n\t"
        "nop\n\t"
        ".endr\n\t"
        : [a] "+w" (addr)
        : [lo] "I" (ASM_ADDR_LO_PORT),
          [hi] "I" (ASM_ADDR_HI_PORT),
          [ctrl] "I" (ASM_Z80_CTRL_PORT),
          [wr] "I" (ASM_BIT_SH_LD),
          [n] "n" (VIDEO_BYTES_PER_LINE - 1)
        : "memory"
    );
}

void video_fetch_line(uint16_t addr14)
{
    /* Whole burst runs with interrupts off. If sync.c's Timer1 ISR fired
     * mid-burst it would blow the cycle-exact 8-cycles/byte budget the
     * asm loop depends on (unpredictable SH_LD timing) and race with
     * this function's own ADDR_HI_PORT writes (HSYNC bit vs. address
     * bits sharing the same register). ATOMIC_BLOCK saves/restores
     * SREG, so this is safe to call regardless of whether interrupts
     * were already on or off.
     *
     * This masks interrupts for the whole ~45us burst, not just the
     * cycle-exact part -- fine on its own, but 2026-09-05 a real crash
     * turned up when video_run() called this 200 times nearly back-to-
     * back *with* Timer1's ISR enabled: masked for that long, Timer1's
     * free-running hardware counter moves arbitrarily far past what the
     * ISR's jitter-cancellation math expects by the time it finally
     * gets to run, which used to underflow a delay computation into a
     * wild jump (fixed in sync.c's ISR, which now clamps instead of
     * trusting a stale reading -- but the real fix here is that
     * video_run() no longer runs Timer1 concurrently with this at all,
     * see video.c). Noted here because the next thing that calls this
     * function alongside an active ISR needs to know this constraint
     * exists, not just find it by crashing again. */
    ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
        /* 1. Assert _BUSRQ, then wait for the Z80 to actually release
         * the bus before touching anything it might still be driving. */
        Z80_CTRL_PORT &= (uint8_t)~(1 << BIT_BUSREQ);
        __builtin_avr_delay_cycles(BUSRQ_SAFE_CYCLES);

        /* 2. Take over _MREQ/_RD: PORT bits set high *before* DDR
         * switches to output, so each pin transitions from pulled-high
         * to driven-high with no glitch low, then explicitly drive both
         * low to begin the burst read (plan.md Phase 6b). SH_LD (PD5)
         * needs none of this -- it's a permanent output (main.c),
         * already idling high; video_fetch_burst()'s own priming
         * sequence pulses it low for the first time, once it's ready to
         * load byte 0. */
        Z80_CTRL_PORT |= (1 << BIT_MREQ) | (1 << BIT_RD);
        Z80_CTRL_DDR |= (1 << BIT_MREQ) | (1 << BIT_RD);
        Z80_CTRL_PORT &= (uint8_t)~((1 << BIT_MREQ) | (1 << BIT_RD));

        /* 3. Take over the address bus. Only bits 0-5 of ADDR_HI -- bits
         * 6-7 are HSYNC/VSYNC (sync.c) and must stay exactly as they
         * are. */
        ADDR_LO_DDR = 0xFF;
        ADDR_HI_DDR |= ADDR_HI_MASK;

        /* 4. Fold the *live* HSYNC/VSYNC state into the address's high
         * byte once, here -- the asm loop's `out` overwrites the whole
         * PORTC byte every iteration and never touches bits 6-7 again
         * (see video_fetch_burst's header comment for why that's safe
         * for this project's actual address range). */
        {
            uint16_t addr = (addr14 & 0x3FFFu) |
                             ((uint16_t)(ADDR_HI_PORT & 0xC0u) << 8);
            video_fetch_burst(addr);
        }

        /* 5. Release everything back to the Z80. SH_LD (PD5) is left
         * alone -- still a permanent output, already idling high since
         * every SH_LD pulse above ends with `sbi`, nothing to release. */
        Z80_CTRL_PORT |= (1 << BIT_MREQ) | (1 << BIT_RD);
        Z80_CTRL_DDR &= (uint8_t)~((1 << BIT_MREQ) | (1 << BIT_RD));
        ADDR_LO_DDR = 0;
        ADDR_HI_DDR &= (uint8_t)~ADDR_HI_MASK;
        Z80_CTRL_PORT |= (1 << BIT_BUSREQ);
    }
}
