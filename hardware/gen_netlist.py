#!/usr/bin/env python3
"""Generate a KiCad-importable netlist (s-expression format, the same
shape 'File > Import Netlist' in Pcbnew expects) from docs/wiring.md.

Built by hand-transcribing every pin connection in wiring.md into a
{net_name: [(ref, pin), ...]} map, then emitting the KiCad netlist
s-expression. See the accompanying notes for what's directly from the
doc vs inferred from standard/datasheet pinouts (VCC/GND pins mostly,
which wiring.md omits since it only lists functionally-relevant pins).
"""

components = {
    # ref: (value, footprint, description)
    "U1":  ("Z80 CPU",            "Package_DIP:DIP-40_W15.24mm",  "Zilog Z80 CPU"),
    "U2":  ("ATmega1284P",        "Package_DIP:DIP-40_W15.24mm",  "AVR service processor"),
    "U3":  ("74HC595",            "Package_DIP:DIP-16_W7.62mm",   "shift register data latch"),
    "U4":  ("74LS74A",            "Package_DIP:DIP-14_W7.62mm",   "dual D flip-flop: clk/2 + _WAIT"),
    "U5":  ("74LS00",             "Package_DIP:DIP-14_W7.62mm",   "quad NAND #1: 595/SRAM OE logic"),
    "U6":  ("TC551001BPL-70L",    "Package_DIP:DIP-32_W15.24mm",  "128Kx8 SRAM"),
    "U7":  ("74LS166A",           "Package_DIP:DIP-16_W7.62mm",   "PISO shift register, video"),
    "U8":  ("74LS138",            "Package_DIP:DIP-16_W7.62mm",   "3-to-8 IO decoder"),
    "U9":  ("8255A",              "Package_DIP:DIP-40_W15.24mm",  "PPI: mode/bank/keyboard/SD"),
    "U10": ("74LS145",            "Package_DIP:DIP-16_W7.62mm",   "BCD-to-decimal, keyboard rows"),
    "U11": ("74LS00",             "Package_DIP:DIP-14_W7.62mm",   "quad NAND #2: bank-switch + 8255 RESET"),
    "X1":  ("16MHz-oscillator",   "Oscillator:Oscillator_DIP-8",  "ASSUMPTION -- wiring.md doesn't name this part; canned oscillator vs. bare crystal on AVR XTAL1/2 is not fully specified, see notes"),
    "J1":  ("microSD_breakout",   "Connector_PinHeader_2.54mm:PinHeader_1x06_P2.54mm_Vertical", "6-pin: VCC,GND,MISO,MOSI,SCK,CS"),
    "J2":  ("Keyboard_Matrix",    "Connector_PinHeader_2.54mm:PinHeader_1x18_P2.54mm_Vertical", "ASSUMPTION -- placeholder connector for 10 rows + 8 columns, not an actual part in wiring.md"),
    # Resistors -- one per pull-up/down net in wiring.md's summary table
    "R1":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "_WR pull-up to VCC"),
    "R2":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "_MREQ pull-up to VCC"),
    "R3":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "_RD pull-up to VCC"),
    "R4":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "A14 pull-up to VCC"),
    "R5":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "A15 pull-up to VCC"),
    "R6":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "mode_pin pull-down to GND"),
    "R7":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "bank pull-down to GND"),
    "R8":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "_INT pull-up to VCC"),
    "R9":  ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "_NMI pull-up to VCC"),
    "R10": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "POR pull-down to GND"),
    "R11": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col0 (8255 PB0) pull-up"),
    "R12": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col1 (8255 PB1) pull-up"),
    "R13": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col2 (8255 PB2) pull-up"),
    "R14": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col3 (8255 PB3) pull-up"),
    "R15": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col4 (8255 PB4) pull-up"),
    "R16": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col5 (8255 PB5) pull-up"),
    "R17": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col6 (8255 PB6) pull-up"),
    "R18": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "keyboard col7 (8255 PB7) pull-up"),
    "R19": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "SD MISO pull-up to VCC"),
    "R20": ("10k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "_BUSRQ pull-up to VCC"),
    # Decoupling: 100nF per chip (wiring.md: "right at every chip's own power pins")
    "C1":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U1 decoupling"),
    "C2":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U2 decoupling"),
    "C3":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U3 decoupling"),
    "C4":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U4 decoupling"),
    "C5":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U5 decoupling"),
    "C6":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U6 decoupling"),
    "C7":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U7 decoupling"),
    "C8":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U8 decoupling"),
    "C9":  ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U9 decoupling"),
    "C10": ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U10 decoupling"),
    "C11": ("100nF", "Capacitor_THT:C_Disc_D3.0mm_W2.0mm_P2.50mm", "U11 decoupling"),
    "C12": ("1000uF", "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm",   "bulk electrolytic, power entry (wiring.md: general guidance, exact placement/count/value not specified)"),
    "C13": ("1000uF", "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm",   "bulk electrolytic, near larger chips"),

    # Composite video driver, added
    # to wiring.md's own new section. D1/D2 diode-OR the two syncs; Q1
    # mixes that with the pixel stream; C14 AC-couples the result to J3.
    "D1":  ("1N4148", "Diode_THT:D_DO-35_SOD27_P10.16mm_Horizontal", "sync mixer: cathode=HSYNC, anode=SYNC_MIX"),
    "D2":  ("1N4148", "Diode_THT:D_DO-35_SOD27_P10.16mm_Horizontal", "sync mixer: cathode=VSYNC, anode=SYNC_MIX"),
    "Q1":  ("BC547", "Package_TO_SOT_THT:TO-92_Inline",
            "NPN mixer/buffer -- ASSUMPTION: pad1=E,pad2=B,pad3=C, the "
            "standard TO-92 BC547 pinout (flat face, leads down, left to "
            "right) -- verify against your actual part before building"),
    "R21": ("1k",   "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "SYNC_MIX pull-up to VCC"),
    "R22": ("330R", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "SYNC_MIX -> Q1 base"),
    "R23": ("500R", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal",
            "Q1 base -> GND -- not a standard E12/E24 value, nearest common "
            "part is 470R or 560R, see docs/wiring.md"),
    "R24": ("2.2k", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "Q1 base <- 74LS166A QH"),
    "R25": ("330R", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "Q1 collector -> VCC"),
    "R26": ("220R", "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal", "Q1 emitter -> GND"),
    "C14": ("47uF", "Capacitor_THT:CP_Radial_D5.0mm_P2.50mm", "AC-couples Q1 emitter to the RCA jack"),
    "J3":  ("RCA_jack", "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
            "ASSUMPTION -- no RCA footprint in stock KiCad libraries, this "
            "is a 2-pin placeholder (pin1=signal, pin2=shield/GND); swap "
            "in your actual RCA connector's real footprint before fab"),
}

# net_name: [(ref, pin), ...]
nets = {}
def n(name, *pins):
    nets.setdefault(name, [])
    nets[name].extend(pins)

# ---- Address bus A0-A15 ----
addr_z80  = {0:30,1:31,2:32,3:33,4:34,5:35,6:36,7:37,8:38,9:39,10:40,11:1,12:2,13:3,14:4,15:5}
addr_sram = {0:12,1:11,2:10,3:9,4:8,5:7,6:6,7:5,8:4,9:3,10:31,11:28,12:27,13:26,14:25,15:23}
addr_avr  = {0:40,1:39,2:38,3:37,4:36,5:35,6:34,7:33,8:22,9:23,10:24,11:25,12:26,13:27}  # A14/A15 not AVR pins
for i in range(16):
    net = f"A{i}"
    n(net, ("U1", addr_z80[i]), ("U6", addr_sram[i]))
    if i in addr_avr:
        n(net, ("U2", addr_avr[i]))
n("A14", ("R4", 1)); n("A15", ("R5", 1), ("U11", 2))
n("A3", ("U8", 1)); n("A4", ("U8", 2)); n("A5", ("U8", 3))
n("A6", ("U8", 5)); n("A7", ("U8", 6))
n("A16", ("U6", 2), ("U11", 6))

# ---- Data bus D0-D7 ----
d_z80   = {0:14,1:15,2:12,3:8,4:7,5:9,6:10,7:13}
d_595   = {0:15,1:1,2:2,3:3,4:4,5:5,6:6,7:7}
d_sram  = {0:13,1:14,2:15,3:17,4:18,5:19,6:20,7:21}
d_8255  = {0:27,1:28,2:29,3:30,4:31,5:32,6:33,7:34}
d_166   = {0:2,1:3,2:4,3:5,4:10,5:11,6:12,7:14}
for i in range(8):
    net = f"D{i}"
    n(net, ("U1", d_z80[i]), ("U3", d_595[i]), ("U6", d_sram[i]), ("U9", d_8255[i]), ("U7", d_166[i]))

# ---- Control signals ----
n("_MREQ", ("U1",19), ("U6",22), ("U2",18), ("R2",1))
n("_RD",   ("U1",21), ("U4",12), ("U5",1), ("U5",2), ("U2",20), ("U9",5), ("R3",1))
n("_WR",   ("U1",22), ("U6",29), ("U9",36), ("R1",1))
# R1/R2/R3 pin1: same bug class as R11-R18 above -- pin2 was wired to
# +5V but pin1 was never wired to the actual net it pulls up. Bench-
# found (2026-09-20) alongside the keyboard resistors.
n("_IORQ", ("U1",20), ("U8",4))
n("_WAIT", ("U1",24), ("U4",9))
n("_BUSRQ",("U1",25), ("U2",21), ("R20",1))
n("_BUSACK",("U1",23), ("U11",5))
n("POR",   ("U1",26), ("U2",16), ("U4",13), ("U11",12), ("U11",13), ("R10",1))
n("_8255_RESET", ("U11",11), ("U9",35))
n("_INT", ("U1",16), ("R8",1))
n("_NMI", ("U1",17), ("R9",1))
n("CLK_8MHz", ("U1",6), ("U4",5), ("U4",11))
n("CLK_16MHz", ("U4",3), ("U7",7), ("U2",13), ("X1",5))
n("FF1_toggle", ("U4",2), ("U4",6))     # D1 <-> Q1', the toggle-FF trick
n("wait_rel", ("U2",17), ("U4",10))     # AVR PD3 -> FF2 /PRE2

# ---- SH_LD / video ----
n("SH_LD", ("U2",19), ("U7",15))
n("HSYNC", ("U2",28), ("D1",1))     # D1 pad1=cathode (standard KiCad diode convention)
n("VSYNC", ("U2",29), ("D2",1))     # D2 pad1=cathode
n("VIDEO_QH", ("U7",13), ("R24",1))

# ---- Composite video driver ----
n("SYNC_MIX", ("D1",2), ("D2",2), ("R21",1), ("R22",1))   # pad2=anode on both diodes
n("Q1_BASE", ("R22",2), ("R23",1), ("R24",2), ("Q1",2))    # Q1 pad2 = Base (assumed EBC)
n("Q1_COLLECTOR", ("Q1",3), ("R25",2))                     # Q1 pad3 = Collector
n("Q1_EMITTER", ("Q1",1), ("R26",1), ("C14",1))            # Q1 pad1 = Emitter; C14 pad1 = '+'
n("COMPOSITE_OUT", ("C14",2), ("J3",1))                    # C14 pad2 = '-'

# ---- 74HC595 control ----
n("RCLK",  ("U2",5), ("U3",12))
n("SER",   ("U2",6), ("U3",14))
n("SRCLK", ("U2",8), ("U3",11))
n("595_OE",("U5",11), ("U3",13))

# ---- 74LS00 #1 internal + mode_pin ----
n("mode_pin", ("U9",4), ("U5",4), ("U5",5), ("U5",12), ("R6",1))
n("NOT_RD",   ("U5",3), ("U5",10), ("U5",13))
n("NOT_mode_pin", ("U5",6), ("U5",9))
n("SRAM_OE",  ("U5",8), ("U6",24))

# ---- 74LS00 #2 internal + bank ----
n("bank", ("U9",3), ("U11",1), ("R7",1))
n("X_bank_a15_nand", ("U11",3), ("U11",4))
n("GATE3_UNUSED_U11", ("U11",9), ("U11",10))   # tied LOW per wiring.md -- see GND net too

# ---- 74LS138 outputs ----
n("_8255_CS", ("U8",10), ("U9",6))
# O0-O4,O6,O7 spare/unused -- left as single-pin nets (no other connection)
for pin in (15,14,13,12,11):
    n(f"U8_O_SPARE_{pin}", ("U8", pin))
n("U8_O6_SPARE", ("U8", 9))
n("U8_O7_SPARE", ("U8", 7))

# ---- 8255 misc ----
n("Z80_A0", ("U1",30), ("U9",9))   # 8255's own A0 register-select pin, taps the A0 bus net
n("Z80_A1", ("U1",31), ("U9",8))
# (folded into A0/A1 nets below instead of a separate name -- see merge step)

# ---- SD card ----
n("SD_CS",   ("U9",2), ("J1",6))
n("SD_SCK",  ("U9",1), ("J1",5))
n("SD_MOSI", ("U9",40), ("J1",4))
n("SD_MISO", ("U9",10), ("J1",3), ("R19",1))

# ---- Keyboard ----
kb_pc = {0:14,1:15,2:16,3:17}
kb_145 = {0:12,1:13,2:14,3:15}
for i in range(4):
    n(f"KB_ROWSEL{i}", ("U9", kb_pc[i]), ("U10", kb_145[i]))
kb_pb = {0:18,1:19,2:20,3:21,4:22,5:23,6:24,7:25}
for i in range(8):
    n(f"KB_COL{i}", ("U9", kb_pb[i]), (f"R{11+i}", 2), ("J2", 11+i))
kb_row_out = [1,2,3,4,5,6,7,9,10,11]  # 74LS145 Q0-Q9
for i, pin in enumerate(kb_row_out):
    n(f"KB_ROW{i}", ("U10", pin), ("J2", i+1))

# ---- Power / ground ----
n("+5V",
  ("U1",11), ("U2",10), ("U2",30), ("U3",16), ("U4",14), ("U5",14), ("U6",32),
  ("U7",16), ("U7",9), ("U8",16), ("U9",26), ("U10",16), ("U11",14),
  ("U3",10),                     # 74HC595 MR-bar tied high
  ("J1",1),
  ("R1",2),("R2",2),("R3",2),("R4",2),("R5",2),("R8",2),("R9",2),("R19",2),("R20",2),
  # R11-R18 (keyboard column pull-ups): pad2 was already wired to each
  # KB_COLx net below, but pad1 -> +5V was missing entirely -- bench-
  # found (2026-09-20): every one of these pads showed a blank net on
  # the real board, not just an unrouted ratsnest. wiring.md: "keyboard
  # columns (PB0-PB7) | 4.7k-10k to VCC, one per column".
  ("R11",1),("R12",1),("R13",1),("R14",1),("R15",1),("R16",1),("R17",1),("R18",1),
  ("C1",1),("C2",1),("C3",1),("C4",1),("C5",1),("C6",1),("C7",1),("C8",1),("C9",1),("C10",1),("C11",1),
  ("C12",1),("C13",1),
  ("X1",8),
  ("U4",1),("U4",4),             # FF1 /CLR,/PRE tied high (unused async control)
  ("U6",30),                     # SRAM CE2 tied active-high
  ("R21",2), ("R25",1),          # composite video driver
  )
n("GND",
  ("U1",29), ("U2",11), ("U2",31), ("U3",8), ("U4",7), ("U5",7), ("U6",16),
  ("U7",8), ("U7",6), ("U7",1),  # 74LS166A GND, CLK_INH, SER all tied to GND
  ("U8",8), ("U9",7), ("U10",8), ("U11",7),
  ("U5",9) if False else ("U11",9), ("U11",10),   # gate3 unused inputs tied low
  ("J1",2),
  ("R6",2),("R7",2),("R10",2),
  ("C1",2),("C2",2),("C3",2),("C4",2),("C5",2),("C6",2),("C7",2),("C8",2),("C9",2),("C10",2),("C11",2),
  ("C12",2),("C13",2),
  ("X1",4),
  ("R23",2), ("R26",2), ("J3",2),   # composite video driver
  )

# ---- Merge the two duplicate-name Z80_A0/A1 taps into A0/A1 ----
nets["A0"].extend(nets.pop("Z80_A0"))
nets["A1"].extend(nets.pop("Z80_A1"))

# ---- Sanity: dedupe any (ref,pin) that ended up listed twice in one net ----
for k in nets:
    seen = set()
    out = []
    for ref, pin in nets[k]:
        key = (ref, pin)
        if key not in seen:
            seen.add(key)
            out.append(key)
    nets[k] = out

# ---- Emit KiCad netlist s-expression ----
lines = []
lines.append('(export (version "E")')
lines.append('  (design')
lines.append('    (source "docs/wiring.md")')
lines.append('    (date "2026-09-20")')
lines.append('    (tool "hand-generated from wiring.md, not eeschema -- see accompanying notes"))')
lines.append('  (components')
for ref in sorted(components, key=lambda r: (r[0], int(''.join(c for c in r if c.isdigit()) or 0))):
    value, footprint, desc = components[ref]
    lines.append(f'    (comp (ref "{ref}")')
    lines.append(f'      (value "{value}")')
    lines.append(f'      (footprint "{footprint}")')
    lines.append(f'      (libsource (lib "") (part "{value}") (description "{desc}"))')
    lines.append(f'      (sheetpath (names "/") (tstamps "/"))')
    lines.append(f'      (tstamps "{ref}"))')
lines.append('  )')
lines.append('  (nets')
code = 0
for name in sorted(nets):
    code += 1
    lines.append(f'    (net (code "{code}") (name "{name}")')
    for ref, pin in nets[name]:
        lines.append(f'      (node (ref "{ref}") (pin "{pin}"))')
    lines.append('    )')
lines.append('  )')
lines.append(')')

with open("/home/p2/claude-code/z80-with-1284p/hardware/board.net", "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"components: {len(components)}")
print(f"nets: {len(nets)}")
print(f"total nodes: {sum(len(v) for v in nets.values())}")

# ---- Cross-check: every component pin referenced should be within its DIP pin count ----
pin_counts = {"DIP-40":40,"DIP-16":16,"DIP-14":14,"DIP-32":32}
for ref,(value,footprint,desc) in components.items():
    for key,cnt in pin_counts.items():
        if key in footprint:
            maxpin = cnt
            break
    else:
        maxpin = None
    if maxpin:
        for name, nodelist in nets.items():
            for r,p in nodelist:
                if r == ref and (not isinstance(p,int) or p < 1 or p > maxpin):
                    print(f"OUT OF RANGE: {ref} pin {p} in net {name} (max {maxpin})")
