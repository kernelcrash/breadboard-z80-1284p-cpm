/* video.h -- Phase 6 entry point, reached from monitor.c after
 * rom_emu_run() reports ROM_EMU_EXIT_MAGIC. See video.c / plan.md
 * Phase 6.
 */
#ifndef VIDEO_H
#define VIDEO_H

/* First-milestone video mode: starts HSYNC/VSYNC generation (sync.h) and
 * idles -- no _BUSRQ, no address ramp, no video steal yet (Phase 6a/6b).
 * The Z80 is left running freely (already switched itself to SRAM
 * execution before the magic read), so a program like
 * memtest-plus-blink.asm keeps blinking its own LED independent of this.
 * Returns to the caller when the user sends a byte on the UART, having
 * disabled both timer interrupts first.
 */
void video_run(void);

#endif /* VIDEO_H */
