/* rom_emu.h -- Phase 4 ROM-emulation loop. See rom_emu.c / plan.md
 * Phase 4 / gate-equations.md / memory-map.md.
 */
#ifndef ROM_EMU_H
#define ROM_EMU_H

#include <stdint.h>

/* Magic address (memory-map.md): served like any other ROM byte, but
 * also acted on here -- the last byte the boot ROM deliberately fetches
 * from ROM space before configuring the 8255 and flipping `mode_pin` to
 * jump into SRAM. 0x3FFF (2026-09-04, changed from 0x1FF0): the top of
 * the full 14-bit address range the ROM window aliases across (A14/A15
 * don't matter in ROM mode -- memory-map.md), chosen so it can never
 * collide with a real ROM image's own copy-loop addresses regardless of
 * how big that image grows, unlike 0x1FF0 which was merely "top of the
 * current 8K buffer". */
#define ROM_EMU_MAGIC_ADDR 0x3FFFu

typedef enum {
    ROM_EMU_EXIT_ABORT = 0, /* user sent a byte on the UART */
    ROM_EMU_EXIT_MAGIC = 1, /* magic address served -- Z80 is mid mode-switch */
} rom_emu_exit_t;

/* Runs the ROM-emulation poll loop: releases Z80 _RESET, then services
 * memory-read requests (_MREQ & _RD both low) by indexing into `rom`
 * (masked by `rom_mask` -- `rom` must be a power-of-two size, and
 * `rom_mask` = that size - 1) and pulsing the WAIT-release line once the
 * byte is on the bus. Returns as soon as either happens:
 *  - the user sends a byte on the UART (ROM_EMU_EXIT_ABORT: re-asserts
 *    Z80 _RESET first, so the Z80 is left stopped rather than wedged
 *    mid-bus-cycle);
 *  - the magic address is served (ROM_EMU_EXIT_MAGIC): the byte is
 *    already on the bus and WAIT already released by the time this
 *    returns, so the caller can go straight into whatever comes after
 *    ROM emulation (Phase 6: video generation) with no bus involvement
 *    of its own needed first.
 */
rom_emu_exit_t rom_emu_run(const uint8_t *rom, uint16_t rom_mask);

#endif /* ROM_EMU_H */
