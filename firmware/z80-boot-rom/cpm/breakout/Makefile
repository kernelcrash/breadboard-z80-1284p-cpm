# breakout: SDCC-compiled CP/M .com game targeting the 640x200 1bpp
# display. Same toolchain recipe as sdcc-test/Makefile (see that file's
# own header for why the sdcc-* wrapper names, not raw /usr/libexec/sdcc
# paths, are required here).
SDCC    = sdcc-sdcc
SDASZ80 = sdcc-sdasz80
MAKEBIN = sdcc-makebin

CODE_LOC = 0x100

CRT0 = crt0.s
ASM_SRCS = video.s input.s ball.s
C_SRCS = main.c
TARGET = breakout.com

ASM_RELS = $(ASM_SRCS:.s=.rel)
C_RELS = $(C_SRCS:.c=.rel)

all: $(TARGET)

crt0.rel: $(CRT0)
	$(SDASZ80) -o crt0.rel $(CRT0)

%.rel: %.s
	$(SDASZ80) -o $@ $<

%.rel: %.c
	$(SDCC) -mz80 --no-std-crt0 -c $< -o $@

$(TARGET:.com=.ihx): crt0.rel $(ASM_RELS) $(C_RELS)
	$(SDCC) -mz80 --no-std-crt0 --code-loc $(CODE_LOC) \
		crt0.rel $(ASM_RELS) $(C_RELS) -o $(TARGET:.com=.ihx)

# makebin's -o here means "skip this many leading bytes of the padded
# binary" (see sdcc-test/Makefile's own comment for the empirical
# verification of this) -- strips the 0x100 bytes of 0xFF padding
# before our real content. -p (pack) truncates at the last real byte.
$(TARGET): $(TARGET:.com=.ihx)
	$(MAKEBIN) -p -o $(CODE_LOC) $(TARGET:.com=.ihx) $(TARGET)

clean:
	rm -f *.rel *.ihx *.lst *.sym *.asm *.map *.noi *.lk $(TARGET)

.PHONY: all clean
