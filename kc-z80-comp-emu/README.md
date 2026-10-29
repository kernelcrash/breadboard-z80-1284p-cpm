# kc-z80-comp-emu

A host-side development emulator of this computer (Z80 core from `third_party/z80em`,
SDL2 for screen and keyboard) that boots the real CP/M BIOS and `boot.img`.
Handy for testing CP/M programs without flashing hardware. Details in `DEVLOG.md`.

Needs `gcc`, `python3`, `z80asm`, SDL2 dev files (`pkg-config sdl2`). First build
the CP/M image: `make -C ../firmware/z80-boot-rom/cpm bios.sym boot.img`.

| Target | What it does |
|---|---|
| `make p0` | sanity check of the Z80 core |
| `make p1` | load the BIOS chunks, check CCP/BDOS/BIOS addresses (runs `bios-chunks`) |
| `make p2` | headless boot to a CCP prompt |
| `make p3` | screen test pattern (SDL window) |
| `make p4` | interactive CCP prompt with real keyboard (SDL window); runs drive A from `boot.img` |
| `make p5` | runs `BREAKOUT.COM` (self-test); `./p5_harness` for interactive play |

Set `SDL_VIDEODRIVER=dummy` to run the SDL targets headless.

`third_party/z80em` is Marat Fayzullin's Z80 emulator, vendored unmodified; its
licence permits non-commercial use only. See `third_party/z80em/NOTICE.md`.
