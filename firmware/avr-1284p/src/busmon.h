/* busmon.h -- Phase 12 diagnostic: address-bus monitor. See busmon.c. */
#ifndef BUSMON_H
#define BUSMON_H

/* Byte value that, when received by video.c's video_run() UART-poll
 * loop, enters bus-monitor mode instead of the plain "stop video, back
 * to monitor" path. Any other byte keeps today's existing behaviour
 * unchanged. */
#define BUSMON_TRIGGER 'm'

/* Run the capture: tight-loop sample _MREQ/_RD/the 14-bit address bus
 * into a circular buffer with no printing, until any byte arrives, then
 * dump the buffer. Caller (video.c) is responsible for having already
 * stopped Timer1 (TIMSK1 = 0) -- this function assumes the Z80 is
 * running completely free, with nothing else contending for the bus. */
void busmon_run(void);

#endif /* BUSMON_H */
