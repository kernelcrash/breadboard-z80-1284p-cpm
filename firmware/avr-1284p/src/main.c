/* main.c -- monitor firmware (see monitor.c / plan.md). As of Phase 3 the
 * Z80/SRAM are expected on the bus (free-running NOPs, no 373/WAIT/mode-
 * latch yet -- that's Phase 4), controlled via the monitor's `z`/`a`
 * commands; control-line defaults below stay safe either way.
 *
 * History: Phase 0 was a build-only stub. Phase 1 replaced main() with a
 * PD3 busy-loop toggle to validate the 16 MHz external clock on a scope
 * (see bring-up-log.md -- expect 1.6 MHz, not 3.2 MHz: the loop's `out`
 * fires once per 5-cycle iteration, so each iteration is one half-period,
 * giving a 10-cycle full period). That test firmware confirmed Phase 1;
 * Phase 2 replaced it with the real monitor, extended in Phase 3 with Z80
 * bus control.
 */
#include <avr/io.h>
#include <avr/interrupt.h>
#include <util/delay.h>
#include <stdint.h>
#include "pins.h"
#include "usart.h"
#include "monitor.h"
#include "databus.h"

int main(void)
{
    cli();

    /* Belt-and-braces: release JTAG pins (PC2-PC5 = A10-A13) for GPIO use
     * immediately. The real protection is the JTAGEN fuse (unprogrammed,
     * see pin-map.md Fuse settings); this is a defensive extra, not the
     * primary mechanism, and per the datasheet a single write like this
     * isn't guaranteed to change JTD (a timed double-write is specified) --
     * kept anyway as free insurance, not relied upon alone. */
    MCUCR = (1 << JTD);

    /* Z80 control lines: safe default before the Z80 is populated
     * (Phase 3) or reset is explicitly managed (Phase 3+ monitor command).
     *  - _RESET driven LOW (asserted): the Z80 must be held in reset from
     *    power-up per CLAUDE.md ("the 1284p starts up and holds the Z80
     *    in reset"), released only by an explicit future monitor command.
     *  - _BUSRQ driven HIGH (not asserted): only used during video steal
     *    (Phase 6+).
     *  - WAIT-release driven HIGH (idle/inactive): this is an active-low
     *    async PRESET on the WAIT flip-flop (gate-equations.md §3) --
     *    idling it LOW would hold that preset permanently asserted from
     *    power-up, forcing _WAIT released forever and defeating WAIT
     *    generation entirely. Only pulsed low momentarily by rom_emu.c
     *    once a byte is actually on the bus. (Caught and fixed here
     *    2026-09-02, before this line was ever wired to real WAIT-latch
     *    hardware -- an earlier version of this file had it backwards.)
     *  - _MREQ/_RD left as inputs: pull-ups hold them high on the board
     *    (see gate-equations.md Pull-up summary); driven only during the
     *    Phase 6 video burst.
     *  - SH_LD (PD5) driven HIGH and set as a permanent output: this pin
     *    is no longer the Z80's _IORQ (physically disconnected from it
     *    on the breadboard, pull-up removed, 2026-09-05 -- see
     *    video_fetch.c). It WAS then a dedicated line to the 74LS166's
     *    SH_LD input; as of 2026-09-21 that job moved to PB6/OC3A
     *    (hardware Timer3, see sync.c/shld_test.c) and this pin is
     *    physically disconnected from the 74LS166 too now. Still set up
     *    here exactly as before purely for video_fetch.c's legacy
     *    debug-only path (monitor's "vf" command), which still pulses
     *    it the old way -- that pulse no longer reaches real hardware.
     */
    Z80_CTRL_PORT = (1 << BIT_BUSREQ) | (1 << BIT_WAITREL) | (1 << BIT_SH_LD); /* RESET=0 (asserted) */
    Z80_CTRL_DDR = (1 << BIT_BUSREQ) | (1 << BIT_RESET) | (1 << BIT_WAITREL) | (1 << BIT_SH_LD);

    /* Data bus: 74HC595 via hardware SPI (2026-09-16, was a direct
     * parallel write to a 74LS373 -- see pins.h/databus.h). The 595's
     * own /OE is gated by the same hardware (_RD/mode) the 373's was,
     * so whatever byte ends up shifted in is inert until that gating
     * says otherwise -- same property as before, just reached via
     * databus_init() instead of a plain DDR/PORT write. */
    databus_init();

    /* Address bus A0-A13: explicitly input (the Z80 drives it during
     * Phase 3+ free-running/ROM-emulation; only driven by the AVR during
     * the Phase 6 video steal). This is already the hardware-reset
     * default (DDR resets to 0 = input on every reset source, including
     * WDT), so this line changes nothing electrically -- kept for the
     * same reason as the Z80 control lines above: explicit beats implicit
     * once other code in this file starts changing directions elsewhere. */
    ADDR_LO_DDR = 0;
    ADDR_HI_DDR &= (uint8_t)~ADDR_HI_MASK;

    /* Sync outputs: idle high (VSYNC/HSYNC high = no sync asserted). */
    ADDR_HI_PORT |= (1 << HSYNC_PIN) | (1 << VSYNC_PIN);
    ADDR_HI_DDR |= (1 << HSYNC_PIN) | (1 << VSYNC_PIN);

    /* Boot-mode strap on PD0 (shared with USART0 RXD). Sampled exactly
     * once, here, BEFORE usart_init() claims PD0 for RXEN0. PD0 is
     * already an input with its pull-up off (the Z80_CTRL_DDR /
     * Z80_CTRL_PORT writes above leave bit 0 clear). Enable the internal
     * pull-up, let the node settle, and read it: a permanent external
     * ~3.3k to GND on the board reads LOW whenever no serial adapter is
     * driving the line -> autoboot the flash-resident stage1 (monitor.c
     * start_from_stage1()); a connected adapter's idle-high TX, or a bare
     * pin held by the internal pull-up, reads HIGH -> drop into the
     * monitor as before. Datasheet (Atmel-42719C, "Reading the Pin
     * Value"): PINxn is readable regardless of DDxn and of the RXEN0
     * override; internal RPU is 20-50k, so a <=4.7k external pull-down
     * wins comfortably. */
    Z80_CTRL_PORT |= (1 << BIT_UART_RX);
    _delay_us(20);
    uint8_t autoboot = (Z80_CTRL_PIN & (1 << BIT_UART_RX)) ? 0 : 1;
    Z80_CTRL_PORT &= (uint8_t)~(1 << BIT_UART_RX);

    usart_init();
    monitor_run(autoboot); /* never returns */

    for (;;) {}
}
