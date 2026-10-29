#!/usr/bin/env python3
"""
place_components.py v2 — KiCad 9 pcbnew layout for board.net
Run inside the PCB editor Python console (F5):
    exec(open('/home/p2/claude-code/z80-with-1284p/hardware/place_components.py').read())
"""

import os
import pcbnew

MM = 1_000_000

def v2(x_mm, y_mm):
    return pcbnew.VECTOR2I(int(x_mm * MM), int(y_mm * MM))

board = pcbnew.GetBoard()
if board is None:
    raise RuntimeError("No board is open in the PCB editor. Open the .kicad_pcb first.")

# Idempotent re-runs: clear footprints and edge cuts
try:
    fps = list(board.Footprints())
except TypeError:
    fps = list(board.GetFootprints())
for fp in fps:
    board.Remove(fp)

try:
    drawings = list(board.DrawingsList())
except AttributeError:
    drawings = []
for d in drawings:
    if d.GetLayer() == pcbnew.Edge_Cuts:
        board.Remove(d)


# ---------------------------------------------------------------------------
# Footprint library root
# ---------------------------------------------------------------------------
def find_footprint_root():
    candidates = [
        "/usr/share/kicad/footprints",
        "/usr/local/share/kicad/footprints",
        os.path.expandvars("/Applications/KiCad/KiCad.app/Contents/SharedSupport/share/kicad/footprints"),
        os.path.expandvars(r"%ProgramFiles%\KiCad\share\kicad\footprints"),
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\KiCad\share\kicad\footprints"),
    ]
    for c in candidates:
        if os.path.isdir(c):
            return c
    raise RuntimeError("Could not find KiCad footprint directory. Set LIB_ROOT manually.")

LIB_ROOT = find_footprint_root()
print("Using footprint root:", LIB_ROOT)

_io = pcbnew.PCB_IO()
def load_fp(lib_name, fp_name):
    libpath = os.path.join(LIB_ROOT, lib_name + ".pretty")
    fp = _io.FootprintLoad(libpath, fp_name)
    if fp is None:
        raise RuntimeError(f"Failed to load {lib_name}/{fp_name} from {libpath}")
    return fp

FP_MAP = {
    "C1":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C2":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C3":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.50mm_P2.50mm" if False else "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C4":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C5":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C6":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C7":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C8":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C9":  ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C10": ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C11": ("Capacitor_THT", "C_Disc_D3.0mm_W2.0mm_P2.50mm"),
    "C12": ("Capacitor_THT", "CP_Radial_D10.0mm_P5.00mm"),
    "C13": ("Capacitor_THT", "CP_Radial_D10.0mm_P5.00mm"),
    "J1":  ("Connector_PinHeader_2.54mm", "PinHeader_1x06_P2.54mm_Vertical"),
    "J2":  ("Connector_PinHeader_2.54mm", "PinHeader_1x18_P2.54mm_Vertical"),
}
for i in range(1, 21):
    FP_MAP[f"R{i}"] = ("Resistor_THT", "R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal")
FP_MAP.update({
    "U1":  ("Package_DIP", "DIP-40_W15.24mm"),
    "U2":  ("Package_DIP", "DIP-40_W15.24mm"),
    "U3":  ("Package_DIP", "DIP-16_W7.62mm"),
    "U4":  ("Package_DIP", "DIP-14_W7.62mm"),
    "U5":  ("Package_DIP", "DIP-14_W7.62mm"),
    "U6":  ("Package_DIP", "DIP-32_W15.24mm"),
    "U7":  ("Package_DIP", "DIP-16_W7.62mm"),
    "U8":  ("Package_DIP", "DIP-16_W7.62mm"),
    "U9":  ("Package_DIP", "DIP-40_W15.24mm"),
    "U10": ("Package_DIP", "DIP-16_W7.62mm"),
    "U11": ("Package_DIP", "DIP-14_W7.62mm"),
    "X1":  ("Oscillator", "Oscillator_DIP-8"),
})

# ---------------------------------------------------------------------------
# Board outline: 150 x 105 mm
# ---------------------------------------------------------------------------
BOARD_W, BOARD_H = 150.0, 105.0

def edge_seg(x1, y1, x2, y2):
    seg = pcbnew.PCB_SHAPE(board)
    seg.SetShape(pcbnew.SHAPE_T_SEGMENT)
    seg.SetStart(v2(x1, y1))
    seg.SetEnd(v2(x2, y2))
    seg.SetWidth(pcbnew.FromMM(0.1))
    seg.SetLayer(pcbnew.Edge_Cuts)
    board.Add(seg)

edge_seg(0, 0, BOARD_W, 0)
edge_seg(BOARD_W, 0, BOARD_W, BOARD_H)
edge_seg(BOARD_W, BOARD_H, 0, BOARD_H)
edge_seg(0, BOARD_H, 0, 0)

# ---------------------------------------------------------------------------
# Placement plan (v2: de-conflicted, 150x105 board)
#
# Body sizes (W x H, mm) for clearance math:
#   DIP-40: 39.88 x 15.24   DIP-32: 38.10 x 15.24
#   DIP-16: 35.56 x 7.62    DIP-14: 33.02 x 7.62
#   DIP-8:  29.21 x 6.35
#   R_Axial_0207: 10.16 x 2.5  (centered on origin)
#   C_Disc: 3.0 x 2.0
#   CP_Radial D10: ~10 x 10
#   PinHeader 1x18: 1.7 x 45.72 (vertical header, pads in a row along X)
#
# ZONE A (left half): Z80 system
#   U1 Z80       center (42, 52.5)   body x 22..62,  y 44.9..60.1
#   U4 74LS74    center (42, 38)     body x 25.5..58.5, y 34.2..41.8
#   U5 74LS00#1  center (42, 70)     body x 25.5..58.5, y 66.2..73.8
#   U11 74LS00#2 center (42, 88)     body x 25.5..58.5, y 84.2..91.8
#
# ZONE B (top center): SRAM above U1
#   U6 TC551001  center (80, 22)     body x 60.9..99.1, y 14.4..29.6
#
# ZONE C (right): IO / keyboard / SD
#   U9 8255      center (118, 30)    body x 98..138,  y 22.4..37.6
#   U10 74LS145  center (100, 47)    body x 82.2..117.8, y 43.2..50.8
#   U8 74LS138   center (118, 60)    body x 100.2..135.8, y 56.2..63.8
#
# ZONE D (bottom): AVR service processor
#   U2 ATmega    center (70, 82.5)   body x 50.1..89.9, y 74.9..90.1
#   U3 74HC595   center (112, 82.5)  body x 94.2..129.8, y 78.7..86.3
#   U7 74LS166   center (112, 68)    body x 94.2..129.8, y 64.2..71.8
#   X1 osc DIP-8 center (135, 82.5)  body x 120.4..149.6, y 79.3..85.7
#
# Connectors (top edge):
#   J1 microSD 1x6   center (133, 12)   pads span x ~127.7..138.3
#   J2 keyboard 1x18 center (100, 12)   pads span x ~77.2..122.8
# ---------------------------------------------------------------------------

PLACEMENTS = {
    # --- main ICs ---
    "U1":  (42.0, 52.5),
    "U2":  (70.0, 82.5),
    "U3":  (112.0, 82.5),
    "U4":  (42.0, 38.0),
    "U5":  (42.0, 70.0),
    "U6":  (80.0, 22.0),
    "U7":  (112.0, 68.0),
    "U8":  (118.0, 60.0),
    "U9":  (118.0, 30.0),
    "U10": (100.0, 47.0),
    "U11": (42.0, 88.0),
    "X1":  (135.0, 82.5),
    # --- connectors ---
    "J1":  (133.0, 12.0),
    "J2":  (100.0, 12.0),
}

# --- Decoupling caps: row above U1, spread out (one per IC, labelled by IC) ---
#     7mm pitch, all at y = 44.5 (just above U1 top edge 44.9 -> use 42.5 gap row)
cap_y = 42.5
caps_row = {
    "C1":  24.0,   # U1
    "C2":  31.0,   # U2
    "C3":  38.0,   # U3
    "C4":  45.0,   # U4
    "C5":  52.0,   # U5
    "C6":  59.0,   # U6
    "C7":  66.0,   # U7
    "C8":  73.0,   # U8
    "C9":  80.0,   # U9
    "C10": 87.0,   # U10
    "C11": 94.0,   # U11
}
for ref, x in caps_row.items():
    PLACEMENTS[ref] = (x, cap_y)
# Bulk electrolytics (10mm diameter -> 12mm center spacing min)
PLACEMENTS["C12"] = (12.0, 30.0)    # power entry, lower-left area
PLACEMENTS["C13"] = (12.0, 48.0)    # near big chips, stacked under C12

# --- Resistors (R_Axial 10.16mm long, horizontal, centered on origin) ---
# Row 1: Z80 pulls, above U1 at y = 64 (U1 top 60.1 -> clear)
res_row1_y = 64.0
PLACEMENTS.update({
    "R1":  (26.0, res_row1_y),   # _WR
    "R2":  (38.0, res_row1_y),   # _MREQ
    "R3":  (50.0, res_row1_y),   # _RD
})
# A14/A15 pulls above U5 (y = 80, U5 top 73.8 -> clear)
PLACEMENTS.update({
    "R4":  (32.0, 80.0),
    "R5":  (44.0, 80.0),
})
# 8255-side pulls: row above U9 at y = 18 (U9 top 22.4, J2 bottom ~14 -> tight but
# J2 pads end at x=122.8; R6/R7 at x=96/108 are clear of J2)
PLACEMENTS.update({
    "R6":  (96.0, 18.0),    # mode_pin
    "R7":  (108.0, 18.0),   # bank
})
# _INT/_NMI pulls, right side of U1 at y = 52.5, x=68 (U1 right edge 62 -> clear,
# U6 left edge 60.9 is at y 14.4..29.6 -> clear of y=52.5)
PLACEMENTS.update({
    "R8":  (68.0, 50.0),
    "R9":  (68.0, 56.0),
})
# POR pull-down near U11
PLACEMENTS["R10"] = (30.0, 97.0)
# Keyboard col pulls R11-R18: row ABOVE U10 at y = 38.5
#   U10 top edge = 43.2; U9 bottom = 37.6 but U9 spans x 98..138.
#   So place R11-R18 to the LEFT of U9: x from 70 to 116 at y=38.5 would hit U9.
#   Instead: 2 rows of 4 below U10 (y = 56 and y = 64), x 78..108.
#   U10 bottom edge = 50.8; U8 top = 56.2 spans x 100.2..135.8 -> avoid x>100 at y=56.
#   Use: row A y=55, x = 70, 82, 94, 106 (R11-R14); row B y=63, x = 70, 82, 94, 106 (R15-R18)
#   Check U8 (x100.2..135.8, y56.2..63.8): R14 at (106,55) -> y=55 < 56.2 OK (r body half-height 1.25, 55+1.25=56.25 ~ touching, shift y to 54.5)
#   R18 at (106, 63) -> inside U8 x-range and y-range. Move row B to x = 60, 72, 84, 96, y=63:
#   R18 at (96,63): U8 left edge 100.2 -> clear. U7 (94.2..129.8, 64.2..71.8): 63+1.25=64.25 > 64.2 barely touching U7 top; use y=62.
kb_cols = {
    "R11": (70.0, 54.5), "R12": (82.0, 54.5), "R13": (94.0, 54.5), "R14": (106.0, 54.5),
    "R15": (60.0, 62.0), "R16": (72.0, 62.0), "R17": (84.0, 62.0), "R18": (96.0, 62.0),
}
PLACEMENTS.update(kb_cols)
# SD MISO pull-up near J1/U9
PLACEMENTS["R19"] = (133.0, 18.0)
# _BUSRQ pull-up near U2
PLACEMENTS["R20"] = (58.0, 95.0)

# ---------------------------------------------------------------------------
# Place everything
# ---------------------------------------------------------------------------
placed = 0
missing = []
for ref in sorted(PLACEMENTS, key=lambda r: (r[0], int(r[1:] or 0))):
    x, y = PLACEMENTS[ref]
    try:
        fp = load_fp(*FP_MAP[ref])
    except RuntimeError as e:
        missing.append(ref)
        print(f"  SKIP {ref}: {e}")
        continue
    fp.SetReference(ref)
    fp.SetPosition(v2(x, y))
    board.Add(fp)
    placed += 1

print(f"\nPlaced {placed} components" + (f" ({len(missing)} skipped: {missing})" if missing else ""))
pcbnew.Refresh()
print("Done. Nudge anything that still overlaps, then File > Save.")

