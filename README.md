# roco

**Ronak's Computer** — a Lattice ECP5-based computer board. Early hardware design; schematics and PCB layout are incomplete.

## Layout

```text
pcb/                 roco_pcb: KiCad 10 hardware project
├── roco_pcb.kicad_pro
├── roco_pcb.kicad_sch
├── roco_pcb.kicad_pcb
├── *.kicad_sch      Hierarchical schematic sheets
├── libraries/       Symbols, footprints, and 3D models
└── docs/            Design notes, budgets, pin plan, and datasheets
cpu/                 roco_cpu: pipelined RV32I SoC (see cpu/README.md)
cc/                  roco_cc: C compiler, assembler, and linker
```

Open [`pcb/roco_pcb.kicad_pro`](pcb/roco_pcb.kicad_pro) in KiCad 10.

## Documentation

- [Parts selection](pcb/docs/parts-selection.md)
- [Power budget](pcb/docs/power-budget.md)
- [Pin plan](pcb/docs/pin-plan.csv)
- [roco_cpu](cpu/README.md)
- [roco_cc toolchain](cc/README.md)
- [Datasheets](pcb/docs/datasheets/) and [sources](pcb/docs/datasheet-sources.csv)
