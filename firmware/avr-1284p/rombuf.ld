/* rombuf.ld -- pins the ROM-emulation upload buffer (see monitor.c,
 * section ".rombuf") to a fixed, real AVR SRAM address, instead of
 * wherever the linker's default .bss placement happens to put it.
 *
 * Address 0x1000 (linker/ELF view 0x801000, per avr-gcc's standard
 * +0x800000 SRAM offset convention) is chosen to sit safely within the
 * 16K internal SRAM (RAMSTART=0x0100, RAMEND=0x40FF, confirmed against
 * avr-gcc -E -dM for this MCU -- see bring-up-log.md):
 *   - ~3.75K of headroom BELOW it (0x0100-0x0FFF) for .data/.bss (other
 *     globals). As of Phase 2, .data alone is already ~1.75K -- NOT
 *     small globals, but every `usart_puts("...")` string literal in
 *     monitor.c/main.c, since plain C string literals on AVR live in
 *     BOTH flash and RAM (copied to RAM at boot) unless marked PROGMEM.
 *     Confirm actual .data+.bss size (avr-size) stays well under this
 *     0x0F00 budget before adding much more message text, or move those
 *     strings to PROGMEM -- see open-questions.md.
 *   - ~4.25K of headroom ABOVE it (0x3000-0x40FF) before RAMEND, where
 *     the stack starts and grows downward. This margin is deliberate --
 *     an earlier version of this placement put the buffer right up
 *     against RAMEND (0x2000-0x3FFF), leaving only 256 bytes before the
 *     stack would immediately collide with it. Don't move this without
 *     re-checking that headroom.
 *
 * (NOLOAD) marks it as BSS-like (no flash space consumed for 8K of
 * zeros) -- confirmed via avr-size/objdump during development: without
 * NOLOAD, a plain --section-start placement bloats .text by 8192 bytes.
 * It is NOT auto-zeroed at reset like real .bss (avr-libc's
 * __do_clear_bss only covers __bss_start..__bss_end, which this sits
 * outside of) -- monitor.c explicitly memsets it once at startup instead.
 */
SECTIONS
{
  .rombuf 0x801000 (NOLOAD) : { *(.rombuf) }
}
INSERT AFTER .bss;
