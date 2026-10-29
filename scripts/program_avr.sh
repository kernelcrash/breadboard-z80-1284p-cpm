#!/bin/sh
# program_avr.sh — fuse + flash the 1284P over ISP.
#
# Usage:
#   ./program_avr.sh [programmer] [firmware.hex]
#     programmer  avrdude programmer id, default "usbasp"
#     firmware.hex default firmware/avr-1284p/z80mcu.hex (built by make)
#
# Fuses (verified against Atmel-42719C tables 10-14, 10-15, 28-5/6/7, 29-8):
#   LOW  0xC0  1100 0000: CKDIV8=1(off) CKOUT=1(off) SUT=00 (6CK, BOD-enabled
#              start-up) CKSEL=0000 (external clock 0-20MHz)
#   HIGH 0xD9  1101 1001: OCDEN=1(off, default) JTAGEN=1(JTAG OFF -- fuse bit
#              is active-LOW: 0=JTAG enabled/factory default, 1=disabled;
#              see datasheet p.377 Table 28-6 + p.61 MCUCR/JTD description)
#              SPIEN=0(ISP enabled) WDTON=1(default) EESAVE=1(default)
#              BOOTSZ=00(default) BOOTRST=1(default, no bootloader)
#   EXT  0x05  000 0101: BODLEVEL=101 -> 2.7V typ (Table 29-8; 111 as
#              previously used is "BOD Disabled", not 2.7V)
#
# NOTE: an earlier version of this script used LOW=0xF0/HIGH=0x91/EXT=0x0F.
# All three were wrong: 0xF0 encoded SUT=11 ("Reserved" per Table 10-15,
# not the intended 00); 0x91 left JTAGEN fuse-programmed (bit=0), which
# per the datasheet KEEPS JTAG enabled, not disables it; 0x0F encoded
# BODLEVEL=111 ("BOD Disabled"), not the intended 2.7V. Corrected
# 2026-09-01 by reading the actual datasheet tables rather than assuming
# fuse-bit polarity.
#
# Fuses are written every time (idempotent); flash is written with the
# default firmware hex (build it first: scripts/build_all.sh) or the
# path you pass as $2. Read fuses back at the end so a bad programmer
# connection is caught immediately.

set -e
PROG="${1:-usbasp}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEX="${2:-$ROOT/firmware/avr-1284p/z80mcu.hex}"
AVRDUDE="avrdude -p m1284p -c $PROG -q"

echo "== programming fuses =="
$AVRDUDE -U lfuse:w:0xC0:m -U hfuse:w:0xD9:m -U efuse:w:0x05:m

if [ -n "$HEX" ]; then
    echo "== programming flash: $HEX =="
    $AVRDUDE -U flash:w:"$HEX":i
fi

echo "== reading back fuses (expect LF 0xC0 HF 0xD9 EF 0x05) =="
#$AVRDUDE -U lfuse:r -U hfuse:r -U efuse:r
$AVRDUDE -U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h
