/* p0_harness.c -- plan-kc-z80-comp-emu.md Phase P0: prove the vendored z80em core
 * itself builds and links, nothing more. No project-specific memory
 * map, no disk, no screen -- those are P1-P3.
 *
 * Runs a tiny hand-assembled Z80 program from a flat 64K RAM array:
 *   0000: 3E 42        LD A,0x42
 *   0002: 06 05        LD B,5
 *   0004: 05           DEC B        <- loop
 *   0005: 20 FD        JR NZ,loop
 *   0007: 18 FE        JR -2        <- spins here forever once B==0
 *
 * Z80.h documents Rd/WrZ80, In/OutZ80, PatchZ80, LoopZ80 as plain C
 * functions the host defines (Z80.c calls them directly by name --
 * confirmed against the real vendored Z80.h, not the function-pointer
 * API an earlier secondary source suggested during planning).
 *
 * IPeriod is set comfortably larger than the ~30-cycle loop above, so
 * by the time LoopZ80 is first called the program has already reached
 * the closing JR -2 spin -- returning INT_QUIT there stops execution
 * deterministically, and the register state is inspected: A must be
 * 0x42, B must be 0 (decremented 5 times), and PC must be within the
 * spin loop (0x0007-0x0009), or the core isn't behaving as it should.
 *
 * Bench-found while writing this harness (2026-09-26): IPeriod MUST be
 * set *before* calling ResetZ80(), not after -- confirmed directly
 * against Z80.c's real ResetZ80(), which does `R->ICount=R->IPeriod`
 * as part of reset. Setting IPeriod on the just-reset struct afterward
 * has no effect on the first run: ICount is already seeded from
 * whatever IPeriod held at reset time (uninitialized stack garbage, for
 * a plain local `Z80 cpu;`). First attempt got this backwards and
 * "passed" by accident -- ICount happened to expire after a single
 * instruction, calling LoopZ80 (and thus INT_QUIT) immediately after
 * `LD A,0x42`, before the B-decrementing loop ever ran at all; B read
 * back as 0x00 anyway because that's ResetZ80's own zeroed initial
 * value, not because the loop executed -- a false pass, not a real
 * one. The PC-range check below exists specifically to catch this
 * class of mistake in the future: PC landing outside the spin loop
 * means the program didn't actually finish running, whatever A/B show.
 */
#include <stdio.h>
#include "Z80.h"

static byte ram[0x10000];

byte RdZ80(register word Addr) { return ram[Addr]; }
void WrZ80(register word Addr, register byte Value) { ram[Addr] = Value; }

byte InZ80(register word Port)  { (void)Port; return 0xFF; }
void OutZ80(register word Port, register byte Value) { (void)Port; (void)Value; }

void PatchZ80(register Z80 *R) { (void)R; /* no patch commands used */ }

word LoopZ80(register Z80 *R) { (void)R; return INT_QUIT; }

int main(void)
{
    static const byte prog[] = {
        0x3E, 0x42,       /* LD A,0x42   */
        0x06, 0x05,       /* LD B,5      */
        0x05,             /* DEC B       */
        0x20, 0xFD,       /* JR NZ,-3 (back to DEC B) */
        0x18, 0xFE        /* JR -2 (spin forever)     */
    };
    for (unsigned i = 0; i < sizeof(prog); i++) ram[i] = prog[i];

    Z80 cpu;
    cpu.IPeriod = 200; /* comfortably more than the ~30 cycles the
                        * program above needs to reach the spin loop --
                        * MUST be set before ResetZ80(), see header */
    ResetZ80(&cpu);
    RunZ80(&cpu);

    byte a = cpu.AF.B.h;
    byte b = cpu.BC.B.h;
    word pc = cpu.PC.W;
    printf("A=0x%02X (want 0x42), B=0x%02X (want 0x00), "
           "PC=0x%04X (want 0x0007-0x0009)\n", a, b, pc);

    if (a == 0x42 && b == 0x00 && pc >= 0x0007 && pc <= 0x0009) {
        printf("PASS: core executed the whole program correctly.\n");
        return 0;
    }
    printf("FAIL: register state does not match expectations.\n");
    return 1;
}
