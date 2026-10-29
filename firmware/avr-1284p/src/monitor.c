/* monitor.c -- CLI over usart.c. See monitor.h / plan.md.
 *
 * Two address spaces are exposed here, deliberately kept separate:
 *  - `d`/`w`/`f`/`c` address the 1284P's own internal SRAM directly (raw
 *    pointer access, bounds-checked against RAMSTART/RAMEND from
 *    avr/io.h) -- "read/write to the 16K RAM in the 1284p" per CLAUDE.md.
 *    General-purpose debug tool, not tied to any particular buffer.
 *  - `rd`/`rw`/`rf`/`rc` address the ROM-emulation upload buffer using
 *    offsets 0000-1FFF relative to the buffer's own start -- matching the
 *    Z80's own ROM address space once emulation starts (memory-map.md:
 *    the ROM window is Z80 addresses 0x0000-0x1FFF). `rd 0100` shows
 *    exactly the byte the Z80 will fetch from address 0x0100, regardless
 *    of wherever the buffer actually lives in the 1284P's real SRAM --
 *    see rombuf.ld for why that raw address is fixed but not something
 *    the user needs to know or type.
 * Phase 3 added `z` (assert/release Z80 _RESET) and `a` (sample the Z80
 * address bus, A0-A13 only -- A14/A15 aren't wired to the AVR). Phase 4
 * adds `s` (start ROM emulation, see rom_emu.c) now that the data latch/
 * WAIT/mode latch exist -- there is still no data-bus peek/poke here,
 * since the shared bus is only ever driven by the AVR indirectly
 * (rom_emu.c calls databus_send(), hardware gates whether the 74HC595
 * actually drives the bus -- a 74LS373 did this same gated-latch job
 * until 2026-09-16, see pins.h/databus.h for the swap).
 * `sb` (2026-09-11) loads the flash-embedded copy of the CP/M bootstrap
 * (src/stage1_rom.h, generated from stage1.bin) into the ROM buffer and
 * starts -- the same path monitor_run() takes automatically when main.c
 * reports the PD0 boot-mode strap pulled low (no serial adapter = boot
 * straight to CP/M).
 *
 * All message text goes out via usart_puts_P(PSTR(...)), not usart_puts()
 * -- see open-questions.md #7 / usart.h: plain string literals live in
 * both flash and RAM on AVR (Harvard architecture, a normal pointer
 * dereference can't read flash), so without PROGMEM the growing help/
 * error text would keep eating into the ROM buffer's RAM headroom.
 */
#include <avr/io.h>
#include <avr/pgmspace.h>
#include <stdint.h>
#include <string.h>
#include "usart.h"
#include "xmodem.h"
#include "monitor.h"
#include "pins.h"
#include "rom_emu.h"
#include "video.h"
#include "video_fetch.h"
#include "stage1_rom.h"		/* generated: stage1_rom[] PROGMEM, STAGE1_ROM_SIZE */

/* Reserved ROM-emulation upload buffer (up to 8K, per CLAUDE.md /
 * memory-map.md). Pinned to a fixed real SRAM address by rombuf.ld (see
 * that file for why); NOT auto-zeroed by the C runtime the way normal
 * .bss is, since it lives outside __bss_start..__bss_end -- monitor_run()
 * memsets it explicitly once at startup instead. xmodem writes land here. */
#define ROM_BUF_SIZE 8192
static uint8_t rom_buf[ROM_BUF_SIZE] __attribute__((section(".rombuf")));

#define LINE_MAX 64
static char line[LINE_MAX];

static uint16_t hex_to_u16(const char *s, uint8_t *ok)
{
    uint16_t v = 0;
    uint8_t any = 0;
    while (*s) {
        char c = *s;
        uint8_t d;
        if (c >= '0' && c <= '9') d = (uint8_t)(c - '0');
        else if (c >= 'a' && c <= 'f') d = (uint8_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = (uint8_t)(c - 'A' + 10);
        else break;
        v = (uint16_t)((v << 4) | d);
        any = 1;
        s++;
    }
    if (ok) *ok = any;
    return v;
}

static char *next_tok(char **cursor)
{
    char *s = *cursor;
    while (*s == ' ') s++;
    if (!*s) { *cursor = s; return 0; }
    char *start = s;
    while (*s && *s != ' ') s++;
    if (*s) { *s = 0; s++; }
    *cursor = s;
    return start;
}

static void read_line(void)
{
    uint8_t i = 0;
    for (;;) {
        uint8_t c = usart_getc();
        if (c == '\r' || c == '\n') {
            usart_puts_P(PSTR("\r\n"));
            line[i] = 0;
            return;
        }
        if ((c == 0x08 || c == 0x7F) && i > 0) { /* backspace / DEL */
            i--;
            usart_puts_P(PSTR("\b \b"));
            continue;
        }
        if (c >= 0x20 && c < 0x7F && i < LINE_MAX - 1) {
            line[i++] = (char)c;
            usart_putc(c);
        }
    }
}

static void cmd_help(void)
{
    usart_puts_P(PSTR(
        "Commands:\r\n"
        "  help                    this text\r\n"
        "ROM buffer (offset 0000-1FFF, matches the Z80's own ROM address once\r\n"
        "emulation starts -- see memory-map.md):\r\n"
        "  rd <off> [len]          hex dump (default len=100)\r\n"
        "  rw <off> <byte>         write one byte\r\n"
        "  rf <off> <len> <byte>   fill range with byte\r\n"
        "  rc <off> <len>          CRC16-CCITT of range\r\n"
        "  x                       receive file via XMODEM-CRC into ROM buffer\r\n"
        "  i                       show ROM buffer's real SRAM address (debug only)\r\n"
        "  s                       start ROM emulation, releases Z80 _RESET\r\n"
        "                          (a key aborts back here, only during startup)\r\n"
        "  sb                      load the flash-embedded stage1 (CP/M bootstrap)\r\n"
        "                          into the ROM buffer and start -- same as the\r\n"
        "                          PD0-strap autoboot\r\n"
        "General 1284P internal SRAM (raw address, for low-level debugging):\r\n"
        "  d <addr> [len]          hex dump (default len=100)\r\n"
        "  w <addr> <byte>         write one byte\r\n"
        "  f <addr> <len> <byte>   fill range with byte\r\n"
        "  c <addr> <len>          CRC16-CCITT of range\r\n"
        "Z80 bus (Phase 3+, no 373/WAIT/mode-latch yet -- no data-bus access):\r\n"
        "  z <0|1>                 0=hold Z80 in _RESET, 1=release it\r\n"
        "  a [n]                   sample A0-A13 n times (hex, default 1)\r\n"
        "  vf [addr14]             Phase 6a: one video-fetch burst (_BUSRQ +\r\n"
        "                          80-byte address ramp + SH_LD), default addr 0000\r\n"
        "All numbers are hex, no 0x prefix. d/w/f/c range: 0100-40FF.\r\n"
        "rd/rw/rf/rc range: 0000-1FFF.\r\n"
    ));
}

/* -------- shared byte-array primitives (used by both address spaces) -- */

static void hexdump(uint16_t label_addr, const uint8_t *p, uint16_t len)
{
    for (uint16_t off = 0; off < len; off = (uint16_t)(off + 16)) {
        usart_puthex16((uint16_t)(label_addr + off));
        usart_puts_P(PSTR("  "));
        uint16_t rowlen = (uint16_t)((len - off) < 16 ? (len - off) : 16);
        for (uint16_t i = 0; i < 16; i++) {
            if (i < rowlen) {
                usart_puthex8(p[off + i]);
                usart_putc(' ');
            } else {
                usart_puts_P(PSTR("   "));
            }
        }
        usart_puts_P(PSTR(" "));
        for (uint16_t i = 0; i < rowlen; i++) {
            uint8_t b = p[off + i];
            usart_putc((uint8_t)((b >= 0x20 && b < 0x7F) ? b : '.'));
        }
        usart_puts_P(PSTR("\r\n"));
    }
}

static uint16_t crc16_bytes(const uint8_t *p, uint16_t len)
{
    uint16_t crc = 0;
    for (uint16_t i = 0; i < len; i++) {
        crc = (uint16_t)(crc ^ ((uint16_t)p[i] << 8));
        for (uint8_t bit = 0; bit < 8; bit++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

/* -------- d/w/f/c: raw 1284P internal SRAM ------------------------------ */

static uint8_t addr_in_range(uint16_t addr, uint16_t len)
{
    if (addr < RAMSTART || addr > RAMEND) return 0;
    if (len == 0) return 0;
    if ((uint32_t)addr + (uint32_t)len - 1 > RAMEND) return 0;
    return 1;
}

static void cmd_dump(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *l = next_tok(&rest);
    if (!a) { usart_puts_P(PSTR("usage: d <addr> [len]\r\n")); return; }
    uint16_t addr = hex_to_u16(a, &ok);
    if (!ok) { usart_puts_P(PSTR("bad address\r\n")); return; }
    uint16_t len = 0x100;
    if (l) {
        len = hex_to_u16(l, &ok);
        if (!ok) { usart_puts_P(PSTR("bad length\r\n")); return; }
    }
    if (!addr_in_range(addr, len)) { usart_puts_P(PSTR("out of range (0100-40FF)\r\n")); return; }
    hexdump(addr, (const uint8_t *)(uintptr_t)addr, len);
}

static void cmd_write(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *v = next_tok(&rest);
    if (!a || !v) { usart_puts_P(PSTR("usage: w <addr> <byte>\r\n")); return; }
    uint16_t addr = hex_to_u16(a, &ok);
    if (!ok || !addr_in_range(addr, 1)) { usart_puts_P(PSTR("bad/out-of-range address\r\n")); return; }
    uint16_t val = hex_to_u16(v, &ok);
    if (!ok || val > 0xFF) { usart_puts_P(PSTR("bad byte value\r\n")); return; }
    *(volatile uint8_t *)(uintptr_t)addr = (uint8_t)val;
    usart_puts_P(PSTR("ok\r\n"));
}

static void cmd_fill(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *l = next_tok(&rest);
    char *v = next_tok(&rest);
    if (!a || !l || !v) { usart_puts_P(PSTR("usage: f <addr> <len> <byte>\r\n")); return; }
    uint16_t addr = hex_to_u16(a, &ok);
    if (!ok) { usart_puts_P(PSTR("bad address\r\n")); return; }
    uint16_t len = hex_to_u16(l, &ok);
    if (!ok) { usart_puts_P(PSTR("bad length\r\n")); return; }
    uint16_t val = hex_to_u16(v, &ok);
    if (!ok || val > 0xFF) { usart_puts_P(PSTR("bad byte value\r\n")); return; }
    if (!addr_in_range(addr, len)) { usart_puts_P(PSTR("out of range (0100-40FF)\r\n")); return; }
    for (uint16_t i = 0; i < len; i++) {
        *(volatile uint8_t *)(uintptr_t)(addr + i) = (uint8_t)val;
    }
    usart_puts_P(PSTR("ok\r\n"));
}

static void cmd_crc(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *l = next_tok(&rest);
    if (!a || !l) { usart_puts_P(PSTR("usage: c <addr> <len>\r\n")); return; }
    uint16_t addr = hex_to_u16(a, &ok);
    if (!ok) { usart_puts_P(PSTR("bad address\r\n")); return; }
    uint16_t len = hex_to_u16(l, &ok);
    if (!ok) { usart_puts_P(PSTR("bad length\r\n")); return; }
    if (!addr_in_range(addr, len)) { usart_puts_P(PSTR("out of range (0100-40FF)\r\n")); return; }
    usart_puts_P(PSTR("CRC16-CCITT: "));
    usart_puthex16(crc16_bytes((const uint8_t *)(uintptr_t)addr, len));
    usart_puts_P(PSTR("\r\n"));
}

/* -------- rd/rw/rf/rc: ROM buffer, offset 0000-1FFF, Z80-ROM-relative -- */

static uint8_t rom_off_in_range(uint16_t off, uint16_t len)
{
    if (len == 0) return 0;
    if ((uint32_t)off + (uint32_t)len > ROM_BUF_SIZE) return 0;
    return 1;
}

static void cmd_rom_dump(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *l = next_tok(&rest);
    if (!a) { usart_puts_P(PSTR("usage: rd <off> [len]\r\n")); return; }
    uint16_t off = hex_to_u16(a, &ok);
    if (!ok) { usart_puts_P(PSTR("bad offset\r\n")); return; }
    uint16_t len = 0x100;
    if (l) {
        len = hex_to_u16(l, &ok);
        if (!ok) { usart_puts_P(PSTR("bad length\r\n")); return; }
    }
    if (!rom_off_in_range(off, len)) { usart_puts_P(PSTR("out of range (0000-1FFF)\r\n")); return; }
    hexdump(off, &rom_buf[off], len);
}

static void cmd_rom_write(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *v = next_tok(&rest);
    if (!a || !v) { usart_puts_P(PSTR("usage: rw <off> <byte>\r\n")); return; }
    uint16_t off = hex_to_u16(a, &ok);
    if (!ok || !rom_off_in_range(off, 1)) { usart_puts_P(PSTR("bad/out-of-range offset\r\n")); return; }
    uint16_t val = hex_to_u16(v, &ok);
    if (!ok || val > 0xFF) { usart_puts_P(PSTR("bad byte value\r\n")); return; }
    rom_buf[off] = (uint8_t)val;
    usart_puts_P(PSTR("ok\r\n"));
}

static void cmd_rom_fill(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *l = next_tok(&rest);
    char *v = next_tok(&rest);
    if (!a || !l || !v) { usart_puts_P(PSTR("usage: rf <off> <len> <byte>\r\n")); return; }
    uint16_t off = hex_to_u16(a, &ok);
    if (!ok) { usart_puts_P(PSTR("bad offset\r\n")); return; }
    uint16_t len = hex_to_u16(l, &ok);
    if (!ok) { usart_puts_P(PSTR("bad length\r\n")); return; }
    uint16_t val = hex_to_u16(v, &ok);
    if (!ok || val > 0xFF) { usart_puts_P(PSTR("bad byte value\r\n")); return; }
    if (!rom_off_in_range(off, len)) { usart_puts_P(PSTR("out of range (0000-1FFF)\r\n")); return; }
    memset(&rom_buf[off], (int)val, len);
    usart_puts_P(PSTR("ok\r\n"));
}

static void cmd_rom_crc(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    char *l = next_tok(&rest);
    if (!a || !l) { usart_puts_P(PSTR("usage: rc <off> <len>\r\n")); return; }
    uint16_t off = hex_to_u16(a, &ok);
    if (!ok) { usart_puts_P(PSTR("bad offset\r\n")); return; }
    uint16_t len = hex_to_u16(l, &ok);
    if (!ok) { usart_puts_P(PSTR("bad length\r\n")); return; }
    if (!rom_off_in_range(off, len)) { usart_puts_P(PSTR("out of range (0000-1FFF)\r\n")); return; }
    usart_puts_P(PSTR("CRC16-CCITT: "));
    usart_puthex16(crc16_bytes(&rom_buf[off], len));
    usart_puts_P(PSTR("\r\n"));
}

static void cmd_info(void)
{
    usart_puts_P(PSTR("ROM buffer: real SRAM addr="));
    usart_puthex16((uint16_t)(uintptr_t)rom_buf);
    usart_puts_P(PSTR(" size=2000 (8192 bytes). Use rd/rw/rf/rc with offset 0000-1FFF\r\n"
                       "instead of this address -- see 'help'.\r\n"));
}

static void cmd_xmodem(void)
{
    usart_puts_P(PSTR("Send file now (XMODEM-CRC)...\r\n"));
    int32_t n = xmodem_receive(rom_buf, ROM_BUF_SIZE);
    if (n < 0) {
        usart_puts_P(PSTR("\r\nxmodem failed/aborted\r\n"));
        return;
    }
    usart_puts_P(PSTR("\r\nreceived "));
    usart_puthex16((uint16_t)n);
    usart_puts_P(PSTR(" bytes into ROM buffer (offset 0000-"));
    usart_puthex16((uint16_t)(n - 1));
    usart_puts_P(PSTR("). CRC16-CCITT: "));
    usart_puthex16(crc16_bytes(rom_buf, (uint16_t)n));
    usart_puts_P(PSTR("\r\n"));
}

/* -------- z/a: Z80 bus (Phase 3+) ---------------------------------------- */

static void cmd_z80_reset(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    if (!a) { usart_puts_P(PSTR("usage: z <0|1>  (0=hold Z80 in reset, 1=release)\r\n")); return; }
    uint16_t v = hex_to_u16(a, &ok);
    if (!ok || v > 1) { usart_puts_P(PSTR("bad value, expected 0 or 1\r\n")); return; }
    if (v) {
        Z80_CTRL_PORT |= (1 << BIT_RESET);
        usart_puts_P(PSTR("Z80 _RESET released\r\n"));
    } else {
        Z80_CTRL_PORT &= (uint8_t)~(1 << BIT_RESET);
        usart_puts_P(PSTR("Z80 _RESET asserted (held in reset)\r\n"));
    }
}

static void cmd_addr(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    uint16_t n = 1;
    if (a) {
        n = hex_to_u16(a, &ok);
        if (!ok || n == 0) { usart_puts_P(PSTR("bad count\r\n")); return; }
    }
    for (uint16_t i = 0; i < n; i++) {
        usart_puthex16(z80_read_addr());
        usart_putc(' ');
        if ((i & 0x07) == 0x07) usart_puts_P(PSTR("\r\n"));
    }
    usart_puts_P(PSTR("\r\n"));
}

static void cmd_video_fetch(char *rest)
{
    uint8_t ok;
    char *a = next_tok(&rest);
    uint16_t addr14 = 0;
    if (a) {
        addr14 = hex_to_u16(a, &ok);
        if (!ok) { usart_puts_P(PSTR("bad address\r\n")); return; }
    }
    addr14 &= 0x3FFF;
    /* Standalone Phase 6a smoke test (open-questions.md #3): exercises
     * _BUSRQ + the address ramp + SH_LD pulsing in isolation, same
     * bring-up philosophy as the earlier "fat pixel" test -- this does
     * NOT check that the shifted-out data is correct (that needs a
     * logic analyzer on QH, or the Z80 having pre-written a known
     * pattern here first), only that the timing/sequencing runs at all
     * without hanging the Z80. Safe to call any time the Z80 is
     * running, regardless of what mode it's in. */
    usart_puts_P(PSTR("video_fetch_line: addr14="));
    usart_puthex16(addr14);
    usart_puts_P(PSTR(" ...\r\n"));
    video_fetch_line(addr14);
    usart_puts_P(PSTR("done.\r\n"));
}

static void cmd_start(void)
{
    usart_puts_P(PSTR(
        "starting ROM emulation -- releasing Z80 _RESET.\r\n"
        "send any byte to abort and return here.\r\n"
    ));
    rom_emu_exit_t why = rom_emu_run(rom_buf, ROM_BUF_SIZE - 1);
    if (why == ROM_EMU_EXIT_MAGIC) {
        video_run();
    }
}

/* Load the flash-embedded CP/M bootstrap (src/stage1_rom.h, generated
 * from firmware/z80-boot-rom/cpm/stage1.bin) into the ROM buffer and run
 * the *unchanged* ROM-emulation path. Shared by the `sb` command and by
 * monitor_run()'s PD0-strap autoboot. Returns rom_emu_run()'s exit code
 * so the caller can distinguish MAGIC (handled here -> video_run) from
 * ABORT (caller falls through to the CLI). The keypress-abort inside
 * rom_emu_run is only reachable during stage1's brief ROM->SRAM copy --
 * stage1 reads the magic address very early, before any SD access -- so
 * once it has started there is no way back but a hardware reset (and a
 * connected serial adapter forcing the monitor via the PD0 strap). */
static rom_emu_exit_t start_from_stage1(void)
{
    memset(rom_buf, 0, ROM_BUF_SIZE);
    memcpy_P(rom_buf, stage1_rom, STAGE1_ROM_SIZE);

    usart_puts_P(PSTR("built-in stage1: "));
    usart_puthex16(STAGE1_ROM_SIZE);
    usart_puts_P(PSTR(" bytes, CRC "));
    usart_puthex16(crc16_bytes(rom_buf, STAGE1_ROM_SIZE));
    usart_puts_P(PSTR("\r\nstarting ROM emulation -- releasing Z80 _RESET.\r\n"
                      "send a byte now to abort back here (startup only).\r\n"));

    rom_emu_exit_t why = rom_emu_run(rom_buf, ROM_BUF_SIZE - 1);
    if (why == ROM_EMU_EXIT_MAGIC) {
        video_run();
    }
    return why;
}

static void cmd_sb(void)
{
    (void)start_from_stage1();
}

static void dispatch(void)
{
    char *cursor = line;
    char *cmd = next_tok(&cursor);
    if (!cmd) return;
    if (!strcmp_P(cmd, PSTR("help")) || !strcmp_P(cmd, PSTR("?"))) cmd_help();
    else if (!strcmp_P(cmd, PSTR("d"))) cmd_dump(cursor);
    else if (!strcmp_P(cmd, PSTR("w"))) cmd_write(cursor);
    else if (!strcmp_P(cmd, PSTR("f"))) cmd_fill(cursor);
    else if (!strcmp_P(cmd, PSTR("c"))) cmd_crc(cursor);
    else if (!strcmp_P(cmd, PSTR("rd"))) cmd_rom_dump(cursor);
    else if (!strcmp_P(cmd, PSTR("rw"))) cmd_rom_write(cursor);
    else if (!strcmp_P(cmd, PSTR("rf"))) cmd_rom_fill(cursor);
    else if (!strcmp_P(cmd, PSTR("rc"))) cmd_rom_crc(cursor);
    else if (!strcmp_P(cmd, PSTR("i"))) cmd_info();
    else if (!strcmp_P(cmd, PSTR("x"))) cmd_xmodem();
    else if (!strcmp_P(cmd, PSTR("s"))) cmd_start();
    else if (!strcmp_P(cmd, PSTR("sb"))) cmd_sb();
    else if (!strcmp_P(cmd, PSTR("z"))) cmd_z80_reset(cursor);
    else if (!strcmp_P(cmd, PSTR("a"))) cmd_addr(cursor);
    else if (!strcmp_P(cmd, PSTR("vf"))) cmd_video_fetch(cursor);
    else usart_puts_P(PSTR("unknown command, try 'help'\r\n"));
}

void monitor_run(uint8_t autoboot)
{
    memset(rom_buf, 0, ROM_BUF_SIZE); /* not auto-zeroed, see top comment */
    usart_puts_P(PSTR("\r\n\r\nZ80+1284P monitor -- Phase 2\r\n"));

    if (autoboot) {
        /* PD0 boot-mode strap pulled low in main.c (no serial adapter):
         * boot the Z80 straight from the flash-embedded stage1. On a
         * MAGIC exit start_from_stage1() runs video_run(), which itself
         * returns to us on any UART byte; on an ABORT it returns
         * immediately. Either way we then fall into the CLI below. */
        usart_puts_P(PSTR("[strap] autoboot from built-in stage1\r\n"));
        start_from_stage1();
        usart_puts_P(PSTR("\r\n[autoboot ended -- monitor]\r\n"));
    }

    usart_puts_P(PSTR("type 'help'\r\n"));
    for (;;) {
        usart_puts_P(PSTR("> "));
        read_line();
        dispatch();
    }
}
