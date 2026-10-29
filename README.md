# Z80 + ATmega1284P CP/M breadboard computer

A low-chip-count Z80 computer built on a few breadboards, running CP/M 2.2.

- Z80 at 8 MHz from a 16 MHz master clock (the same clock is the pixel clock).
- 128 KB SRAM (96 KB used), simple bank switching, no ROM or EEPROM.
- An ATmega1284P emulates the boot ROM at power-on, then generates 640x200
  2-colour PAL composite video by stealing bus cycles (`_BUSRQ`) from the Z80.
- 8255 PPI for an MSX keyboard matrix, a bit-banged SD card and system control bits.
- CP/M 2.2 BIOS with VT52 (Zenith) terminal emulation. SD card holds drive A:
  (a small floppy-sized partition) and drive B: (a 50 MB "hard disk").

See `docs/` for the design: `wiring.md`, `pin-map.md`,
`memory-map.md`, and `bring-up-log.md`.

## Prerequisites

`avr-gcc`/`avr-libc`, `avrdude`, `z80asm`, `python3`, `make`.
(`sdcc` is only needed for the `breakout` sample.)

## Build the firmware

```sh
scripts/build_all.sh
```

This assembles the Z80 bootstrap (`stage1.bin`), embeds it in the AVR
firmware and produces `firmware/avr-1284p/z80mcu.hex`.

## Flash the ATmega1284P

Wire an ISP programmer (e.g. USBasp) to the 1284P, power it, then:

```sh
scripts/program_avr.sh [programmer] [hexfile]   # default: usbasp
```

This sets the fuses (external clock, JTAG off) and writes the flash.

## Build the SD card images

Partition the SD card with two primary partitions (type doesn't matter).
They are raw CP/M images, not FAT.

**Drive A: + boot area** (partition 1): everything in `drive-a/` is put on the drive (it ships with `HELLO.COM`, a hello-world test). Then

```sh
make -C firmware/z80-boot-rom/cpm
sudo dd if=firmware/z80-boot-rom/cpm/boot.img of=/dev/sdX1 bs=512 conv=notrunc,fsync
```

The `make` also builds the small CP/M utilities (`cksum.com` etc.) that you
can copy into `drive-a/` or `drive-b/`.

**Drive B:** (partition 2): everything in `drive-b/` is put on the drive (it ships with `BREAKOUT.COM`, a simple game; at least one file is required). Then

```sh
python3 firmware/z80-boot-rom/cpm/cpm_put.py --geometry driveB driveB.img build drive-b/
sudo dd if=driveB.img of=/dev/sdX2 bs=512 conv=notrunc,fsync
```

Use the partition device nodes (`sdX1`/`sdX2`), not the whole disk. Add your
own CP/M software to those folders as you like; only `*.COM` files there are
tracked by git, so don't commit copyrighted software.

`HELLO.COM` is built from `firmware/z80-boot-rom/cpm/hello.asm` (`make`);
`BREAKOUT.COM` from `firmware/z80-boot-rom/cpm/breakout/` (needs `sdcc`). Both
are checked in so the images build without them. On the board, run `HELLO`
from `A:` and `B:` then `BREAKOUT`.

## Run

Plug a composite monitor into the video out, then power-cycle the board
(unplug the USBasp first). With the boot-mode strap on RXD pulled low and no
serial adapter attached, the 1284P loads the flash-resident bootstrap and
starts the Z80, which boots CP/M from the SD card. With a serial adapter
attached it enters the monitor instead (xmodem upload of a ROM image).

The serial console is **115200 baud, 8N1, no flow control** (adapter TX to
the 1284P's `PD0`/pin 14, adapter RX to `PD1`/pin 15, common GND). Open the
terminal before resetting the board: the banner is only printed once. In
autoboot mode, pressing a key drops you into the monitor.

## Layout

| Path | Contents |
|---|---|
| `firmware/avr-1284p/` | AVR firmware: ROM emulation, video, monitor |
| `firmware/z80-boot-rom/cpm/` | CP/M BIOS, bootstrap, image tools, `breakout/` sample |
| `firmware/z80-boot-rom/test-progs/` | Z80 bring-up test programs |
| `kc-z80-comp-emu/` | host-side emulator that boots the real CP/M image (see its README) |
| `hardware/` | netlist, BOM, KiCad helper scripts |
| `scripts/` | `build_all.sh`, `program_avr.sh` |
| `docs/` | design and bring-up documentation |

## Credits

CP/M 2.2 sources and BIOS structure draw on
[Z80-Retro/2063-Z80-cpm](https://github.com/Z80-Retro/2063-Z80-cpm) and
[Z80-Retro/cpm-2.2](https://github.com/Z80-Retro/cpm-2.2). Most of this
project was developed with Claude Code.
