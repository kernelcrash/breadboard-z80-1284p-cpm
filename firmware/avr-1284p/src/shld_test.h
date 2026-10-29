/* shld_test.h -- see shld_test.c. Despite the "test" name, this is now
 * the real SH_LD generator (board rewired to PB6, 2026-09-21) -- kept
 * as-is pending a rename, see shld_test.c's header. */
#ifndef SHLD_TEST_H
#define SHLD_TEST_H

/* One-time setup: configures Timer3/OC3A (PB6) to generate SH_LD in
 * hardware, gated on/off around each active line's video-fetch burst
 * by sync.c's own DDRB6 sbi/cbi. Call once at boot. */
void shld_test_init(void);

#endif /* SHLD_TEST_H */
