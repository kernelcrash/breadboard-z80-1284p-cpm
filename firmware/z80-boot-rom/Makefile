# z80-boot-rom build (z80asm)
Z80ASM = z80asm

all: test-progs/nop_loop.bin test-progs/fill_pattern.bin test-progs/blink.bin test-progs/memtest-plus-blink.bin test-progs/video-test1.bin test-progs/video-test2.bin test-progs/video-test3.bin test-progs/video-nmi-vsync-benchmark.bin test-progs/bank-switch-test.bin test-progs/plh.bin test-progs/keyboard-scan-test.bin test-progs/plh2.bin test-progs/bank-switch-test2.bin test-progs/video-test4.bin test-progs/sdcard-test.bin test-progs/sdcard-test2.bin test-progs/spi-loopback-test.bin test-progs/portc-probe-test.bin test-progs/porta-write-portc-read-test.bin test-progs/console-io-test.bin test-progs/cbios-disk-test.bin

test-progs/%.bin: test-progs/%.asm
	$(Z80ASM) -o $@ $<

clean:
	rm -f test-progs/*.bin

.PHONY: all clean
