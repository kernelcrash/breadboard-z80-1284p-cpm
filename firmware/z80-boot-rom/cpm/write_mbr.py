#!/usr/bin/env python3
"""
write_mbr.py -- writes a standard MBR partition table to a local file
(never a device directly -- writing that to the real SD card is a
separate, explicit `dd` step, same philosophy as cpm_put.py). This is a
ONE-TIME, host-side artifact: the Z80 BIOS never parses it at boot --
partitioning exists purely so a human can `dd` into /dev/sdX1/sdX2 with
standard tools (fdisk/parted/gdisk all understand it) instead of hand-
computing byte offsets. bios.asm's own per-drive LBA base constants
(BASE_LBA_A/BASE_LBA_B) and stage1.asm's BOOT_PARTITION_BASE are hand-
synced against the values below -- if you ever change this layout,
those must change too.

Layout (multi-drive plan, cpm-plan.md):
    partition 1 (drive A + boot area): LBA 2048,    2048 sectors (1 MiB)
    partition 2 (drive B):             LBA 4096, 2080768 sectors (1016 MiB)

1 MiB (2048-sector) alignment matches every modern fdisk/parted/gdisk
default. Partition 2 is sized to the eventual ~1GiB drive B target
(cpm-plan.md's Tier 2, a later follow-up) even though only the first
50 MiB (Tier 1, DSM=3199 in bios.asm's dpb1 -- shrunk from an original
100 MiB on 2026-09-16 to buy back BIOS code-size margin, see bios.asm's
own dpb1 comment) is actually used by CP/M today -- so growing drive B
later only touches the DPB/ALV/MEM, never the card's partition table
again.

Usage:
    write_mbr.py <output.img>

<output.img> is a plain local file this script writes exactly 512
bytes to (or overwrites the first 512 bytes of, if it already exists
and is at least that large) -- never a device. Write it to the real
card yourself:
    sudo dd if=<output.img> of=/dev/sdX bs=512 seek=0 conv=notrunc,fsync
    sudo sync
"""
import struct
import sys

PARTITION_TYPE = 0xDA          # "Non-FS data" -- a real, recognized
                                # type ID meaning "a format this OS
                                # doesn't understand"; avoids any tool
                                # trying to auto-mount it.
CHS_SENTINEL = (0xFE, 0xFF, 0xFF)  # standard "not CHS-representable"
                                     # marker modern LBA-only tools
                                     # write; never read by anything
                                     # here (nothing on this machine
                                     # executes MBR code or does CHS).

PARTITIONS = [
    # (start_lba, size_sectors)
    (2048, 2048),        # partition 1: drive A + boot area (1 MiB)
    (4096, 2080768),      # partition 2: drive B (1016 MiB, Tier-2 sized)
]


def build_partition_entry(start_lba, size_sectors):
    boot_indicator = 0x00
    chs_start = CHS_SENTINEL
    chs_end = CHS_SENTINEL
    return struct.pack(
        '<B3sB3sII',
        boot_indicator,
        bytes(chs_start),
        PARTITION_TYPE,
        bytes(chs_end),
        start_lba,
        size_sectors,
    )


def build_mbr():
    sector = bytearray(512)
    # bytes 0-445: bootstrap code region -- never executed by anything
    # on this machine (the Z80 boots via stage1.asm being xmodem-
    # uploaded directly into the AVR's ROM-emulation RAM; the SD card
    # is only ever touched by stage1's own SD driver code afterward).
    # Left zero-filled.
    for i, (start_lba, size_sectors) in enumerate(PARTITIONS):
        entry = build_partition_entry(start_lba, size_sectors)
        off = 446 + i * 16
        sector[off:off + 16] = entry
    sector[510] = 0x55
    sector[511] = 0xAA
    return bytes(sector)


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    out_path = argv[1]
    mbr = build_mbr()

    try:
        with open(out_path, 'r+b') as f:
            f.write(mbr)
    except FileNotFoundError:
        with open(out_path, 'wb') as f:
            f.write(mbr)

    print("wrote MBR to %s:" % out_path)
    for i, (start_lba, size_sectors) in enumerate(PARTITIONS, 1):
        print("  partition %d: LBA %d, %d sectors (%.1f MiB)" %
              (i, start_lba, size_sectors, size_sectors * 512 / 1048576))
    print("\nwrite it to the real card with:")
    print("  sudo dd if=%s of=/dev/sdX bs=512 seek=0 conv=notrunc,fsync" %
          out_path)
    print("  sudo sync")
    print("\nthen (once, on a fresh card): partprobe /dev/sdX (or replug)")
    print("so the kernel creates /dev/sdX1 and /dev/sdX2.")


if __name__ == '__main__':
    main(sys.argv)
