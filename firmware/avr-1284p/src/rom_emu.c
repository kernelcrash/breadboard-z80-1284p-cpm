/* rom_emu.c -- Phase 4 ROM-emulation loop. See rom_emu.h / plan.md
 * Phase 4 / gate-equations.md.
 *
 * plan.md originally called for hand-written AVR assembly here, but risk
 * #1 in the same document notes the timing is NOT a hard deadline: _WAIT
 * can be held low indefinitely (static RAM, no refresh hazard), so the
 * Z80 just stalls a little longer if this loop is slow -- it never
 * breaks correctness. Plain C is used instead for maintainability;
 * revisit only if bench measurement (bring-up-log.md Phase 4) shows an
 * actual throughput problem, not preemptively.
 */
#include <avr/io.h>
#include <avr/pgmspace.h>
#include <stdint.h>
#include "pins.h"
#include "usart.h"
#include "rom_emu.h"
#include "databus.h"

rom_emu_exit_t rom_emu_run(const uint8_t *rom, uint16_t rom_mask)
{
    /* Re-arm wait_rel (idle-high) before releasing the Z80 -- NOT
     * redundant with main.c's own one-time power-on init. A previous
     * session's magic-address exit (below) deliberately drives this
     * low and leaves it there permanently, and nothing else in this
     * codebase ever raised it back up -- confirmed 2026-09-10 by
     * grepping every BIT_WAITREL reference. Without this line, a
     * second `s` (start ROM emulation) in the same monitor session
     * (no AVR power-cycle in between) left the WAIT flip-flop's async
     * PRESET permanently asserted from the prior exit: _WAIT could
     * never be pulled low again, so the Z80 ran completely unthrottled
     * from its very first fetch, never giving this loop a chance to
     * serve a single byte -- "can't get it to reboot again into ROM
     * emulation" on the bench, real and reproducible. A full AVR power
     * cycle masked this (main.c's own init re-arms it once at true
     * startup), which is why it went unnoticed until this was actually
     * tried. */
    Z80_CTRL_PORT |= (1 << BIT_WAITREL);

    /* Release the Z80 from reset -- it starts fetching immediately. */
    Z80_CTRL_PORT |= (1 << BIT_RESET);

    for (;;) {
        /* Bail out to the monitor if the user sends anything -- without
         * this there is no way back to the CLI except a power cycle. */
        if (UCSR0A & (1 << RXC0)) {
            (void)usart_getc();
            Z80_CTRL_PORT &= (uint8_t)~(1 << BIT_RESET); /* stop the Z80 safely */
            usart_puts_P(PSTR("\r\naborted, Z80 held in reset\r\n"));
            return ROM_EMU_EXIT_ABORT;
        }

        /* Poll for a memory read (_MREQ & _RD both low). This mirrors the
         * hardware `_S` signal for the mode-0 case (gate-equations.md
         * §0: _S = (_G OR mode) AND (_IORQ OR _RD), _G = _MREQ OR _RD) --
         * for a plain mode-0 memory read that reduces to exactly
         * _MREQ=0 & _RD=0, which is all this loop needs: IO reads
         * (Phase 7) and mode-1 SRAM reads are never this loop's job (see
         * rom_emu.h for why it's still safe if one happens anyway). */
        if ((Z80_CTRL_PIN & (1 << BIT_MREQ)) || (Z80_CTRL_PIN & (1 << BIT_RD))) {
            continue;
        }

        uint16_t addr = z80_read_addr();

        /* Present the byte via the 74HC595 (2026-09-16, was a direct
         * DATA_PORT write to a 74LS373 -- see pins.h/databus.h).
         * databus_send() already includes the shift-then-latch
         * sequence; MOSI/SCK/RCLK DDR is set once at boot
         * (databus_init(), called from main.c) -- the 595's own
         * output-enable is fully hardware-gated (OE = _S) exactly as
         * the 373's was, so there is nothing else to enable here.
         * `rom_mask` (not the full 14-bit address) is deliberate: the
         * ROM buffer is 8K (13 bits) but A0-A13 spans 16K, so without
         * this mask an address in 0x2000-0x3FFF would index past the
         * end of `rom` -- masking aliases the 8K image across that
         * range instead of overrunning it. */
        databus_send(rom[addr & rom_mask]);

        /* A couple of cycles' margin before releasing WAIT, matching
         * plan.md's "pause for one or two NOPs". Generous either way:
         * the old 373 needed this to cover its own ~10-15ns propagation
         * delay from data-valid to output-valid; databus_send() above
         * already blocks until its own RCLK pulse (the 595's own
         * propagation delay equivalent) has happened, so this margin is
         * now stricter insurance than it needs to be -- left in rather
         * than trimmed, since it's cheap and unrelated to any hard
         * deadline (see rom_emu.c's own header). */
        __asm__ __volatile__("nop\n\tnop");


        if (addr == ROM_EMU_MAGIC_ADDR) {
            /* Byte already served and WAIT already released above --
             * that's enough for THIS read. But once this function
             * returns, nothing is left running to service any *future*
             * read either: the WAIT FF (gate-equations.md §3) has no
             * mode_pin gating -- D is tied straight to _RD, so it
             * asserts _WAIT on *every* read unconditionally, ROM or
             * SRAM, relying entirely on a wait_rel pulse to ever release
             * it. Leaving wait_rel idle-high (as the pulse above just
             * did, ready to pulse again) means the Z80's very next
             * instruction fetch would latch _WAIT low with nothing left
             * to release it -- a permanent hang, found 2026-09-05 before
             * this was ever exercised on real hardware (the previous
             * version of this loop ran forever regardless of the magic
             * address, which accidentally covered for this by continuing
             * to service every read blindly).
             *
             * Fix: drive wait_rel low again and leave it there. The
             * async PRESET stays asserted indefinitely, forcing Q
             * (_WAIT) permanently high (released) regardless of
             * _RD/CLK from this point on -- exactly what's needed once
             * nothing is left to babysit individual reads. This is a
             * one-way trip, matching the mode switch itself: there's no
             * path back into ROM emulation without a full reset (which
             * re-asserts the POR/CLEAR net and reinitializes everything
             * cleanly anyway). video.c's later reuse of this same pin as
             * a brief high-then-low test pulse is compatible with this
             * -- it always returns to low, restoring the invariant.
             *
             * 2026-09-06: this drive-low MUST happen before the debug
             * print below, not after -- found via a real bench symptom
             * (corrupted/duplicated video content right after the magic
             * address) while investigating "does something strange
             * happen to the instruction that follows the magic-address
             * access." It does: with the print first, wait_rel sits
             * idle-high (from the per-byte pulse above) for as long as
             * usart_puts_P() takes -- ~20ms at 38400 baud for this
             * string -- during which the WAIT FF is NOT preset-held, so
             * it latches _WAIT low again on the Z80's very next
             * instruction fetch exactly as normal (D=_RD, no mode
             * gating), and nothing is polling to release it (this
             * function is blocked in the print, not looping). The Z80's
             * first post-magic-address instruction fetch was silently
             * eating an unintended ~20ms WAIT-stall every single run.
             * Not fully confirmed as the cause of the specific
             * duplication symptom (this delay is identical for every
             * program that hits the magic address, so it doesn't by
             * itself explain why one program was affected and another
             * wasn't) but it's a real, unconditional bug regardless --
             * fixed by reordering so the hardware transition completes
             * before anything blocks on I/O for the human's benefit. */
            Z80_CTRL_PORT &= (uint8_t)~(1 << BIT_WAITREL);
            usart_puts_P(PSTR("\r\n[magic address served -- exiting ROM "
                               "emulation, WAIT disabled permanently]\r\n"));
            return ROM_EMU_EXIT_MAGIC;
        }
        /* Pulse wait_rel (active-low async PRESET on the WAIT flip-flop,
         * gate-equations.md §3): low then high forces _WAIT released.
         * Edge-triggered on the *next* slow-read start, so this can't
         * re-trigger while _MREQ/_RD are still low from this same
         * cycle. Intended to be `cbi`/`sbi` back-to-back -- each is 2 AVR
         * clock cycles, so tight this is a clean 4-cycle (250 ns @
         * 16 MHz) low pulse, comfortably over the 74LS74A's
         * datasheet-specified 30 ns minimum PRE/CLR pulse width
         * (hardware/datasheets/sn74ls74a.pdf, recommended operating
         * conditions table).
         *
         * 2026-09-07: written as inline asm, not the two plain C
         * statements this used to be -- found via a real disassembly
         * dump (bring-up-log.md) that GCC was common-subexpression-
         * eliminating the "drive low" step above (identical to the
         * magic-address branch's own "drive low and leave it") into a
         * *single* instruction shared by both branches, hoisted ahead of
         * the `addr == MAGIC` comparison. Harmless for the magic branch
         * (it never runs the `sbi` anyway), but for every *normal* byte
         * it meant the comparison's own instructions (`cpi`/`sbci`/
         * `brne`, 4 cycles) landed *between* the `cbi` and `sbi` --
         * measured from the real disassembly at 8 cycles (500 ns)
         * cbi-to-sbi-done instead of the intended tight 4 (250 ns), a
         * real, silent ~2x stretch of every single byte's WAIT-release
         * pulse. Still comfortably over the 30 ns minimum either way, so
         * not a correctness bug by itself, but a genuine, avoidable
         * stretch of AVR-loop-paced read timing worth closing now that
         * it's been found, especially given ongoing investigation into
         * whether this loop's own pacing interacts with the bank-switch
         * circuit (cpm-plan.md §2, bring-up-log.md). `asm volatile` is
         * opaque to the optimizer -- nothing can be hoisted into or out
         * of it, guaranteeing these two instructions stay adjacent
         * regardless of what the magic-address branch above does. */
        asm volatile(
            "cbi %[port], %[bit]\n\t"
            "sbi %[port], %[bit]\n\t"
            :: [port] "I" (_SFR_IO_ADDR(Z80_CTRL_PORT)),
               [bit] "I" (BIT_WAITREL)
            : "memory"
        );

        /* No "wait for _MREQ/_RD to go high" step here on purpose --
         * bench-found bug (bring-up-log.md Phase 4): an earlier version
         * had one, reasoning that without it the same still-in-progress
         * cycle would get needlessly re-served on every iteration until
         * the Z80 finished it. True, but harmless -- re-driving the same
         * address with the same byte and re-pulsing wait_rel (idempotent,
         * _WAIT already released) costs a few redundant AVR cycles, not
         * correctness. The wait-loop itself was the real bug: it relied
         * on sampling a guaranteed-high window between cycles, but that
         * gap only exists after an M1 (opcode fetch) cycle, whose T3/T4
         * refresh states hold _RD high for a full 2 T-states (Z80 UM:
         * "Clock state T3 and T4 of a fetch cycle are used to refresh
         * dynamic memories... An RD signal is not generated during
         * refresh time"). Plain memory-read M-cycles (operand fetches,
         * back-to-back with no refresh) have no such mandated gap -- on
         * real hardware this hung permanently the first time two of
         * those happened in a row, because the loop never observed a
         * high sample and never returned to the top of the poll. Simply
         * not waiting sidesteps the whole class of bug: the outer poll
         * just re-reads whatever address is *currently* on the bus every
         * iteration, so it tracks the Z80 correctly whether or not it
         * ever "sees" a gap between cycles. (The magic-address check
         * above returns on the first observation, so this redundant
         * re-serving can no longer cause it to fire twice either.) */
    }
}
