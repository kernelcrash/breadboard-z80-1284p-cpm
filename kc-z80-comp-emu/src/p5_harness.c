/* p5_harness.c -- plan-kc-z80-comp-emu.md Phase P5: the acceptance test. Boots the
 * real CP/M image (same as P4) against a disk image with the already-
 * real-hardware-proven `breakout.com` added to drive A, then runs it,
 * to check whether this emulator is trustworthy enough to build new
 * code against rather than a plausible-looking toy.
 *
 * Points at `build/boot_p5.img`, a copy of the real `boot.img` with
 * BREAKOUT.COM injected via `cpm_put.py` (default driveA geometry,
 * image-offset 0 -- both correct for boot.img unchanged, confirmed by
 * running it and getting a clean "wrote BREAKOUT.COM ... dir slot(s)
 * [1]" with no complaint) -- deliberately a copy, never the real
 * boot.img, so nothing here can affect the actual disk image real
 * hardware boots from.
 *
 * Known, real limitation going in, not discovered by surprise:
 * breakout's own `input.s` bypasses BDOS/CONST/CONIN entirely and
 * polls the 8255 keyboard-matrix ports directly (`OUT ($AA)` row-
 * select, `IN ($A9)` column-read) -- this emulator's `InZ80` stub
 * (unconditional `0xFF`) was never meant to emulate matrix hardware,
 * but happens to read as "no key in any row" under breakout's own
 * active-low convention, i.e. a plausible, if unintentional, "nothing
 * pressed right now" default -- good enough to check that the game
 * loads, initializes, and draws correctly, not to play it. Real
 * keyboard-matrix modeling (row-select-aware `OutZ80`/`InZ80`) would be
 * genuinely new work, out of scope for this acceptance check.
 *
 * Everything else below is unchanged from p4_harness.c -- same bank-
 * switch-corrected memory model, same disk/keyboard patch points
 * (poll_key is irrelevant to breakout itself, but CCP still needs it
 * to load the program in the first place). This is possible without
 * modeling the real hardware's bank=1/A16 gate any further than P4
 * already does (cpm-plan.md sec.2) -- real BIOS/CCP/breakout code that
 * flips bank before touching video RAM works unmodified against the
 * same `physram`/`xlate()` model.
 *
 * Keyboard patch point: `poll_key` ($f400), not const_impl/conin_impl
 * themselves -- poll_key is bios.asm's own boundary between "hardware
 * keyboard-matrix scan" (get_key_event/find_key, real 8255-port-
 * touching code, NOT replicated here) and the higher-level pending_char
 * bookkeeping (still real, unmodified: const_impl/conin_impl/
 * show_cursor/hide_cursor all run as actual BIOS code). Matches
 * poll_key's own contract exactly (`CALL get_key_event / RET NC / LD
 * (pending_char),A / RET`): if a synthetic keystroke is queued, write
 * it to `pending_char` directly and return; otherwise return without
 * touching it, precisely mirroring what a real "no key" scan does.
 *
 * Default (no arguments) is a plain interactive session: a real SDL
 * window, real keyboard input, no auto-quit -- runs until you close the
 * window. Pass --self-test to instead run the scripted "type BREAKOUT,
 * screenshot, auto-quit after ~2.5s" verification this file was
 * originally built around (used to check this harness itself, e.g. in
 * an environment with no human present to type) -- both paths queue
 * characters through the exact same queue_char(), so the scripted path
 * genuinely exercises the same code a real keypress would, it's not a
 * separate shortcut.
 *
 * Options: --line-double (doubled window height, see that flag's own
 * comment further down), --self-test (above).
 *
 * Real bank-switch modeling (added after this file's first version,
 * bench-found: half the screen showed CCP/BDOS/BIOS's own machine code
 * rendered as pixel noise). $8000-$FFFF is genuinely two different
 * physical pages on real hardware, selected by bit 1 of port $A8
 * (cpm-plan.md sec.2): bank=0 -> CCP/BDOS/BIOS code (chunk3, $DC00
 * onward); bank=1 -> font+blit code (chunk2, $8000 onward) *and* video
 * RAM ($C000-$FFDF) in the same 32K page. This emulator's earlier flat
 * 64K model conflated both pages into one, so chunk3's code physically
 * overlapped the video-RAM address range the renderer reads -- CCP/
 * BDOS/BIOS's own opcodes were being displayed as pixels. Fixed with a
 * 128K backing store (`physram`) and a real translation matching the
 * hardware's own truth table exactly: `addr<0x8000` or `bank==0` ->
 * `physram[addr]`; `bank==1` -> `physram[addr+0x10000]` (0x18000-0x8000
 * happens to equal exactly 0x10000, so bank=1's upper half is simply
 * "the same address plus a fixed offset", not a separate case per
 * region). `OutZ80` tracks `bank` from real writes to port $A8.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <SDL2/SDL.h>
#include "Z80.h"

#define BOOT_ENTRY      0xF200
#define READ_RAW_SECTOR 0xFA3C
#define WRITE_BLOCK     0xF998
#define POLL_KEY        0xF400
#define PENDING_CHAR    0xF4C4
#define NEW_LBA         0xFAD2

#define VRAM_BASE     0xC000
#define SCREEN_W      640
#define SCREEN_H      200
#define WINDOW_SCALE  2
#define FRAME_MS      33

#define PORT_A_BANK_BIT  0x02   /* bank = bit 1 of 8255 Port A, $A8 */

static byte physram[0x20000];   /* 128K: two full 32K views of $8000-$FFFF,
                                  * see this file's header for the formula */
static int bank = 0;
static FILE *disk_img;

static inline byte *xlate(word addr)
{
    if (addr < 0x8000 || !bank) return &physram[addr];
    return &physram[addr + 0x10000];
}

byte RdZ80(register word Addr) { return *xlate(Addr); }
void WrZ80(register word Addr, register byte Value) { *xlate(Addr) = Value; }
byte InZ80(register word Port)  { (void)Port; return 0xFF; }
void OutZ80(register word Port, register byte Value)
{
    if ((Port & 0xFF) == 0xA8) bank = (Value & PORT_A_BANK_BIT) ? 1 : 0;
}

/* --- keystroke queue, fed by real SDL events or the scripted test --- */
static char key_queue[256];
static size_t key_head = 0, key_tail = 0;

static void queue_char(char c)
{
    size_t next = (key_tail + 1) % sizeof(key_queue);
    if (next != key_head) { key_queue[key_tail] = c; key_tail = next; }
}

static int dequeue_char(char *out)
{
    if (key_head == key_tail) return 0;
    *out = key_queue[key_head];
    key_head = (key_head + 1) % sizeof(key_queue);
    return 1;
}

static void simulate_ret(Z80 *R)
{
    word ret = (word)(*xlate(R->SP.W)) | ((word)(*xlate((word)(R->SP.W + 1))) << 8);
    R->SP.W += 2;
    R->PC.W = ret;
}

static uint32_t read_new_lba(void)
{
    return (uint32_t)(*xlate(NEW_LBA)) | ((uint32_t)(*xlate(NEW_LBA + 1)) << 8) |
           ((uint32_t)(*xlate(NEW_LBA + 2)) << 16) | ((uint32_t)(*xlate(NEW_LBA + 3)) << 24);
}

void PatchZ80(register Z80 *R)
{
    word patch_addr = (word)(R->PC.W - 2);

    if (patch_addr == READ_RAW_SECTOR) {
        uint32_t lba = read_new_lba();
        byte *dest = xlate(R->HL.W);
        int fail = !(fseek(disk_img, (long)lba * 512, SEEK_SET) == 0 &&
                     fread(dest, 1, 512, disk_img) == 512);
        if (fail) R->AF.B.l |= 0x01; else R->AF.B.l &= ~0x01;
        simulate_ret(R);
        return;
    }
    if (patch_addr == WRITE_BLOCK) {
        uint32_t lba = read_new_lba();
        byte *src = xlate(R->HL.W);
        int fail = !(fseek(disk_img, (long)lba * 512, SEEK_SET) == 0 &&
                     fwrite(src, 1, 512, disk_img) == 512);
        if (!fail) fflush(disk_img);
        R->AF.B.h = fail ? 4 : 0;
        simulate_ret(R);
        return;
    }
    if (patch_addr == POLL_KEY) {
        /* Bench-found (see kc-z80-comp-emu/DEVLOG.md): const_impl calls poll_key
         * UNCONDITIONALLY on every CONST check, whether or not the
         * previous pending_char has been consumed by CONIN yet -- on
         * real hardware this is safe because get_key_event's own
         * debounce/last_row/last_col logic only reports a "new" key
         * once per genuine physical transition (same still-held key
         * -> carry clear, no overwrite). Naively dequeuing here on
         * every call skipped that latch and silently ate characters
         * (typed "DIR", CCP saw "DR" -- CONST got called at least
         * twice before CONIN drained the first one). Fix: only pull a
         * new character from the queue when pending_char is already
         * 0 (i.e. actually consumed -- conin_impl's own `XOR A / LD
         * (pending_char),A` after reading it), exactly mirroring "key
         * still held, no new event" instead of refilling every call. */
        if (*xlate(PENDING_CHAR) == 0) {
            char c;
            if (dequeue_char(&c)) *xlate(PENDING_CHAR) = (byte)c;
        }
        simulate_ret(R);
        return;
    }

    fprintf(stderr, "PatchZ80: unexpected patch at $%04X, halting\n", patch_addr);
    exit(1);
}

/* --- P1's manifest-driven RAM loader, bank-aware (see this file's
 * header) -- chunk2 (font+blit code) belongs to the bank=1 view of
 * $8000+, chunk1/chunk3 to the bank-invariant/bank=0 view. Known by
 * name from extract_bios_chunks.py's own fixed chunk1/chunk2/chunk3
 * naming, not re-derived here. */
static int load_chunk(const char *path, unsigned addr, unsigned size, int in_bank1)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "can't open %s\n", path); return -1; }
    byte *dest = in_bank1 ? &physram[addr + 0x10000] : &physram[addr];
    size_t got = fread(dest, 1, size, f);
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
        int in_bank1 = (strcmp(name, "chunk2") == 0);
        if (load_chunk(path, addr, size, in_bank1) != 0) ok = -1;
    }
    fclose(f);
    return ok;
}

static void patch_at(word addr) { *xlate(addr) = 0xED; *xlate((word)(addr + 1)) = 0xFE; }

/* --- screen (P3, unchanged rendering logic) --- */
static SDL_Window *win;
static SDL_Renderer *ren;
static SDL_Texture *tex;
static uint32_t pixels[SCREEN_W * SCREEN_H * 2];
static int line_double = 0;
static int out_h = SCREEN_H;
static Uint32 last_render_ms;
static Uint32 start_ms;
static int screenshot_taken = 0;
static int script_typed = 0;
static int mid_shot_taken = 0;
static int self_test = 0;   /* --self-test: run the scripted "type BREAKOUT,
                             * screenshot, auto-quit" verification instead
                             * of a plain interactive session (the default) */

static void save_screenshot(const char *path)
{
    int w, h;
    SDL_GetRendererOutputSize(ren, &w, &h);
    SDL_Surface *surf = SDL_CreateRGBSurfaceWithFormat(
        0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
    if (!surf) return;
    if (SDL_RenderReadPixels(ren, NULL, SDL_PIXELFORMAT_ARGB8888,
                             surf->pixels, surf->pitch) == 0) {
        SDL_SaveBMP(surf, path);
        printf("wrote %s\n", path);
    }
    SDL_FreeSurface(surf);
}

static void render_frame(void)
{
    /* Video hardware always reads the bank=1 physical page regardless
     * of the CPU's own *current* bank setting (real hardware: the AVR's
     * video fetch forces A16=1 unconditionally, independent of whatever
     * the Z80 last wrote to the bank bit) -- so this reads physram's
     * bank=1 copy directly, not through xlate() (which follows the
     * CPU's live `bank` state, the wrong thing here). See this file's
     * header for the bug this fixes: the bank=0 view of this same
     * address range is CCP/BDOS/BIOS's own code, a different physical
     * page entirely on real hardware. */
    for (int row = 0; row < SCREEN_H; row++) {
        const byte *line = &physram[VRAM_BASE + row * 80 + 0x10000];
        uint32_t out_row[SCREEN_W];
        for (int col_byte = 0; col_byte < 80; col_byte++) {
            byte b = line[col_byte];
            for (int bit = 0; bit < 8; bit++) {
                int on = (b >> (7 - bit)) & 1;
                out_row[col_byte * 8 + bit] = on ? 0xFFFFFFFFu : 0xFF000000u;
            }
        }
        memcpy(&pixels[(row * (line_double ? 2 : 1)) * SCREEN_W],
               out_row, sizeof(out_row));
        if (line_double)
            memcpy(&pixels[(row * 2 + 1) * SCREEN_W], out_row, sizeof(out_row));
    }
    SDL_UpdateTexture(tex, NULL, pixels, SCREEN_W * (int)sizeof(uint32_t));
    SDL_RenderClear(ren);
    SDL_RenderCopy(ren, tex, NULL, NULL);
    SDL_RenderPresent(ren);
}

/* Types a fixed command a moment after boot, for unattended
 * verification -- see this file's header. Goes through the exact same
 * queue_char() a real keypress would. */
static void run_self_test_script(void)
{
    static const char *cmd = "BREAKOUT\r";
    for (const char *p = cmd; *p; p++) queue_char(*p);
    printf("[self-test: typed \"BREAKOUT\" + Enter]\n");
}

word LoopZ80(register Z80 *R)
{
    (void)R;
    Uint32 now = SDL_GetTicks();

    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        if (ev.type == SDL_QUIT) return INT_QUIT;
        if (ev.type == SDL_TEXTINPUT) queue_char(ev.text.text[0]);
        if (ev.type == SDL_KEYDOWN && ev.key.keysym.sym == SDLK_RETURN)
            queue_char('\r');
        if (ev.type == SDL_KEYDOWN && ev.key.keysym.sym == SDLK_BACKSPACE)
            queue_char(0x08);
    }

    if (now - last_render_ms >= FRAME_MS) {
        render_frame();
        last_render_ms = now;
        if (self_test) {
            if (!screenshot_taken && now - start_ms >= 500) {
                save_screenshot("build/p5_prompt.bmp");
                screenshot_taken = 1;
            }
            if (!script_typed && now - start_ms >= 800) {
                run_self_test_script();
                script_typed = 1;
            }
            /* Burst-capture across the whole load+play+game-over
             * window instead of guessing one timestamp -- the entire
             * lifecycle turned out to fit inside ~300ms of wall-clock
             * time (this core runs far faster than real hardware, and
             * nothing paces ball/paddle movement except a busy-wait
             * delay loop counted in Z80 cycles, per plan-kc-z80-comp-emu.md's own
             * "don't model bus-steal timing" choice) -- single-shot
             * timestamps kept landing on either "not typed yet" or
             * "already game over," never actual gameplay. */
            if (!mid_shot_taken && now - start_ms >= 820 && now - start_ms <= 1080) {
                char path[64];
                snprintf(path, sizeof(path), "build/p5_burst_%03lu.bmp",
                         (unsigned long)(now - start_ms));
                save_screenshot(path);
            }
            if (now - start_ms > 1080) mid_shot_taken = 1;
            if (script_typed && now - start_ms >= 6000) {
                save_screenshot("build/p5_after_breakout.bmp");
                printf("[auto-quit after typing test]\n");
                return INT_QUIT;
            }
        }
    }
    return INT_NONE;
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--line-double") == 0) line_double = 1;
        else if (strcmp(argv[i], "--self-test") == 0) self_test = 1;
        else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            fprintf(stderr, "usage: %s [--line-double] [--self-test]\n", argv[0]);
            return 1;
        }
    }
    out_h = line_double ? SCREEN_H * 2 : SCREEN_H;

    if (load_manifest("build/manifest.txt", "build") != 0) return 1;
    disk_img = fopen("build/boot_p5.img", "r+b");
    if (!disk_img) { fprintf(stderr, "can't open build/boot_p5.img\n"); return 1; }

    patch_at(READ_RAW_SECTOR);
    patch_at(WRITE_BLOCK);
    patch_at(POLL_KEY);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    win = SDL_CreateWindow("z80-with-1284p emulator -- P5 breakout test",
                           SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                           SCREEN_W * WINDOW_SCALE, out_h * WINDOW_SCALE,
                           SDL_WINDOW_SHOWN);
    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_RenderSetLogicalSize(ren, SCREEN_W, out_h);
    tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                            SDL_TEXTUREACCESS_STREAMING, SCREEN_W, out_h);
    SDL_StartTextInput();

    start_ms = last_render_ms = SDL_GetTicks();

    Z80 cpu;
    cpu.IPeriod = 10000;
    ResetZ80(&cpu);
    cpu.PC.W = BOOT_ENTRY;
    RunZ80(&cpu);

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    fclose(disk_img);

    printf("PASS: ran to completion.\n");
    return 0;
}
