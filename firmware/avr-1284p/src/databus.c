/* databus.c -- see databus.h. */
#include <avr/io.h>
#include "pins.h"
#include "databus.h"

void databus_init(void)
{
    /* MOSI/SCK/RCLK all outputs. This also sidesteps the standard AVR
     * SPI-master gotcha: if SS (PB4, repurposed here as RCLK) were left
     * as an *input* and something drove it low externally, the
     * hardware would silently downgrade the peripheral to SPI slave
     * mode. Configuring it as an output here avoids that regardless of
     * what PB4 is actually used for -- matching how DATA_SPI_DDR was
     * already unconditionally set fully output in the old 373 design
     * (rom_emu.c's own comment), just carried forward deliberately
     * rather than by the same coincidence. */
    DATA_SPI_DDR |= (1 << BIT_MOSI) | (1 << BIT_SCK) | (1 << BIT_RCLK);
    DATA_SPI_PORT &= (uint8_t)~(1 << BIT_RCLK);   /* RCLK idles low */

    /* SPI master, fastest available rate (SPI2X + SPR1:0=00 ->
     * F_CPU/2 = 8MHz bit rate at this project's 16MHz clock -- 8 bits
     * in 8 SPI-clock periods = 16 AVR cycles). CPOL/CPHA default to
     * SPI mode 0 (SCK idles low, data driven/sampled on the rising
     * edge), which is exactly what the 74HC595 expects on SER/SRCLK --
     * no inversion or phase shift needed. */
    SPCR = (1 << SPE) | (1 << MSTR);
    SPSR = (1 << SPI2X);
}

/* databus_send() itself now lives in databus.h as `static inline` --
 * see that header's comment for why (removing the call/ret boundary
 * once a real bench measurement showed it mattered enough to ask
 * about). Nothing left to define here. */
