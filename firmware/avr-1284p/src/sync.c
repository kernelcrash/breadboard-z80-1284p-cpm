/* sync.c -- Phase 6 HSYNC/VSYNC generation + video-fetch trigger.
 * See sync.h.
 *
 * 2026-09-14: the entire ISR body is now one hand-written `asm volatile`
 * block -- no C arithmetic, no call to video_fetch_line()/video_fetch_
 * burst() (video_fetch.c still exists and is unchanged, but is now only
 * reachable from monitor.c's standalone "vf" debug command, never from
 * this ISR). Per the project owner's direction: leaving the fetch/sync
 * logic split across C functions made the ISR's real cost depend on
 * whatever GCC happened to generate (inlining decisions, register
 * allocation, a `call`/`rcall` if something didn't get inlined) rather
 * than on something inspectable directly in this file. Writing it all as
 * one asm block removes that uncertainty outright: what's below the
 * `asm volatile(` is *exactly* what runs, in order, every active line.
 * `grep -c "call\|rcall" sync.lst` on a fresh disassembly must read 0.
 *
 * This does NOT introduce any project-wide register reservation (no
 * `-ffixed-rN` in the Makefile) -- registers r16-r25/r30/r31 are simply
 * hardcoded by name inside this one asm block and listed in its clobber
 * list, so GCC's own ISR prologue/epilogue pushes/pops whichever of them
 * this function actually touches, exactly the same one-time cost the
 * previous (C-calling) version already paid for its own register set --
 * see the now-superseded "~35-cycle prologue" note below. No other
 * function on this chip is affected.
 *
 * 2026-09-19: a `-ffixed-r2 -ffixed-r3` variant (moving `video_addr`
 * permanently into r2:r3, no SRAM static at all) was tried and reverted
 * after a jumbled screen. Root cause turned out fully understood, just
 * not reconnected to this variant at the time: those 3 saved cycles ran
 * *before* the burst, and at that point nothing protected `SH_LD` (then
 * still `cbi`/`sbi` on PD5) from cycle-count changes shifting its pulse
 * relative to the address bus -- exactly the same mechanism the
 * SHLD_TIMER3_PHASE comment below describes for the DDR-constant fix.
 * `SH_LD` generation has since moved to Timer3/OC3A/PB6 in hardware
 * with that same phase lock, which re-establishes the correct phase at
 * a fixed point every line regardless of how many cycles ran before
 * it -- so this variant's saved cycles (the `video_addr` top-read, which
 * runs before the phase-lock write) were safe to reintroduce.
 *
 * 2026-09-21: reintroduced on that basis -- `video_addr` lives in
 * r2:r3 again, see its own declaration comment below for the mechanics/
 * safety argument. Not yet bench-verified on hardware.
 *
 * `line` and `video_addr` stay as plain C statics; the asm block reaches
 * them with bare `lds`/`sts <symbol>` rather than through operand
 * constraints, matching how hand-written AVR asm conventionally touches
 * a translation unit's own globals -- the assembler emits a real
 * relocation against the symbol, so `-ffunction-sections -fdata-sections
 * --gc-sections` (Makefile) still keeps their storage: the linker's
 * reachability walk follows that relocation exactly like it would a
 * C-level reference, this isn't a C-visible dependency that a garbage
 * collector could miss.
 *
 * The address arithmetic is plain linear video addressing --
 * `video_addr` runs 0..15999 and simply advances by VIDEO_BYTES_PER_LINE
 * (80) each active line, reset once per frame. (An interleaved,
 * Amstrad-CPC-style row/scanline addressing scheme was explored and
 * fully implemented here on 2026-09-13 in pursuit of running a CPC
 * Knight Lore binary on this hardware, then reverted in full -- CPC
 * compatibility was explicitly abandoned as a goal. This file carries no
 * trace of that scheme any more.)
 *
 * Re-derived the worst-case active-line cycle count from a fresh
 * `avr-objdump -d -z` against this hand-written form (this project's own
 * standing rule, see the sled's SYNC_TARGET/SYNC_SLED_LEN comment below)
 * rather than assume the old C version's 21-cycle-margin figure still
 * applies -- it doesn't, the instruction sequence is different code now.
 * Confirmed empirically from the disassembly (not just from the source):
 * the sled truly is jitter-cancelling -- true edge to landing at the "3:"
 * label costs exactly 70 cycles whether pad=0 (j>=56) or pad=56 (j=0).
 * From there: HSYNC pulse + active-line dispatch test = 91, the active-
 * line body (back porch through the video_addr store) = 802, the common
 * tail (line++/wrap check, not taken, + epilogue + reti) = 51. Total
 * 70+91+802+51 = 1014 of 1024 cycles -- 10 cycles (~0.6us) of margin.
 * Thinner than the old design's 21, but real -- and bench-confirmed
 * working on real hardware 2026-09-14 (stable picture, no rolling/tear),
 * not just a static count this time. If it ever needs more headroom the
 * cheapest cut is BACK_PORCH_CYCLES (currently 80, pure margin -- see its
 * own comment).
 *
 * ----------------------------------------------------------------
 * Earlier history, still true of the *design* even though the ISR is no
 * longer C calling into video_fetch.c:
 *
 * 2026-09-05d: bench found a real bug in the 05c trim below -- the
 * `video_addr` reset (`if (line == ACTIVE_LINE_START) video_addr = 0;`)
 * lived on the active-line path, and its two outcomes compiled to
 * different cycle counts (7 taken the reset vs. 4 not -- verified via
 * disassembly). Since 1 AVR cycle = 1 pixel at this pixel clock (8
 * pixels/byte at 8 cycles/byte), that 3-cycle difference was a real,
 * deterministic 3-pixel rightward shift on exactly the first active
 * line of every frame -- reported on the bench as "the very first line
 * is pushed one pixel to the right" (close enough given a rough visual
 * read). Fixed by moving the reset onto the blanking side entirely
 * (`line == ACTIVE_LINE_START - 1`, i.e. the last blanking line before
 * active video starts) -- every active line now runs *identical* code,
 * no branch-dependent cost at all, so this class of bug can't recur
 * here. The hand-written rewrite below keeps the reset on that same
 * blanking-side line for exactly this reason. Also let
 * BACK_PORCH_CYCLES grow further (56 -> 80): the previous 40->56 change
 * (~1us) produced no visible shift on the bench ("doesn't look like
 * it's moved at all") -- a small fraction of a 640-pixel image -- so
 * this time raised it by a much bigger, harder-to-miss amount instead
 * of another small nudge. Verified via a fresh `avr-objdump -d -z`
 * (against the pre-rewrite C version): worst case was 1003 of 1024
 * cycles -- **and uniform across every active line**, no more first-line
 * special case -- 21 cycles (~1.3us) margin. Thinner than the 05c value
 * (34-37), but a real, deliberate trade for a clearly-testable back-porch
 * change and a bug fix, not sloppiness -- revisit if 21 cycles proves
 * too tight in practice (not yet bench-confirmed against *this*
 * hand-written form).
 *
 * 2026-09-05c: image was still shifted left (not centred) after the
 * jitter fix below, and there was very little margin left to grow
 * BACK_PORCH_CYCLES further -- rather than the bigger "fetch all 200
 * lines in one BUSRQ takeover" redesign (rejected: it would starve the
 * Z80 of any run time during the whole ~12.8ms visible frame, only
 * letting it run during the 112 blanking lines, a real behaviour change
 * from CLAUDE.md's "the z80 keeps going for a few microseconds" between
 * *every* line), trimmed the ISR's own non-pixel overhead instead:
 * - the per-line VSYNC-bookkeeping check (only ever relevant on lines
 *   0/VSYNC_PULSE_LINES, deep in blanking) is gated behind the "not
 *   active" branch, so the 200 active lines skip it entirely;
 * - the per-line `video_line * VIDEO_BYTES_PER_LINE` multiply is gone,
 *   replaced by `video_addr`, a running total advanced by
 *   VIDEO_BYTES_PER_LINE each active line.
 *
 * 2026-09-05b: merged back into a SINGLE Timer1 ISR (TIMER1_COMPA_vect),
 * undoing an earlier COMPA/COMPB split. Real bug found on the bench:
 * with the split, HSYNC-to-first-SH_LD-pulse showed a period-3 jitter
 * pattern -- root-caused to a documented AVR core behaviour (after
 * RETI/SEI the core always executes at least one more instruction of
 * the code being returned to before honouring a newly-pending
 * interrupt) that only bites when two separate interrupt sources can
 * both be "in flight" at once. A single ISR firing alone every line
 * cannot hit it. Real fix: one ISR, back porch from a plain fixed
 * delay rather than a second hardware interrupt.
 *
 * Jitter cancellation (the Uzebox AVR-console technique): Timer1 runs
 * *unprescaled* so TCNT1 increments once per CPU cycle; reading it right
 * at ISR entry gives the exact number of CPU cycles elapsed since the
 * true edge, capturing all AVR interrupt-latency jitter as one number,
 * which a NOP-sled (entered via a computed jump) then cancels by burning
 * exactly enough more cycles to always reach the real work at a fixed
 * total latency after the true edge. (Sign-inversion history: the sled's
 * dispatch computes `Z = end_of_sled - pad` via `sub`/`sbc`, NOT
 * `Z = start + pad` -- an earlier version had this backwards, doubling
 * rather than cancelling jitter, caught via a user-reported "zigzag"
 * pixel pattern.)
 *
 * VSYNC is derived from a 312-line counter (`line`) incremented once per
 * line, not a second free-running timer -- an earlier version used an
 * independent Timer3, which (even individually exact) could drift
 * relative to Timer1 and land VSYNC mid-line, a real picture-rolling bug.
 *
 * SYNC_TARGET/SYNC_SLED_LEN below are sized for the ISR's real dispatch
 * cost from TCNT1L-read to the sled landing point -- this project's own
 * history has twice silently regressed this budget back down to a
 * smaller value sized for a lighter ISR body, disabling jitter
 * cancellation without any crash to reveal it. Verify against a fresh
 * `avr-objdump -d -z` after *any* change to this file, rather than
 * trusting arithmetic carried over from before.
 *
 * First-milestone simplification, still true: pulse widths are
 * round/approximate, no equalizing-pulse structure or composite
 * sync-mixing network -- that level of PAL accuracy is Phase 6b work.
 */
#include <avr/io.h>
#include <avr/interrupt.h>
#include "pins.h"
#include "sync.h"
#include "video_fetch.h"

/* PAL-ish, non-interlaced: 312 lines/frame (memory-map.md). VSYNC is a
 * broad LOW pulse spanning the first few lines of the frame -- 3 lines
 * (192us) is a round, simplified stand-in for real PAL's ~2.5-line
 * broad pulse, not broadcast-exact. */
#define LINES_PER_FRAME    312u
#define VSYNC_PULSE_LINES  3u

/* Vertical blanking, split around the 200 active lines (memory-map.md):
 * 56 lines before, 200 active, 56 after = 312 exact. The VSYNC pulse
 * falls within the first 56. */
#define ACTIVE_LINE_START 56u
#define ACTIVE_LINE_COUNT 200u

/* __attribute__((used)): touched only via bare `lds`/`sts line` inside
 * the ISR's asm block, never through a C expression -- with zero
 * *visible* references, GCC's own dead-store elimination silently drops
 * its storage entirely before it ever reaches the assembler (confirmed:
 * without this attribute, the build fails at link time with "undefined
 * reference to `line'" -- not a --gc-sections issue, the definition was
 * never emitted in the first place). `used` forces emission regardless.
 * `video_addr` used to need this too, but no longer being a C variable
 * at all (see its own declaration comment below) makes it moot there. */
static uint16_t line __attribute__((used)) = 0;

/* Running video-buffer offset for the *next* active line -- plain linear
 * addressing (0..15999), advanced by VIDEO_BYTES_PER_LINE each active
 * line, reset to 0 on the last blanking line before active video starts
 * (see the 2026-09-05d entry above for why it's reset there and not on
 * the active path itself).
 *
 * 2026-09-21 (reintroduced, see the 2026-09-19 header entry): no longer
 * a C variable. Lives permanently in registers r2:r3 instead -- reserved
 * project-wide via -ffixed-r2/-ffixed-r3 (Makefile), so GCC never
 * allocates them for anything else. The ISR moves its running total
 * in/out of r2:r3 with `movw` (1 cycle) instead of `lds`/`sts` (2 cycles
 * each) to/from an SRAM static, since the value only ever needs to
 * persist *between* ISR calls, never be visible to C code. Verified
 * safe via `avr-objdump -d`: grepped the entire linked binary
 * (including every avr-libc/libgcc routine actually pulled in) for any
 * instruction touching r2 or r3 -- zero matches. Re-verify this the
 * same way if a future change links in different library code (a new
 * precompiled helper wasn't built with this project's -ffixed flags and
 * could silently violate the reservation). r2:r3 aren't zeroed by
 * `__do_clear_bss` (that only clears BSS memory, not registers) --
 * sync_init() zeroes them once explicitly at boot instead. */

/* Jitter-cancellation target for the ISR's own dispatch, from TCNT1L-read
 * to the sled's landing point. See header comment: a too-small budget
 * here silently disables the sled with no crash to reveal it -- verify
 * against a fresh `avr-objdump -d -z`, don't trust this arithmetic. */
#define SYNC_TARGET    64
#define SYNC_SLED_LEN  56
#define SYNC_REMAINDER 8

#define HSYNC_PULSE_CYCLES ((47UL * (F_CPU / 1000000UL)) / 10UL)

/* Back porch: fixed delay between HSYNC returning high and the video
 * fetch actually starting, so a real display has time to settle after
 * retrace before active video begins. Only paid on active lines --
 * blanking lines have no video fetch to delay. */
#define BACK_PORCH_CYCLES 80

/* Cycles to wait after asserting _BUSRQ before assuming the Z80 has
 * actually released the bus -- see video_fetch.c's own copy of this
 * same constant/rationale (Z80 UM: 6 T-states is the longest documented
 * single M-cycle in the instruction set = 750ns = 12 AVR cycles @
 * 16MHz; trimmed to 14 for 2 cycles/125ns of margin). Duplicated here
 * (rather than shared) because this file's copy runs as plain NOPs
 * inside a single asm block, not a call into video_fetch.c. */
#define BUSRQ_SAFE_CYCLES 14

/* SH_LD (PB6/OC3A, Timer3 Fast PWM -- see shld_test.c) phase lock.
 *
 * 2026-09-19, bench-root-caused: Timer3 free-runs, so its pulse edges sit
 * on an absolute hardware timeline the CPU cannot move. `DDRB6` only opens
 * a window onto that timeline -- it does not reposition the pulses. That
 * meant every cycle added to or removed from the code *before* the burst
 * slid the address bus out from under a stationary SH_LD, rotating the
 * latch point. Removing 5 such cycles (2 from the DDR read-modify-write
 * cleanup, 3 from a since-reverted `movw` change) pushed SH_LD from ~2
 * cycles after the address went valid to ~9 -- past the next byte's
 * address change at 8 -- and the screen came up jumbled.
 *
 * `cbi`/`sbi` never had this failure mode: generating SH_LD from the
 * instruction stream locked it to the address output by construction.
 * Writing TCNT3 immediately before the burst restores that property --
 * Timer3's phase is then set by *this code*, not by a boot-time accident,
 * and is immune to anything that changes cycle counts earlier in the ISR.
 *
 * Standing invariant, once this is in: **everything between the
 * `sts TCNT3L` below and the burst loop is phase-critical -- changing its
 * cycle count rotates SH_LD relative to the address bus. Everything
 * before the write is free.**
 *
 * This value is the counter value written, i.e. the phase itself. Each
 * unit rotates SH_LD one cycle (62.5ns) later relative to the address
 * bus; it wraps mod 8 (ICR3+1). If the picture comes up displaced by
 * whole bytes or showing torn bytes, adjust by +/-1 -- the paper
 * derivation of the exact write-to-count latency is good to about a
 * cycle, the same uncertainty that made OCR3A need one bench iteration
 * (see shld_test.c). */
#define SHLD_TIMER3_PHASE 0

/* Hardcoded I/O addresses/bits used inside the asm block below, matching
 * video_fetch.c's established practice (rather than threading pins.h's
 * SFR macros through inline-asm operand constraints for every one of
 * them). Guarded by the _Static_assert block below so a future pins.h
 * change can't silently desync the asm from reality. */
#define ASM_ADDR_LO_PORT  0x02 /* PORTA */
#define ASM_ADDR_LO_DDR   0x01 /* DDRA */
#define ASM_ADDR_HI_PORT  0x08 /* PORTC */
#define ASM_ADDR_HI_DDR   0x07 /* DDRC */
#define ASM_Z80_CTRL_PORT 0x0B /* PORTD */
#define ASM_Z80_CTRL_DDR  0x0A /* DDRD */
#define ASM_BIT_BUSREQ    7
#define ASM_BIT_RD        6
#define ASM_BIT_SH_LD     5
#define ASM_BIT_MREQ      4
#define ASM_HSYNC_PIN     6
#define ASM_VSYNC_PIN     7
#define ASM_ADDR_HI_MASK  0x3F

_Static_assert(_SFR_IO_ADDR(ADDR_LO_PORT) == ASM_ADDR_LO_PORT,
               "sync.c's hardcoded ADDR_LO_PORT address is stale");
_Static_assert(_SFR_IO_ADDR(ADDR_LO_DDR) == ASM_ADDR_LO_DDR,
               "sync.c's hardcoded ADDR_LO_DDR address is stale");
_Static_assert(_SFR_IO_ADDR(ADDR_HI_PORT) == ASM_ADDR_HI_PORT,
               "sync.c's hardcoded ADDR_HI_PORT address is stale");
_Static_assert(_SFR_IO_ADDR(ADDR_HI_DDR) == ASM_ADDR_HI_DDR,
               "sync.c's hardcoded ADDR_HI_DDR address is stale");
_Static_assert(_SFR_IO_ADDR(Z80_CTRL_PORT) == ASM_Z80_CTRL_PORT,
               "sync.c's hardcoded Z80_CTRL_PORT address is stale");
_Static_assert(_SFR_IO_ADDR(Z80_CTRL_DDR) == ASM_Z80_CTRL_DDR,
               "sync.c's hardcoded Z80_CTRL_DDR address is stale");
_Static_assert(BIT_BUSREQ == ASM_BIT_BUSREQ, "sync.c's hardcoded BIT_BUSREQ is stale");
_Static_assert(BIT_RD == ASM_BIT_RD, "sync.c's hardcoded BIT_RD is stale");
_Static_assert(BIT_SH_LD == ASM_BIT_SH_LD, "sync.c's hardcoded BIT_SH_LD is stale");
_Static_assert(BIT_MREQ == ASM_BIT_MREQ, "sync.c's hardcoded BIT_MREQ is stale");
_Static_assert(HSYNC_PIN == ASM_HSYNC_PIN, "sync.c's hardcoded HSYNC_PIN is stale");
_Static_assert(VSYNC_PIN == ASM_VSYNC_PIN, "sync.c's hardcoded VSYNC_PIN is stale");
_Static_assert(ADDR_HI_MASK == ASM_ADDR_HI_MASK, "sync.c's hardcoded ADDR_HI_MASK is stale");

ISR(TIMER1_COMPA_vect)
{
    /* One continuous hand-written block: no C arithmetic, no call/rcall
     * anywhere in this ISR (verify with `avr-objdump -d -z` + grep after
     * any edit). Registers r16-r25/r30/r31 are scratch, reused freely
     * section to section -- comments mark what each holds at the point
     * it's introduced. `line`/`video_addr` (this file's own statics) are
     * read/written directly by symbol name via lds/sts. */
    asm volatile(
        /* ================= 1. jitter-cancellation sled ================
         * r16 = j = TCNT1L; pad = (j < thresh) ? thresh-j : 0, computed
         * with both branch arms costing identical cycles (this project's
         * branch-balance rule -- see 2026-09-05d above) so the *total*
         * time from the TCNT1L read to the sled's landing label (3:) is
         * constant regardless of which arm runs. */
        "lds  r16, %[tcnt1l]\n\t"          /* r16 = j                 (2) */
        "ldi  r17, %[thresh]\n\t"          /* r17 = SYNC_TARGET-REM   (1) */
        "cp   r16, r17\n\t"                /* C set if j < thresh     (1) */
        "brlo 1f\n\t"                      /* not-taken:1 / taken:2      */
        "clr  r16\n\t"                     /* pad = 0                 (1) */
        "rjmp 2f\n\t"                      /*                         (2) */
        "1:\n\t"
        "sub  r17, r16\n\t"                /* r17 = thresh - j        (1) */
        "mov  r16, r17\n\t"                /* r16 = pad               (1) */
        "2:\n\t"

        /* Computed jump into a NOP sled -- `Z = end - pad`, not
         * `start + pad` (sign-inversion history, see header comment). */
        "ldi  r30, lo8(gs(3f))\n\t"
        "ldi  r31, hi8(gs(3f))\n\t"
        "sub  r30, r16\n\t"
        "sbc  r31, __zero_reg__\n\t"
        "ijmp\n\t"
        ".rept %[sled]\n\t"
        "nop\n\t"
        ".endr\n\t"
        "3:\n\t"

        /* ===================== 2. HSYNC pulse ======================
         * Short LOW pulse at the jitter-cancelled line start, HIGH for
         * the rest of the line. */
        "cbi  %[addrhi], %[hsyncbit]\n\t"
        ".rept %[hdelay]\n\t"
        "nop\n\t"
        ".endr\n\t"
        "sbi  %[addrhi], %[hsyncbit]\n\t"

        /* ============ 3. load `line`, test active window ============
         * r20:r21 = line, preserved across both paths below for the
         * common line++ tail. r18:r19 = line - ACTIVE_LINE_START, then
         * compared against ACTIVE_LINE_COUNT (unsigned, both ends of the
         * active window handled by one comparison, same trick the old C
         * version used via `(uint16_t)(line - ACTIVE_LINE_START) <
         * ACTIVE_LINE_COUNT`). */
        "lds  r20, line\n\t"
        "lds  r21, line+1\n\t"
        "mov  r18, r20\n\t"
        "mov  r19, r21\n\t"
        "subi r18, lo8(%[actstart])\n\t"
        "sbci r19, hi8(%[actstart])\n\t"
        "mov  r22, r18\n\t"
        "mov  r23, r19\n\t"
        "subi r22, lo8(%[actcount])\n\t"
        "sbci r23, hi8(%[actcount])\n\t"
        "brlo 4f\n\t"                      /* (line-56) < 200 -> active line */

        /* ================ 4a. blanking-line path =================
         * VSYNC bookkeeping only -- no timing constraint at all here,
         * this branch's cost is irrelevant (every blanking line already
         * differs from every other in this project's design). */
        "tst  r21\n\t"
        "brne 8f\n\t"                      /* line>=256: none of 0/3/55 match */
        "cpi  r20, 0\n\t"
        "brne 6f\n\t"
        "cbi  %[addrhi], %[vsyncbit]\n\t"  /* line==0: VSYNC low */
        "rjmp 8f\n\t"
        "6:\n\t"
        "cpi  r20, %[vsynclines]\n\t"
        "brne 7f\n\t"
        "sbi  %[addrhi], %[vsyncbit]\n\t"  /* line==VSYNC_PULSE_LINES: VSYNC high */
        "rjmp 8f\n\t"
        "7:\n\t"
        "cpi  r20, %[lastblank]\n\t"
        "brne 8f\n\t"
        "clr  r2\n\t"                      /* line==ACTIVE_LINE_START-1: */
        "clr  r3\n\t"                      /*   video_addr (now r2:r3) = 0 (2026-09-05d:
                                             *   reset lives here, not on the active path) */
        "8:\n\t"
        "rjmp 9f\n\t"

        /* ================== 4b. active-line path ==================
         * Every active line runs this identical sequence -- no
         * branch-dependent cost anywhere in here (2026-09-05d). */
        "4:\n\t"
        ".rept %[backporch]\n\t"           /* let the display settle after HSYNC */
        "nop\n\t"
        ".endr\n\t"

        /* -- inline video_fetch_line: take the bus from the Z80 -- */
        "cbi  %[ctrlport], %[busreqbit]\n\t" /* assert _BUSRQ */
        ".rept %[busrqsafe]\n\t"
        "nop\n\t"
        ".endr\n\t"
        "sbi  %[ctrlport], %[mreqbit]\n\t"   /* port high before DDR output, */
        "sbi  %[ctrlport], %[rdbit]\n\t"     /*  so no glitch-low transition  */
        "sbi  %[ctrlddr], %[mreqbit]\n\t"
        "sbi  %[ctrlddr], %[rdbit]\n\t"
        "cbi  %[ctrlport], %[mreqbit]\n\t"   /* now drive both low: begin burst */
        "cbi  %[ctrlport], %[rdbit]\n\t"
        "ldi  r24, 0xFF\n\t"
        "out  %[addrloddr], r24\n\t"         /* ADDR_LO_DDR = 0xFF (output) */
        "out  %[addrhiddr], r24\n\t"         /* ADDR_HI_DDR = 0xFF (2026-09-19: was a read-
                                               * modify-write preserving bits 6-7 -- confirmed
                                               * via grep that HSYNC/VSYNC DDR bits are set
                                               * once at boot (main.c) and never touched
                                               * anywhere else, so this is always 0xFF here;
                                               * a plain constant write is equivalent and
                                               * saves 1 cycle) */

        /* -- fold the *live* HSYNC/VSYNC state (PORTC bits 6-7) into
         * the address's high byte once, since the burst loop below
         * overwrites the whole port every iteration and never touches
         * those bits again (safe: video_addr's high byte never exceeds
         * 0x3F for this project's 200x80 buffer, see video_fetch.c's
         * own header comment for the same argument) -- */
        "movw r24, r2\n\t"                   /* r24:r25 = video_addr (adiw-eligible pair);
                                               * r2:r3 is video_addr's permanent home now,
                                               * see its declaration comment above */
        "andi r25, %[addrhimask]\n\t"
        "in   r18, %[addrhi]\n\t"
        "andi r18, 0xC0\n\t"
        "or   r25, r18\n\t"

        /* -- inline video_fetch_burst: cycle-exact 8-cycles/byte ramp.
         * Pipeline structure: prime loads byte 0, each 8-cycle main-loop
         * iteration increments to byte i's address and loads it while
         * byte i-1 shifts out, the trailing window lets the last byte
         * finish shifting out before the bus is released. -- */
        "out  %[addrlo], r24\n\t"            /* -- priming: load byte 0 -- */
        "out  %[addrhi], r25\n\t"

        /* -- SH_LD phase lock (see SHLD_TIMER3_PHASE above) --
         * Pins Timer3's free-running phase to this exact point in the
         * instruction stream, so SH_LD's latch point sits at a fixed,
         * known offset from each byte's address going out instead of
         * wherever Timer3 happened to be when it was started at boot.
         * 16-bit write protocol: high byte first (lands in TEMP), then
         * the low byte, which commits both. High byte is always 0 here
         * (TOP is 7), so it comes free from r1/__zero_reg__, which the
         * ISR prologue has already cleared.
         *
         * Costs nothing: these 5 cycles replace 5 of the 8 NOPs that
         * were here, and the 3 below make the window 8 cycles again --
         * byte 0's SRAM settle time is unchanged. That window was
         * explicitly "not cycle-constrained" padding; it now does real
         * work instead of nothing. */
        "ldi  r18, %[t3phase]\n\t"           /* 1 */
        "sts  %[tcnt3h], r1\n\t"             /* 2 -- TEMP = 0 */
        "sts  %[tcnt3l], r18\n\t"            /* 2 -- commits; phase locked here */
        ".rept 3\n\t"                        /* 3 -- rest of the settle delay */
        "nop\n\t"
        ".endr\n\t"
        "sbi  %[ddrb], %[ddb6]\n\t"          /* gate PB6/OC3A's output driver on
                                               * right as the real burst starts --
                                               * +2 cycles, see 2026-09-19 note below */
        /* 2026-09-21: SH_LD's real generation moved to hardware (Timer3/
         * OC3A/PB6, gated by the sbi/cbi ddrb/ddb6 pair around this whole
         * burst) once the board was rewired -- this cbi/sbi pair used to
         * pulse SH_LD itself (PD5), now drives a pin nothing's wired to.
         * NOP-padded to hold the priming step at its original length
         * rather than removed outright, so the settle delay before the
         * main loop starts is unchanged. */
        "nop\n\t"
        "nop\n\t"
        "nop\n\t"
        "nop\n\t"
        ".rept %[nbytesm1]\n\t"              /* -- main loop, 8 cycles/iter -- */
        "adiw r24, 1\n\t"                    /* 2 */
        "out  %[addrlo], r24\n\t"            /* 1 */
        "out  %[addrhi], r25\n\t"            /* 1 */
        /* 2026-09-21: this pair used to be the real SH_LD pulse (PD5,
         * cbi/sbi) -- NOP-padded instead of removed, since the loop must
         * stay at exactly 8 cycles/iteration to pace the address bus
         * against the 74LS166's own clock domain regardless of what (if
         * anything) fills these 4 cycles. Real SH_LD now comes from
         * Timer3/OC3A/PB6 in hardware, gated on/off around this whole
         * loop by the sbi/cbi ddrb/ddb6 pair outside it -- untouched by
         * this change. These 4 free cycles are earmarked for future use
         * (not yet assigned to anything). */
        "nop\n\t"                            /* 1 */
        "nop\n\t"                            /* 1 */
        "nop\n\t"                            /* 1 */
        "nop\n\t"                            /* 1 */
        ".endr\n\t"
        "cbi  %[ddrb], %[ddb6]\n\t"          /* TEMPORARY bench test: gate PB6/OC3A's
                                               * output driver back off right as the
                                               * real burst ends -- +2 cycles */
        ".rept 8\n\t"                        /* -- trailing window -- */
        "nop\n\t"
        ".endr\n\t"

        /* -- release everything back to the Z80 --
         * 2026-09-19: scratch moved from r24 to r18 here (r18 is idle by
         * this point -- last used folding the live HSYNC/VSYNC bits in,
         * before the burst loop). r24:r25 still holds the burst's running
         * address (original video_addr + 79 after the loop's 79 adiw's)
         * and is deliberately left alone so the video_addr update below
         * can reuse it instead of re-reading video_addr from memory. */
        "sbi  %[ctrlport], %[mreqbit]\n\t"
        "sbi  %[ctrlport], %[rdbit]\n\t"
        "cbi  %[ctrlddr], %[mreqbit]\n\t"
        "cbi  %[ctrlddr], %[rdbit]\n\t"
        "clr  r18\n\t"
        "out  %[addrloddr], r18\n\t"         /* ADDR_LO_DDR = 0 (input) */
        "ldi  r18, 0xC0\n\t"                 /* ADDR_HI_DDR = 0xC0 (always exactly this
                                               * here, see the OR'd constant above) */
        "out  %[addrhiddr], r18\n\t"
        "sbi  %[ctrlport], %[busreqbit]\n\t" /* release _BUSRQ */

        /* -- video_addr += VIDEO_BYTES_PER_LINE --
         * 2026-09-19: r24:r25 already equals video_addr + (nbytesm1=79)
         * from the burst loop's own adiw's -- one more adiw reaches
         * +VIDEO_BYTES_PER_LINE (=80) directly, no need to re-read
         * video_addr or re-add the stride from scratch. Storing back is
         * now a single movw into r2:r3 (video_addr's permanent home)
         * instead of two sts to an SRAM static. Original lds x2 +
         * ldi+add+ldi+adc + sts x2 was 12 cycles; this is adiw + movw =
         * 3 cycles. */
        "adiw r24, 1\n\t"
        "movw r2, r24\n\t"

        /* ================ 5. common tail: line++, wrap ================
         * 2026-09-19: line += 1 via subi/sbci of the negative constant
         * (-1 as 16-bit = 0xFFFF) instead of ldi+add/ldi+adc -- subi/sbci
         * take an immediate directly, so this skips loading 1/0 into a
         * scratch register first. Saves 2 cycles (4 -> 2). */
        "9:\n\t"
        "subi r20, lo8(-1)\n\t"
        "sbci r21, hi8(-1)\n\t"
        "mov  r22, r20\n\t"
        "mov  r23, r21\n\t"
        "subi r22, lo8(%[linesperframe])\n\t"
        "sbci r23, hi8(%[linesperframe])\n\t"
        "brlo 10f\n\t"                       /* line < LINES_PER_FRAME -> keep it */
        "clr  r20\n\t"
        "clr  r21\n\t"
        "10:\n\t"
        "sts  line, r20\n\t"
        "sts  line+1, r21\n\t"

        : /* no outputs */
        : [tcnt1l]       "n" (_SFR_MEM_ADDR(TCNT1L)),
          [thresh]        "M" (SYNC_TARGET - SYNC_REMAINDER),
          [sled]          "n" (SYNC_SLED_LEN),
          [hdelay]        "n" (HSYNC_PULSE_CYCLES - 2),
          [backporch]     "n" (BACK_PORCH_CYCLES),
          [busrqsafe]     "n" (BUSRQ_SAFE_CYCLES),
          [nbytesm1]      "n" (VIDEO_BYTES_PER_LINE - 1),
          [actstart]      "n" (ACTIVE_LINE_START),
          [actcount]      "n" (ACTIVE_LINE_COUNT),
          [vsynclines]    "M" (VSYNC_PULSE_LINES),
          [lastblank]     "M" (ACTIVE_LINE_START - 1),
          [linesperframe] "n" (LINES_PER_FRAME),
          [addrlo]        "I" (ASM_ADDR_LO_PORT),
          [addrloddr]     "I" (ASM_ADDR_LO_DDR),
          [addrhi]        "I" (ASM_ADDR_HI_PORT),
          [addrhiddr]     "I" (ASM_ADDR_HI_DDR),
          [addrhimask]    "M" (ASM_ADDR_HI_MASK),
          [ctrlport]      "I" (ASM_Z80_CTRL_PORT),
          [ctrlddr]       "I" (ASM_Z80_CTRL_DDR),
          [busreqbit]     "I" (ASM_BIT_BUSREQ),
          [mreqbit]       "I" (ASM_BIT_MREQ),
          [rdbit]         "I" (ASM_BIT_RD),
          [shldbit]       "I" (ASM_BIT_SH_LD),
          [hsyncbit]      "I" (ASM_HSYNC_PIN),
          [vsyncbit]      "I" (ASM_VSYNC_PIN),
          /* TEMPORARY bench-test hooks (see shld_test.c). 2026-09-19: a
           * first attempt gated Timer3/OC3A's *pin connection* (COM3A1)
           * once per frame, from this blanking path -- bench-found wrong,
           * since it left PB6 toggling continuously across each active
           * line's whole 64us (including HSYNC/back-porch/release), not
           * just the ~40us video-fetch burst the real SH_LD is actually
           * confined to. Real fix has to live in the active-line path
           * below instead (gating PB6's DDR bit right around the burst,
           * 2 sbi/cbi added there, +4 cycles total, 1018/1024) -- these
           * two operands are its only trace up here. */
          [ddrb]          "I" (_SFR_IO_ADDR(DDRB)),
          [ddb6]          "I" (DDB6),
          [tcnt3h]        "n" (_SFR_MEM_ADDR(TCNT3H)),
          [tcnt3l]        "n" (_SFR_MEM_ADDR(TCNT3L)),
          [t3phase]       "M" (SHLD_TIMER3_PHASE)
        : "r16", "r17", "r18", "r19", "r20", "r21", "r22", "r23",
          "r24", "r25", "r30", "r31", "cc", "memory"
    );
}

void sync_init(void)
{
    /* video_addr (r2:r3, see its declaration comment above) has no C-level
     * initializer to zero it -- registers aren't part of __do_clear_bss's
     * work, only BSS memory is. Zero it explicitly here, once, before the
     * ISR that reads it can ever fire. */
    asm volatile("clr r2\n\t" "clr r3\n\t");

    /* Timer1: CTC via OCR1A (WGM13:10 = 0100 -> WGM12 only), UNPRESCALED
     * (CS12:11:10 = 001 -> CS10 only) -- 16MHz timer clock, 1 tick/CPU
     * cycle, needed so TCNT1 gives single-cycle jitter resolution.
     * OCR1A=1023 -> 1024 ticks/period = 64.000us exactly. Only one
     * compare unit (OCR1A/COMPA) is used now -- see header comment for
     * why OCR1B/COMPB was removed. */
    TCCR1A = 0;
    TCCR1B = (1 << WGM12) | (1 << CS10);
    OCR1A = 1023;

    TIMSK1 = (1 << OCIE1A);
}
