# Dev-emulator devlog

Working log for `plan-kc-z80-comp-emu.md`'s implementation -- mirrors
`docs/bring-up-log.md`'s style (real findings, bench-verified, dated)
but scoped to this host-side software subsystem rather than hardware
bring-up.

## 2026-09-26: Phase P0 -- vendored z80em, minimal harness passes

Downloaded the real, current source directly (`fms.komkon.org/EMUL8/
Z80-081707.zip`, 2007-08-17) rather than trusting a secondary mirror --
vendored `Z80.c`/`Z80.h`/`Codes*.h`/`Tables.h` unmodified into
`third_party/z80em/` (the optional debugger, `ConDebug.c`/`Debug.c`,
intentionally not vendored -- out of scope). License quoted exactly
from the real header in `third_party/z80em/NOTICE.md`; courtesy
notification email to the author is a manual step, not something done
here.

**Correction to the plan's own API description**: `plan-kc-z80-comp-emu.md` (written
during planning, based on a secondary GitHub mirror of an older version)
described `RdZ80`/`WrZ80`/`InZ80`/`OutZ80`/`LoopZ80` as function-pointer
hooks the host assigns. The real, current vendored `Z80.h` declares
these as **plain C functions the host defines directly** -- `Z80.c`
calls them by name at compile time, no pointer indirection at all.
Simpler to integrate than planned (no setup code needed), just a
naming correction.

Built `src/p0_harness.c`: a tiny hand-assembled Z80 program (load A,
loop-decrement B 5 times via `DEC B`/`JR NZ`, then spin forever on
`JR -2`) run through `ResetZ80`/`RunZ80` with stub `Rd`/`Wr`/`In`/`Out`/
`Patch`/`LoopZ80` hooks (a flat 64K array for memory, `LoopZ80` returns
`INT_QUIT` on its first call to stop deterministically once `IPeriod`
cycles have elapsed).

**Bench-found bug in the harness itself, not the core**: first attempt
set `cpu.IPeriod` *after* calling `ResetZ80()`. Confirmed directly
against the real `ResetZ80()` source that it does `R->ICount =
R->IPeriod` as part of reset -- setting `IPeriod` afterward has no
effect on the first run, since `ICount` was already seeded from
whatever `IPeriod` held at reset time (uninitialized stack garbage for
a plain local `Z80 cpu;`). Result: `ICount` expired after a single
instruction, calling `LoopZ80`/`INT_QUIT` right after `LD A,0x42` --
before the `B`-decrementing loop ever ran. This still printed `B=0x00`
and looked like a pass, because that's `ResetZ80`'s own zeroed initial
value for `BC`, not evidence the loop executed -- a false pass, caught
only because a PC-range assertion (spin-loop landing) was added
alongside the register check. Fixed by setting `IPeriod` before
`ResetZ80()`; re-verified with the PC check in place: `A=0x42, B=0x00,
PC=0x0007` -- genuinely correct this time, whole program including the
loop executed as intended.

**Takeaway for later phases**: when driving this core from a `LoopZ80`-
gated cycle budget, always set `IPeriod` before `ResetZ80()`, and don't
trust a data-register-only check to prove a loop actually ran when the
register's reset value happens to coincide with the expected post-loop
value -- add a control-flow-position check (PC, or a memory-side
effect) alongside it.

**Done**: `cd emu && make p0` builds cleanly (zero warnings) and passes.
Confirms the vendored core itself builds, links, and executes real Z80
code correctly on this dev machine. Phase P0 complete per `plan-kc-z80-comp-emu.md`.

## 2026-09-26: Phase P1 (scoped) -- real CP/M image loads at the right addresses

Found real complexity beyond the plan's one-line description before
writing any code: `bios.bin` is not one contiguous memory image --
`bios.asm` builds it as three separately-addressed chunks (page-zero
trampoline at `$0008`, font+blit code at `$8000`, CCP+BDOS+BIOS at
`$DC00`), normally stitched together at real boot time by
`stage1.asm`'s own disk-sector-reading bootstrap. Replicating that
whole bootstrap faithfully is a P2+ concern (needs the disk
abstraction); scoped P1 down to just: load each chunk at its real
address and confirm known bytes are there.

Wrote `kc-z80-comp-emu/tools/extract_bios_chunks.py`, deliberately mirroring (not
importing -- that script isn't a module) `firmware/z80-boot-rom/cpm/
build-boot-image.py`'s own chunk-offset arithmetic, which is the real,
bench-proven source of truth for how bios.bin's linear byte layout maps
to the three chunks' addresses. Ran it against a freshly-rebuilt
`bios.sym`/`bios.bin` -- output sizes (chunk1: 38 bytes, chunk2: 2413
bytes, chunk3: 8813 bytes) landed exactly at the file's real EOF with
no gap/overlap, a good independent consistency check that the
arithmetic is right, before writing anything that reads the result.

Hand-verified the actual bytes at CBASE/FBASE/BOOT via `xxd` *before*
writing the automated check, per this project's own standing practice
of confirming manually before trusting an automated pass: `$DC00`
(CBASE) reads `C3 5C DF` -- a `JP` to CCP's own entry, with a visible
"Copyright" string a few bytes further in (CP/M's own startup banner --
about as reassuring a sanity check as this gets); `$E406` (FBASE) reads
`C3 11 E4` -- `JP` to the real BDOS entry; `$F200` (BOOT) reads
`C3 33 F2` -- the first `JP` of the BIOS's own jump table. All three are
real, meaningful CP/M code, not zeros or garbage.

Built `src/p1_harness.c`: loads all three chunks per
`kc-z80-comp-emu/build/manifest.txt` (generated by the extraction script) into a
plain flat 64K RAM array -- no bank-switch modeling yet, deliberately
deferred to P3 when bank=1/video/font access actually needs it -- then
checks the exact byte patterns above. `cd emu && make p1` builds clean
and passes.

**Done**: Phase P1 complete, as scoped (memory dump shows CCP/BDOS/BIOS
resident at the real, confirmed addresses -- `$DC00`/`$E406`/`$F200`).
Not done: the real 3-chunk disk-boot sequence itself, bank-switch
address translation, any CPU execution of the loaded image (needs
console/disk I/O -- P2).

## 2026-09-26: Phase P2 -- disk abstraction, real boot to a live CCP prompt

Read `bios.asm` directly to find the real disk-driver intercept points
rather than guess a level of abstraction: `read_impl`/`write_impl`
(CP/M's own BIOS jump-table entries) both do a 512-byte read-modify-
write cache (`sector_cache`) around a 128-byte logical sector, then
call down to two lower routines that actually touch SD hardware --
`read_raw_sector` ($fa3c, HL=destination buffer, LBA read from a fixed
4-byte little-endian word `new_lba` at $face) and `write_block` ($f998,
HL=source buffer, same `new_lba`, called only after the command frame
for CMD24 is already sent). `parse_partition_table` (real MBR read at
boot) also calls `read_raw_sector` directly with `new_lba=0` -- so
patching these two routines' entries covers both the boot-time MBR
read and all ongoing CP/M disk I/O, exactly matching `plan-kc-z80-comp-emu.md`'s
own "recognize the port sequence, do direct file I/O" recommendation,
at the lowest level that's still convenient (below the RMW cache, so
none of that logic needs replicating; above the actual SPI bit-shift
code, so none of *that* needs replicating either).

Used z80em's `PatchZ80` hook (`ED FE` two-byte "patch" opcode,
purpose-built by the core for exactly this -- its own doc comment says
"emulate BIOS calls, such as disk and tape access") to intercept both,
plus `const_impl`/`conin_impl`/`conout_impl` for a deliberately
temporary stdio console (headless CONST -- always "no key ready";
CONOUT -- plain `putchar`) -- real screen/keyboard abstraction is
P3/P4's job, not this one's. `PatchZ80` reads the routine's own
register/memory conventions directly (LBA from `new_lba`, buffer from
`HL`) and does real `fseek`/`fread`/`fwrite` against the actual
`boot.img`, then manually pops a return address off the emulated stack
to behave exactly like the patched routine's own final `RET` would
have -- necessary because `PatchZ80` replaces the whole routine body,
not just one instruction.

**Real, fundamental bug found and fixed**: first attempt hung for the
full 20M-cycle budget with zero console output and not a single disk
patch ever firing. Traced it down to a handful of cycles by shrinking
`IPeriod` step by step (200 -> 20 -> 4) and logging `PC`/`SP` every
`LoopZ80` call: execution diverged in the *very first instruction*.
`BOOT_ENTRY` ($f200) correctly holds `JP $F233`, but the CPU landed at
$33F2 instead -- the exact byte-swap of the intended target. Root
cause: `Z80.h`'s `pair` union overlays a 16-bit `.W` on two named bytes
(`.B.h`/`.B.l`), and which byte sits first in memory (so a 16-bit
target built from two separately-fetched bytes, as every `JP`/`CALL`/
16-bit-immediate-load does, agrees with `.W`) depends on the `LSB_FIRST`
macro -- which this little-endian (x86_64) build never defined. P0's
own test happened not to catch this: it only used `JR`'s 8-bit
PC-relative offset, added straight into `.W`, never constructing a
16-bit address from two separate bytes -- so P0 "passed" while sitting
on a bug that would have broken essentially all real CP/M execution
(every `CALL`, every 16-bit `LD reg,nnnn`) the moment anything less
trivial than a tiny hand-rolled loop ran. Fixed by adding `-DLSB_FIRST`
to the Makefile's `CFLAGS` (applies to the whole build, `Z80.c` and
every harness alike, since they all share the same `pair` layout via
`Z80.h`). Re-ran P0 and P1 after the fix to confirm no regression --
both still pass unchanged.

With that fixed: `cd emu && make p2` boots the real, unmodified
`bios.bin`/`boot.img` all the way to a live `A>` CCP prompt, captured
via the temporary stdio console. A few stray NUL bytes trail the
prompt in the captured output -- plausibly cursor-positioning control
bytes the real `conout_impl` would use to drive an actual video
cursor, harmlessly printed as raw NULs by this phase's deliberately
dumb `putchar`-only console; not investigated further since P3's real
screen abstraction supersedes this stdio shim rather than fixing it.
Confirmed `boot.img` was never actually written to during this run
(`cmp` against a pre-run backup) -- consistent with a read-only cold
boot to an idle prompt, no user command yet issued.

**Done**: Phase P2 complete -- CP/M boots to a live CCP prompt entirely
in emulation, matching real hardware's own already-bench-confirmed CCP
boot (`docs/bring-up-log.md`).

## 2026-09-26: Phase P3 -- real SDL2 screen abstraction, visually confirmed

Deliberately decoupled from CP/M/disk/console entirely (no `PatchZ80`
use at all) -- wrote `testprogs/vram_fill.asm`, a small standalone Z80
program purpose-built to exercise the screen abstraction in isolation:
fills the 640x200 1bpp framebuffer at `$C000` (80 bytes/line) in 8-line
bands, solid black (`$00`) alternating with solid white (`$FF`) --
chosen over `video-test2.asm`'s own `$AA`/`$55` convention specifically
because those two values are bit-complements that both render as the
same fine 50%-dither stripe (just phase-shifted by one pixel), hard to
tell apart at a glance; solid bands are unambiguous in a screenshot.
Loops forever, delaying and inverting which band starts black/white
each pass, so the image is genuinely live-updating, not a one-shot fill.

`src/p3_harness.c`: a real SDL2 window (not a dummy/headless driver --
confirmed a real X11 display was available first, `DISPLAY=:0`),
640x200 logical size scaled 2x for visibility, reads `ram[$C000..]`
bit-by-bit (MSB-first, matching the real 74LS166 shift-out convention)
into an ARGB8888 texture once per throttled ~30fps tick (`SDL_GetTicks`
-- decoupled from the Z80 core's own, much-faster-than-real-hardware
execution speed, per `plan-kc-z80-comp-emu.md`'s own "don't model bus-steal timing"
decision), presents it, and polls for `SDL_QUIT`. Auto-quits after 4
real seconds so this runs unattended in CI/this sandbox, not just
interactively.

**Visually verified, not just trusted from the code**: `import`/
`gnome-screenshot` (X11 screen-capture tools) turned out unusable in
this sandbox (`import`: cryptic "missing an image filename" error even
with correct syntax, likely an X11-delegate-less ImageMagick 7 build;
`gnome-screenshot`: hangs indefinitely, no gnome-shell/D-Bus session to
talk to) -- rather than fight the sandbox's screenshot tooling, added
`SDL_RenderReadPixels`+`SDL_SaveBMP` directly to the harness itself
(reads the renderer's own real output, at its actual physical
resolution via `SDL_GetRendererOutputSize` -- the logical 640x200 set
via `SDL_RenderSetLogicalSize` is a scaling viewport, not the backing
surface's real size, so using the logical size directly would have
under-sized the capture buffer), then converted the resulting BMP to
PNG (`magick`) and looked at it directly. **Correct**: clean alternating
solid black/white 8-line horizontal bands, exactly the intended
pattern, no artifacts.

**Done**: Phase P3 complete -- `cd emu && make p3` shows a real,
correctly-updating rendering of the framebuffer in an actual SDL2
window, visually confirmed via a saved screenshot
(`build/p3_screenshot.bmp`/`.png`, regenerated each run, not committed).

**Added `--line-double`** (user request, not part of the original phase
scope): draws each real scanline twice into the pixel buffer (sharp
duplication, not a smooth stretch), doubling the window's real height.
Purely a viewing convenience -- default (undoubled) stays the norm for
work on the emulator itself, since it's a real, if small, distortion of
the raw framebuffer. Incidentally lands closer to the real hardware's
own confirmed non-square-pixel aspect than the undoubled 640x200 does,
but that's a side effect, not the point. Verified both modes via the
harness's own screenshot mechanism: default still 1280x400 with 25
bands; `--line-double` correctly 1280x800, same 25 bands (not 50),
each visually taller.

## 2026-09-26: Phase P4 -- keyboard abstraction, typing at the real CCP prompt

Natural convergence point of P1-P3, in a new `p4_harness.c`: P1's
manifest loader, P2's disk patches (`read_raw_sector`/`write_block`,
unchanged), P3's screen rendering (unchanged) -- but this time CONOUT
is *not* patched at all. The real `conout_impl` (font-blit, cursor,
VT52-subset terminal handling) now runs for real and writes actual
characters into video RAM, which P3's renderer already displays
correctly -- no bank=1/A16 modeling needed for this to work, since this
emulator's flat 64K RAM has always let `$C000+` through unconditionally
(P1's own deliberate simplification), which is more permissive than
real hardware, not less.

Read `bios.asm` again to find the right keyboard intercept boundary:
`poll_key` ($f400), not `const_impl`/`conin_impl` themselves --
`poll_key` is exactly the BIOS's own line between "hardware keyboard-
matrix scan" (`get_key_event`/`find_key`, real 8255-port-touching code,
not replicated) and the higher-level `pending_char` bookkeeping (left
real: `const_impl`/`conin_impl`/`show_cursor`/`hide_cursor` all still
run as actual BIOS code). Patched via the same `PatchZ80`/`ED FE`
mechanism as the disk routines, mirroring `poll_key`'s own contract
(`CALL get_key_event / RET NC / LD (pending_char),A / RET`): write a
queued character to `pending_char` and return, or leave it untouched
if nothing's queued -- same shape as P2's disk patches, at the same
"lowest hardware-touching primitive" boundary.

Keystrokes reach the queue two ways: real SDL events (`SDL_TEXTINPUT`
for printable characters, `SDL_KEYDOWN`/`SDLK_RETURN` for Enter) for
actual interactive use, and a scripted self-test (queue "DIR\r" a fixed
delay after boot) for unattended verification here -- both go through
the identical `queue_char()`, so the scripted path genuinely exercises
the same code a real keypress would, not a parallel shortcut.

**Real bug found and fixed, visible directly in the first screenshot**:
typed "DIR" + Enter, screen showed "A>DR" then CCP's own "DR?" unknown-
command error -- the "I" was silently dropped. Root cause: `const_impl`
calls `poll_key` *unconditionally* on every CONST check, whether or not
the previous `pending_char` has been consumed by CONIN yet. On real
hardware this is safe because `get_key_event`'s own debounce/
`last_row`/`last_col` logic only reports a "new" key once per genuine
physical transition -- scanning the same still-held key again returns
carry clear, no overwrite. The first patch attempt dequeued
unconditionally on every `poll_key` call, with no such latch, so a
`CONST` call arriving before `CONIN` drained the previous character
silently ate the next one in the queue. Fixed by only pulling a new
character when `pending_char` is already 0 (i.e. actually consumed --
`conin_impl`'s own `XOR A / LD (pending_char),A` after reading it),
exactly mirroring "key still held, no new event" instead of refilling
on every call.

After the fix: `A>DIR` typed correctly, and CCP's *real* directory
listing appeared -- `A: PIP     COM`, an actual file read off
`boot.img` -- followed by a fresh prompt. Confirmed visually via the
harness's own screenshot mechanism (`build/p4_prompt.bmp` before typing,
`build/p4_after_dir.bmp` after) and confirmed `boot.img` itself was
untouched afterward (a `DIR` is read-only). This is the full loop
working end to end: keyboard -> CCP -> BDOS -> disk -> screen.

**Done**: Phase P4 complete -- typing at the emulated CCP prompt works
correctly, verified with a real command against the real disk image,
not just a synthetic test pattern.

## 2026-09-26: Real bank-switch modeling added (user caught it live)

User was watching the SDL window directly (not just the saved
screenshots) and reported: "half the screen is random garbage." Real
bug, not a viewing artifact -- confirmed the cause before touching
anything: `bank` is bit 1 of the 8255's Port A, written via `OUT
($A8),A` (`SHADOW_BASELINE=$05`, `porta_shadow` shadow-copy pattern,
`bios.asm` lines ~20-60 and 664-666). This emulator's memory model, up
through the first version of P4, was a single flat 64K array with no
bank modeling at all -- a deliberate simplification noted back in P1's
own devlog entry ("deferred to P3 when bank=1/video/font access
actually needs it"). That note undersold the real consequence: on real
hardware, `$8000-$FFFF` is two genuinely *different physical pages*
selected by that bit -- bank=0 is CCP/BDOS/BIOS's own code (chunk3,
`$DC00`-`$FE6C`), bank=1 is font+blit code (chunk2, `$8000`-`$896C`)
*and* video RAM (`$C000`-`$FFDF`) in the same page. A flat model can
only hold one of those two pages at a given address at a time, and
chunk3's own address range sits almost entirely *inside* the video-RAM
address range -- so the renderer was displaying CCP/BDOS/BIOS's actual
machine code as pixels. The overlap fraction (`(0xFE6C-0xDC00) /
(0xFFDF-0xC000)` ~= 54%) matches "half the screen" almost exactly.

Fixed with a real 128K backing store (`physram`) and the hardware's own
translation, confirmed against `cpm-plan.md`'s truth table rather than
re-derived: `addr<0x8000` or `bank==0` -> `physram[addr]`; `bank==1` ->
`physram[addr+0x10000]` -- `0x18000-0x8000` happens to equal exactly
`0x10000`, so bank=1's upper-32K view is simply "the same address plus
a fixed offset," not a separate case per sub-region. `OutZ80` tracks
`bank` from real writes to port `$A8`. The loader now places chunk2 in
the bank=1 view (`physram[addr+0x10000]`) and chunk1/chunk3 in the
bank-invariant/bank=0 view (`physram[addr]`), matching which physical
page each chunk is really destined for. All patch code (disk buffer
addresses, `pending_char`, `new_lba`, the return-address pop in
`simulate_ret`) now goes through the same `xlate()` the CPU itself
uses. The screen renderer is the one deliberate exception: it always
reads the bank=1 copy directly (`physram[... + 0x10000]`), never
through `xlate()`, matching real hardware's own behavior that the video
fetch hardware forces its own page selection unconditionally,
independent of whatever the Z80's own `bank` variable currently holds.

Re-verified after the fix: `boot.img` still untouched, and the DIR
self-test screenshot now shows clean solid black everywhere except the
real text -- no garbage at all. This fix matters beyond cosmetics: it's
required for P5's `breakout.com` (any real program drawing to video
RAM needs this to work at all) and was genuinely missed by this
project's own earlier reasoning about the flat-memory simplification
being "strictly more permissive, never less" -- true for *writes*
(CP/M code can touch `$C000+` without an explicit bank flip and still
land in the right physical page, since there's no gate at all), false
for *reads done by something else* (the renderer), which is exactly
the case that was missed.

## 2026-09-26: p4_harness was never actually runnable interactively

User pointed out (twice, the first answer having missed the actual
problem): `p4_harness` always ran the scripted "type DIR, screenshot,
auto-quit after ~2.5s" self-test unconditionally -- there was no way to
just sit at the emulated machine and use it. That self-test existed
purely for this session's own unattended verification and had
accidentally become the *only* mode. Fixed: plain interactive session
(real window, real keyboard, no auto-quit -- runs until the window is
closed) is now the default with no arguments; `--self-test` opts into
the old scripted verification instead. Confirmed default mode actually
stays running (checked a background instance was still alive after 3
real seconds, unlike the old unconditional ~2.5s auto-quit) and
`--self-test` still passes unchanged.

Run it yourself: `cd emu && make p4_harness && ./p4_harness` (add
`--line-double` for the taller view).

## 2026-09-26: Phase P5 -- the acceptance test, breakout.com runs for real

New `p5_harness.c` (copied from P4, same bank-switch-corrected memory
model and disk/keyboard patches unchanged). Points at
`build/boot_p5.img`, a **copy** of the real `boot.img` with
`BREAKOUT.COM` injected via `cpm_put.py` (default driveA geometry,
image-offset 0 -- both correct unchanged: `cpm_put.py build/boot_p5.img
.../breakout.com BREAKOUT.COM` reported a clean "wrote BREAKOUT.COM:
1946 bytes, 16 records, blocks [10, 11], dir slot(s) [1]" with no
complaint). The real `boot.img` is never touched -- the Makefile's
`build/boot_p5.img` rule always starts from a fresh `cp` of it.

**Known limitation going in, not a surprise found the hard way**:
breakout's own `input.s` bypasses BDOS/CONST/CONIN entirely and polls
the 8255 keyboard-matrix ports directly -- this emulator's `InZ80` stub
(unconditional `0xFF`) isn't matrix-hardware emulation, but happens to
read as "nothing pressed in any row" under breakout's own active-low
convention, a plausible if unintentional "no input" default. Good
enough to check the game loads/runs/draws correctly; not good enough to
actually play it (the paddle can never move).

Self-test types `BREAKOUT\r` at the live CCP prompt (same mechanism as
P4's `DIR` test). Result: the game genuinely loaded, initialized, and
ran a real session -- reaching "GAME OVER / PRESS ESC" (unsurprising
with a permanently stationary paddle) within roughly 300ms of *wall-
clock* time. That collapsed timing is itself informative, not a bug:
this emulator runs the Z80 core at full host speed with no bus-steal
throttling (`plan-kc-z80-comp-emu.md`'s own deliberate choice), and nothing paces
ball/paddle movement except a busy-wait delay loop counted in Z80
cycles -- so the entire load-to-game-over lifecycle, timed in real
seconds on actual 8MHz-ish hardware, compresses into a fraction of a
second here. Worth remembering for any future game-timing work (other games'
own main loop included): a busy-wait-paced game will run at whatever
speed the host CPU allows unless something explicitly throttles overall
execution to approximate real hardware's rate, not just the screen's
own render throttle.

Single-timestamp screenshots kept landing on "not typed yet" or
"already game over" -- the real play window was only tens of
milliseconds wide. Switched to burst-capturing every rendered frame
across an 820-1080ms wall-clock window instead of guessing one moment,
and got real gameplay frames (`build/p5_burst_925.bmp` and `_991.bmp`,
not committed -- regenerated by `make p5`): a full brick wall (multiple
rows, distinct patterns per row), the score display ("00000"), a lives
counter, the paddle, and the ball, all correctly rendered. **The two
frames 66ms apart show the lives counter correctly drop from 3 to 2** --
real game logic executing correctly (ball passed the paddle, a life
was lost, the counter updated), not just a static rendered screen.

**Done**: Phase P5 complete -- `breakout.com`, already proven on real
hardware, loads, initializes, draws, and runs correct game logic under
this emulator, with the one known, explicitly-scoped-out limitation
(no real keyboard-matrix modeling, so it can't actually be played
interactively yet). This is the acceptance test `plan-kc-z80-comp-emu.md` set out
to pass: the emulator is now trustworthy enough to build new code
against, not just a plausible-looking toy. Run it yourself: `cd emu &&
make p5_harness build/boot_p5.img && ./p5_harness` (add `--self-test`
for the scripted verification instead of a plain interactive session).

Not yet done, explicitly out of scope for P5: real keyboard-matrix
modeling (row-select-aware `OutZ80`/`InZ80`) for actual playable input
in games that bypass BDOS, and any of P5's own findings about
CPU-speed-dependent game timing.

## 2026-09-26: BREAKOUT.COM added to the real boot.img

User asked for `BREAKOUT.COM` to actually show up on drive A when
running `p4_harness` against the real disk image, not just P5's
disposable test copy. Backed up the real `boot.img` first, then ran
the exact same `cpm_put.py` invocation used for P5's copy directly
against it: `wrote BREAKOUT.COM: 1946 bytes, 16 records, blocks [10,
11], dir slot(s) [1]`. Diffed before/after to confirm the write landed
only in drive A's own data/directory area (changed bytes span file
offset 16672-28824, entirely past the 12288-byte boot-chunk region) --
the boot chunks themselves are untouched.

**First verification attempt showed a blank screen after `DIR`** --
looked alarming, but the actual cause was mundane: `p4_harness`'s
`--self-test` mode takes its "after typing" screenshot at a fixed
2500ms mark, tuned back when `DIR` only had one file to print. Listing
two files takes a bit longer, and the screenshot landed before CCP
finished printing. Confirmed by re-running with a longer wait (8000ms)
first -- showed the correct listing, `A: PIP     COM : BREAKOUT COM` --
then set a permanent, comfortably generous 4000ms in place of the
original 2500ms and reconfirmed clean. Not a bug in the bank-switch
model or the disk patches, just a self-test constant that needed
updating alongside the disk image it now has more to report on.

## 2026-09-26: real-speed throttle -- BREAKOUT was unplayable, confirmed by the user

User actually played `BREAKOUT.COM` interactively and confirmed exactly
what P5's own devlog entry had already flagged as a side-finding, not
just a theoretical concern: the game ends almost immediately, far
faster than real hardware, because nothing paces it. Fixed properly
this time, in `p4_harness.c` (the interactive harness -- `p5_harness.c`
deliberately keeps its own unthrottled self-test as-is, see below).

`LoopZ80` now tracks total emulated cycles against wall-clock time
since start, and sleeps off any surplus once the core has run ahead of
where a real 8MHz Z80 (this project's own nominal clock, `CLAUDE.md`)
would be. Deliberately 8MHz, not the ~4.79MHz *effective* throughput
real hardware sees once video bus-steal is factored in -- this emulator
doesn't model bus-steal timing at all (`plan-kc-z80-comp-emu.md`'s own
architecture decision), so 8MHz is the only real reference rate it has;
there's no slower "effective" number to throttle to here. New
`--unthrottled` flag opts back into the old fast-as-possible behavior
for anyone who wants it; automated `--self-test` runs also stay
unthrottled unconditionally (verification wants to finish fast, not
pace itself against a game's own timing).

Verified with a temporary env-var-gated auto-quit (removed after
testing, not shipped) rather than trusting the arithmetic alone: a
controlled 3.000s run measured **exactly 24,000,000 cycles -> 8.00MHz
effective**; the same test with `--unthrottled` measured ~98MHz over
500ms, confirming the flag genuinely bypasses the throttle rather than
silently doing nothing. A permanent, always-printed exit line reports
the same measurement (`N cycles emulated over Mms -> X.XXMHz effective,
throttled to 8MHz` or `, unthrottled`) so this is checkable at a glance
on any run, not just this session's own test.

## 2026-09-26: real keyboard-matrix emulation -- arrow keys/ESC now work

User confirmed cursor keys and ESC don't do anything in `BREAKOUT.COM`.
Root cause was already known, not a surprise: `breakout.com`'s own
`input.s` bypasses BDOS/CONST/CONIN entirely and polls the keyboard
matrix directly (`OUT ($AA)` row-select, `IN ($A9)` active-low column
read) -- P5's own devlog entry had explicitly flagged this as out of
scope, and `InZ80`'s unconditional `0xFF` stub never modeled it at all.
Read `input.s` itself for the exact protocol (row 8 = LEFT/RIGHT at
columns 4/7, row 7 = ESC at column 2) and
`firmware/z80-boot-rom/test-progs/keyboard-scan-test.asm`'s own
`keynames` table for the complete row/col map (the standard MSX matrix
this hardware follows, confirmed there against map.grauw.nl) -- both
already fully documented this project's own real hardware, nothing
reverse-engineered.

Implemented properly, not just enough for LEFT/RIGHT/ESC: `OutZ80` now
latches `kbd_row` on writes to port `$AA`; `InZ80` returns the selected
row's 8 column bits (active-low) from a new `key_held[9][8]` state
array on reads from port `$A9`. A `KBD_MAP` table (every symbol from
the keynames table with a reasonable modern-keyboard equivalent --
digits, letters, punctuation, arrows, ESC/TAB/RETURN/BACKSPACE/SPACE/
HOME/INS/DEL, SHIFT/CTRL, F1-F5; GRAPH/CODE/STOP/SELECT/DEAD skipped,
no sensible modern mapping) drives `kbd_set()`, called from
`SDL_KEYDOWN`/`SDL_KEYUP` in `LoopZ80` -- a second, independent
"currently held" tracking alongside the existing `key_queue` FIFO
(BDOS-level typing is edge-triggered discrete characters; a matrix scan
is level-triggered "is this held right now," genuinely different
models, both fed from the same physical keypresses).

**Verified positionally, not just trusted from the code** -- a
temporary scratch copy of this harness (never committed) typed
`BREAKOUT`, called `kbd_set(SDLK_LEFT, 1)` directly a moment after
gameplay starts (bypassing real SDL input, since nothing here can press
a physical key), and screenshotted the paddle's position at two
timestamps 400ms apart while held. **The paddle's left edge moved from
x~95 to x~63** between those frames -- a real, measured, deterministic
position change while LEFT was held, not inferred from a win/loss
outcome (an earlier attempt tried to confirm this by whether the paddle
saved the ball, but the ball had already ended that life before the
hold began -- inconclusive by construction, replaced by this direct
positional check instead). Confirmed the real committed source has none
of the scratch copy's test-only changes (`diff` against a pre-edit
backup, clean).
