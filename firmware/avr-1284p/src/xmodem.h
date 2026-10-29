/* xmodem.h -- XMODEM-CRC (128-byte block) receiver over usart.c. */
#ifndef XMODEM_H
#define XMODEM_H

#include <stdint.h>

/* Receive a file into buf (capacity bytes). Returns the number of bytes
 * received (always a multiple of 128 -- trailing SUB/0x1A pad bytes from
 * the sender are NOT stripped, caller trims if needed), or -1 on
 * handshake timeout / transfer error / sender abort / buffer overrun. */
int32_t xmodem_receive(uint8_t *buf, uint32_t capacity);

#endif /* XMODEM_H */
