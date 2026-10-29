/* shld_test.c -- despite the name (kept for now -- see below), this is
 * THE REAL SH_LD GENERATOR, not a bench-test comparison. Originally
 * written to generate a second, independent SH_LD-shaped pulse on PB6
 * (Timer3/OC3A, a pin freed by the already-completed 74LS373->74HC595
 * swap) purely in hardware, for a logic-analyzer shape/width comparison
 * against the real cbi/sbi-generated SH_LD that was then still on PD5
 * (sync.c's TIMER1_COMPA_vect). That comparison passed; the board was
 * then physically rewired so PB6 drives the 74LS166's real SH_LD input
 * and PD5 is disconnected (2026-09-21) -- sync.c's own cbi/sbi pulse
 * was retired the same day (NOP-padded instead, see its header). This
 * file's job is now permanent, not temporary: every "the real pulse"/
 * "the real SH_LD" comparison below refers to that now-retired PD5
 * signal, kept as accurate history of how this design was validated,
 * not a currently-existing alternative to compare against. Worth a
 * rename (this file, shld_test_init(), its header, its one call site in
 * video.c) to drop the "test" framing entirely -- not yet done.
 *
 * The real pulse is low for exactly 2 of its 8 cycles (a single CLK
 * edge's worth, triggering one parallel load before shifting resumes)
 * -- NOT a symmetric 50%-duty square wave, which would hold SH_LD low
 * across multiple CLK edges and re-load repeatedly instead. Plain CTC
 * toggle-on-compare-match can't produce that shape; this uses Fast PWM
 * with TOP on ICR3 (mode 14) instead of OCR3A, which frees OCR3A to be
 * an independent duty-cycle threshold on the same OC3A output:
 *   - TOP (ICR3) = 7 -> 8-count period, matching the real 8-cycle/byte
 *     rate exactly (unprescaled, 16MHz timer clock = 1 count/AVR cycle).
 *   - Non-inverting mode (COM3A1:0 = 10): pin goes high at BOTTOM
 *     (count 0); the compare-match "clear" takes effect the count
 *     AFTER TCNT==OCR3A (bench-confirmed 2026-09-19 -- an initial
 *     OCR3A=6 measured a ~60ns/1-cycle low, half the expected width,
 *     showing the low span is (TOP-OCR3A) counts, not (TOP-OCR3A+1)
 *     as first assumed); back high at the next BOTTOM.
 *   - OCR3A = 5 -> low during counts 6,7 (TOP-OCR3A = 2 of 8 counts),
 *     matching the real pulse's 2-low/6-high shape exactly.
 * Bench-verified 2026-09-19: period matches the real pulse; pulse
 * width now matches too with OCR3A=5 (130ns low / 370ns high measured
 * -- 130+370=500ns, exactly 8 cycles @ 16MHz). The two signals are
 * offset from each other by ~1 cycle/62.5ns (PB6 goes low that much
 * after the real SH_LD) -- expected and permanently fixed rather than
 * drifting, since Timer1 and Timer3 share the same 16MHz clock and
 * period, but are two independent counters started at uncorrelated
 * boot-time moments -- not something either register value can tune
 * away.
 *
 * Runs entirely in Timer3's own hardware once configured -- zero CPU/
 * ISR involvement for the pulse *shape* itself. COM3A1 (the compare
 * unit's connection to the OC3A/PB6 pin) is left permanently set here
 * -- Timer3 free-runs and keeps computing a compare-match output state
 * the whole time regardless of video state, same as the real SH_LD's
 * own 74LS166 clock domain runs continuously. What actually gates
 * *visibility* on PB6 is DDRB6 (the pin's output-driver enable, a
 * plain GPIO direction bit, not part of Timer3 at all): sync.c's ISR
 * sets it right as each active line's real video-fetch burst begins
 * and clears it right as that burst ends, so PB6 only shows anything
 * during the same ~40us window the real SH_LD is confined to, not the
 * whole 64us line or the 200-line active region as a coarser
 * approximation would give.
 *
 * 2026-09-19, first gating attempt (superseded): tried connecting/
 * disconnecting OC3A itself (TCCR3A's COM3A1 bit) once per *frame*,
 * from two small additions to sync.c's blanking-line path (line==
 * ACTIVE_LINE_START-1 to connect, line==ACTIVE_LINE_START+
 * ACTIVE_LINE_COUNT to disconnect). Bench-found wrong: this left PB6
 * toggling continuously across each active line's *entire* 64us
 * (HSYNC pulse + back porch + the real ~40us burst + release window),
 * not gated down to the ~40us burst itself the way the real SH_LD is.
 * Reverted in favor of the per-line DDRB6 approach above, which lives
 * in sync.c's active-line path instead (see that file) -- cheaper too:
 * DDRB is plain low I/O space, so sbi/cbi cost 2 cycles each (+4
 * total), versus TCCR3A's extended-I/O lds/andi-ori/sts sequence (~5
 * cycles each way) the frame-level version needed.
 *
 * Cost: sync.c's active-line path (1014 of 1024 cycles before this)
 * gains exactly 2 sbi/cbi instructions, +4 cycles -> 1018/1024, 6
 * cycles margin (down from 10). Verified via avr-objdump -d -z that
 * every other instruction in that path is byte-for-byte unchanged.
 *
 * 2026-09-19, phase lock (sync.c's SHLD_TIMER3_PHASE): the caveat that
 * used to live here -- "Timer3's phase when DDRB6 flips to output is
 * arbitrary, so the first edge each burst may be torn" -- turned out to
 * be the whole ballgame once SH_LD was actually rewired to PB6, not a
 * cosmetic footnote. A free-running Timer3 puts SH_LD on an absolute
 * timeline the CPU can't move, so every cycle added or removed in the
 * ISR before the burst slid the address bus out from under it and
 * rotated the latch point; 5 cycles of it produced a jumbled screen.
 * sync.c now writes TCNT3 immediately before the burst, which pins the
 * phase to the instruction stream and restores the self-synchronisation
 * that generating SH_LD with cbi/sbi used to give for free. See that
 * file for the standing invariant about which code is phase-critical.
 *
 * (The related history this echoes, from sync.c's own header: an earlier
 * VSYNC design used a free-running Timer3 and was dropped after real
 * picture-rolling drift against Timer1. Same root cause, same fix
 * shape -- don't let an independent counter define a timing
 * relationship that belongs to the instruction stream.)
 *
 * 2026-09-19 fix, bench-found: PB6 read stuck low on the first attempt
 * (before any of the gating work above). Root cause confirmed against
 * the real datasheet (Atmel-42719C, Table 20-1 "SPI Pin Overrides"):
 * while the AVR's hardware SPI is enabled in MASTER mode -- which it
 * is, permanently, via databus_init() (video.c's 74HC595 databus) --
 * PB6/MISO's data direction is unconditionally forced to INPUT by the
 * SPI peripheral itself, regardless of DDRB or any other peripheral's
 * claim on the pin. This silently overrides OC3A's own output driver
 * (Timer/Counter chapter, Sec 15.3.2: "the DDR bit corresponding to
 * the OC3A pin must be set in order to enable the output driver" --
 * true, but moot once SPI's own override forces the direction back to
 * input regardless). The Timer3 register configuration was already
 * correct; SPI's pin override was the only thing actually blocking it.
 *
 * Fix: disable SPI here. Safe specifically at this point in execution
 * -- the 74HC595/SPI's only two real users are ROM emulation
 * (rom_emu.c), which has already permanently exited by the time
 * video_run() (and hence this function) ever runs, and virtual IO
 * reads, which were never implemented. Nothing downstream of this
 * point calls databus_send() or touches SPI again this session. */
#include <avr/io.h>
#include "shld_test.h"

void shld_test_init(void)
{
    SPCR = 0;                                /* release SPI's MISO/MOSI/SCK
                                               * pin overrides -- see header
                                               * comment; safe, nothing uses
                                               * the 74HC595 again after this */

    /* DDRB6 starts clear (input, the power-on default -- left untouched
     * here on purpose): PB6 stays quiet/high-Z until sync.c's ISR sets
     * DDRB6 for the duration of each active line's real video-fetch
     * burst, then clears it again.
     *
     * 2026-09-19 fix, bench-found: with DDRB6 clear, PB6 is a genuine
     * tri-stated pad between bursts -- no pull, so its observed level
     * outside the burst is whatever stray capacitance/loading (and,
     * being also the MISO pin, whatever's on that shared SD-card net)
     * happens to leave it at, not a clean deterministic level. Bench
     * result: read low for a stretch, then high, with visible bounce
     * around each line's HSYNC in between -- a floating-node symptom,
     * not a logic bug in the gating itself. Fixed by enabling the
     * AVR's own internal pull-up here (PORTB6=1 while DDRB6=0 enables
     * it; it's automatically excluded whenever DDRB6=1 during a burst,
     * so this costs nothing per-line, just this one-time write) --
     * pulls PB6 to a clean, deterministic HIGH whenever it's not
     * actively driven, which also happens to match the real SH_LD's
     * own idle-high level between pulses. SPI is already permanently
     * off (see the SPCR write above), so nothing on the shared MISO
     * net contends with this. */
    PORTB |= (1 << PORTB6);

    TCCR3A = (1 << COM3A1) | (1 << WGM31);   /* Fast PWM, non-inverting,
                                               * OC3A permanently connected --
                                               * DDRB6 is the only gate now */
    TCCR3B = (1 << WGM33) | (1 << WGM32) | (1 << CS30); /* mode 14, TOP=ICR3, unprescaled */
    ICR3   = 7;                               /* TOP -> 8-cycle period, matches the byte rate */
    OCR3A  = 5;                               /* low for counts 6-7 (2 of 8 cycles), matching cbi/sbi's 2-cycle low */
}
