/* usart.h -- USART0 driver (host monitor link). Fixed hardware pins
 * PD0=RXD0 (in), PD1=TXD0 (out) -- see pins.h. RXEN0/TXEN0 override normal
 * port operation on those pins automatically (Atmel-42719C, UCSR0B bit
 * descriptions), so no DDR setup is needed here.
 */
#ifndef USART_H
#define USART_H

#include <stdint.h>

/* 115200 8N1, using double-speed mode (U2X0=1): UBRR = round(F_CPU/(8*BAUD))-1
 * = 16000000/(8*115200) -> 17.4 -> 17, minus 1 = 16; actual baud =
 * 16000000/(8*17) = 117647, error = +2.1%. That is the best 16 MHz can do
 * at this rate (normal speed would be +8.5%, too far off to frame reliably)
 * and is the same setup Arduino uses at 115200/16 MHz. Previously 38400
 * (+0.16% error); lower rates are more tolerant of a noisy or marginal
 * adapter -- change USART_BAUD here if you need that, usart.c adapts. */
#define USART_BAUD 115200UL

void usart_init(void);
void usart_putc(uint8_t c);
void usart_puts(const char *s);
/* Like usart_puts, but reads from flash (PROGMEM) instead of RAM -- use
 * with PSTR("literal") so message text doesn't also cost RAM. AVR can't
 * read flash through a normal pointer dereference (separate address
 * spaces, only the LPM instruction can fetch from flash), which is why
 * this needs to be a distinct function using pgm_read_byte() rather than
 * just usart_puts() working on a flash pointer. */
void usart_puts_P(const char *s);
uint8_t usart_getc(void);                        /* blocking */
int16_t usart_getc_timeout(uint16_t timeout_ms);  /* -1 on timeout */
void usart_puthex8(uint8_t v);
void usart_puthex16(uint16_t v);

#endif /* USART_H */
