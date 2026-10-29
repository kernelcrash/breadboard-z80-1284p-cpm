The video output stage is
- The HSYNC and VSYNC pins each go to 1N4148 diodes. The anodes are tied together and the cathodes go to HSYNC and VSYNC.
- The diode anodes go to a 1K pullup and then the anodes go to a 330 ohm that goes to the base of a BC547.
- The base is also connected to a 500 ohm to ground
- The base also goes to a 2.2k resistor that goes to the video out of the 74ls166
- The collector of the BC547 goes to a 330 ohm to +5V
- the emitter goes to a 220 ohm to ground
- the emitter also goes to the positive lead of a 47uF electrolytic. The negative pin is the composite video output.
- The composite video out and GND got to a RCA socket.


