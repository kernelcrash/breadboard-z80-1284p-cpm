/* pins.h — generated from docs/pin-map.md (single source of truth).
 * ATmega1284P-PU DIP-40. 16 MHz external clock. 27 of 32 GPIO allocated
 * (2026-09-16: down from 32/32 -- the 74LS373->74HC595 swap freed 5:
 * PB0-PB3, PB6). Regenerate/edit when pin-map.md changes.
 */
#ifndef PINS_H
#define PINS_H

/* Address bus A0-A7: PORTA, bidirectional */
#define ADDR_LO_PORT  PORTA
#define ADDR_LO_DDR   DDRA
#define ADDR_LO_PIN   PINA
#define ADDR_LO_MASK  0xFF

/* Address bus A8-A13: PC0-PC5, bidirectional (JTAG disabled by fuse) */
#define ADDR_HI_PORT  PORTC
#define ADDR_HI_DDR   DDRC
#define ADDR_HI_PIN   PINC
#define ADDR_HI_MASK  0x3F

/* Data bus: serial to a 74HC595 (2026-09-16, replaced a parallel
 * 74LS373 latch -- see docs/gate-equations.md §4 and
 * docs/373-gates-sram-wiring.md for the swap's full history/reasoning,
 * and 74HC595-plan.md for why it's safe: the video-fetch burst, the
 * only genuinely hard-real-time path in this design, never touches
 * this bus at all). SER/SRCLK ride the AVR's own hardware SPI
 * peripheral -- MOSI/SCK, the same physical pins the old parallel
 * D5/D7 used, just driven by the SPI peripheral now instead of plain
 * GPIO. RCLK is a plain GPIO, pulsed once per byte after the SPI shift
 * completes (see databus.c) to latch the shifted bits into the 595's
 * output register. PB0-PB3 and PB6 (old D0-D3, D6) are now free --
 * not reused for anything yet. */
#define DATA_SPI_PORT PORTB
#define DATA_SPI_DDR  DDRB
#define BIT_MOSI      5   /* PB5  out  74HC595 SER   (DIP 6, was D5) */
#define BIT_SCK       7   /* PB7  out  74HC595 SRCLK (DIP 8, was D7) */
#define BIT_RCLK      4   /* PB4  out  74HC595 RCLK  (DIP 5, was D4/SS) */

/* Z80 control, PORTD */
#define Z80_CTRL_PORT PORTD
#define Z80_CTRL_DDR  DDRD
#define Z80_CTRL_PIN  PIND

#define BIT_BUSREQ    7   /* PD7  out  _BUSRQ   (DIP 21) */
#define BIT_RD        6   /* PD6  bidir _RD     (DIP 20) */
#define BIT_SH_LD     5   /* PD5  out  74LS166 SH_LD (DIP 19) -- 2026-09-05:
                           * this pin is no longer wired to the Z80's
                           * _IORQ at all (physically disconnected on the
                           * breadboard, pull-up removed) -- dedicated
                           * permanently to SH_LD instead, after PD3/
                           * wait_rel turned out fundamentally unable to
                           * serve both that role and SH_LD at once
                           * (video_fetch.c). DDR is output permanently
                           * (main.c), never toggled per-burst the way
                           * _MREQ/_RD/the address bus are.
                           *
                           * 2026-09-21: the REAL SH_LD moved off this pin
                           * entirely, onto PB6/OC3A (hardware Timer3 Fast
                           * PWM -- see sync.c/shld_test.c). PD5 is
                           * physically disconnected from the 74LS166 now.
                           * This constant and the pin's permanent-output
                           * setup in main.c only matter to video_fetch.c's
                           * legacy debug-only path (monitor's "vf"
                           * command) -- that path's own SH_LD pulse no
                           * longer reaches real hardware. */
#define BIT_MREQ      4   /* PD4  bidir _MREQ   (DIP 18) */
#define BIT_WAITREL   3   /* PD3  out   WAIT-release (DIP 17) */
#define BIT_RESET     2   /* PD2  out   Z80 _RESET (DIP 16) */
#define BIT_UART_TX   1   /* PD1  out   USART0 TXD (DIP 15) */
#define BIT_UART_RX   0   /* PD0  in    USART0 RXD (DIP 14) */

/* Sync: PC6/PC7, timer-ISR toggled (no free OC pins on DIP-40) */
#define HSYNC_PIN     6   /* PC6  out  HSYNC  (DIP 28) */
#define VSYNC_PIN     7   /* PC7  out  VSYNC  (DIP 29) */

/* Convenience: read the 14 Z80 address bits (valid only when the Z80
 * drives the bus: ROM emulation / IO virtualization).
 * Returns A0-A13 in a uint16_t, A0 in bit 0.
 */
static inline uint16_t z80_read_addr(void)
{
    return (uint16_t)ADDR_LO_PIN | ((uint16_t)(ADDR_HI_PIN & ADDR_HI_MASK) << 8);
}

#endif /* PINS_H */
