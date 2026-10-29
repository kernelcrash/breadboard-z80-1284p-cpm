#!/usr/bin/env python3
"""build-boot-image.py -- Phase 12: extracts the three chunks bios.bin
actually needs loaded (see bios.asm's own header and stage1.asm's
header), assembles them into one block-aligned image, and now
(2026-09-16) also formats the REST of that same image as a real CP/M
drive-A filesystem, populated with every file in repo-root `drive-a/`
-- so a fresh card's drive A comes up with real files on it straight
out of this one script, rather than needing a separate manual
`cpm_put.py build` pass against a dd'd-off copy of the partition. Ready
to be written starting at BOOT_PARTITION_BASE (stage1.asm) -- MBR
partition 1's own start LBA (2048), NOT raw LBA 0 of the whole disk.
stage1.asm's own header explains why: chunk1 used to occupy the whole
of LBA0, colliding with a real MBR's partition-table bytes at
offset 446-511, so the boot area was moved to partition 1 instead.
In practice this means writing this file to the partition device node
(e.g. `dd if=boot.img of=/dev/sdX1 bs=512 seek=0`), not the raw disk
device -- writing it to /dev/sdX at LBA 0 puts it in the wrong place
(the MBR sector itself) and the AVR will never see it. (This docstring
itself was stale relative to that fix until 2026-09-13 -- caught only
after acting on the wrong instruction; see stage1.asm's own comment
for the actual, authoritative LBA, not this file's prose.)

Note this is independent of stage1.asm's/bios.asm's own
BOOT_PARTITION_BASE/base_lba_a now being runtime, MBR-read values
rather than compile-time constants (2026-09-16): whatever LBA the real
MBR's partition 1 actually starts at, this file's own output bytes are
the same either way -- only WHERE the resulting boot.img gets dd'd to
on a real card depends on that, which is a human decision at `dd`
time, not something this script needs to know or compute.

Reads addresses out of bios.sym (produced by `make bios.sym`) rather
than hardcoding them, so this stays correct if bios.asm's layout ever
shifts -- but the BLOCK COUNTS/LBAs written here must still match
stage1.asm's own CHUNK1_BLOCKS/CHUNK2_BLOCKS/CHUNK3_BLOCKS constants
by hand; there is no single source of truth linking the two files, so
if this script's block counts and stage1.asm's ever diverge, update
both. Run `make bios.sym stage1.bin` first.

Why these specific file-offset computations (verified empirically,
2026-09-08, not assumed): z80asm does NOT auto-fill the byte gap when
an `org` jumps forward, UNLESS an explicit `ds` follows -- confirmed by
checking that the font's own bytes land in bios.bin exactly 42 bytes
in (matching the low-memory trampoline's real 42-byte size, with zero
padding for the $7c2a-$8000 logical gap the low-memory section and the
bank=1 region's `org` statements leave between them) while the
bank=1-region-to-CPM_BASE gap, which bios.asm pads explicitly via
`ds CPM_BASE-$,0`, does consume real file bytes matching its full
logical size.

The drive-A filesystem portion reuses cpm_put.py's own Geometry/
format_image/import_dir functions directly (imported, not
reimplemented) -- that file is this project's one place that knows the
DR CP/M 2.2 directory-entry/allocation-block format, and bios.asm's
dpb0 is its single source of truth for drive A's geometry (cpm_put.py's
own header says as much); duplicating that logic here would just be a
second copy to keep in sync.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cpm_put

BLOCK = 512
CPM_DIR = Path(__file__).parent
DRIVE_A_DIR = CPM_DIR.parent.parent.parent / "drive-a"

# Must match stage1.asm's own BOOT_PARTITION_BASE/CHUNK*_BLOCKS/
# CHUNK*_LBA constants -- this file's chunk LBAs are all relative to
# this (i.e. relative to MBR partition 1's own start), NOT the raw
# disk's LBA 0.
BOOT_PARTITION_BASE = 2048

# Must match stage1.asm's own CHUNK*_BLOCKS/CHUNK*_LBA constants.
CHUNK1_BLOCKS = 1   # trampoline
CHUNK2_BLOCKS = 6   # font + blit/scroll code -- was 5 until 2026-10-12,
                    # when bios.asm's own bank1_scratch grew 16->256
                    # bytes (a real stack-starvation bug fix); see that
                    # file's own comment and stage1.asm's own
                    # CHUNK2_BLOCKS comment
CHUNK3_BLOCKS = 18  # CCP+BDOS+BIOS -- hard max (CHUNK3_DEST $DC00 +
                    # 18*512 = $10000 exactly); see stage1.asm's own
                    # comment for why this is a hard ceiling, not a
                    # soft margin choice


def read_symbols(sym_path):
    syms = {}
    pat = re.compile(r"^(\S+):\s+equ\s+\$([0-9a-fA-F]+)")
    for line in sym_path.read_text().splitlines():
        m = pat.match(line.strip())
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def main():
    sym_path = CPM_DIR / "bios.sym"
    bin_path = CPM_DIR / "bios.bin"
    out_path = CPM_DIR / "boot.img"

    syms = read_symbols(sym_path)
    needed = ["porta_shadow", "trampoline_end", "char_base", "bank1_end",
              "CPM_BASE", "end"]
    missing = [n for n in needed if n not in syms]
    if missing:
        sys.exit(f"missing symbols in {sym_path}: {missing} -- "
                  f"did `make bios.sym` run cleanly?")

    low_start = syms["porta_shadow"]       # $0008 (2026-09-10; was $7c00)
    trampoline_end = syms["trampoline_end"]
    char_base = syms["char_base"]          # $8000
    bank1_end = syms["bank1_end"]
    cpm_base = syms["CPM_BASE"]
    end = syms["end"]
    # 2026-09-10: alv1 (drive B's allocation vector) USED to sit in the
    # gap between trampoline_end and char_base and had to be skipped
    # explicitly here (its `ds` emits real bytes into bios.bin's linear
    # layout, unlike a bare `org` jump). It has since moved to the BIOS's
    # own high-memory scratch area, so there is no gap byte here any more.
    # Kept as a guarded lookup so an older bios.sym still builds; a fresh
    # one has no alv1_end symbol and this is 0.
    alv1_gap = syms.get("alv1_end", trampoline_end) - trampoline_end

    data = bin_path.read_bytes()

    # Chunk 1: the page-zero trampoline, file offset 0 onward (the first
    # `org` in bios.asm, so its first byte is bios.bin's first byte).
    # stage1.asm loads this to $7C00 and LDIRs it down to $0008 -- the
    # chunk's own bytes are the same either way; only its final resting
    # place changed.
    off1_start = 0
    off1_end = trampoline_end - low_start
    chunk1 = data[off1_start:off1_end]

    # Chunk 2: font + blit/scroll/cls/hb_toggle code -- continues right
    # after chunk 1 (alv1_gap is 0 for a current build, see above).
    off2_start = off1_end + alv1_gap
    off2_end = off2_start + (bank1_end - char_base)
    chunk2 = data[off2_start:off2_end]

    # Chunk 3: CCP+BDOS+BIOS -- starts after skipping the *real*
    # padding bytes bios.asm's own `ds CPM_BASE-$,0` inserted.
    off3_start = off2_end + (cpm_base - bank1_end)
    off3_end = off3_start + (end - cpm_base)
    chunk3 = data[off3_start:off3_end]

    print(f"chunk1 (trampoline):      {len(chunk1)} bytes "
          f"(${low_start:04x}-${trampoline_end - 1:04x})")
    print(f"chunk2 (font+blit code):  {len(chunk2)} bytes "
          f"(${char_base:04x}-${bank1_end - 1:04x})")
    print(f"chunk3 (CCP+BDOS+BIOS):   {len(chunk3)} bytes "
          f"(${cpm_base:04x}-${end - 1:04x})")

    def pad_to_blocks(chunk, nblocks, label):
        size = nblocks * BLOCK
        if len(chunk) > size:
            sys.exit(f"{label} is {len(chunk)} bytes, doesn't fit in "
                      f"{nblocks} blocks ({size} bytes) -- increase its "
                      f"block count in both this script and stage1.asm")
        return chunk + b"\x00" * (size - len(chunk))

    boot_chunks = (pad_to_blocks(chunk1, CHUNK1_BLOCKS, "chunk1")
                    + pad_to_blocks(chunk2, CHUNK2_BLOCKS, "chunk2")
                    + pad_to_blocks(chunk3, CHUNK3_BLOCKS, "chunk3"))
    boot_blocks = CHUNK1_BLOCKS + CHUNK2_BLOCKS + CHUNK3_BLOCKS

    # ---- Format the REST of this same image as a real drive-A CP/M
    # filesystem (cpm_put.py's own dpb0-derived geometry -- imported,
    # not reimplemented, see this file's header) and drop the boot
    # chunks above into the start of its reserved (OFF=5) area. The gap
    # between the chunks' real end and the reserved area's own end
    # (16640 bytes -- comfortable margin per bios.asm's dpb0 comment)
    # stays zero-filled by format_image, same as it always was; the
    # directory (at byte 16640 on) and the whole data area past it are
    # new territory build-boot-image.py didn't used to touch at all.
    geo = cpm_put.Geometry("driveA", cpm_put.GEOMETRIES["driveA"])
    if len(boot_chunks) > geo.RESERVED:
        sys.exit(f"boot chunks are {len(boot_chunks)} bytes, don't fit "
                  f"in drive A's {geo.RESERVED}-byte reserved area "
                  f"(bios.asm's dpb0 OFF field) -- shrink the chunks or "
                  f"grow OFF in both bios.asm and cpm_put.py")
    image = cpm_put.format_image(geo)
    image[0:len(boot_chunks)] = boot_chunks

    if DRIVE_A_DIR.is_dir():
        files = [n for n in sorted(DRIVE_A_DIR.iterdir()) if n.is_file() and not n.name.startswith(".")]
        if files:
            print(f"\nimporting {DRIVE_A_DIR} into drive A:")
            cpm_put.import_dir(image, geo, str(DRIVE_A_DIR))
        else:
            print(f"\n{DRIVE_A_DIR} has no files -- drive A's directory "
                  "left empty.")
    else:
        print(f"\n{DRIVE_A_DIR} doesn't exist -- drive A's directory "
              "left empty.")

    # Pad to a whole number of 512-byte physical SD blocks purely so the
    # file writes cleanly with `dd bs=512` -- geo.IMAGE_SIZE (CP/M's own
    # 128-byte-record-based accounting) isn't guaranteed to land on a
    # 512-byte boundary (it doesn't here: 256256 bytes = 500.5 blocks),
    # but CP/M itself never addresses past its own DSM-defined byte
    # range regardless, so this trailing pad is inert, never read.
    if len(image) % BLOCK:
        image += b"\x00" * (BLOCK - (len(image) % BLOCK))
    total_blocks = len(image) // BLOCK

    out_path.write_bytes(image)
    print(f"\nwrote {out_path} -- {len(image)} bytes ({total_blocks} "
          f"blocks: {boot_blocks} boot + drive-A filesystem), "
          f"partition-relative LBA 0-{total_blocks - 1} == disk LBA "
          f"{BOOT_PARTITION_BASE}-{BOOT_PARTITION_BASE + total_blocks - 1} "
          f"*if* partition 1 is still at the write_mbr.py default (2048) "
          f"-- re-check against the real card's own MBR/BOOT_PARTITION_BASE "
          f"comment now that both stage1.asm and bios.asm read the real "
          f"partition table at boot rather than trusting this number.")
    print("write it to the SD card's FIRST PARTITION (not the raw disk --")
    print("chosen specifically so it never collides with the MBR's own")
    print("bytes at raw LBA0 offset 446-511 -- see stage1.asm's header),")
    print("e.g.:")
    print(f"  dd if={out_path} of=/dev/sdX1 bs=512 seek=0 conv=notrunc,fsync")
    print("  sync")
    print("(use the real partition device node for your card, and double-")
    print(f"check it -- this overwrites that partition's first {total_blocks} "
          "sectors unconditionally, boot chunks AND drive-A filesystem")
    print("both. Writing this to /dev/sdX -- the whole disk, no trailing")
    print("partition number -- puts it at the wrong LBA entirely: raw LBA 0")
    print("is the MBR sector itself, and the AVR will never see it there.)")


if __name__ == "__main__":
    main()
