# ATmega1284P firmware build
# 16 MHz external clock, JTAG disabled, ISP programming.
#
# monitor.c bakes in a copy of the Z80 CP/M bootstrap: this Makefile
# recurses into ../z80-boot-rom/cpm to (re)build stage1.bin, then
# tools/bin2c.py turns it into the generated header src/stage1_rom.h
# (gitignored). So this build now needs z80asm on PATH.

MCU      = atmega1284p
F_CPU    = 16000000UL
OBJCOPY  = avr-objcopy
OBJDUMP  = avr-objdump
SIZE     = avr-size
TARGET   = z80mcu

# -ffixed-r2/-ffixed-r3: reserved project-wide for sync.c's video_addr,
# which lives permanently in r2:r3 instead of an SRAM static (see that
# file's video_addr declaration comment for why, and how this was
# verified safe against every linked-in avr-libc/libgcc routine).
CFLAGS   = -mmcu=$(MCU) -DF_CPU=$(F_CPU) -Os -std=gnu11 -Wall -Wextra -ffunction-sections -fdata-sections -ffixed-r2 -ffixed-r3
LDFLAGS  = -mmcu=$(MCU) -Os -Wl,--gc-sections -Wl,-T,rombuf.ld

SRCS = $(wildcard src/*.c)
OBJS = $(SRCS:.c=.o)
ASM  = $(wildcard src/*.S)

STAGE1_DIR = ../z80-boot-rom/cpm
STAGE1_BIN = $(STAGE1_DIR)/stage1.bin
STAGE1_HDR = src/stage1_rom.h
BIN2C      = ../../tools/bin2c.py

all: $(TARGET).hex $(TARGET).size

$(TARGET).elf: $(OBJS) $(ASM) rombuf.ld
	avr-gcc $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(ASM)

%.o: %.c src/pins.h
	avr-gcc $(CFLAGS) -c -o $@ $<

# stage1.bin is built by the CP/M Makefile's own `stage1.bin: stage1.asm`
# rule. FORCE (not a .PHONY on the .bin) means the sub-make runs on every
# build, but stage1.bin's timestamp only changes when stage1.asm actually
# did -- so stage1_rom.h and monitor.o below stay properly incremental.
$(STAGE1_BIN): FORCE
	$(MAKE) -C $(STAGE1_DIR) stage1.bin

$(STAGE1_HDR): $(STAGE1_BIN) $(BIN2C)
	python3 $(BIN2C) --name stage1_rom $(STAGE1_BIN) > $@

src/monitor.o: $(STAGE1_HDR)

$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O ihex -R .eeprom $< $@

$(TARGET).size: $(TARGET).elf
	$(SIZE) $< | tee $(TARGET).size

disasm: $(TARGET).elf
	$(OBJDUMP) -d -S $< > $(TARGET).lst

clean:
	rm -f $(OBJS) $(TARGET).elf $(TARGET).hex $(TARGET).size $(TARGET).lst $(STAGE1_HDR)

.PHONY: all clean disasm FORCE
FORCE:
