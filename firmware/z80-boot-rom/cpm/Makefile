# CP/M system build. bios.asm includes cpm22.asm directly (z80asm
# multi-file continuous assembly -- see bios.asm's own header), so
# this only needs to assemble the one top-level file, with cpm/ on the
# include path for the `include 'cpm22.asm'` line to find it.
Z80ASM = z80asm

all: bios.bin stage1.bin boot.img cksum.com cpydbg.com cpyrand.com cpyren.com hello.com

bios.bin: bios.asm cpm22.asm msxfont.img
	$(Z80ASM) -I . -o $@ bios.asm

stage1.bin: stage1.asm
	$(Z80ASM) -o $@ stage1.asm

# Standalone CP/M .COM utilities -- assembled separately from the
# BIOS/bootstrap above, loaded onto a disk image via cpm_put.py rather
# than xmodem'd to the AVR (they run as ordinary CP/M programs, not
# part of the boot chain).
cksum.com: cksum.asm
	$(Z80ASM) -o $@ cksum.asm

cpydbg.com: cpydbg.asm
	$(Z80ASM) -o $@ cpydbg.asm

cpyrand.com: cpyrand.asm
	$(Z80ASM) -o $@ cpyrand.asm

cpyren.com: cpyren.asm
	$(Z80ASM) -o $@ cpyren.asm

hello.com: hello.asm
	$(Z80ASM) -o $@ hello.asm

# Label file for verifying the address layout (BOOT should land at
# $F200 -- see bios.asm's header for the full reasoning) without
# needing a full disassembly every time. build-boot-image.py also
# reads this to find the chunk boundaries.
bios.sym: bios.asm cpm22.asm msxfont.img
	$(Z80ASM) -I . -o bios.bin -L bios.asm 2>$@

# The image to write to the SD card's partition 1 -- see
# build-boot-image.py's own header for the chunk layout and the
# drive-A-from-drive-a/ population it also does. cpm_put.py is a real
# dependency (imported, not just a sibling script); the drive-a/ wildcard
# means adding/removing/editing a file there triggers a rebuild too, not
# just changing the two .py files.
boot.img: bios.sym build-boot-image.py cpm_put.py $(wildcard ../../../drive-a/*)
	python3 build-boot-image.py

clean:
	rm -f bios.bin bios.sym stage1.bin boot.img cksum.com cpydbg.com cpyrand.com cpyren.com hello.com

.PHONY: all clean
