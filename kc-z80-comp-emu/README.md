# kc-z80-comp-emu

A host-side development emulator of this computer (Z80 core from `third_party/z80em`,
SDL2 for screen and keyboard) that boots the real CP/M BIOS and `boot.img`.
Handy for testing CP/M programs without flashing hardware. Details in `DEVLOG.md`.

Needs `gcc`, `python3`, `z80asm`, SDL2 dev files (`pkg-config sdl2`).
The targets build the CP/M image (`bios.sym`, `boot.img`) automatically if it is missing.

| Target | What it does |
|---|---|
| `make p0` | sanity check of the Z80 core |
| `make p1` | load the BIOS chunks, check CCP/BDOS/BIOS addresses (runs `bios-chunks`) |
| `make p2` | headless boot to a CCP prompt |
| `make p3` | screen test pattern (SDL window) |
| `make p4` | interactive CCP prompt with real keyboard (SDL window); runs drive A from `boot.img` (`--image FILE` to boot another) |
| `make p5` | automated self-test: types BREAKOUT and quits (unthrottled, so the game ends instantly; not for playing) |
| `make play` | boot a drive A with `BREAKOUT.COM` at real 8 MHz speed with keyboard; type `BREAKOUT` at the `A>` prompt (arrows move, ESC quits) |

Set `SDL_VIDEODRIVER=dummy` to run the SDL targets headless.

`third_party/z80em` is Marat Fayzullin's Z80 emulator, vendored unmodified; its
licence permits non-commercial use only. See `third_party/z80em/NOTICE.md`.
