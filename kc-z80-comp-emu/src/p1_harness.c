/* p1_harness.c -- plan-kc-z80-comp-emu.md Phase P1 (scoped): load the real CP/M
 * image into the emulated memory array and confirm CCP/BDOS/BIOS sit
 * at the real, confirmed addresses. No CPU execution yet (that needs
 * disk/console I/O, P2+) -- this only proves the *loading* is correct.
 *
 * Deliberately scoped down from "faithfully replicate stage1.asm's
 * real 3-chunk disk-sector boot sequence" (real complexity: bios.bin
 * is not one contiguous image, see kc-z80-comp-emu/tools/extract_bios_chunks.py's
 * own header) to just: load all three chunks at their real addresses
 * via that script's output (kc-z80-comp-emu/build/{chunk1,chunk2,chunk3}.bin +
 * manifest.txt, generated from the real bios.sym/bios.bin -- run
 * `python3 tools/extract_bios_chunks.py` first if build/ is missing or
 * stale), then check known-good bytes at CBASE/FBASE/BOOT.
 *
 * Memory model here is a plain flat 64K array -- the real hardware's
 * bank-switch/A16 behavior (cpm-plan.md §2) only matters once bank=1
 * video/font access is exercised (P3+), so it's deliberately not
 * modeled yet. This harness never touches bank=1-only addresses in a
 * bank-dependent way (chunk2's font data lives at $8000-$896C, which
 * reads back the same regardless of bank in this simplified model --
 * fine for a load-and-verify check, not yet a faithful simulation of
 * the real address-translation hardware).
 *
 * Expected bytes (hand-verified against chunk3.bin directly before
 * writing this, see kc-z80-comp-emu/DEVLOG.md P1 entry):
 *   CBASE ($DC00): C3 5C DF  (JP $DF5C -- CCP's own entry jump)
 *   FBASE ($E406): C3 11 E4  (JP $E411 -- real BDOS entry)
 *   BOOT  ($F200): C3 33 F2  (JP $F233 -- BIOS jump table's first entry)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "Z80.h"

static byte ram[0x10000];

byte RdZ80(register word Addr) { return ram[Addr]; }
void WrZ80(register word Addr, register byte Value) { ram[Addr] = Value; }
byte InZ80(register word Port)  { (void)Port; return 0xFF; }
void OutZ80(register word Port, register byte Value) { (void)Port; (void)Value; }
void PatchZ80(register Z80 *R) { (void)R; }
word LoopZ80(register Z80 *R) { (void)R; return INT_QUIT; }

static int load_chunk(const char *path, unsigned addr, unsigned size)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "can't open %s\n", path); return -1; }
    size_t got = fread(&ram[addr], 1, size, f);
    fclose(f);
    if (got != size) {
        fprintf(stderr, "%s: read %zu bytes, expected %u\n", path, got, size);
        return -1;
    }
    return 0;
}

static int load_manifest(const char *manifest_path, const char *build_dir)
{
    FILE *f = fopen(manifest_path, "r");
    if (!f) {
        fprintf(stderr, "can't open %s -- run "
                "`python3 tools/extract_bios_chunks.py` first\n", manifest_path);
        return -1;
    }
    char name[64];
    unsigned addr, size;
    int ok = 0;
    while (fscanf(f, "%63s %x %u", name, &addr, &size) == 3) {
        char path[512];
        snprintf(path, sizeof(path), "%s/%s.bin", build_dir, name);
        printf("loading %-6s -> $%04x, %u bytes ... ", name, addr, size);
        if (load_chunk(path, addr, size) == 0) {
            printf("ok\n");
        } else {
            ok = -1;
        }
    }
    fclose(f);
    return ok;
}

static int check_bytes(const char *label, unsigned addr,
                       const byte *want, unsigned n)
{
    if (memcmp(&ram[addr], want, n) == 0) {
        printf("PASS: %-6s ($%04x) matches expected bytes\n", label, addr);
        return 0;
    }
    printf("FAIL: %-6s ($%04x): got", label, addr);
    for (unsigned i = 0; i < n; i++) printf(" %02X", ram[addr + i]);
    printf(", want");
    for (unsigned i = 0; i < n; i++) printf(" %02X", want[i]);
    printf("\n");
    return -1;
}

int main(void)
{
    if (load_manifest("build/manifest.txt", "build") != 0) return 1;

    int fail = 0;
    static const byte cbase_want[] = {0xC3, 0x5C, 0xDF};
    static const byte fbase_want[] = {0xC3, 0x11, 0xE4};
    static const byte boot_want[]  = {0xC3, 0x33, 0xF2};

    fail |= check_bytes("CBASE", 0xDC00, cbase_want, sizeof(cbase_want));
    fail |= check_bytes("FBASE", 0xE406, fbase_want, sizeof(fbase_want));
    fail |= check_bytes("BOOT",  0xF200, boot_want,  sizeof(boot_want));

    if (!fail) {
        printf("PASS: CCP/BDOS/BIOS all resident at their real, "
               "confirmed addresses.\n");
        return 0;
    }
    printf("FAIL: memory load does not match the real CP/M image.\n");
    return 1;
}
