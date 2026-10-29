/* p3_harness.c -- plan-kc-z80-comp-emu.md Phase P3: screen abstraction via SDL2.
 *
 * Deliberately decoupled from CP/M (no BIOS/disk/console patches at
 * all here) -- runs testprogs/vram_fill.asm, a small standalone
 * program purpose-built to exercise the screen abstraction alone,
 * per that file's own header for why. Renders the 640x200 1bpp
 * framebuffer at $C000 (80 bytes/line, matching docs/memory-map.md)
 * into a real SDL2 window, live, throttled to the framebuffer's own
 * update rate via SDL_GetTicks() rather than the Z80 core's own
 * (much faster than real hardware, nothing paces it) execution speed
 * -- matching plan-kc-z80-comp-emu.md's own "run at full host speed, don't model
 * bus-steal timing" architecture decision.
 *
 * Auto-quits after a few real seconds (so this can run unattended/
 * headless-checked) or on window close, whichever comes first.
 *
 * --line-double: doubles the window's height by drawing each real
 * scanline twice (sharp pixel duplication, not a smooth stretch) --
 * purely a viewing convenience (the framebuffer itself is still real
 * 640x200, one bit/pixel). Incidentally closer to how the real
 * hardware's own non-square pixels actually look (this project's own
 * docs confirm real scanlines read about 2x taller than wide on the
 * actual PAL screen) -- but that's a side effect, not the point of
 * the flag; off by default since it's a real, if small, distortion of
 * the raw framebuffer that most work on the emulator itself won't want.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL2/SDL.h>
#include "Z80.h"

#define VRAM_BASE     0xC000
#define VRAM_BYTES    16000   /* 80 bytes/line * 200 lines */
#define SCREEN_W      640
#define SCREEN_H      200
#define WINDOW_SCALE  2
#define RUN_MS        4000    /* auto-quit after this long, unattended */
#define FRAME_MS      33      /* ~30fps redraw throttle */

static byte ram[0x10000];

byte RdZ80(register word Addr) { return ram[Addr]; }
void WrZ80(register word Addr, register byte Value) { ram[Addr] = Value; }
byte InZ80(register word Port)  { (void)Port; return 0xFF; }
void OutZ80(register word Port, register byte Value) { (void)Port; (void)Value; }
void PatchZ80(register Z80 *R) { (void)R; /* not used by this test program */ }

static SDL_Window *win;
static SDL_Renderer *ren;
static SDL_Texture *tex;
static uint32_t pixels[SCREEN_W * SCREEN_H * 2]; /* *2: room for --line-double */
static Uint32 last_render_ms;
static Uint32 start_ms;
static int line_double = 0;      /* --line-double: draw each real scanline
                                   * twice, sharp duplication not a stretch */
static int out_h = SCREEN_H;     /* SCREEN_H, or *2 under --line-double */

static int screenshot_taken = 0;

static void save_screenshot(void)
{
    int w, h;
    SDL_GetRendererOutputSize(ren, &w, &h);
    SDL_Surface *surf = SDL_CreateRGBSurfaceWithFormat(
        0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
    if (!surf) return;
    if (SDL_RenderReadPixels(ren, NULL, SDL_PIXELFORMAT_ARGB8888,
                             surf->pixels, surf->pitch) == 0) {
        SDL_SaveBMP(surf, "build/p3_screenshot.bmp");
        printf("wrote build/p3_screenshot.bmp\n");
    } else {
        fprintf(stderr, "SDL_RenderReadPixels failed: %s\n", SDL_GetError());
    }
    SDL_FreeSurface(surf);
}

static void render_frame(void)
{
    for (int row = 0; row < SCREEN_H; row++) {
        const byte *line = &ram[VRAM_BASE + row * 80];
        uint32_t out_row[SCREEN_W];
        for (int col_byte = 0; col_byte < 80; col_byte++) {
            byte b = line[col_byte];
            for (int bit = 0; bit < 8; bit++) {
                int x = col_byte * 8 + bit;
                /* MSB-first, matching this project's own 74LS166
                 * shift-out convention (bit 7 = leftmost pixel). */
                int on = (b >> (7 - bit)) & 1;
                out_row[x] = on ? 0xFFFFFFFFu : 0xFF000000u;
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

word LoopZ80(register Z80 *R)
{
    (void)R;
    Uint32 now = SDL_GetTicks();

    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        if (ev.type == SDL_QUIT) return INT_QUIT;
    }

    if (now - last_render_ms >= FRAME_MS) {
        render_frame();
        last_render_ms = now;
        if (!screenshot_taken && now - start_ms >= 500) {
            save_screenshot();
            screenshot_taken = 1;
        }
    }

    if (now - start_ms >= RUN_MS) {
        printf("[auto-quit after %ums]\n", RUN_MS);
        return INT_QUIT;
    }
    return INT_NONE;
}

int main(int argc, char **argv)
{
    const char *program_path = "testprogs/vram_fill.bin";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--line-double") == 0) {
            line_double = 1;
        } else if (strcmp(argv[i], "--program") == 0 && i + 1 < argc) {
            program_path = argv[++i];
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            fprintf(stderr, "usage: %s [--line-double] [--program PATH]\n", argv[0]);
            return 1;
        }
    }
    out_h = line_double ? SCREEN_H * 2 : SCREEN_H;

    FILE *f = fopen(program_path, "rb");
    if (!f) { fprintf(stderr, "can't open %s\n", program_path); return 1; }
    size_t n = fread(ram, 1, sizeof(ram), f);
    fclose(f);
    printf("loaded %s, %zu bytes at $0000\n", program_path, n);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    win = SDL_CreateWindow("z80-with-1284p emulator -- P3 screen test",
                           SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                           SCREEN_W * WINDOW_SCALE, out_h * WINDOW_SCALE,
                           SDL_WINDOW_SHOWN);
    if (!win) { fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError()); return 1; }
    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!ren) { fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError()); return 1; }
    SDL_RenderSetLogicalSize(ren, SCREEN_W, out_h);
    tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                            SDL_TEXTUREACCESS_STREAMING, SCREEN_W, out_h);
    if (!tex) { fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError()); return 1; }

    start_ms = last_render_ms = SDL_GetTicks();

    Z80 cpu;
    cpu.IPeriod = 5000;
    ResetZ80(&cpu);
    /* z80em's own reset default (SP=$F000, Z80.c's ResetZ80()) sits
     * INSIDE the video RAM range ($C000-$FFDF) -- bench-found the hard
     * way: any
     * standalone test program here that uses CALL/RET (not all do --
     * vram_fill.asm never triggered this) leaves leftover return-
     * address bytes in what's also the pixel framebuffer, showing up
     * as small stray garbage marks that looked exactly like a drawing
     * bug until traced to this. Real CP/M/BIOS code run through P2/P4/
     * P5's harnesses was never at risk -- boot_init's own first act is
     * `LD SP,CCPSTACK`, a safe location -- only bare standalone
     * programs run directly through *this* harness could hit it, so
     * the fix belongs here rather than in every future .asm file. */
    cpu.SP.W = 0x8000;
    RunZ80(&cpu);

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();

    printf("PASS: ran to completion (window closed or auto-quit timeout).\n");
    return 0;
}
