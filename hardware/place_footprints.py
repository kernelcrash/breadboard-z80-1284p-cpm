#!/usr/bin/env python3
"""place_footprints.py -- set initial X/Y positions on a KiCad .kicad_pcb
file, after the board.net netlist import, so footprints start out grouped
by the board's actual logical structure (per docs/wiring.md's own section
order) instead of stacked in a pile at the origin.

Uses the real pcbnew Python API throughout -- not text/regex patching,
and (as of 2026-09-20) not a hand-maintained size table either. Run from
a shell with KiCad's Python module on the path (the same Python KiCad
itself uses; on most Linux installs that's just the system python3).

Usage:
    python3 place_footprints.py <board.kicad_pcb> [-o output.kicad_pcb]

Without -o, writes alongside the input as <name>.placed.kicad_pcb -- never
overwrites your file in place, so you can review it in Pcbnew (or diff
the two files) before replacing your working copy.

2026-09-20 rewrite -- the anchor-point bug: every earlier version of this
script assumed a footprint's `position` is its geometric CENTER, sized
via a hand-maintained (length, width) table. That is wrong for every THT
footprint checked in this design (DIP packages, resistors, capacitors,
pin headers): the real anchor is pin 1, and the body extends only in +X
(DIPs also -Y) from there -- never symmetric. It went unnoticed through
several rounds of "zero overlaps" because generous gaps papered over the
error, until a tighter row (the composite video driver) and pin-precise
decoupling-cap placement exposed real overlaps, including decoupling
caps landing inside their own chip.

Fix: calibrate real bounding boxes from each footprint's own pad
positions (bench-verified against the actual installed libraries, not
assumed), and derive the 90-degree rotation transform empirically rather
than guess it (confirmed: (dx, dy) -> (dy, -dx) about the anchor, checked
against both a DIP-40 and a vertical pin header). All spacing and
collision-checking now uses these real, asymmetric, anchor-relative
boxes -- no more hand-maintained SIZES table to get out of sync.
"""
import argparse
import sys

try:
    import pcbnew
except ImportError:
    sys.exit("Can't import pcbnew -- run this with the same Python KiCad "
              "itself uses (its Scripting Console's 'import sys; sys.executable' "
              "or 'import sys; print(sys.path)' will tell you which, if the "
              "plain system python3 doesn't have it already).")

FOOTPRINT_LIB_BASE = "/usr/share/kicad/footprints"

FOOTPRINTS = {
    "U1": "Package_DIP:DIP-40_W15.24mm", "U2": "Package_DIP:DIP-40_W15.24mm",
    "U9": "Package_DIP:DIP-40_W15.24mm", "U6": "Package_DIP:DIP-32_W15.24mm",
    "U3": "Package_DIP:DIP-16_W7.62mm", "U7": "Package_DIP:DIP-16_W7.62mm",
    "U8": "Package_DIP:DIP-16_W7.62mm", "U10": "Package_DIP:DIP-16_W7.62mm",
    "U4": "Package_DIP:DIP-14_W7.62mm", "U5": "Package_DIP:DIP-14_W7.62mm",
    "U11": "Package_DIP:DIP-14_W7.62mm",
    "X1": "Oscillator:Oscillator_DIP-8",
    "J1": "Connector_PinHeader_2.54mm:PinHeader_1x06_P2.54mm_Vertical",
    "J2": "Connector_PinHeader_2.54mm:PinHeader_1x18_P2.54mm_Vertical",
    "J3": "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
    "C12": "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm",
    "C13": "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm",
    "C14": "Capacitor_THT:CP_Radial_D5.0mm_P2.50mm",
    "D1": "Diode_THT:D_DO-35_SOD27_P10.16mm_Horizontal",
    "D2": "Diode_THT:D_DO-35_SOD27_P10.16mm_Horizontal",
    "Q1": "Package_TO_SOT_THT:TO-92_Inline",
}
for i in range(1, 12):
    FOOTPRINTS[f"C{i}"] = "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm"
for i in range(1, 27):
    FOOTPRINTS[f"R{i}"] = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"

# Rotate every DIP/header (long axis native-Y -> onto X, matching row()
# spacing) and -- per instruction -- every resistor and capacitor too.
NEEDS_ROTATION = {ref for ref, fpid in FOOTPRINTS.items()
                  if fpid.startswith("Package_DIP:")
                  or "PinHeader" in fpid
                  or fpid.startswith("Resistor_THT:")
                  or fpid.startswith("Capacitor_THT:")}

VCC_PIN = {"U1": 11, "U2": 10, "U3": 16, "U4": 14, "U5": 14, "U6": 32,
           "U7": 16, "U8": 16, "U9": 26, "U10": 16, "U11": 14}
CAP_FOR_CHIP = {"C1": "U1", "C2": "U2", "C3": "U3", "C4": "U4", "C5": "U5",
                "C6": "U6", "C7": "U7", "C8": "U8", "C9": "U9", "C10": "U10",
                "C11": "U11"}

GAP = 8.0        # mm, minimum edge-to-edge clearance between bodies in a row
DECAP_GAP = 2.0  # mm, decoupling caps sit much closer -- "right at the pin"
MARGIN = 2.0     # mm, rough courtyard/body allowance beyond bare pad centers

_bbox_cache = {}


def native_bbox(footprint_id):
    """(xmin, xmax, ymin, ymax) of `footprint_id`'s own pads, relative to
    its anchor (pin 1, for every THT footprint used here -- bench-
    verified, not assumed), at rotation 0, with MARGIN added on each
    side. Cached per footprint_id -- loaded once, not once per instance."""
    if footprint_id in _bbox_cache:
        return _bbox_cache[footprint_id]
    lib, name = footprint_id.split(":")
    fp = pcbnew.FootprintLoad(f"{FOOTPRINT_LIB_BASE}/{lib}.pretty", name)
    if fp is None:
        raise RuntimeError(f"Could not load footprint {footprint_id}")
    xs, ys = [], []
    for pad in fp.Pads():
        p = pad.GetPosition()
        xs.append(pcbnew.ToMM(p.x))
        ys.append(pcbnew.ToMM(p.y))
    bbox = (min(xs) - MARGIN, max(xs) + MARGIN, min(ys) - MARGIN, max(ys) + MARGIN)
    _bbox_cache[footprint_id] = bbox
    return bbox


def rotated_bbox(native, rotate90):
    """Bench-verified rotation transform about the anchor: (dx, dy) ->
    (dy, -dx). Checked against DIP-40 (pin 20 native (0,48.26) -> rotated
    (48.26,0)) and a 1x06 pin header (pin 2 native (0,2.54) -> rotated
    (2.54,0)) -- both matched exactly."""
    if not rotate90:
        return native
    xmin, xmax, ymin, ymax = native
    return (ymin, ymax, -xmax, -xmin)


def ref_bbox(ref):
    """Rotated (per NEEDS_ROTATION) bounding box for `ref`, relative to
    its own anchor -- i.e. still needs the placed (x, y) added to become
    absolute."""
    return rotated_bbox(native_bbox(FOOTPRINTS[ref]), ref in NEEDS_ROTATION)


def row(refs, x0, y, gap=GAP):
    """Place `refs` left-to-right so consecutive real bodies (not
    assumed-symmetric ones) are exactly `gap` apart, vertically centered
    on `y`. Returns {ref: (anchor_x, anchor_y)} -- the anchor position to
    feed into fp.SetPosition(), already accounting for each footprint's
    own (possibly asymmetric) offset from its anchor."""
    pos = {}
    cursor = x0
    for ref in refs:
        xmin, xmax, ymin, ymax = ref_bbox(ref)
        anchor_x = cursor - xmin
        anchor_y = y - (ymin + ymax) / 2
        pos[ref] = (round(anchor_x, 2), round(anchor_y, 2))
        cursor = anchor_x + xmax + gap
    return pos


def stack_rows(row_specs, y0, gap=GAP):
    """Stack `row_specs` (a list of (refs, x0) pairs, each one row())
    vertically, `gap` mm apart measured between REAL bounding boxes (not
    a guessed band pitch) -- places each row, measures where its bbox
    actually ended up, and only then commits to a final Y before moving
    to the next row. Returns a merged position dict."""
    pos = {}
    cursor = y0
    for refs, x0 in row_specs:
        band_ymin = min(ref_bbox(r)[2] for r in refs)
        band_ymax = max(ref_bbox(r)[3] for r in refs)
        band_y = cursor - band_ymin
        pos.update(row(refs, x0=x0, y=band_y, gap=gap))
        cursor = band_y + band_ymax + gap
    return pos


def grid_wrap(refs, x0, y0, max_width, gap=GAP):
    """Pack `refs` left-to-right, wrapping to a new sub-row (stacked
    below, using each sub-row's own real measured height) whenever the
    next item would push that sub-row past `x0 + max_width`. Compact by
    construction -- unlike stacking one group per row regardless of how
    little width it actually needs, which is what put the utility
    resistors ~230mm below this project's real board outline the first
    time (bench-found: board is 195mm wide but only 148mm tall, and nothing
    in the old layout used more than half that width). Original relative
    order is preserved (adjacent in the packed grid), so the semantic
    grouping (which signal each resistor serves) still reads left-to-
    right, top-to-bottom -- just not as visually separated rows anymore."""
    pos = {}
    cursor_y = y0
    current_row, row_ymin, row_ymax = [], None, None

    def flush_row():
        nonlocal cursor_y, current_row, row_ymin, row_ymax
        if not current_row:
            return
        band_y = cursor_y - row_ymin
        pos.update(row(current_row, x0=x0, y=band_y, gap=gap))
        cursor_y = band_y + row_ymax + gap
        current_row, row_ymin, row_ymax = [], None, None

    for ref in refs:
        xmin, xmax, ymin, ymax = ref_bbox(ref)
        width = xmax - xmin
        projected = (sum(ref_bbox(r)[1] - ref_bbox(r)[0] for r in current_row)
                     + gap * len(current_row) + width)
        if current_row and projected > max_width:
            flush_row()
        current_row.append(ref)
        row_ymin = ymin if row_ymin is None else min(row_ymin, ymin)
        row_ymax = ymax if row_ymax is None else max(row_ymax, ymax)
    flush_row()
    return pos


def compute_layout():
    """Bands grouped by real connectivity (not wiring.md's document
    order -- see the 2026-09-20 rearrangement note on chip_rows below):
    data-bus row, AVR/video/clock cluster, remaining glue logic,
    connectors, composite video driver -- then pull-up/down resistors
    packed into a compact grid (see grid_wrap()). This is a *starting*
    layout, not a routed one -- rearrange freely once you're in Pcbnew.
    Decoupling caps (C1-C11) are NOT positioned here -- see
    place_decoupling_caps(), which needs the chips' real post-placement
    pad positions; DECAP_ROOM below reserves vertical space on both
    sides of every chip row for whichever direction each one ends up
    extending in."""
    # A cap's full reach beyond its chip's edge is DECAP_GAP + its own
    # real height (not half -- bench-found that assumption wrong too,
    # see place_decoupling_caps()): for C_Disc, 2 + 6.5 = 8.5mm. Two
    # adjacent bands' chips can both need their caps to reach into the
    # *same* shared gap (worst case, facing each other), so DECAP_ROOM
    # has to clear that per side, not half of it -- 6mm under-reserved
    # by ~1mm and still let C1/C5 clip each other; 8mm has real margin.
    DECAP_ROOM = 8.0
    LAYOUT_WIDTH = 180.0  # mm -- keeps this layout inside a modest board;
                          # widen if your actual board is bigger than this.

    # 2026-09-20 rearranged per connectivity, not wiring.md's document
    # order -- U9 wants the Z80 data bus primarily (moved out of the old
    # "IO subsystem" row, into the bus row itself), and U7 wants to sit
    # near X1 (its pixel clock), the Z80/SRAM data bus, and the AVR (its
    # SH_LD source) all at once -- so row 2 clusters exactly those three.
    chip_rows = [
        (["U6", "U1", "U9", "U8"], 20),            # data bus + the IO chip that needs it most
        (["U2", "U7", "X1", "U4"], 20),            # AVR/video/clock cluster, below the bus row
        (["U5", "U11", "U3", "U10"], 20),          # remaining glue + 595 (data bus) + keyboard decoder
    ]
    pos = {}
    cursor = 20.0
    for refs, x0 in chip_rows:
        band_ymin = min(ref_bbox(r)[2] for r in refs)
        band_ymax = max(ref_bbox(r)[3] for r in refs)
        band_y = cursor - band_ymin + DECAP_ROOM
        pos.update(row(refs, x0=x0, y=band_y))
        cursor = band_y + band_ymax + DECAP_ROOM + GAP

    # Connectors and the composite video driver don't carry decaps --
    # plain stack_rows, no extra room needed.
    pos.update(stack_rows([
        (["J1", "J2"], 20),
        (["D1", "D2", "R21", "R22", "R23", "Q1", "R24", "R25", "R26", "C14", "J3"], 20),
    ], y0=cursor))
    cursor = max(y for _, y in pos.values()) + GAP

    # Least-informed placements here -- wiring.md gives no specific
    # location for these, just "near power entry"/"near larger chips".
    pos["C12"] = (10, 10)
    pos["C13"] = (10, cursor + 15)

    # Utility resistors: one compact grid instead of 5 separate rows.
    utility_resistors = ["R1", "R2", "R3", "R20", "R4", "R5", "R8", "R9",
                          "R10", "R6", "R7", "R11", "R12", "R13", "R14",
                          "R15", "R16", "R17", "R18", "R19"]
    pos.update(grid_wrap(utility_resistors, x0=20, y0=cursor, max_width=LAYOUT_WIDTH))

    return pos


def place_decoupling_caps(board):
    """Second pass, run after the main layout is placed on the real
    board: for each chip, find its actual VCC pad position (post-
    rotation), work out which of the chip's own real top/bottom edges
    that pad is closer to, and park that chip's decoupling cap just
    beyond that specific edge, at the pad's own X -- the standard "right
    at the power pin" placement, not a generic side offset."""
    placed = []
    for cap_ref, chip_ref in CAP_FOR_CHIP.items():
        cap_fp = board.FindFootprintByReference(cap_ref)
        chip_fp = board.FindFootprintByReference(chip_ref)
        if cap_fp is None or chip_fp is None:
            continue
        vcc_pad = next((p for p in chip_fp.Pads()
                         if p.GetNumber() == str(VCC_PIN[chip_ref])), None)
        if vcc_pad is None:
            continue
        vpos = vcc_pad.GetPosition()
        vx, vy = pcbnew.ToMM(vpos.x), pcbnew.ToMM(vpos.y)

        chip_anchor = chip_fp.GetPosition()
        chip_ax, chip_ay = pcbnew.ToMM(chip_anchor.x), pcbnew.ToMM(chip_anchor.y)
        _, _, cymin, cymax = ref_bbox(chip_ref)
        abs_top, abs_bottom = chip_ay + cymin, chip_ay + cymax
        # Measure from the chip's real bbox EDGE, not the VCC pin's own
        # position -- the pin can sit a couple mm inside that edge (the
        # margin added in native_bbox()), and starting from the pin
        # under-counted that gap, landing the cap back inside the chip's
        # own body. Bench-found: C1/U1 and C2/U2 still overlapped even
        # after fixing the row-to-row spacing, traced to exactly this.
        closer_to_top = abs(vy - abs_top) < abs(vy - abs_bottom)

        # Same anchor-asymmetry issue as the chips themselves: a cap's
        # bbox isn't symmetric around its own anchor either (C_Disc's is
        # [-4.5, +2], not +-3.25) -- bench-found this still let C1/C5
        # overlap even after the chip-edge fix above, since `cap_half`
        # assumed the anchor sat at the bbox's center. Solve directly for
        # the position that puts the cap's own real edge exactly
        # DECAP_GAP from the chip's real edge, instead of approximating
        # with a half-height from the wrong point.
        _, _, capymin, capymax = ref_bbox(cap_ref)
        if closer_to_top:
            sign = -1
            new_y = abs_top - DECAP_GAP - capymax   # cap's bottom edge (new_y+capymax) lands here
        else:
            sign = 1
            new_y = abs_bottom + DECAP_GAP - capymin  # cap's top edge (new_y+capymin) lands here

        cap_fp.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(vx), pcbnew.FromMM(new_y)))
        cap_fp.SetOrientationDegrees(90)
        placed.append(cap_ref)
    return placed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcb_file")
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args()

    board = pcbnew.LoadBoard(args.pcb_file)
    layout = compute_layout()

    placed, not_found = [], []
    for ref, (x, y) in layout.items():
        fp = board.FindFootprintByReference(ref)
        if fp is None:
            not_found.append(ref)
            continue
        fp.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(x), pcbnew.FromMM(y)))
        if ref in NEEDS_ROTATION:
            fp.SetOrientationDegrees(90)
        placed.append(ref)

    decap_placed = place_decoupling_caps(board)
    placed.extend(decap_placed)

    on_board_refs = {fp.GetReference() for fp in board.GetFootprints()}
    untouched = sorted(on_board_refs - set(placed))

    out_path = args.output or args.pcb_file.replace(".kicad_pcb", ".placed.kicad_pcb")
    pcbnew.SaveBoard(out_path, board)

    print(f"Placed {len(placed)} refs ({len(layout)} from the layout table, "
          f"{len(decap_placed)} decoupling caps anchored to real VCC pads).")
    if not_found:
        print(f"In the layout table but NOT on this board (nothing done): {sorted(not_found)}")
    if untouched:
        print(f"On the board but not placed by this script (left wherever they were): {untouched}")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
