/* main.c -- breakout, Phase 7: finishing the core game loop (see below).
 * Phase 2's static playfield, Phase 3's paddle movement, Phase 4's
 * ball/wall/paddle bounce, and Phase 5's brick collision are unchanged;
 * Phase 6 replaces the flat 0xFF brick fill with a per-row dither
 * texture (fill_rect_tile8(), video.s) and adds two textured border
 * pillars along the screen edges -- inspired by the dithered/3D brick
 * look in classic 1-bit ports like the Macintosh Arkanoid (see the
 * repo root's arkanoid-macintosh screenshot and the analysis that
 * preceded this phase). The background "well" texture behind the
 * bricks from that reference is deliberately NOT done here -- plain
 * black stays there for now, out of scope.
 *
 * Corrected after the first pass: a per-row dither byte alone can't
 * put a highlight on just the LEFT edge of a brick (the same byte
 * repeats across the whole row, so it can only band whole scanlines,
 * not shade one column within one) -- missed the reference's most
 * important cue, a consistent bright top+left / dark bottom+right
 * bevel on every brick and pillar (light from top-left). Fixed via
 * draw_pillar(): a solid bright edge and solid dark edge layered over
 * the texture, shared by both draw_bricks() (which also stamps
 * full-width bright/dark bands on top for the top/bottom edges) and
 * draw_border().
 *
 * BRICK_COLS narrowed from 10 to 9 to make room for the two
 * MARGIN_BYTES-wide border pillars without changing individual brick
 * size/spacing -- every x-coordinate constant that used to assume the
 * playfield ran edge-to-edge (paddle bounds, ball wall-bounce bounds)
 * is updated accordingly; see PLAYFIELD_LEFT_PX/PLAYFIELD_RIGHT_PX.
 *
 * Bounce axis (dx vs dy) is chosen via a standard "minimum overlap"
 * heuristic (see check_brick_hit()) rather than assumed to always be
 * dy -- not physically exact for a fast-moving ball, but reliable here
 * since the ball only moves a few px/frame, so by the time a collision
 * is detected the two rectangles have barely interpenetrated (the
 * smaller-overlap axis really is the one that was just crossed).
 *
 * Phase 7 finishes the core game loop, closing out the three things
 * the paragraph above used to flag as deliberately missing:
 * - a "win" (all bricks cleared) and "game over" (3 missed balls)
 *   end state, each showing a message and returning to CP/M -- see
 *   end_game() and its two call sites, both in move_ball() (the win
 *   check right after check_brick_hit(), the game-over check in the
 *   miss branch);
 * - a real exit path -- the main loop now polls poll_quit() (input.s)
 *   once per iteration for ESC, alongside poll_lr()'s own direct
 *   hardware read of LEFT/RIGHT. Both are plain direct reads of the
 *   same keyboard-matrix hardware (just different rows), run strictly
 *   sequentially here (no interrupts involved), so there's no race --
 *   just two independent, back-to-back polls. Originally written using
 *   BDOS function 6 (direct console I/O) instead -- corrected below,
 *   see poll_quit()'s own header comment (input.s) for the real,
 *   bench-found reason that had to change;
 * - an on-screen lives/score HUD (draw_hud()) at the request of a
 *   real bench report: the first version of this phase used BDOS
 *   function 2 (print()/putchar(), CONOUT) to print a "miss -- N
 *   lives left" message on every miss -- which turned out to (a) land
 *   wherever CP/M's own text cursor happened to be, not a fixed HUD
 *   position, and (b) once, on real hardware, print correctly and
 *   then lock up the whole machine. Every on-screen message in this
 *   file (the HUD, and end_game()'s "GAME OVER"/"YOU WIN!"/"QUIT") now
 *   goes through draw_char()/draw_text() (video.s), which blit glyphs
 *   from the same font CONOUT uses directly into video RAM using this
 *   file's own already-proven bank_on/bank_off pairing -- CONOUT/BDOS
 *   function 2 is never called anywhere in this file any more.
 *
 * Real second bug, found from the SAME class of mistake, caught right
 * after the above on a second bench round: BDOS function 6 (direct
 * console I/O) was kept for the quit-key poll and end_game()'s
 * keypress-wait, reasoned to be safe since it "only reads keyboard
 * hardware, never Port A" -- true for the character it returns, but
 * function 6 (cpm22.asm's DIRCIO, E=0xFF) calls BDOS's CONST
 * internally, and bios.asm's const_impl calls show_cursor() whenever
 * no key is ready -- which XORs CP/M's own text cursor into video RAM
 * via enter_bank1 on every single call. Polling that every frame
 * repeatedly redrew a stale cursor at whatever (cur_row,cur_col) CP/M
 * had last been left at, corrupting a border pillar on real hardware
 * -- bench-confirmed, not theoretical. Fixed the same way as the first
 * bug: replaced with poll_quit() (input.s), a direct hardware read of
 * ESC that never calls BDOS at all. BDOS is now called from exactly
 * one place in this whole file: bdos(0,0) in end_game(), a plain warm
 * boot with no console-I/O side effects.
 */
unsigned char bdos(unsigned char func, unsigned int arg) __naked
{
    (void)func;
    (void)arg;
    __asm
        ld c, a         ; func was passed in A; BDOS wants it in C
        call 5
        ret
    __endasm;
}

/* Defined in video.s. */
extern void video_cls(void);
extern void fill_rect(unsigned int addr, unsigned char width_bytes,
                       unsigned char height, unsigned char pattern);
extern void fill_rect_tile8(unsigned int addr, unsigned char width_bytes,
                             unsigned char height, const unsigned char *tile);
extern void edge_col(unsigned int addr, unsigned char height,
                      unsigned char or_mask, unsigned char and_mask);
extern void draw_char(unsigned int addr, unsigned char ascii);

/* Draws a NUL-terminated string starting at `addr`, one character per
 * byte-column (matching the font's natural 8px cell width) -- used for
 * both the HUD and end_game()'s messages, see this file's header. */
static void draw_text(unsigned int addr, const char *s)
{
    while (*s) {
        draw_char(addr, (unsigned char)*s);
        addr++;
        s++;
    }
}

/* Defined in input.s. */
extern unsigned char poll_lr(void);
extern unsigned char poll_quit(void);
extern void delay_short(void);

/* Defined in ball.s. */
extern void ball_xor(unsigned int addr, unsigned char shift);

#define KEY_LEFT  0x01
#define KEY_RIGHT 0x02

#define VBASE     0xC000
#define ROW_BYTES 80

/* Byte-aligned playfield layout (Phase 2 scope: no sub-byte shifting --
 * every x coordinate below is a whole-byte offset, i.e. a multiple of
 * 8 pixels).
 *
 * Phase 6: MARGIN_BYTES on each side is new (border pillars, see
 * draw_border() below) -- BRICK_COLS narrowed from 10 to 9 to make
 * room for it while leaving BRICK_STRIDE/BRICK_W_BYTES (individual
 * brick size/spacing) exactly as before. 80 bytes/row total (640px) =
 * MARGIN_BYTES + 9*BRICK_STRIDE + MARGIN_BYTES = 4 + 72 + 4. */
#define MARGIN_BYTES     4   /* 32px border pillar, each side */
#define BRICK_COLS       9
#define BRICK_W_BYTES    7   /* 56px brick + 1 byte (8px) gap = 8-byte stride */
#define BRICK_STRIDE     8
#define BRICK_ROWS       6
#define BRICK_H          8   /* 8 scanlines tall -- also fill_rect_tile8's
                              * tile height, see video.s */
#define BRICK_ROW_STRIDE 12  /* 8 scanlines + 4-scanline gap */
#define BRICK_TOP        16  /* first brick row starts at scanline 16 */

/* Inner playfield (between the two border pillars), in bytes/pixels. */
#define PLAYFIELD_INNER_BYTES (BRICK_COLS * BRICK_STRIDE)          /* 72 */
#define PLAYFIELD_LEFT_PX     (MARGIN_BYTES * 8)                   /* 32 */
#define PLAYFIELD_RIGHT_PX    ((unsigned int)(MARGIN_BYTES + PLAYFIELD_INNER_BYTES) * 8) /* 608 */

#define PADDLE_W_BYTES 10   /* 80px */
#define PADDLE_H       8
#define PADDLE_X_MIN   MARGIN_BYTES
#define PADDLE_X_BYTE  (MARGIN_BYTES + (PLAYFIELD_INNER_BYTES - PADDLE_W_BYTES) / 2) /* centered */
#define PADDLE_Y       184  /* near the bottom, 16 lines of margin below */

static unsigned int addr_at(unsigned char row, unsigned char xbyte)
{
    return VBASE + (unsigned int)row * ROW_BYTES + xbyte;
}

#define LIVES_START 3

/* Lives remaining -- reset once per program run (main(), not per-ball
 * like bx/by/dx/dy below), decremented on each miss (move_ball()).
 * Zero-initialized (plain BSS) same as everything else in this file;
 * main() assigns the real starting value at runtime for the same
 * crt0.s gsinit reason the ball-state comment further down explains. */
static unsigned char lives;

/* On-screen HUD: lives towards the left, a static "00000" score
 * placeholder towards the right, both on the free 16-scanline strip
 * above the bricks (BRICK_TOP=16) -- no real score is tracked yet
 * (out of this phase's scope), just the digits the reference asked
 * for. HUD_Y=4 centers the 8px-tall glyphs in that strip (4px clear
 * above and below) rather than flush against the very top edge.
 * HUD_LIVES_X sits a few character-widths right of the left pillar
 * (MARGIN_BYTES alone, i.e. flush against it, bench-reported as
 * reading too close/cramped). */
#define HUD_Y            4
#define HUD_LIVES_X      (MARGIN_BYTES + 3)
#define HUD_SCORE_DIGITS 5
#define HUD_SCORE_X      (MARGIN_BYTES + PLAYFIELD_INNER_BYTES - HUD_SCORE_DIGITS - 2)

static void update_lives_hud(void)
{
    draw_char(addr_at(HUD_Y, HUD_LIVES_X), (unsigned char)('0' + lives));
}

static void draw_hud(void)
{
    unsigned char i;

    update_lives_hud();
    for (i = 0; i < HUD_SCORE_DIGITS; i++) {
        draw_char(addr_at(HUD_Y, HUD_SCORE_X + i), '0');
    }
}

/* Dither tiles for fill_rect_tile8() -- one byte per scanline, cycling
 * every 8 rows (BRICK_H). Each row of bricks gets a different texture
 * (standing in for the different brick "colors" a monochrome display
 * can't show), loosely in the spirit of the dithered/3D brick look in
 * classic 1-bit ports (e.g. the Macintosh Arkanoid) -- not a literal
 * bit-for-bit copy of any specific reference, both because that
 * wouldn't be square-pixel-clean here anyway and because designing our
 * own tiles is simpler than reverse-engineering someone else's exact
 * bitmap.
 *
 * Deliberately "taller" than a naive 1:1 port of a square-pixel
 * original: every dither feature below spans 2 scanlines, not 1 (e.g.
 * the checkerboard's cells are 1 pixel wide but 2 scanlines tall, not
 * 1x1). This project's display is 640x200 on a 4:3-ish screen --
 * fewer, physically taller scanlines per unit height than a
 * square-pixel display -- so a pattern designed at 1 scanline per
 * feature (matching a square-pixel source) would visually run about
 * 2x too fast vertically; doubling each feature's row-span compensates. */
static const unsigned char BRICK_TILES[BRICK_ROWS][8] = {
    /* Row 0: solid with two dotted accent lines -- a brighter, more
     * "solid-looking" brick, echoing the reference's top/"silver" row. */
    {0xFF, 0xFF, 0xAA, 0xFF, 0xFF, 0xAA, 0xFF, 0xFF},
    /* Row 1: coarse basket-weave crosshatch. */
    {0xCC, 0xCC, 0x33, 0x33, 0xCC, 0xCC, 0x33, 0x33},
    /* Row 2: shallow diagonal hatch (steps right every 2 rows). */
    {0xE0, 0xE0, 0x70, 0x70, 0x38, 0x38, 0x1C, 0x1C},
    /* Row 3: checkerboard, 1x2 cells. */
    {0xAA, 0xAA, 0x55, 0x55, 0xAA, 0xAA, 0x55, 0x55},
    /* Row 4: wavy/zigzag stripe. */
    {0x81, 0x81, 0x42, 0x42, 0x24, 0x24, 0x42, 0x42},
    /* Row 5: sparse dotted/houndstooth. */
    {0x88, 0x88, 0x22, 0x22, 0x88, 0x88, 0x22, 0x22},
};

/* Border pillar tile: a repeating bright-ring / textured-band / dark-gap
 * unit (also 8 rows, also "tall" per feature) -- same idea as the
 * bricks above, applied to the two vertical margin columns instead of
 * a brick. No background/"well" dithering behind the bricks yet --
 * deliberately out of scope for now, plain black stays there.
 *
 * The bright "ring" band is deliberately only 1 row here (unlike the
 * brick tiles' 2-row features) -- bench-reported 2026-09-16: at 2
 * rows it visibly read as "too deep" for this specific feature, unlike
 * the brick textures where 2-row features read fine. Not a blanket
 * retraction of the general "taller tiles" compensation, just this
 * one feature tuned back down after seeing it on the real screen. */
static const unsigned char PILLAR_TILE[8] = {
    0xFF, 0x99, 0x66, 0x66, 0x99, 0x00, 0x00, 0x00,
};

/* Beveled "3D" look, light from top-left (matches the Macintosh
 * Arkanoid reference this phase is based on -- its bricks/borders
 * always show a white edge on the top and left, dark on the bottom
 * and right, regardless of the interior texture) -- genuinely
 * 1-PIXEL-wide edges, not a full byte. A per-row dither byte alone
 * (fill_rect_tile8) can't produce this at all: the same byte repeats
 * across every byte of a row, so it can make a highlight *band* (a
 * whole scanline) but not a highlight *column* (just the leftmost
 * pixels of an otherwise-textured row). The first version of this
 * used fill_rect to overwrite the whole leftmost/rightmost BYTE
 * (8px) with solid white/black -- bench-reported 2026-09-16 as
 * visibly far too wide (and the reason the brick's top/bottom bands
 * looked like they "overhung" the hatch pattern: the bands span the
 * brick's full width, but the hatch only showed in the narrower
 * middle once 2 whole bytes were carved out for edge columns).
 * Fixed with edge_col() (video.s): a genuine single-BIT read-modify-
 * write that sets/clears just one pixel, leaving the other 7 bits of
 * that byte showing whatever fill_rect_tile8 already drew there.
 *
 * draw_pillar() is the shared shape (used for both bricks and the
 * border pillars): a 1px bright edge, a 1px dark edge, and a textured
 * interior spanning the FULL width in between (no bytes carved out
 * for the edges any more) -- callers just pick how wide/tall it is. */
/* right_and_mask lets callers pick how many rightmost pixels go dark
 * (0xFE = 1px, 0xFC = 2px, ...) -- bricks and pillars turned out to
 * need different answers here: verified via a memory-dump test
 * (2026-09-16) that 1px (0xFE) genuinely does darken every row's
 * rightmost pixel correctly, but bench-reported as still not reading
 * as a real separator between the pillar and its neighboring brick --
 * unlike a brick-to-brick gap (a full 8px BRICK_STRIDE-BRICK_W_BYTES
 * byte of plain black), the pillar/brick seam has no such buffer, so
 * the single dark pixel sits directly against the brick's own bright
 * pixel with nothing around it. Trying 2px (0xFC) there per that
 * report; bricks keep 1px (0xFE, already confirmed looking right). */
static void draw_pillar(unsigned int addr, unsigned char width_bytes,
                         unsigned char height, const unsigned char *tile,
                         unsigned char right_and_mask)
{
    fill_rect_tile8(addr, width_bytes, height, tile);
    edge_col(addr, height, 0x80, 0xFF);          /* leftmost pixel -> white */
    /* width_bytes>=2 is assumed by every call site below (bricks:
     * BRICK_W_BYTES=7; pillars: MARGIN_BYTES=4) -- a 1-byte-wide
     * region would have its single byte's leftmost and rightmost bits
     * both modified, which is still well-defined (just not a
     * meaningful "edge" look) rather than a real bug. */
    edge_col(addr + width_bytes - 1, height, 0x00, right_and_mask);
}

static void draw_border(void)
{
    draw_pillar(addr_at(0, 0), MARGIN_BYTES, 200, PILLAR_TILE, 0xFC);
    draw_pillar(addr_at(0, MARGIN_BYTES + PLAYFIELD_INNER_BYTES),
                MARGIN_BYTES, 200, PILLAR_TILE, 0xFC);
}

/* Per-brick alive flag, indexed [row][col]. Zero-initialized (plain
 * BSS) like bx/by/dx/dy below -- real "all alive" state is assigned at
 * runtime by reset_bricks(), not a non-zero static initializer (same
 * crt0.s gsinit gap explained in the ball-state comment below). */
static unsigned char bricks_alive[BRICK_ROWS][BRICK_COLS];

/* Brick rectangles in pixel coordinates (matching the ball's own
 * pixel-coordinate system, bx/by below) -- BRICK_TOP/BRICK_ROW_STRIDE
 * are already scanline (pixel) units, but BRICK_STRIDE/BRICK_W_BYTES
 * are byte units (draw_bricks()/addr_at() convention) and need <<3 to
 * become pixels. MARGIN_BYTES<<3 accounts for the left border pillar --
 * brick column 0 starts just to the right of it, not at the screen edge. */
#define BRICK_PIXEL_X0(c) ((unsigned int)(MARGIN_BYTES + (c) * BRICK_STRIDE) * 8)
#define BRICK_PIXEL_X1(c) (BRICK_PIXEL_X0(c) + (unsigned int)(BRICK_W_BYTES * 8))
#define BRICK_PIXEL_Y0(r) ((unsigned int)BRICK_TOP + (unsigned int)(r) * BRICK_ROW_STRIDE)
#define BRICK_PIXEL_Y1(r) (BRICK_PIXEL_Y0(r) + BRICK_H)

/* bricks_remaining tracks how many bricks_alive[][] entries are still
 * set, without needing to rescan the whole array to check for a win --
 * kept in lockstep with bricks_alive purely by convention (reset_bricks()
 * sets both; check_brick_hit() is the only other place either changes,
 * decrementing this every time it clears a bricks_alive entry). */
static unsigned char bricks_remaining;

static void reset_bricks(void)
{
    unsigned char r, c;

    for (r = 0; r < BRICK_ROWS; r++) {
        for (c = 0; c < BRICK_COLS; c++) {
            bricks_alive[r][c] = 1;
        }
    }
    bricks_remaining = BRICK_ROWS * BRICK_COLS;
}

static void draw_bricks(void)
{
    unsigned char r, c, y, x;

    for (r = 0; r < BRICK_ROWS; r++) {
        y = BRICK_TOP + r * BRICK_ROW_STRIDE;
        for (c = 0; c < BRICK_COLS; c++) {
            x = MARGIN_BYTES + c * BRICK_STRIDE;
            /* draw_pillar() gives the left/right bevel columns +
             * texture; the top/bottom bands drawn after it deliberately
             * overwrite its corner bytes, so the full top scanline ends
             * up entirely bright and the full bottom scanline entirely
             * dark (last-drawn-wins) -- painter's-algorithm-style, not
             * a special corner case. */
            draw_pillar(addr_at(y, x), BRICK_W_BYTES, BRICK_H, BRICK_TILES[r], 0xFE);
            fill_rect(addr_at(y, x), BRICK_W_BYTES, 1, 0xFF);
            fill_rect(addr_at((unsigned char)(y + BRICK_H - 1), x), BRICK_W_BYTES, 1, 0x00);
        }
    }
}

static void erase_brick(unsigned char r, unsigned char c)
{
    unsigned char y = BRICK_TOP + r * BRICK_ROW_STRIDE;
    unsigned char x = MARGIN_BYTES + c * BRICK_STRIDE;
    fill_rect(addr_at(y, x), BRICK_W_BYTES, BRICK_H, 0x00);
}

/* Max x (byte offset) the paddle's left edge can reach without its
 * right edge running past the border pillar (PADDLE_X_MIN is the
 * analogous left bound, defined above next to the other playfield
 * geometry). */
#define PADDLE_X_MAX (MARGIN_BYTES + PLAYFIELD_INNER_BYTES - PADDLE_W_BYTES)

static void draw_paddle(unsigned char x)
{
    fill_rect(addr_at(PADDLE_Y, x), PADDLE_W_BYTES, PADDLE_H, 0xFF);
}

static void erase_paddle(unsigned char x)
{
    fill_rect(addr_at(PADDLE_Y, x), PADDLE_W_BYTES, PADDLE_H, 0x00);
}

/* Ball: pixel coordinates (not byte-aligned like the bricks/paddle --
 * ball.s's sub-byte shift handles arbitrary x). 4x4 solid block
 * (ball.s's own BALL_IMAGE/BALL_H). */
#define BALL_W  4
#define BALL_H  4
#define BALL_X_MIN PLAYFIELD_LEFT_PX
#define BALL_X_MAX (PLAYFIELD_RIGHT_PX - BALL_W)
#define BALL_Y_MAX (200 - BALL_H)

#define BALL_START_X ((BALL_X_MIN + BALL_X_MAX) / 2)   /* centered between the pillars */
#define BALL_START_Y 100

/* Zero-initialized (plain BSS), real starting values assigned by
 * reset_ball() below at the start of main() -- NOT non-zero static
 * initializers. A real bug, caught while building this: crt0.s's own
 * header says exactly why ("no SDCC global-constructor 'gsinit'
 * support here") -- a non-zero initializer needs SDCC's _INITIALIZED/
 * _GSINIT/_INITIALIZER machinery to actually copy the value into place
 * at startup, which this project's crt0.s deliberately doesn't wire
 * up. Without it, these would silently start as whatever garbage bytes
 * happened to be in that RAM, not the intended position/velocity.
 * (Also independently surfaced as a build error the same way Phase 1's
 * bank_shadow-in-_DATA bug did: SDCC's linker defaults _DATA to $8000
 * with no --data-loc given.) */
static unsigned int bx;
static unsigned char by;
static signed char dx;
static signed char dy;

static void reset_ball(void)
{
    bx = BALL_START_X;
    by = BALL_START_Y;
    dx = 3;
    dy = 2;
}

static void draw_ball(void)
{
    ball_xor(VBASE + (unsigned int)by * ROW_BYTES + (bx >> 3), bx & 7);
}

/* Whole-pixel px byte-offset conversion, matching addr_at()'s own
 * xbyte convention -- paddle_x is already in bytes (see Phase 2/3).
 * Must return unsigned int, not unsigned char: paddle_x's byte range
 * (PADDLE_X_MIN..PADDLE_X_MAX, 4-66) times 8 reaches 528, which
 * doesn't fit in 8 bits -- a real bug caught here before building,
 * not after. */
static unsigned int paddle_left_px(unsigned char paddle_x)
{
    return (unsigned int)paddle_x << 3;
}

/* Checks whether the ball's PROPOSED new position (nbx,nby -- already
 * wall-bounced by the caller, not yet committed to bx/by) overlaps any
 * live brick. On the first overlap found: kills that brick (clears its
 * alive flag + erases it on screen), flips whichever of dx/dy has the
 * smaller penetration into the brick's rectangle (the axis "just
 * crossed" -- see this file's header for why that heuristic is
 * reliable at this ball speed), and returns 1. Returns 0 if no live
 * brick overlaps. At most one brick is ever killed per call -- two
 * bricks overlapping the same ball position in the same frame is
 * possible in principle (a fast enough ball / thin enough gaps) but not
 * handled specially; the next frame's check picks up any remaining
 * overlap on its own. */
static unsigned char check_brick_hit(unsigned int nbx, unsigned char nby)
{
    unsigned char r, c;

    /* Cheap early-out: skip the whole 60-brick scan once the ball is
     * outside the brick field's vertical span entirely -- true for
     * most of a rally (ball down near the paddle, or bricks already
     * cleared from that row). */
    if ((unsigned int)nby + BALL_H <= BRICK_PIXEL_Y0(0) ||
        (unsigned int)nby >= BRICK_PIXEL_Y1(BRICK_ROWS - 1)) {
        return 0;
    }

    for (r = 0; r < BRICK_ROWS; r++) {
        unsigned int y0 = BRICK_PIXEL_Y0(r);
        unsigned int y1 = BRICK_PIXEL_Y1(r);
        if ((unsigned int)nby + BALL_H <= y0 || (unsigned int)nby >= y1) {
            continue;
        }

        for (c = 0; c < BRICK_COLS; c++) {
            unsigned int x0, x1;
            int ox0, ox1, oy0, oy1, overlap_x, overlap_y;

            if (!bricks_alive[r][c]) continue;

            x0 = BRICK_PIXEL_X0(c);
            x1 = BRICK_PIXEL_X1(c);
            if (nbx + BALL_W <= x0 || nbx >= x1) continue;

            bricks_alive[r][c] = 0;
            bricks_remaining--;
            erase_brick(r, c);

            ox0 = (nbx > x0) ? (int)nbx : (int)x0;
            ox1 = (nbx + BALL_W < x1) ? (int)(nbx + BALL_W) : (int)x1;
            overlap_x = ox1 - ox0;

            oy0 = ((unsigned int)nby > y0) ? (int)nby : (int)y0;
            oy1 = ((unsigned int)nby + BALL_H < y1) ? (int)((unsigned int)nby + BALL_H) : (int)y1;
            overlap_y = oy1 - oy0;

            if (overlap_x < overlap_y) {
                dx = -dx;
            } else {
                dy = -dy;
            }
            return 1;
        }
    }
    return 0;
}

/* Ends the game: clears the screen, draws `msg` plus a "PRESS ESC"
 * hint (video RAM text, see this file's header for why not print()),
 * waits for ESC (poll_quit(), input.s -- same direct hardware poll the
 * quit key uses, NOT bdos(6,0xFF): that goes through BDOS's CONST,
 * which redraws CP/M's own text cursor into video RAM on every call
 * that doesn't see a key -- see input.s's own header for the bench-
 * found bug that caused), then returns to CP/M cleanly via BDOS
 * function 0 (warm boot) -- function 0 is a plain warm boot, not
 * console I/O, so it doesn't go through CONST/CONOUT at all. This is
 * the "real exit path" Phase 6 flagged as missing -- previously the
 * only way back to CP/M was a hardware reset. Never returns in
 * practice; the trailing for(;;) is defensive only, matching this
 * project's own style elsewhere (e.g. rom_emu.c's fallback loop) in
 * case BDOS's warm boot ever unexpectedly returned control here. */
#define MSG_X  30
#define MSG_Y  96
#define MSG2_Y 112

static void end_game(const char *msg)
{
    video_cls();
    draw_text(addr_at(MSG_Y, MSG_X), msg);
    draw_text(addr_at(MSG2_Y, MSG_X), "PRESS ESC");
    while (!poll_quit()) {
        /* wait for ESC */
    }
    bdos(0, 0);
    for (;;) {}
}

static void move_ball(unsigned char paddle_x)
{
    unsigned int new_bx;
    unsigned char new_by;
    unsigned int paddle_l, paddle_r;

    /* Wall bounce: left/right/top. (Bottom isn't a wall -- reaching the
     * paddle's row is handled below, either as a bounce or a miss.)
     *
     * X axis: detecting "would go past the left wall" by computing
     * bx+dx first and reinterpreting the unsigned result as signed is
     * safe here (same trick, now compared against BALL_X_MIN instead
     * of 0 now that a border pillar occupies x<BALL_X_MIN -- still
     * safe because bx's legitimate range (BALL_X_MIN..BALL_X_MAX,
     * roughly 32..604) sits nowhere near the 16-bit signed/unsigned
     * boundary (32768).
     *
     * Y axis: a REAL bug, found on real hardware, used to do the exact
     * same reinterpret trick on an 8-bit unsigned char -- but by's
     * legitimate range (0..BALL_Y_MAX=196) DOES cross the 8-bit
     * signed/unsigned boundary (128). Every legitimate by>=128 was
     * being read as "negative", snapping the ball back to y=0 right
     * around 2/3 of the way down the screen, every time (reported
     * exactly this way on real hardware -- 128/200 is close enough to
     * "2/3" to be the same bug, not a coincidence). Fixed by checking
     * the pre-addition condition directly (dy negative AND by too
     * small to absorb it) instead of reinterpreting a post-addition
     * result that can legitimately be large. */
    new_bx = bx + dx;
    if ((signed int)new_bx <= (signed int)BALL_X_MIN) {
        new_bx = BALL_X_MIN;
        dx = -dx;
    } else if (new_bx >= BALL_X_MAX) {
        new_bx = BALL_X_MAX;
        dx = -dx;
    }
    if (dy < 0 && by < (unsigned char)(-dy)) {
        new_by = 0;
        dy = -dy;
    } else {
        new_by = by + dy;
    }

    /* Brick collision: check_brick_hit() already flipped the right
     * axis of dx/dy on a hit -- cancel this frame's movement (stay at
     * the old bx/by) rather than trying to compute exactly where along
     * the reflected path the ball should land. The ball moves away
     * cleanly next frame using the just-reflected velocity; losing one
     * frame of motion is imperceptible at this speed and avoids the
     * ball visually sinking into where the brick used to be. */
    if (check_brick_hit(new_bx, new_by)) {
        new_bx = bx;
        new_by = by;
        if (bricks_remaining == 0) {
            end_game("YOU WIN!");
        }
    }

    /* Paddle row reached: bounce if the ball's x-range overlaps the
     * paddle's, otherwise it's a miss -- decrements lives (Phase 7)
     * and ends the game once they run out, or just resets the ball to
     * the start position if any remain. */
    if (new_by >= PADDLE_Y - BALL_H) {
        paddle_l = paddle_left_px(paddle_x);
        paddle_r = paddle_l + (PADDLE_W_BYTES << 3);
        if (bx + BALL_W > paddle_l && bx < paddle_r) {
            new_by = PADDLE_Y - BALL_H;
            dy = -dy;
        } else if (new_by > BALL_Y_MAX) {
            draw_ball();       /* erase at the old position */
            lives--;
            if (lives == 0) {
                end_game("GAME OVER");
            }
            update_lives_hud();
            reset_ball();      /* also a real bug fix along the way:
                                 * the inline version this replaced set
                                 * dy negative with a comment claiming
                                 * that meant "back down toward the
                                 * paddle" -- backwards, since y
                                 * increases downward here; reset_ball()
                                 * itself has always used the correct
                                 * positive (downward) dy=2 */
            draw_ball();
            return;
        }
    }

    draw_ball();               /* erase at the old position (XOR) */
    bx = new_bx;
    by = new_by;
    draw_ball();               /* draw at the new position */
}

void main(void)
{
    unsigned char paddle_x = PADDLE_X_BYTE;
    unsigned char keys;

    video_cls();
    reset_ball();
    reset_bricks();
    lives = LIVES_START;
    draw_border();
    draw_bricks();
    draw_paddle(paddle_x);
    draw_ball();
    draw_hud();

    for (;;) {
        /* Quit key -- poll_quit() (input.s) is a direct hardware read
         * of ESC, same technique as poll_lr()'s own LEFT/RIGHT read
         * just below, deliberately NOT bdos(6,0xFF) -- see this file's
         * header comment for the real bug that caused (BDOS's CONST
         * redrawing CP/M's own text cursor into video RAM on every
         * poll that doesn't see a key). Doesn't conflict with
         * poll_lr(): both are direct port reads of the same keyboard-
         * matrix hardware, just different rows, run strictly
         * sequentially here (no interrupts involved). */
        if (poll_quit()) {
            end_game("QUIT");
        }

        keys = poll_lr();
        if ((keys & KEY_LEFT) && paddle_x > PADDLE_X_MIN) {
            erase_paddle(paddle_x);
            paddle_x--;
            draw_paddle(paddle_x);
        } else if ((keys & KEY_RIGHT) && paddle_x < PADDLE_X_MAX) {
            erase_paddle(paddle_x);
            paddle_x++;
            draw_paddle(paddle_x);
        }
        move_ball(paddle_x);
        delay_short();
    }
}
