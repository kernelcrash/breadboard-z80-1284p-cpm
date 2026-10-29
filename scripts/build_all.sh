#!/bin/sh
# build_all.sh — build all firmware + ROM test programs.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# stage1.bin first: the AVR firmware embeds a copy of it (bin2c.py ->
# src/stage1_rom.h). The AVR Makefile also recurses to build it, but
# doing it up front keeps the dependency visible here.
make -C "$ROOT/firmware/z80-boot-rom/cpm" stage1.bin
make -C "$ROOT/firmware/avr-1284p"
make -C "$ROOT/firmware/z80-boot-rom"

echo
echo "Build outputs:"
ls -la "$ROOT/firmware/avr-1284p/z80mcu.hex" \
       "$ROOT/firmware/z80-boot-rom/test-progs/"*.bin
