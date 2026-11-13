# TPS259470ARPWR CAD import

Source: user-downloaded TI / Ultra Librarian `ul_TPS259470ARPWR.zip`, KiCADv6 export `2026-11-11_01-22-08.kicad_sym` and `RPW0010A-MFG.kicad_mod`.
TI CAD link: https://vendor.ultralibrarian.com/TI/embedded/?gpn=TPS25947&package=RPW&pin=10

Project symbol: `roco_power:TPS259470ARPWR` in `libraries/power.kicad_sym`.
Footprint: `roco:RPW0010A-MFG`.

The downloaded symbol used labels from the wrong variant. Corrected against local `docs/datasheets/TPS25947.pdf`, Table 5-1, physical pages 5–6:
- pin 2 OVCSEL -> OVLO
- pin 3 PG -> AUXOFF, open-collector electrical type for open-drain output
- pin 4 PGTH -> active-low FLT, open-collector electrical type for open-drain output
- qualified the footprint reference with the project library name.

All ten pin numbers/functions checked against Table 5-1. KiCad CLI successfully exported the symbol to SVG; pcbnew loaded the footprint with pads 1–10. Footprint geometry, copper shapes, paste apertures, clearances and manufacturing suitability still require review against the RPW package drawing; parsing and pad-number checks are not fabrication signoff. No schematic instance placed by this import.
