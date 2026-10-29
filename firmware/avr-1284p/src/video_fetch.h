/* video_fetch.h -- Phase 6a pixel-fetch burst: 80 bytes/line @ 500ns
 * each, software-pulsed 74LS166 SH_LD. See video_fetch.c,
 * gate-equations.md §6, open-questions.md #3, plan.md Phase 6a/6b.
 */
#ifndef VIDEO_FETCH_H
#define VIDEO_FETCH_H

#include <stdint.h>

/* Bytes per active line (memory-map.md: 80 bytes x 200 lines). */
#define VIDEO_BYTES_PER_LINE 80u

/* Runs one line's worth of video steal: asserts _BUSRQ, takes over
 * _MREQ/_RD and the address bus, ramps through VIDEO_BYTES_PER_LINE
 * consecutive addresses starting at `addr14` (a 14-bit A0-A13 value --
 * e.g. `(line * 80) & 0x3FFF` for video-buffer line `line`; the Z80
 * address 0xC000+line*80 is never actually driven by the AVR, since
 * A14/A15 are pulled high externally and the AVR only ever sees/drives
 * the low 14 bits), pulsing the 74LS166's SH_LD (PD3/wait_rel) once per
 * byte to load it, then releases everything back to the Z80.
 *
 * This is Phase 6a's isolated test unit (plan.md: "validate the
 * address-ramp + shift-register chain against a static, known-good SRAM
 * pattern... before wiring into _BUSRQ arbitration and real video
 * timing") -- it is *not* yet called from the per-line HSYNC ISR
 * (sync.c). Caller must ensure nothing else touches PD3, the address
 * bus, or _MREQ/_RD/_BUSRQ for the duration of the call.
 *
 * NOT YET BENCH-VERIFIED -- see video_fetch.c.
 */
void video_fetch_line(uint16_t addr14);

#endif /* VIDEO_FETCH_H */
