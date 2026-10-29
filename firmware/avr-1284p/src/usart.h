/* usart.h -- USART0 driver (host monitor link). Fixed hardware pins
 * PD0=RXD0 (in), PD1=TXD0 (out) -- see pins.h. RXEN0/TXEN0 override normal
 * port operation on those pins automatically (Atmel-42719C, UCSR0B bit
 * descriptions), so no DDR setup is needed here.
 */
#ifndef USART_H
#define USART_H

#include <stdint.h>

/* 38400 8N1: UBRR = F_CPU/(16*BAUD)-1 = 16000000/(16*38400)-1 = 25,
 * actual baud = 16000000/(16*26) = 38461, error = +0.16% -- well within
 * the ~2% tolerance USARTs need for reliable framing. Chosen over faster
 * rates (57600/115200) specifically for that low error margin; see
 * open-questions.md #5. */
#define USART_BAUD 38400UL

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
