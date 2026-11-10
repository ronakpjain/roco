# roco

**Ronak's Computer** — a Lattice ECP5-based computer board. Early hardware design; schematics and PCB layout are incomplete.

## Layout

```text
pcb/
├── roco.kicad_pro   KiCad 10 project
├── roco.kicad_sch   Top-level schematic
├── roco.kicad_pcb   PCB layout
├── *.kicad_sch      Hierarchical schematic sheets
├── libraries/       Symbols, footprints, and 3D models
└── docs/            Design notes, budgets, pin plan, and datasheets
cpu/                 Empty; reserved for CPU/RTL development
```

Open [`pcb/roco.kicad_pro`](pcb/roco.kicad_pro) in KiCad 10.

## Documentation

- [Rev A design](pcb/docs/rev-a-design.md)
- [Parts selection](pcb/docs/parts-selection.md)
- [USB-C PD](pcb/docs/usb-c-pd.md)
- [Power budget](pcb/docs/power-budget.md) and [current allocations](pcb/docs/current-budget.csv)
- [Pin plan](pcb/docs/pin-plan.csv)
- [Datasheets](pcb/docs/datasheets/) and [sources](pcb/docs/datasheet-sources.csv)

Power-budget calculator (Python 3.9+):

```sh
python3 pcb/docs/calculate_power_budget.py
```
