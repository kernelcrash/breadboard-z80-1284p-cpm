# Third-party notice: z80em

`Z80.c`, `Z80.h`, `Codes.h`, `CodesCB.h`, `CodesED.h`, `CodesXCB.h`,
`CodesXX.h`, `Tables.h` in this directory are vendored, **unmodified**
upstream source from Marat Fayzullin's "Z80 Portable Emulation
Package" (`Z80-081707.zip`, dated 2007-08-17), downloaded directly from
https://fms.komkon.org/EMUL8/Z80-081707.zip -- the current, canonical
source location (an older mirror lives at
https://www.komkon.org/~dekogel/misc.html, same core).

The optional debugger (`ConDebug.c`/`Debug.c`) was intentionally not
vendored -- this project's use only needs the core (`Z80.c`/`Z80.h`
plus the opcode tables), and the plan (`plan-kc-z80-comp-emu.md`) explicitly scopes
this out.

## License

Quoted exactly as it appears in the vendored `Z80.h`'s own header
comment (the authoritative copy, since it ships with the code itself):

> Copyright (C) Marat Fayzullin 1994-2007
> You are not allowed to distribute this software commercially.
> Please, notify me, if you make any changes to this file.

The author's own web pages (fms.komkon.org/EMUL8/,
komkon.org/~dekogel/misc.html) state the same terms in slightly
different words across different pages -- e.g. "you can use these
resources for any non-profit purposes, as long as you make a proper
reference to me" and, on an older page, "no profit is made and I am
notified." All versions agree on the substance: **non-commercial use
is fine with attribution; notify the author of changes; commercial use
needs separate permission.**

This project's use is a personal hobby project, non-commercial, and
these files are used unmodified -- squarely within what the license
allows.

**Action still needed from the project owner (not something an
assistant can do on your behalf): send a courtesy notification email**
to Marat Fayzullin about this use, per the license's own request. The
author's contact details are on the pages linked above. His site dates
from 1997/2007, so treat a non-response as expected, not a blocker --
this is a good-faith courtesy, not a gate on using the code.

## Provenance / verification

Downloaded and extracted directly during this project's own emulator
work (`plan-kc-z80-comp-emu.md`, Phase P0) -- the API described there (`RdZ80`/
`WrZ80`/`InZ80`/`OutZ80`/`LoopZ80`/`PatchZ80`, all plain C functions
the host program defines, called directly by `Z80.c` -- not function
pointers, correcting an earlier assumption from a secondary GitHub
mirror used during planning) was confirmed directly against this real,
vendored `Z80.h`, not assumed.
