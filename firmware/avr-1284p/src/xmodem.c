/* xmodem.c -- XMODEM-CRC receiver (128-byte blocks), CRC16-CCITT
 * (poly 0x1021, init 0), matching the standard XMODEM-CRC protocol used
 * by lrzsz/sx/most terminal programs' "send file (xmodem-crc)".
 */
#include "usart.h"
#include "xmodem.h"

#define SOH            0x01
#define EOT            0x04
#define ACK            0x06
#define NAK            0x15
#define CAN            0x18
#define CRC_CHAR       'C'
#define BLOCK_SIZE     128
#define MAX_ERRORS     10
#define START_RETRIES  20

static uint16_t crc16_update(uint16_t crc, uint8_t data)
{
    crc = (uint16_t)(crc ^ ((uint16_t)data << 8));
    for (uint8_t i = 0; i < 8; i++) {
        crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

/* Read one 128-byte data block; the SOH that introduced it has already
 * been consumed by the caller. Returns 1 = valid block (*is_dup tells the
 * caller whether it's a resend of the previous block, to be ACKed but not
 * re-stored), 0 = bad block/out of sequence (caller should NAK), -1 =
 * timeout mid-block (caller should NAK). */
static int8_t read_block(uint8_t *data, uint8_t expected_block, uint8_t *is_dup)
{
    int16_t blk = usart_getc_timeout(1000);
    int16_t blk_c = usart_getc_timeout(1000);
    if (blk < 0 || blk_c < 0) return -1;
    if ((uint8_t)(blk + blk_c) != 0xFF) return 0;

    uint16_t crc = 0;
    for (uint16_t i = 0; i < BLOCK_SIZE; i++) {
        int16_t d = usart_getc_timeout(1000);
        if (d < 0) return -1;
        data[i] = (uint8_t)d;
        crc = crc16_update(crc, data[i]);
    }
    int16_t crc_hi = usart_getc_timeout(1000);
    int16_t crc_lo = usart_getc_timeout(1000);
    if (crc_hi < 0 || crc_lo < 0) return -1;
    if ((uint16_t)(((uint16_t)crc_hi << 8) | (uint16_t)crc_lo) != crc) return 0;

    if ((uint8_t)blk == expected_block) { *is_dup = 0; return 1; }
    if ((uint8_t)blk == (uint8_t)(expected_block - 1)) { *is_dup = 1; return 1; }
    return 0; /* out of sequence -- desynced, let caller NAK/abort via error count */
}

int32_t xmodem_receive(uint8_t *buf, uint32_t capacity)
{
    uint8_t expected_block = 1;
    uint32_t received = 0;
    uint8_t errors = 0;

    while (usart_getc_timeout(50) >= 0) {} /* flush stale input before starting */

    /* Handshake: send 'C' (request CRC mode) until the sender responds. */
    int16_t c = -1;
    for (uint8_t tries = 0; tries < START_RETRIES; tries++) {
        usart_putc(CRC_CHAR);
        c = usart_getc_timeout(2000);
        if (c >= 0) break;
    }
    if (c < 0) return -1; /* sender never showed up */

    for (;;) {
        if (c == EOT) {
            usart_putc(ACK);
            return (int32_t)received;
        }
        if (c == CAN) return -1;
        if (c != SOH) {
            if (++errors > MAX_ERRORS) { usart_putc(CAN); usart_putc(CAN); return -1; }
            usart_putc(NAK);
            c = usart_getc_timeout(10000);
            continue;
        }

        uint8_t data[BLOCK_SIZE];
        uint8_t is_dup;
        int8_t r = read_block(data, expected_block, &is_dup);
        if (r <= 0) {
            if (++errors > MAX_ERRORS) { usart_putc(CAN); usart_putc(CAN); return -1; }
            usart_putc(NAK);
            c = usart_getc_timeout(10000);
            continue;
        }
        if (!is_dup) {
            if (received + BLOCK_SIZE > capacity) {
                usart_putc(CAN);
                usart_putc(CAN);
                return -1; /* buffer full: abort rather than overrun */
            }
            for (uint16_t i = 0; i < BLOCK_SIZE; i++) buf[received + i] = data[i];
            received += BLOCK_SIZE;
            expected_block++;
        }
        errors = 0;
        usart_putc(ACK);
        c = usart_getc_timeout(10000);
    }
}
