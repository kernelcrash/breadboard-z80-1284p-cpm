#!/usr/bin/env python3
"""
place_components_ipc.py — places board.net components using the KiCad IPC API (kipy).

Requires:
  1. KiCad 9 running with the API server enabled:
       Preferences -> Plugins -> enable "KiCad API server"
  2. A .kicad_pcb open in the PCB editor
  3. Python (any, system python3 is fine — no SWIG needed):
       pip install kicad-python

Run:  python3 place_components_ipc.py
"""

import math
import kipy
from kipy import KiCad
from kipy.geometry import Vector2
from kipy.board import BoardLayer

# ---------------------------------------------------------------------------
# Connect to KiCad
# ---------------------------------------------------------------------------
try:
    k = KiCad(timeout_ms=3000)
    k.ping()
except Exception as e:
    raise SystemExit(
        "Cannot reach KiCad's API server: " + str(e) +
        "\nMake sure KiCad 9 is running, a .kicad_pcb is open in the PCB editor,"
        "\nand Preferences > Plugins > 'KiCad API server' is enabled."
    )

board = k.get_board()
if board is None:
    raise SystemExit("No board is open in the PCB editor.")

print("Connected to KiCad", k.get_version(), "- placing components on board")


# ---------------------------------------------------------------------------
# Footprint library IDs (lib:name) for each component
# ---------------------------------------------------------------------------
FPIDS = {
    "C1":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C2":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C3":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C4":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C5":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C6":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C7":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C8":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C9":  "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C10": "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C11": "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm",
    "C12": "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm",
    "C13": "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm",
    "J1":  "Connector_PinHeader_2.54mm:PinHeader_1x06_P2.54mm_Vertical",
    "J2":  "Connector_PinHeader_2.54mm:PinHeader_1x18_P2.54mm_Vertical",
    "R1":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R2":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R3":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R4":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R5":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R6":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R7":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R8":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R9":  "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R10": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R11": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R12": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R13": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R14": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R15": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R16": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R17": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R18": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R19": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "R20": "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
    "U1":  "Package_DIP:DIP-40_W15.24mm",
    "U2":  "Package_DIP:DIP-40_W15.24mm",
    "U3":  "Package_DIP:DIP-16_W7.62mm",
    "U4":  "Package_DIP:DIP-14_W7.62mm",
    "U5":  "Package_DIP:DIP-14_W7.62mm",
    "U6":  "Package_DIP:DIP-32_W15.24mm",
    "U7":  "Package_DIP:DIP-16_W7.62mm",
    "U8":  "Package_DIP:DIP-16_W7.62mm",
    "U9":  "Package_DIP:DIP-40_W15.24mm",
    "U10": "Package_DIP:DIP-16_W7.62mm",
    "U11": "Package_DIP:DIP-14_W7.62mm",
    "X1":  "Oscillator:Oscillator_DIP-8",
}

# ---------------------------------------------------------------------------
# Placement plan (mm). Same de-conflicted layout as the SWIG version:
# 150 x 105 mm board, 4 zones (Z80 left, SRAM top-center, IO right, AVR bottom)
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
    # --- connectors (top edge) ---
    "J1":  (133.0, 12.0),
    "J2":  (100.0, 12.0),
    # --- decoupling caps: 7mm-pitch row above U1 ---
    "C1":  (24.0, 42.5),
    "C2":  (31.0, 42.5),
    "C3":  (38.0, 42.5),
    "C4":  (45.0, 42.5),
    "C5":  (52.0, 42.5),
    "C6":  (59.0, 42.5),
    "C7":  (66.0, 42.5),
    "C8":  (73.0, 42.5),
    "C9":  (80.0, 42.5),
    "C10": (87.0, 42.5),
    "C11": (94.0, 42.5),
    # --- bulk electrolytics, lower-left ---
    "C12": (12.0, 30.0),
    "C13": (12.0, 48.0),
    # --- Z80 pull-ups, above U1 ---
    "R1":  (26.0, 64.0),
    "R2":  (38.0, 64.0),
    "R3":  (50.0, 64.0),
    # --- A14/A15 pulls, above U5 ---
    "R4":  (32.0, 80.0),
    "R5":  (44.0, 80.0),
    # --- 8255 mode/bank pulls, above U9 (left of J2 pads) ---
    "R6":  (96.0, 18.0),
    "R7":  (108.0, 18.0),
    # --- _INT/_NMI pulls, right of U1 ---
    "R8":  (68.0, 50.0),
    "R9":  (68.0, 56.0),
    # --- POR pull-down near U11 ---
    "R10": (30.0, 97.0),
    # --- keyboard col pulls, two rows left of U10 ---
    "R11": (70.0, 54.5),
    "R12": (82.0, 54.5),
    "R13": (94.0, 54.5),
    "R14": (106.0, 54.5),
    "R15": (60.0, 62.0),
    "R16": (72.0, 62.0),
    "R17": (84.0, 62.0),
    "R18": (96.0, 62.0),
    # --- SD MISO pull-up near J1 ---
    "R19": (133.0, 18.0),
    # --- _BUSRQ pull-up near U2 ---
    "R20": (58.0, 95.0),
}

# ---------------------------------------------------------------------------
# Create the footprints
# ---------------------------------------------------------------------------
new_footprints = []
for ref, (x, y) in PLACEMENTS.items():
    fp = kipy.board.FootprintInstance()
    fp.id = FPIDS[ref]
    fp.position = Vector2.from_xy_mm(x, y)
    fp.reference_field.text.value = ref
    new_footprints.append(fp)
    print(f"  {ref:5s}  {FPIDS[ref]}  @ ({x:.1f}, {y:.1f}) mm")

# ---------------------------------------------------------------------------
# Commit
# ---------------------------------------------------------------------------
comm = board.begin_commit()
try:
    board.create_items(new_footprints)
    board.push_commit(comm)
    print(f"\nCreated {len(new_footprints)} footprints.")
except Exception as e:
    board.abort_commit(comm)
    raise SystemExit(f"Commit failed: {e}")

# ---------------------------------------------------------------------------
# Add board outline (Edge.Cuts) if none exists
# ---------------------------------------------------------------------------
BOARD_W, BOARD_H = 150.0, 105.0
has_outline = False
try:
    for g in board.graphics_items:
        if g.layer == kipy.board_types.Layer.Edge_Cuts:
            has_outline = True
            break
except Exception:
    pass

if not has_outline:
    print("Adding board outline...")
    from kipy.board_types import BoardGraphic, GraphicShapeType
    gcomm = board.begin_commit()
    corners = [(0, 0), (BOARD_W, 0), (BOARD_W, BOARD_H), (0, BOARD_H)]
    graphics = []
    for i in range(4):
        x1, y1 = corners[i]
        x2, y2 = corners[(i + 1) % 4]
        g = BoardGraphic()
        g.shape = GraphicShapeType.GRAPHIC_SHAPE_SEGMENT
        g.start = Vector2.from_xy_mm(x1, y1)
        g.end = Vector2.from_xy_mm(x2, y2)
        g.width = 0.1
        g.layer = kipy.board_types.Layer.Edge_Cuts
        graphics.append(g)
    try:
        board.create_items(graphics)
        board.push_commit(gcomm)
    except Exception:
        board.abort_commit(gcomm)
        print("  (outline failed to add — draw it manually in KiCad)")

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------
try:
    board.save()
    print("Board saved.")
except Exception as e:
    print(f"Warning: save failed ({e}) — save manually in KiCad.")

print("Done. Review the placement in KiCad and nudge anything that still overlaps.")

