/* p4_harness.c -- plan-kc-z80-comp-emu.md Phase P4: keyboard abstraction via SDL2
 * input, typing at the real CCP prompt.
 *
 * This is the natural convergence point of P1-P3: real CP/M image
 * (P1's loader), real disk I/O (P2's read_raw_sector/write_block
 * patches), real screen rendering (P3's SDL framebuffer view) -- but
 * CONOUT is deliberately *not* patched any more, unlike P2's temporary
 * stdio shim: the real conout_impl (font-blit, cursor, VT52-subset
 * terminal handling) now runs for real and writes real characters into
 * video RAM, which P3's rendering already displays correctly. This is
 * possible without modeling the real hardware's bank=1/A16 gate at all
 * (cpm-plan.md sec.2) -- this emulator's flat 64K RAM has always let
 * $C000+ through unconditionally (a deliberate simplification noted
 * back in the P1 devlog entry), which happens to be *more* permissive
 * than real hardware, not less, so real BIOS code that flips bank
 * before touching video RAM works unmodified.
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
 * window. Pass --self-test to instead run the scripted "type DIR,
 * screenshot, auto-quit after ~2.5s" verification this file was
 * originally built around (used to check this harness itself, e.g. in
 * an environment with no human present to type) -- both paths queue
 * characters through the exact same queue_char(), so the scripted path
 * genuinely exercises the same code a real keypress would, it's not a
 * separate shortcut.
 *
 * Options: --line-double (doubled window height, see that flag's own
 * comment further down), --self-test (above), --unthrottled (skip the
 * real-8MHz-speed pacing in LoopZ80 -- default is throttled now, since
 * an unthrottled core runs so far ahead of real hardware that anything
 * timed by a busy-wait delay loop, e.g. a game's own ball/paddle
 * movement, is unplayably fast -- see LoopZ80's own comment).
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
#define NEW_LBA         0xFACE

#define VRAM_BASE     0xC000
#define SCREEN_W      640
#define SCREEN_H      200
#define WINDOW_SCALE  2
#define FRAME_MS      33
#define Z80_HZ        8000000.0  /* nominal Z80 clock, CLAUDE.md's own
                                   * spec -- see --unthrottled's comment
                                   * for why this, not the ~4.79MHz
                                   * bus-steal-derated *effective* rate,
                                   * is the right throttle target here */

#define PORT_A_BANK_BIT  0x02   /* bank = bit 1 of 8255 Port A, $A8 */
#define PORT_KBD_ROW     0xAA   /* row-select (out) -- 8255 PC0-3 -> 74LS145 */
#define PORT_KBD_COL     0xA9   /* column read (in), active-low -- 8255 PortB */

static byte physram[0x20000];   /* 128K: two full 32K views of $8000-$FFFF,
                                  * see this file's header for the formula */
static int bank = 0;
static FILE *disk_img;

/* Real keyboard-matrix emulation, added after this file's first version
 * (bench-found: breakout.com's own arrow-key/ESC input never worked at
 * all -- it bypasses BDOS/CONST/CONIN and polls this matrix directly,
 * see firmware/z80-boot-rom/cpm/breakout/input.s, which was the only
 * documentation needed: row-select is a plain write to $AA, latched
 * here; a read from $A9 returns the selected row's 8 column bits,
 * active-low (0=held). Row/col assignments (the standard MSX matrix
 * this hardware follows) come straight from firmware/z80-boot-rom/
 * test-progs/keyboard-scan-test.asm's own keynames table -- not
 * reinvented. `key_held` is level-triggered state (currently-held,
 * checked live whenever polled), a different model from `key_queue`
 * above (discrete, one-shot characters for BDOS-level typing) -- both
 * are fed from the same SDL_KEYDOWN/UP events in LoopZ80, since a game
 * doing hardware polling and CCP doing BDOS-level input are two
 * genuinely different consumers of the same physical keypress. */
static int kbd_row = 0;
static byte key_held[9][8]; /* [row][col], 1 = currently held */

static const struct { SDL_Keycode key; int row, col; } KBD_MAP[] = {
    {SDLK_0,0,0},{SDLK_1,0,1},{SDLK_2,0,2},{SDLK_3,0,3},
    {SDLK_4,0,4},{SDLK_5,0,5},{SDLK_6,0,6},{SDLK_7,0,7},
    {SDLK_8,1,0},{SDLK_9,1,1},{SDLK_MINUS,1,2},{SDLK_EQUALS,1,3},
    {SDLK_BACKSLASH,1,4},{SDLK_LEFTBRACKET,1,5},{SDLK_RIGHTBRACKET,1,6},
    {SDLK_SEMICOLON,1,7},
    {SDLK_QUOTE,2,0},{SDLK_BACKQUOTE,2,1},{SDLK_COMMA,2,2},{SDLK_PERIOD,2,3},
    {SDLK_SLASH,2,4},/* col5 DEAD key, no modern equivalent */
    {SDLK_a,2,6},{SDLK_b,2,7},
    {SDLK_c,3,0},{SDLK_d,3,1},{SDLK_e,3,2},{SDLK_f,3,3},
    {SDLK_g,3,4},{SDLK_h,3,5},{SDLK_i,3,6},{SDLK_j,3,7},
    {SDLK_k,4,0},{SDLK_l,4,1},{SDLK_m,4,2},{SDLK_n,4,3},
    {SDLK_o,4,4},{SDLK_p,4,5},{SDLK_q,4,6},{SDLK_r,4,7},
    {SDLK_s,5,0},{SDLK_t,5,1},{SDLK_u,5,2},{SDLK_v,5,3},
    {SDLK_w,5,4},{SDLK_x,5,5},{SDLK_y,5,6},{SDLK_z,5,7},
    {SDLK_LSHIFT,6,0},{SDLK_RSHIFT,6,0},{SDLK_LCTRL,6,1},{SDLK_RCTRL,6,1},
    /* col2 GRAPH, col4 CODE: no modern equivalent */
    {SDLK_CAPSLOCK,6,3},{SDLK_F1,6,5},{SDLK_F2,6,6},{SDLK_F3,6,7},
    {SDLK_F4,7,0},{SDLK_F5,7,1},{SDLK_ESCAPE,7,2},{SDLK_TAB,7,3},
    /* col4 STOP, col6 SELECT: no modern equivalent */
    {SDLK_BACKSPACE,7,5},{SDLK_RETURN,7,7},
    {SDLK_SPACE,8,0},{SDLK_HOME,8,1},{SDLK_INSERT,8,2},{SDLK_DELETE,8,3},
    {SDLK_LEFT,8,4},{SDLK_UP,8,5},{SDLK_DOWN,8,6},{SDLK_RIGHT,8,7},
};
#define KBD_MAP_N (sizeof(KBD_MAP) / sizeof(KBD_MAP[0]))

static void kbd_set(SDL_Keycode key, int down)
{
    for (size_t i = 0; i < KBD_MAP_N; i++) {
        if (KBD_MAP[i].key == key) {
            key_held[KBD_MAP[i].row][KBD_MAP[i].col] = (byte)down;
            /* don't break -- SHIFT/CTRL map from two physical keys onto
             * one matrix cell, both should be able to set/clear it */
        }
    }
}

static inline byte *xlate(word addr)
{
    if (addr < 0x8000 || !bank) return &physram[addr];
    return &physram[addr + 0x10000];
}

byte RdZ80(register word Addr) { return *xlate(Addr); }
void WrZ80(register word Addr, register byte Value) { *xlate(Addr) = Value; }

byte InZ80(register word Port)
{
    if ((Port & 0xFF) == PORT_KBD_COL) {
        if (kbd_row < 0 || kbd_row > 8) return 0xFF; /* row 9: unwired */
        byte b = 0xFF;
        for (int col = 0; col < 8; col++)
            if (key_held[kbd_row][col]) b &= (byte)~(1 << col);
        return b;
    }
    return 0xFF;
}

void OutZ80(register word Port, register byte Value)
{
    if ((Port & 0xFF) == 0xA8) bank = (Value & PORT_A_BANK_BIT) ? 1 : 0;
    else if ((Port & 0xFF) == PORT_KBD_ROW) kbd_row = Value & 0x0F;
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
static int self_test = 0;   /* --self-test: run the scripted "type DIR,
                             * screenshot, auto-quit" verification instead
                             * of a plain interactive session (the default) */
static int unthrottled = 0; /* --unthrottled: skip the real-speed pacing
                             * below, run the core as fast as the host
                             * allows (this project's own earlier default,
                             * fine for logic-only testing, useless for
                             * actually playing anything -- see LoopZ80) */
static double total_cycles = 0.0;

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
    static const char *cmd = "DIR\r";
    for (const char *p = cmd; *p; p++) queue_char(*p);
    printf("[self-test: typed \"DIR\" + Enter]\n");
}

word LoopZ80(register Z80 *R)
{
    total_cycles += R->IPeriod;

    /* Real-speed throttle (default, unless --self-test or --unthrottled):
     * this core runs far faster than real hardware with nothing to slow
     * it down, so anything paced by a busy-wait delay loop counted in
     * Z80 cycles (which is most game logic, breakout's ball/paddle
     * movement included -- see kc-z80-comp-emu/DEVLOG.md's P5 entry,
     * bench-found the hard way: a full load-to-game-over run compressed
     * into ~300ms of wall-clock time) runs correspondingly, unplayably
     * fast. Fix: track total emulated cycles against wall-clock time
     * since start, and sleep off any surplus -- if the core has gotten
     * ahead of where an 8MHz Z80 (this project's own nominal clock,
     * CLAUDE.md) would be by now, wait for real time to catch up. Not
     * the ~4.79MHz *effective* throughput the real machine sees once
     * video bus-steal is accounted for (this emulator doesn't model
     * bus-steal timing at all, per plan-kc-z80-comp-emu.md's own
     * architecture decision, so there's no slower "effective" rate to
     * throttle to here -- 8MHz is what this core actually executes at
     * when not held back, and is the only real reference point the
     * emulator has). Skipped for --self-test (automated verification
     * wants to finish fast, not pace itself) and --unthrottled (opt-out
     * for anyone who explicitly wants the old fast-as-possible
     * behavior). */
    if (!self_test && !unthrottled) {
        double target_ms = (total_cycles / Z80_HZ) * 1000.0;
        Uint32 elapsed = SDL_GetTicks() - start_ms;
        if ((double)elapsed < target_ms) {
            SDL_Delay((Uint32)(target_ms - (double)elapsed));
        }
    }

    Uint32 now = SDL_GetTicks();

    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        if (ev.type == SDL_QUIT) return INT_QUIT;
        if (ev.type == SDL_TEXTINPUT) queue_char(ev.text.text[0]);
        if (ev.type == SDL_KEYDOWN && ev.key.keysym.sym == SDLK_RETURN)
            queue_char('\r');
        if (ev.type == SDL_KEYDOWN && ev.key.keysym.sym == SDLK_BACKSPACE)
            queue_char(0x08);
        if (ev.type == SDL_KEYDOWN && !ev.key.repeat)
            kbd_set(ev.key.keysym.sym, 1);
        if (ev.type == SDL_KEYUP)
            kbd_set(ev.key.keysym.sym, 0);
    }

    if (now - last_render_ms >= FRAME_MS) {
        render_frame();
        last_render_ms = now;
        if (self_test) {
            if (!screenshot_taken && now - start_ms >= 500) {
                save_screenshot("build/p4_prompt.bmp");
                screenshot_taken = 1;
            }
            if (!script_typed && now - start_ms >= 800) {
                run_self_test_script();
                script_typed = 1;
            }
            if (script_typed && now - start_ms >= 4000) {
                save_screenshot("build/p4_after_dir.bmp");
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
        else if (strcmp(argv[i], "--unthrottled") == 0) unthrottled = 1;
        else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            fprintf(stderr, "usage: %s [--line-double] [--self-test] "
                    "[--unthrottled]\n", argv[0]);
            return 1;
        }
    }
    out_h = line_double ? SCREEN_H * 2 : SCREEN_H;

    if (load_manifest("build/manifest.txt", "build") != 0) return 1;
    disk_img = fopen("../firmware/z80-boot-rom/cpm/boot.img", "r+b");
    if (!disk_img) { fprintf(stderr, "can't open boot.img\n"); return 1; }

    patch_at(READ_RAW_SECTOR);
    patch_at(WRITE_BLOCK);
    patch_at(POLL_KEY);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    win = SDL_CreateWindow("z80-with-1284p emulator -- P4 keyboard test",
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
    printf("[%.0f cycles emulated over %ums real time -> %.2fMHz effective"
           "%s]\n", total_cycles, SDL_GetTicks() - start_ms,
           total_cycles / (SDL_GetTicks() - start_ms) / 1000.0,
           unthrottled || self_test ? ", unthrottled" : ", throttled to 8MHz");

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    fclose(disk_img);

    printf("PASS: ran to completion.\n");
    return 0;
}
