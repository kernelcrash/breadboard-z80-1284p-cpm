/* sync.h -- Phase 6 HSYNC/VSYNC generation. See sync.c / pin-map.md
 * "Sync generation" / plan.md Phase 6b.
 */
#ifndef SYNC_H
#define SYNC_H

/* Starts Timer1 (unprescaled CTC, 64.000us period) with its compare-
 * match interrupt enabled. The ISR toggles PC6 (HSYNC) at a fixed,
 * jitter-cancelled cycle offset from the true hardware edge (Uzebox-
 * style TCNT1-read + NOP-sled correction, see sync.c) -- plain ISR
 * latency alone is not accurate enough to trust here. VSYNC (PC7) is
 * derived from a 312-line counter inside the same ISR rather than a
 * second independent timer, so it always lands exactly on an HSYNC
 * edge (a free-running second timer can drift relative to the first,
 * landing VSYNC mid-line and losing a fixed line count per frame) --
 * it does NOT need its own jitter correction: it only has to be
 * roughly right, not cycle-accurate, unlike HSYNC. Caller must sei()
 * afterward; this only arms the timer/interrupt enable, it does not
 * touch the global interrupt flag.
 *
 * First-milestone simplification: produces plain 50% duty square waves
 * at the right frequency, not PAL-accurate narrow negative sync pulses
 * -- real pulse widths plus the composite sync-mixing network are
 * Phase 6b work once video steal itself exists.
 */
void sync_init(void);

#endif /* SYNC_H */
