/* p2_harness.c -- plan-kc-z80-comp-emu.md Phase P2: disk abstraction, CP/M boots
 * to a live CCP prompt entirely in emulation.
 *
 * Per plan-kc-z80-comp-emu.md's own architecture decision, does NOT bit-bang SPI
 * or replicate the SD-card block-cache logic in bios.asm -- instead
 * uses z80em's PatchZ80 hook (explicitly documented for exactly this:
 * "emulate BIOS calls, such as disk and tape access") to intercept at
 * the lowest-level real hardware calls and do direct host file I/O
 * against the real boot.img instead:
 *
 *   - read_raw_sector ($fa3c): HL=destination buffer, LBA in the fixed
 *     `new_lba` 4-byte little-endian word ($face) -- used both by
 *     ongoing disk reads (read_impl/write_impl's read-modify-write
 *     cache miss path) AND by parse_partition_table's boot-time MBR
 *     read (LBA 0) -- one patch covers both.
 *   - write_block ($f998): HL=source buffer (512 bytes), LBA still in
 *     `new_lba` (unchanged since write_impl set it, nothing touches it
 *     in between) -- the actual "commit to media" step, after
 *     write_impl's own read-modify-write cache logic already merged
 *     the 128-byte quarter into the 512-byte block in RAM.
 *
 * All of this confirmed by reading the real bios.asm directly (see
 * kc-z80-comp-emu/DEVLOG.md's P2 entry), not assumed from the BIOS spec alone --
 * this project's own disk driver's exact register/memory conventions
 * (new_lba's byte layout, which routine takes which buffer) matter and
 * were checked line by line.
 *
 * Console I/O (const_impl/conin_impl/conout_impl) is *also* patched at
 * entry, bypassing the real keyboard-matrix/cursor/video-RAM code
 * entirely -- deliberately temporary and minimal (a plain stdio
 * console), since the real screen/keyboard abstraction is P3/P4's job,
 * not this phase's. CONST always reports "no key ready" (headless --
 * nothing here has anything to type); CONOUT prints straight to
 * stdout.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "Z80.h"

#define BOOT_ENTRY   0xF200
#define READ_RAW_SECTOR 0xFA3C
#define WRITE_BLOCK     0xF998
#define CONST_IMPL      0xF2F7
#define CONIN_IMPL      0xF308
#define CONOUT_IMPL     0xF31E
#define NEW_LBA         0xFACE   /* 4-byte LE absolute block LBA */

static byte ram[0x10000];
static FILE *disk_img;

byte RdZ80(register word Addr) { return ram[Addr]; }
void WrZ80(register word Addr, register byte Value) { ram[Addr] = Value; }
byte InZ80(register word Port)  { (void)Port; return 0xFF; }
void OutZ80(register word Port, register byte Value) { (void)Port; (void)Value; }

/* Console output captured here too, so the harness can check for an
 * expected substring without relying on eyeballing stdout. */
static char console_buf[8192];
static size_t console_len = 0;

static void console_putc(char c)
{
    putchar(c);
    if (console_len + 1 < sizeof(console_buf)) console_buf[console_len++] = c;
}

/* Pop a return address off the emulated stack -- used to make a
 * patched routine behave like it just executed a real RET, since
 * PatchZ80 replaces the routine's body, not just one instruction. */
static void simulate_ret(Z80 *R)
{
    word ret = (word)ram[R->SP.W] | ((word)ram[(word)(R->SP.W + 1)] << 8);
    R->SP.W += 2;
    R->PC.W = ret;
}

static void set_carry(Z80 *R, int fail)
{
    if (fail) R->AF.B.l |= 0x01;
    else      R->AF.B.l &= ~0x01;
}

static uint32_t read_new_lba(void)
{
    return (uint32_t)ram[NEW_LBA] | ((uint32_t)ram[NEW_LBA + 1] << 8) |
           ((uint32_t)ram[NEW_LBA + 2] << 16) | ((uint32_t)ram[NEW_LBA + 3] << 24);
}

void PatchZ80(register Z80 *R)
{
    word patch_addr = (word)(R->PC.W - 2); /* ED FE already consumed */

    if (patch_addr == READ_RAW_SECTOR) {
        uint32_t lba = read_new_lba();
        word dest = R->HL.W;
        int fail = 1;
        if (fseek(disk_img, (long)lba * 512, SEEK_SET) == 0 &&
            fread(&ram[dest], 1, 512, disk_img) == 512) {
            fail = 0;
        }
        set_carry(R, fail);
        simulate_ret(R);
        return;
    }
    if (patch_addr == WRITE_BLOCK) {
        uint32_t lba = read_new_lba();
        word src = R->HL.W;
        int fail = 1;
        if (fseek(disk_img, (long)lba * 512, SEEK_SET) == 0 &&
            fwrite(&ram[src], 1, 512, disk_img) == 512) {
            fflush(disk_img);
            fail = 0;
        }
        R->AF.B.h = fail ? 4 : 0; /* write_impl returns status in A directly */
        simulate_ret(R);
        return;
    }
    if (patch_addr == CONST_IMPL) {
        R->AF.B.h = 0x00; /* no key ready -- headless for now, see P4 */
        simulate_ret(R);
        return;
    }
    if (patch_addr == CONIN_IMPL) {
        R->AF.B.h = 0x00; /* shouldn't be reached if CONST never says
                            * "ready", kept as a harmless fallback */
        simulate_ret(R);
        return;
    }
    if (patch_addr == CONOUT_IMPL) {
        console_putc((char)R->BC.B.l);
        simulate_ret(R);
        return;
    }

    fprintf(stderr, "PatchZ80: unexpected patch at $%04X, halting\n", patch_addr);
    exit(1);
}

/* --- P1's manifest-driven RAM loader, reused verbatim --- */
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
        if (load_chunk(path, addr, size) != 0) ok = -1;
    }
    fclose(f);
    return ok;
}

/* Overwrite a routine's first 2 bytes with ED FE ("patch" opcode). */
static void patch_at(word addr)
{
    ram[addr]     = 0xED;
    ram[addr + 1] = 0xFE;
}

word LoopZ80(register Z80 *R)
{
    static long total_cycles = 0;
    total_cycles += R->IPeriod;

    if (strstr(console_buf, "A>") || strstr(console_buf, "A:")) {
        printf("\n[reached what looks like a CCP prompt]\n");
        return INT_QUIT;
    }
    if (total_cycles > 20000000L) {
        printf("\n[cycle budget exhausted without seeing a prompt, "
               "PC=$%04X SP=$%04X]\n", R->PC.W, R->SP.W);
        return INT_QUIT;
    }
    return INT_NONE;
}

int main(void)
{
    if (load_manifest("build/manifest.txt", "build") != 0) return 1;

    disk_img = fopen("../firmware/z80-boot-rom/cpm/boot.img", "r+b");
    if (!disk_img) {
        fprintf(stderr, "can't open boot.img\n");
        return 1;
    }

    patch_at(READ_RAW_SECTOR);
    patch_at(WRITE_BLOCK);
    patch_at(CONST_IMPL);
    patch_at(CONIN_IMPL);
    patch_at(CONOUT_IMPL);

    Z80 cpu;
    cpu.IPeriod = 10000;
    ResetZ80(&cpu);
    cpu.PC.W = BOOT_ENTRY;

    RunZ80(&cpu);

    fclose(disk_img);

    console_buf[console_len < sizeof(console_buf) ? console_len : sizeof(console_buf) - 1] = 0;
    printf("\n--- captured console output (%zu bytes) ---\n%s\n---\n",
           console_len, console_buf);

    if (strstr(console_buf, "A>") || strstr(console_buf, "A:")) {
        printf("PASS: booted to what looks like a live CCP prompt.\n");
        return 0;
    }
    printf("FAIL: did not see an expected CCP prompt in console output.\n");
    return 1;
}
