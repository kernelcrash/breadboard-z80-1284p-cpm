#!/usr/bin/env python3
"""
cpm_put.py -- inject file(s) into a CP/M 2.2 disk image as properly
formatted directory entries + data blocks, without going through CP/M's
own BDOS at all. Originally built to get Zork 1 onto drive A (no in-CP/M
transfer tool exists); extended for the multi-drive plan (cpm-plan.md)
to also target drive B (a large, hard-disk-style volume) and to bulk-
import a whole directory of files in one pass.

Each drive's geometry is a profile in GEOMETRIES below, matching
bios.asm's dpb0/dpb1 exactly (re-derive there first if these ever need
to change -- don't edit one without the other). The DR CP/M 2.2 rule
this script implements mechanically (not invented): DSM<=255 uses
1-byte block-allocation pointers (16 per 32-byte directory entry);
DSM>255 uses 2-byte pointers (8 per entry) -- which in turn halves how
many *blocks* one directory entry ("extent") covers, so a directory
entry's real data capacity is (EXM+1)*128 records regardless of drive
(128 records/entry when EXM=0, matching AL_SLOTS=16 blocks * 8
records/block; scales the same way for any EXM/AL_SLOTS combination).

    driveA (bios.asm's dpb0): SPT=26  BSH=3 (1024-byte blocks)  BLM=7
        EXM=0  DSM=233 (234 blocks)  DRM=63 (64 dir entries)
        AL0=$C0 AL1=$00  CKS=16  OFF=5 (reserved boot area)
    driveB (bios.asm's dpb1): SPT=128  BSH=7 (16384-byte blocks)
        BLM=127  EXM=7  DSM=3199 (3200 blocks, 50 MiB -- shrunk from
        the original 100 MiB Tier 1 on 2026-09-16 to buy back BIOS
        code-size margin, see bios.asm's own dpb1 comment; see
        cpm-plan.md for the ~1GiB Tier-2 follow-up)  DRM=1023
        (1024 dir entries)  AL0=$C0 AL1=$00  CKS=0 (fixed disk, no
        CSV)  OFF=0 (boot image lives entirely in drive A's own
        reserved area)

Usage:
    cpm_put.py [--geometry driveA|driveB] [--image-offset BYTES] \\
        <disk_image> put <host_file> <cpm_name> [--user N]
    cpm_put.py --geometry driveB [--image-offset BYTES] \\
        <disk_image> import-dir <folder> [--user N] \\
        [--on-collision skip|abort]
    cpm_put.py --geometry driveB \\
        <disk_image> build <folder> [--user N]

    (legacy form, still works exactly as before, defaults to
    --geometry driveA --image-offset 0:)
    cpm_put.py <disk_image> <host_file> <cpm_name> [--user N]

`build` creates <disk_image> FRESH (formats an empty directory, zeros
the data area -- overwriting anything already at that path) and then
imports every file in <folder> into it in one step -- the "build a
whole drive from a folder of files" workflow. Unlike `import-dir`, it
never reads an existing image first, so there's no collision handling
to configure: every name in the folder is necessarily new. Use
`import-dir` instead for incrementally adding files to an image that
already has content you want to keep.

`build` is meant for drive B (OFF=0 -- the whole image is real
filesystem, nothing else belongs there). For drive A, `build`'s fresh
image has its reserved boot area (OFF=5, the first 16640 bytes) left
zeroed rather than containing stage1/font/BIOS -- that content comes
from a completely separate pipeline (`make boot.img`) and does not
belong in this tool. Don't dd a drive-A `build` output over a card
that already has `boot.img` written -- it would zero that area out.

<disk_image> must already be a snapshot of the real card's own bytes
for that drive's own partition (dd it off the card first -- see the
partition layout in write_mbr.py) -- this script edits an image file,
it never touches a device directly, on purpose: writing the result
back to the card is a separate, deliberate step. --image-offset exists
only for the secondary case of operating on a whole-card raw dump
instead of a per-partition slice; the per-partition-slice workflow
(image file == exactly that drive's own bytes, offset 0) is the
primary, documented path.
"""
import os
import sys

GEOMETRIES = {
    'driveA': dict(SPT=26, BSH=3, BLM=7, EXM=0, DSM=233, DRM=63,
                   AL0=0xC0, AL1=0x00, CKS=16, OFF=5),
    'driveB': dict(SPT=128, BSH=7, BLM=127, EXM=7, DSM=3199, DRM=1023,
                   AL0=0xC0, AL1=0x00, CKS=0, OFF=0),
}


class Geometry:
    def __init__(self, name, profile, image_offset=0):
        self.name = name
        self.SPT = profile['SPT']
        self.BSH = profile['BSH']
        self.EXM = profile['EXM']
        self.DSM = profile['DSM']
        self.DRM = profile['DRM']
        self.OFF = profile['OFF']
        self.image_offset = image_offset

        self.BLOCK = 128 << self.BSH
        self.AL_PTR_BYTES = 1 if self.DSM <= 255 else 2
        self.AL_SLOTS = 16 // self.AL_PTR_BYTES   # 16 or 8
        self.RECORDS_PER_BLOCK = self.BLOCK // 128
        # One directory entry ("extent") covers (EXM+1)*128 records --
        # the DR CP/M 2.2 rule, mechanical for any EXM/AL_SLOTS
        # combination (self-checked against driveA: EXM=0 -> 128
        # records/entry, matching AL_SLOTS=16 * 8 records/block exactly).
        self.RECORDS_PER_EXTENT = (self.EXM + 1) * 128
        self.BLOCKS_PER_EXTENT = self.AL_SLOTS
        self.DIR_BYTES = (self.DRM + 1) * 32
        self.RESERVED = self.OFF * self.SPT * 128
        self.IMAGE_SIZE = self.RESERVED + (self.DSM + 1) * self.BLOCK
        self.DIR_OFFSET = self.RESERVED
        self.FIRST_DATA_BLOCK = 2   # blocks 0,1 are the directory (AL0=$C0)

    def block_offset(self, n):
        return self.image_offset + self.RESERVED + n * self.BLOCK

    def dir_entry_offset(self, slot):
        return self.image_offset + self.DIR_OFFSET + slot * 32


def parse_entries(img, geo):
    entries = []
    for i in range(geo.DRM + 1):
        off = geo.dir_entry_offset(i)
        entries.append(bytearray(img[off:off + 32]))
    return entries


def entry_al_blocks(e, geo):
    """Decode an entry's allocation-block list, honoring AL_PTR_BYTES."""
    blocks = []
    for j in range(geo.AL_SLOTS):
        if geo.AL_PTR_BYTES == 1:
            v = e[16 + j]
        else:
            v = e[16 + j * 2] | (e[16 + j * 2 + 1] << 8)
        if v != 0:
            blocks.append(v)
    return blocks


def used_blocks(entries, geo):
    used = set()
    for e in entries:
        if e[0] == 0xE5:
            continue
        used.update(entry_al_blocks(e, geo))
    return used


def free_blocks(entries, geo, count):
    used = used_blocks(entries, geo)
    out = []
    for b in range(geo.FIRST_DATA_BLOCK, geo.DSM + 1):
        if b not in used:
            out.append(b)
            if len(out) == count:
                return out
    raise SystemExit(
        "cpm_put.py: not enough free blocks on drive %s "
        "(%d needed, %d free)" %
        (geo.name, count, geo.DSM + 1 - geo.FIRST_DATA_BLOCK - len(used)))


def free_dir_slots(entries, count):
    out = [i for i, e in enumerate(entries) if e[0] == 0xE5]
    if len(out) < count:
        raise SystemExit(
            "cpm_put.py: not enough free directory entries "
            "(%d needed, %d free)" % (count, len(out)))
    return out[:count]


def cpm_name(name):
    if '.' in name:
        raw_base, raw_ext = name.split('.', 1)
    else:
        raw_base, raw_ext = name, ''
    # Length check BEFORE truncating -- found a real pre-existing bug
    # here: the old code did base.ljust(8)[:8] first, so a too-long
    # name got silently truncated instead of ever failing the len()>8
    # check below it (the slice already made it exactly 8). That's a
    # real risk for import-dir specifically: two different long names
    # truncating to the same 8.3 name would silently collide/overwrite
    # in a batch with no warning at all.
    if len(raw_base.strip()) == 0 or len(raw_base) > 8 or len(raw_ext) > 3:
        raise SystemExit("cpm_put.py: bad 8.3 name %r" % name)
    base = raw_base.upper().ljust(8)
    ext = raw_ext.upper().ljust(3)
    return base, ext


def name_exists(entries, base, ext, user):
    for e in entries:
        if e[0] == user and bytes(e[1:9]).decode('ascii') == base \
                and bytes(e[9:12]).decode('ascii', 'replace')[:3].upper() == ext:
            return True
    return False


def put_file(img, geo, data, name, user=0):
    entries = parse_entries(img, geo)
    base, ext = cpm_name(name)

    # Refuse to silently duplicate/overwrite -- caller must ERA first.
    if name_exists(entries, base, ext, user):
        raise SystemExit(
            "cpm_put.py: %s.%s already has a directory entry (user %d) "
            "on drive %s -- ERA it in CP/M first, or pick a different "
            "name" % (base.strip(), ext.strip(), user, geo.name))

    total_records = (len(data) + 127) // 128
    if total_records == 0:
        raise SystemExit("cpm_put.py: refusing to write an empty file")
    extents_needed = (total_records + geo.RECORDS_PER_EXTENT - 1) \
        // geo.RECORDS_PER_EXTENT
    total_blocks = (len(data) + geo.BLOCK - 1) // geo.BLOCK

    blocks = free_blocks(entries, geo, total_blocks)
    slots = free_dir_slots(entries, extents_needed)

    padded = data + b'\x00' * (total_blocks * geo.BLOCK - len(data))

    # EX/RC semantics, verified directly against cpm22.asm's own
    # OPENIT1/OPENIT2 (not assumed): EX is a LOGICAL 16K-extent number,
    # never a physical-directory-entry index -- when EXM>0 lets one
    # physical entry span (EXM+1) logical extents, BDOS's own open
    # logic treats any logical extent LOWER than the entry's stored EX
    # as implicitly full (RC=128, hardcoded in OPENIT1, never read from
    # the entry) and uses the stored RC only for the logical extent
    # that EXACTLY equals the entry's own EX. So a physical entry's EX
    # must be set to the HIGHEST logical extent it covers, and its RC
    # must be that top logical extent's own record count -- not the
    # physical entry's total record count capped at 128. On drive A
    # (EXM=0) one physical entry covers exactly one logical extent and
    # this reduces to the previous, already-working formula exactly
    # (self-checked below), so this is a genuine drive-B fix, not a
    # drive-A behavior change.
    block_i = 0
    rec_i = 0
    for entry_i, slot in enumerate(slots):
        records_here = min(geo.RECORDS_PER_EXTENT, total_records - rec_i)
        blocks_here = (records_here + geo.RECORDS_PER_BLOCK - 1) \
            // geo.RECORDS_PER_BLOCK

        top_sub_extent = (records_here - 1) // 128   # 0-based, within
                                                        # this physical
                                                        # entry
        top_logical_extent = entry_i * (geo.EXM + 1) + top_sub_extent
        rc = ((records_here - 1) % 128) + 1

        e = bytearray(32)
        e[0] = user
        e[1:9] = base.encode('ascii')
        e[9:12] = ext.encode('ascii')
        e[12] = top_logical_extent & 0x1F   # EX
        e[13] = 0                           # S1, reserved
        e[14] = top_logical_extent >> 5     # S2
        e[15] = rc
        for j in range(geo.AL_SLOTS):
            if j < blocks_here:
                v = blocks[block_i]
                block_i += 1
            else:
                v = 0
            if geo.AL_PTR_BYTES == 1:
                e[16 + j] = v
            else:
                e[16 + j * 2] = v & 0xFF
                e[16 + j * 2 + 1] = (v >> 8) & 0xFF

        off = geo.dir_entry_offset(slot)
        img[off:off + 32] = e

        rec_i += records_here

    for i, b in enumerate(blocks):
        src = padded[i * geo.BLOCK:(i + 1) * geo.BLOCK]
        off = geo.block_offset(b)
        img[off:off + geo.BLOCK] = src

    return {
        'name': '%s.%s' % (base.strip(), ext.strip()),
        'bytes': len(data),
        'records': total_records,
        'blocks': blocks,
        'dir_slots': slots,
    }


def import_dir(img, geo, folder, user=0, on_collision='abort'):
    entries_snapshot = parse_entries(img, geo)
    names = sorted(n for n in os.listdir(folder) if not n.startswith("."))
    files = [n for n in names
             if os.path.isfile(os.path.join(folder, n))]
    if not files:
        raise SystemExit("cpm_put.py: %s has no files to import" % folder)

    # Validate every name up front (illegal 8.3 -> hard error, whole
    # batch aborts) before writing anything -- no partial imports from
    # a name that turns out to be invalid partway through.
    planned = []
    for fname in files:
        base, ext = cpm_name(fname)   # raises SystemExit on a bad name
        if name_exists(entries_snapshot, base, ext, user):
            if on_collision == 'skip':
                print("skipping %s (already present on drive %s)" %
                      (fname, geo.name))
                continue
            raise SystemExit(
                "cpm_put.py: %s.%s already has a directory entry (user "
                "%d) on drive %s -- pass --on-collision skip to import "
                "the rest anyway, or ERA it in CP/M first" %
                (base.strip(), ext.strip(), user, geo.name))
        planned.append(fname)

    results = []
    for fname in planned:
        with open(os.path.join(folder, fname), 'rb') as f:
            data = f.read()
        info = put_file(img, geo, data, fname, user)
        results.append(info)
        print("  %-12s %6d bytes, %d records, blocks %s, dir slot(s) %s" %
              (info['name'], info['bytes'], info['records'],
               info['blocks'], info['dir_slots']))
    return results


def format_image(geo):
    """A fresh image: directory formatted to $E5 (all entries empty),
    data area zero-filled, reserved area (if any -- drive A only)
    left zero. Same shape `dirinit.img` + a zeroed data area gave
    drive A by hand, generalized to any geometry."""
    img = bytearray(geo.image_offset + geo.IMAGE_SIZE)
    dir_off = geo.image_offset + geo.DIR_OFFSET
    img[dir_off:dir_off + geo.DIR_BYTES] = b'\xE5' * geo.DIR_BYTES
    return img


def make_geometry(argv):
    geometry_name = 'driveA'
    image_offset = 0
    if '--geometry' in argv:
        i = argv.index('--geometry')
        geometry_name = argv.pop(i + 1)
        argv.pop(i)
    if '--image-offset' in argv:
        i = argv.index('--image-offset')
        image_offset = int(argv.pop(i + 1))
        argv.pop(i)
    if geometry_name not in GEOMETRIES:
        sys.exit("cpm_put.py: unknown --geometry %r (choices: %s)" %
                  (geometry_name, ', '.join(GEOMETRIES)))
    return Geometry(geometry_name, GEOMETRIES[geometry_name], image_offset)


def load_image(image_path, geo):
    with open(image_path, 'rb') as f:
        img = bytearray(f.read())
    needed = geo.image_offset + geo.IMAGE_SIZE
    if len(img) < needed:
        sys.exit("cpm_put.py: %s is %d bytes, need at least %d for "
                  "--geometry %s at offset %d" %
                  (image_path, len(img), needed, geo.name,
                   geo.image_offset))
    return img


def main(argv):
    argv = list(argv[1:])
    if len(argv) < 3:
        sys.exit(__doc__)

    geo = make_geometry(argv)

    user = 0
    if '--user' in argv:
        i = argv.index('--user')
        user = int(argv.pop(i + 1))
        argv.pop(i)

    on_collision = 'abort'
    if '--on-collision' in argv:
        i = argv.index('--on-collision')
        on_collision = argv.pop(i + 1)
        argv.pop(i)
        if on_collision not in ('skip', 'abort'):
            sys.exit("cpm_put.py: --on-collision must be skip or abort")

    # Explicit subcommand form: <image> {put|import-dir|build} ...
    # Legacy form: <image> <host_file> <cpm_name> -- subcommand is
    # implicitly "put", detected by argv[1] not being a known verb.
    image_path = argv[0]
    if len(argv) >= 2 and argv[1] in ('put', 'import-dir', 'build'):
        verb = argv[1]
        rest = argv[2:]
    else:
        verb = 'put'
        rest = argv[1:]

    if verb == 'build':
        if len(rest) < 1:
            sys.exit(__doc__)
        folder = rest[0]
        img = format_image(geo)
        print("building a fresh %s image (%d bytes) from %s:" %
              (geo.name, len(img), folder))
        import_dir(img, geo, folder, user, on_collision='abort')
    else:
        img = load_image(image_path, geo)
        if verb == 'put':
            if len(rest) < 2:
                sys.exit(__doc__)
            host_path, cpm_path = rest[0], rest[1]
            with open(host_path, 'rb') as f:
                data = f.read()
            info = put_file(img, geo, data, cpm_path, user)
            print("wrote %s: %d bytes, %d records, blocks %s, dir slot(s) %s" %
                  (info['name'], info['bytes'], info['records'],
                   info['blocks'], info['dir_slots']))
        elif verb == 'import-dir':
            if len(rest) < 1:
                sys.exit(__doc__)
            folder = rest[0]
            print("importing %s into drive %s:" % (folder, geo.name))
            import_dir(img, geo, folder, user, on_collision)
        else:
            sys.exit(__doc__)

    with open(image_path, 'wb') as f:
        f.write(img)

    print("image updated in place: %s -- write it back to the card with:" %
          image_path)
    print("  sudo dd if=%s of=/dev/sdXN bs=512 seek=0 conv=notrunc,fsync"
          % image_path)
    print("  sudo sync")


if __name__ == '__main__':
    main(sys.argv)
