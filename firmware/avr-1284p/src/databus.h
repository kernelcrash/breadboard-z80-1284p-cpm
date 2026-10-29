/* databus.h -- serial byte presentation to the Z80 via a 74HC595
 * (2026-09-16, replaced a direct parallel PORTB write to a 74LS373 --
 * see pins.h's own comment and docs/gate-equations.md §4 for the full
 * history/reasoning).
 */
#ifndef DATABUS_H
#define DATABUS_H

#include <stdint.h>
#include <avr/io.h>
#include "pins.h"

/* One-time setup: configures MOSI/SCK/RCLK as outputs and puts the
 * AVR's hardware SPI peripheral into master mode at its fastest
 * available rate (F_CPU/2). Call once at boot, before any
 * databus_send(). */
void databus_init(void);

/* Presents one byte to the 595: shifts it in via hardware SPI (SER/
 * SRCLK), then pulses RCLK once to latch it into the 595's output
 * register, making it visible on Q0-Q7 -- and hence the Z80's data
 * bus, gated by the same hardware (mode_pin/_RD NAND network) the 373
 * used, now driving the 595's /OE instead. Roughly 20-25 AVR cycles,
 * vs. the old 373's single-cycle parallel write -- an accepted
 * tradeoff: rom_emu.c (ROM emulation) and any future virtual-IO
 * response are the only callers, and neither has a hard deadline
 * (rom_emu.c's own header says so outright); the video-fetch burst
 * (the one genuinely cycle-exact path in this design) never touches
 * this function at all -- see 74HC595-plan.md.
 *
 * `static inline`, not a real function (2026-09-16, after a bench
 * logic-analyzer measurement showed ~5us actual _MREQ low time --
 * bring-up-log.md worked out that a real `call`/`ret` boundary here
 * was costing ~8 of the ~30 added cycles, pure overhead the old
 * single-instruction 373 write never paid): defining the body here in
 * the header, rather than in databus.c, lets the compiler fold it
 * directly into rom_emu_run()'s poll loop at its one call site instead
 * of emitting a separate callable routine. Purely a speed tweak, not a
 * correctness fix -- this path still has no hard deadline either way,
 * see the paragraph above -- done because it was cheap and asked for,
 * not because it was needed. */
static inline void databus_send(uint8_t b)
{
    SPDR = b;
    while (!(SPSR & (1 << SPIF))) {
        /* Spin until the 8-bit shift completes (~16 cycles at the
         * fastest divider) -- fine to block here, see the paragraph
         * above. */
    }

    /* Latch: RCLK's rising edge moves the shift register's contents
     * into the 595's output register (and hence onto Q0-Q7). The
     * shift itself (SER/SRCLK, just done above) doesn't do this on its
     * own -- the 595's two-stage design is exactly what lets the next
     * byte start shifting in without disturbing what's currently
     * presented, though this project doesn't yet pipeline that way. */
    DATA_SPI_PORT |= (1 << BIT_RCLK);
    DATA_SPI_PORT &= (uint8_t)~(1 << BIT_RCLK);
}

#endif /* DATABUS_H */
