#include <avr/io.h>
#include <avr/pgmspace.h>
#include "usart.h"

void usart_init(void)
{
    uint16_t ubrr = (uint16_t)(((F_CPU + 4UL * USART_BAUD) / (8UL * USART_BAUD)) - 1);
    UBRR0H = (uint8_t)(ubrr >> 8);
    UBRR0L = (uint8_t)ubrr;
    UCSR0A = (1 << U2X0);                      /* double speed, see usart.h */
    UCSR0B = (1 << RXEN0) | (1 << TXEN0);
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);    /* 8 data bits, 1 stop, no parity */
}

void usart_putc(uint8_t c)
{
    while (!(UCSR0A & (1 << UDRE0))) {}
    UDR0 = c;
}

void usart_puts(const char *s)
{
    while (*s) usart_putc((uint8_t)*s++);
}

void usart_puts_P(const char *s)
{
    uint8_t c;
    while ((c = pgm_read_byte(s++)) != 0) usart_putc(c);
}

uint8_t usart_getc(void)
{
    while (!(UCSR0A & (1 << RXC0))) {}
    return UDR0;
}

int16_t usart_getc_timeout(uint16_t timeout_ms)
{
    /* Tight-poll RXC0 every iteration -- NOT poll-then-sleep. At 38400
     * baud (the original rate; ~87us at today's 115200), back-to-back
     * bytes inside an XMODEM block arrive ~260us apart, and the USART only buffers ~1 extra byte in hardware; a
     * sleep of even 1ms between checks silently drops/overruns bytes
     * that arrive during the sleep (this was a real bug here that broke
     * every XMODEM transfer -- see bring-up-log.md Phase 2). Approximate
     * the timeout with a cycle-counted iteration budget instead of an
     * actual delay, so every iteration re-checks RXC0 with no blocking
     * gap. The per-iteration cost (~6 cycles: SFR read, branch, dec,
     * branch) means this budget is a rough approximation, not a precise
     * timer -- fine for XMODEM, which only needs "on the order of Nms". */
    uint32_t iters = (uint32_t)timeout_ms * (F_CPU / 1000UL / 6UL);
    while (iters--) {
        if (UCSR0A & (1 << RXC0)) return UDR0;
    }
    return -1;
}

static char hex_digit(uint8_t nyb)
{
    nyb &= 0x0F;
    return (char)(nyb < 10 ? ('0' + nyb) : ('A' + nyb - 10));
}

void usart_puthex8(uint8_t v)
{
    usart_putc((uint8_t)hex_digit((uint8_t)(v >> 4)));
    usart_putc((uint8_t)hex_digit(v));
}

void usart_puthex16(uint16_t v)
{
    usart_puthex8((uint8_t)(v >> 8));
    usart_puthex8((uint8_t)v);
}
