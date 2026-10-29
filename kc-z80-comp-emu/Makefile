# Development emulator build (plan-kc-z80-comp-emu.md). Host-side (this dev
# machine's own gcc), not part of the AVR/Z80 firmware toolchain.

# -DLSB_FIRST: REQUIRED on this (and any little-endian, e.g. x86_64)
# host -- Z80.h's `pair` union overlays a 16-bit `.W` on top of two
# named bytes (`.B.h`/`.B.l`), and which byte is "first in memory" (so
# `.W` and separately-written `.B.h`/`.B.l` halves agree on which end is
# significant) depends on this macro. Bench-found the hard way (P2):
# omitting it silently byte-swaps every 16-bit address built from two
# separately-fetched bytes -- JP/CALL/16-bit immediate loads all do
# this -- so `JP $F233` executed as `JP $33F2` instead. P0's own test
# happened not to catch this (it only used JR's PC-relative 8-bit
# offset, never a 16-bit absolute target), which is exactly why P2's
# real CP/M boot code, full of CALLs and 16-bit loads, is what surfaced
# it. See kc-z80-comp-emu/DEVLOG.md.
CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -O2 -DLSB_FIRST -I third_party/z80em
Z80_SRC = third_party/z80em/Z80.c

SDL2_CFLAGS = $(shell pkg-config --cflags sdl2)
SDL2_LIBS   = $(shell pkg-config --libs sdl2)

.PHONY: all clean p0 p1 p2 p3 p4 p5 bios-chunks
all: p0 p1 p2 p3 p4 p5

# Phase P0: minimal harness, proves the vendored core builds/links/runs
# correctly. No project memory map/disk/screen yet -- see plan-kc-z80-comp-emu.md.
p0: p0_harness
	./p0_harness

p0_harness: src/p0_harness.c $(Z80_SRC)
	$(CC) $(CFLAGS) -o $@ src/p0_harness.c $(Z80_SRC)

# Phase P1 (scoped): load the real CP/M image's three chunks and
# confirm CCP/BDOS/BIOS land at their real addresses. Needs
# build/{chunk1,chunk2,chunk3}.bin + manifest.txt -- regenerate with
# `make bios-chunks` (requires firmware/z80-boot-rom/cpm/bios.sym to
# be up to date: `make bios.sym` there first).
p1: p1_harness build/manifest.txt
	./p1_harness

bios-chunks:
	python3 tools/extract_bios_chunks.py

build/manifest.txt:
	python3 tools/extract_bios_chunks.py

p1_harness: src/p1_harness.c $(Z80_SRC)
	$(CC) $(CFLAGS) -o $@ src/p1_harness.c $(Z80_SRC)

# Phase P2: disk abstraction (PatchZ80-based, see p2_harness.c's own
# header), boots the real CP/M image to a live CCP prompt. Needs a
# real boot.img -- build one with the cpm/ Makefile if missing.
p2: p2_harness build/manifest.txt
	./p2_harness

p2_harness: src/p2_harness.c $(Z80_SRC)
	$(CC) $(CFLAGS) -o $@ src/p2_harness.c $(Z80_SRC)

# Phase P3: screen abstraction via SDL2 (see p3_harness.c/
# testprogs/vram_fill.asm's own headers). Decoupled from CP/M --
# needs only testprogs/vram_fill.bin, rebuilt with z80asm if missing.
p3: p3_harness testprogs/vram_fill.bin
	./p3_harness

testprogs/vram_fill.bin: testprogs/vram_fill.asm
	z80asm -o $@ testprogs/vram_fill.asm

p3_harness: src/p3_harness.c $(Z80_SRC)
	$(CC) $(CFLAGS) $(SDL2_CFLAGS) -o $@ src/p3_harness.c $(Z80_SRC) $(SDL2_LIBS)

# Phase P4: keyboard abstraction, typing at the real CCP prompt (see
# p4_harness.c's own header) -- the natural convergence of P1-P3 plus
# real SDL keyboard input. Needs the same manifest + boot.img as P2.
p4: p4_harness build/manifest.txt
	./p4_harness

p4_harness: src/p4_harness.c $(Z80_SRC)
	$(CC) $(CFLAGS) $(SDL2_CFLAGS) -o $@ src/p4_harness.c $(Z80_SRC) $(SDL2_LIBS)

# Phase P5: the acceptance test (see p5_harness.c's own header) --
# runs breakout.com under the emulator. build/boot_p5.img is a COPY of
# the real boot.img with BREAKOUT.COM injected via cpm_put.py; the real
# boot.img is never touched.
p5: p5_harness build/boot_p5.img
	./p5_harness --self-test

build/boot_p5.img: ../firmware/z80-boot-rom/cpm/boot.img ../drive-b/BREAKOUT.COM
	cp ../firmware/z80-boot-rom/cpm/boot.img $@
	python3 ../firmware/z80-boot-rom/cpm/cpm_put.py $@ \
		../drive-b/BREAKOUT.COM BREAKOUT.COM

p5_harness: src/p5_harness.c $(Z80_SRC)
	$(CC) $(CFLAGS) $(SDL2_CFLAGS) -o $@ src/p5_harness.c $(Z80_SRC) $(SDL2_LIBS)

clean:
	rm -f p0_harness p1_harness p2_harness p3_harness p4_harness p5_harness testprogs/vram_fill.bin
	rm -rf build

.PHONY: clean
