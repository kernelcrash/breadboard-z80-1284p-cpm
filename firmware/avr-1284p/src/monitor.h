/* monitor.h -- Phase 2 host-facing CLI: memory read/write/dump against
 * the 1284P's own internal SRAM, plus XMODEM upload into the reserved
 * ROM-image buffer. See plan.md Phase 2 / CLAUDE.md.
 */
#ifndef MONITOR_H
#define MONITOR_H

#include <stdint.h>

/* autoboot != 0: load the flash-embedded stage1 and start the Z80 before
 * offering the CLI prompt (set from the PD0 boot-mode strap in main.c). */
void monitor_run(uint8_t autoboot); /* never returns */

#endif /* MONITOR_H */
