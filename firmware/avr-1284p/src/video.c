/* video.c -- Phase 6 entry point. See video.h.
 *
 * 2026-09-05: real, integrated video steal. sync.c's Timer1 ISR now
 * calls video_fetch_line() itself for each of the 200 active lines,
 * anchored to the same jitter-cancelled point HSYNC's own pulse uses --
 * see sync.c for why calling it from inside the ISR (rather than this
 * file's main loop, the previous arrangement) is what actually made
 * this safe: it sidesteps the interrupt-masking-vs-Timer1-counter race
 * that caused a real crash under the old "video_run() sweeps, Timer1
 * disabled" design. This file's only job now is to start Timer1 and
 * get out of the way.
 *
 * 2026-09-06: `sync_init()`/`sei()` moved ahead of the banner print --
 * same class of bug just fixed in rom_emu.c's magic-address exit (see
 * that file's header comment for the full story): this print is long
 * enough (~50ms at 38400 baud) that arming the timer/interrupt only
 * *after* it returns leaves a real, if likely harmless in practice,
 * gap where the Z80 is already running free (mode_pin's been SRAM-exec
 * for a while by this point) but nothing is yet driving HSYNC/VSYNC or
 * servicing video fetches. The print itself is purely for the human at
 * the terminal and has no reason to gate anything hardware-side --
 * reordered so the real transition completes first.
 *
 * 2026-09-10: the UART-stop loop now dispatches on the byte's value
 * instead of treating any byte as "stop" -- BUSMON_TRIGGER (busmon.h)
 * suspends video generation and hands off to busmon.c's address-bus
 * capture (Phase 12 diagnostic for the Zork 1 hang investigation,
 * bring-up-log.md) instead of returning straight to the monitor. Any
 * other byte keeps the original behaviour unchanged.
 */
#include <avr/io.h>
#include <avr/interrupt.h>
#include <avr/pgmspace.h>
#include "usart.h"
#include "sync.h"
#include "busmon.h"
#include "video.h"
#include "shld_test.h"

void video_run(void)
{
    sync_init();
    shld_test_init();  /* real SH_LD generator (PB6/OC3A) -- "test" in the
                        * name is stale, see shld_test.c's header */
    sei();
    usart_puts_P(PSTR("\r\n[video: real video steal running -- HSYNC on "
                       "PC6, VSYNC on PC7, 200 active lines fetched from "
                       "Z80 $C000 each frame (single TIMER1_COMPA_vect in "
                       "sync.c: HSYNC pulse, a fixed back-porch delay, "
                       "then video_fetch.c). send '"));
    usart_putc(BUSMON_TRIGGER);
    usart_puts_P(PSTR("' for the address-bus monitor, any other byte to "
                       "stop.]\r\n"));

    uint8_t c = 0;
    for (;;) {
        if (UCSR0A & (1 << RXC0)) {
            c = usart_getc();
            break;
        }
    }

    /* Stop the compare-match interrupt before doing anything else --
     * leaving it enabled would keep firing an ISR (doing real bus work,
     * including its own BUSRQ takeover of the address bus) against
     * either a CLI loop or busmon's own polling, neither of which
     * expects it. */
    TIMSK1 = 0;

    if (c == BUSMON_TRIGGER) {
        busmon_run();
    }

    usart_puts_P(PSTR("\r\nvideo stopped, back to monitor\r\n"));
}
