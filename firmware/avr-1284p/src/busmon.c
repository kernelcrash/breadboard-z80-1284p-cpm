/* busmon.c -- Phase 12 diagnostic: address-bus monitor. See busmon.h.
 *
 * Built to chase a specific bug: CP/M running Zork 1 goes completely
 * unresponsive (no keyboard echo, no video activity at all -- see
 * bring-up-log.md's hb_toggle finding) at a reproducible point in a
 * standard walkthrough, with no other diagnostic so far explaining why.
 * This answers the most basic question of all: is the Z80 still
 * fetching instructions when it happens, and if so, roughly where?
 *
 * Workflow (video.c's video_run() calls this on BUSMON_TRIGGER, after
 * already setting TIMSK1 = 0 to suspend video generation): the human
 * plays up to, but does not yet execute, the suspect input; sends
 * BUSMON_TRIGGER, which lands here; this loop then runs silently while
 * they execute the suspect input on the Z80's own keyboard; if/when it
 * hangs, they send any byte back over UART to stop the capture and see
 * the last BUSMON_DEPTH bus samples.
 *
 * Polling technique deliberately mirrors rom_emu.c's own hard-won
 * lesson (see that file's header comment on why its read loop dropped
 * a "wait for _MREQ/_RD to go high" step): back-to-back plain
 * memory-read M-cycles have no guaranteed high gap between them (only
 * an M1/opcode-fetch cycle's T3/T4 refresh states produce one), so an
 * edge-detecting loop here could sit forever mid-cycle waiting for a
 * high sample that a run of non-M1 cycles will never produce. This loop
 * does the same thing rom_emu.c's does: unconditionally re-check
 * _MREQ/_RD and re-sample the address bus every iteration, with no
 * higher-level "did this already get recorded" tracking. A real
 * in-progress bus cycle gets sampled several times in a row (AVR loop
 * iterations are far faster than one Z80 M-cycle) -- an expected,
 * harmless artifact of this technique, not a bug. The dump below
 * collapses consecutive identical samples into "value xN" specifically
 * so this artifact doesn't drown out the interesting parts, and so a
 * genuinely stuck loop (many samples landing on the same handful of
 * addresses) is visible as a few large N's at a glance, not something
 * that has to be eyeballed out of a wall of hex.
 *
 * No printing at all happens during capture -- the whole point is to
 * not disturb the timing of whatever the Z80 is doing while under
 * observation.
 *
 * 2026-09-10: BUSMON_DEPTH raised from 128 to 1024 after the first
 * real capture (bring-up-log.md) came back as one long, coherent,
 * *non-repeating* BDOS/BIOS/SD-driver call chain rather than a stuck
 * loop -- every single sample decoded to a sensible named routine once
 * the (inferred, not measured) A14/A15=11 case was tried against
 * bios.sym, right up through compute_lba_and_offset/build_rw_cmd/
 * sd_cs_assert for drive B. That's a real, useful finding, but 128
 * samples is too short a window (very roughly a few hundred
 * microseconds of Z80 execution) to tell "captured mid-flight of an
 * ordinary, slightly slow disk read" apart from "captured the last
 * gasp before it got stuck a little further on" -- an 8x deeper buffer
 * (2KB of RAM, cheap against the 1284P's 16K) gives a much longer
 * window at the same sampling rate, and the RLE dump makes a real stuck
 * loop obvious (heavy repetition dominating the output) instead of
 * requiring another manual symbol-table cross-reference to notice.
 *
 * A14/A15 are NOT wired to the AVR at all (see monitor.c's own header
 * comment, and pins.h) -- every sample here is really one of 4 possible
 * physical 16K-aligned addresses (value | 0x0000/0x4000/0x8000/0xC000),
 * ambiguous without other context (known code layout: TPA starts
 * $0100, trampoline/font/blit $7C00-$BFFF, video RAM/CCP/BDOS/BIOS
 * $C000 up -- the 2026-09-10 capture's own values matched that last
 * region, +0xC000, almost perfectly). The dump below says so explicitly
 * rather than implying a real 16-bit address.
 */
#include <avr/io.h>
#include <avr/pgmspace.h>
#include <stdint.h>
#include "pins.h"
#include "usart.h"
#include "busmon.h"

#define BUSMON_DEPTH 1024 /* power of two -- wrap is (idx+1) & (DEPTH-1) */

void busmon_run(void)
{
    static uint16_t buf[BUSMON_DEPTH];
    uint16_t idx = 0;

    usart_puts_P(PSTR("\r\n[busmon: capturing -- do the thing on the Z80, "
                       "then send any byte here to stop]\r\n"));

    for (;;) {
        if (UCSR0A & (1 << RXC0)) {
            (void)usart_getc();
            break;
        }
        if (!(Z80_CTRL_PIN & (1 << BIT_MREQ)) &&
            !(Z80_CTRL_PIN & (1 << BIT_RD))) {
            buf[idx] = z80_read_addr();
            idx = (uint16_t)((idx + 1) & (BUSMON_DEPTH - 1));
        }
    }

    /* `idx` is already the oldest sample's slot (one past the last
     * write, wrapped) -- dump starting there for chronological order. */
    usart_puts_P(PSTR("\r\n[busmon: stopped. Last 1024 A0-A13 samples, "
                       "oldest first, runs of consecutive identical "
                       "samples collapsed to 'value xN' (N in hex, same "
                       "as every other number here -- a large N means "
                       "the bus sat at that one value for N polls in a "
                       "row, NOT that N Z80 cycles elapsed, since the "
                       "AVR polls far faster than one Z80 M-cycle). "
                       "A14/A15 are NOT wired to the AVR -- each value "
                       "is really one of 4 possible real addresses: "
                       "value, value+0x4000, value+0x8000, "
                       "value+0xC000.]\r\n"));

    uint16_t i = 0;
    uint16_t printed = 0;
    while (i < BUSMON_DEPTH) {
        uint16_t j = (uint16_t)((idx + i) & (BUSMON_DEPTH - 1));
        uint16_t v = buf[j];
        uint16_t run = 1;
        while ((i + run) < BUSMON_DEPTH) {
            uint16_t j2 = (uint16_t)((idx + i + run) & (BUSMON_DEPTH - 1));
            if (buf[j2] != v) {
                break;
            }
            run++;
        }

        usart_puthex16(v);
        if (run > 1) {
            usart_putc('x');
            usart_puthex16(run);
        }
        usart_putc(' ');

        printed++;
        if ((printed & 7) == 0) {
            usart_puts_P(PSTR("\r\n"));
        }

        i = (uint16_t)(i + run);
    }
    usart_puts_P(PSTR("\r\n"));
}
