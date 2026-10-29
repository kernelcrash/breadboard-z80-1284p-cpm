#!/usr/bin/env python3
"""extract_bios_chunks.py -- pulls the three chunks bios.bin actually
contains (trampoline, font+blit code, CCP+BDOS+BIOS) out as flat,
individually-addressed binary files the emulator can load directly.

This deliberately mirrors firmware/z80-boot-rom/cpm/build-boot-image.py's
own chunk-offset computation (read_symbols() + the off1/off2/off3
arithmetic) rather than re-deriving it independently -- that script is
the authoritative, bench-proven source for how bios.bin's linear layout
maps to the three chunks' real addresses (see its own header for the
full "why" -- verified there against real hardware, not re-verified
here). Keep this in sync with that script if bios.asm's chunk layout
ever changes; it does not import it directly since build-boot-image.py
is written as a script, not a module, and duplicating ~30 lines of
simple arithmetic is less risk than reaching into another subsystem's
internals.

Usage: python3 extract_bios_chunks.py
Reads from firmware/z80-boot-rom/cpm/{bios.sym,bios.bin} (run `make
bios.sym` there first if either is stale). Writes chunk1.bin/
chunk2.bin/chunk3.bin to kc-z80-comp-emu/build/, plus a manifest.txt recording each
chunk's real load address and size, so the C loader never needs to
hardcode these numbers itself.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CPM_DIR = REPO_ROOT / "firmware" / "z80-boot-rom" / "cpm"
OUT_DIR = Path(__file__).resolve().parent.parent / "build"


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

    if not sym_path.exists() or not bin_path.exists():
        sys.exit(f"missing {sym_path} or {bin_path} -- "
                  f"run `make bios.sym` in {CPM_DIR} first")

    syms = read_symbols(sym_path)
    needed = ["porta_shadow", "trampoline_end", "char_base", "bank1_end",
              "CPM_BASE", "end"]
    missing = [n for n in needed if n not in syms]
    if missing:
        sys.exit(f"missing symbols in {sym_path}: {missing}")

    low_start = syms["porta_shadow"]
    trampoline_end = syms["trampoline_end"]
    char_base = syms["char_base"]
    bank1_end = syms["bank1_end"]
    cpm_base = syms["CPM_BASE"]
    end = syms["end"]
    # Same guarded lookup as build-boot-image.py -- see its comment.
    alv1_gap = syms.get("alv1_end", trampoline_end) - trampoline_end

    data = bin_path.read_bytes()

    off1_start = 0
    off1_end = trampoline_end - low_start
    chunk1 = data[off1_start:off1_end]

    off2_start = off1_end + alv1_gap
    off2_end = off2_start + (bank1_end - char_base)
    chunk2 = data[off2_start:off2_end]

    off3_start = off2_end + (cpm_base - bank1_end)
    off3_end = off3_start + (end - cpm_base)
    chunk3 = data[off3_start:off3_end]

    if off3_end != len(data):
        print(f"WARNING: computed chunk3 end ({off3_end}) doesn't match "
              f"bios.bin's real size ({len(data)}) -- the chunk math may "
              f"be out of sync with a changed bios.asm layout. Proceeding "
              f"anyway, but treat this as a sign to re-check against "
              f"build-boot-image.py.", file=sys.stderr)

    OUT_DIR.mkdir(exist_ok=True)
    chunks = [
        ("chunk1", low_start, chunk1, "page-zero trampoline"),
        ("chunk2", char_base, chunk2, "font + blit/scroll code"),
        ("chunk3", cpm_base, chunk3, "CCP+BDOS+BIOS"),
    ]
    manifest_lines = []
    for name, addr, data_bytes, desc in chunks:
        out_path = OUT_DIR / f"{name}.bin"
        out_path.write_bytes(data_bytes)
        print(f"{name} ({desc}): {len(data_bytes)} bytes -> "
              f"${addr:04x}-${addr + len(data_bytes) - 1:04x} "
              f"(wrote {out_path})")
        manifest_lines.append(f"{name} {addr:#06x} {len(data_bytes)}")

    (OUT_DIR / "manifest.txt").write_text("\n".join(manifest_lines) + "\n")
    print(f"wrote {OUT_DIR / 'manifest.txt'}")


if __name__ == "__main__":
    main()
