# roco

**Ronak's Computer** — an FPGA-based computer board built around the Lattice ECP5.

## Status

Early hardware design. The KiCad project has an organized schematic hierarchy, with a documented Rev A architecture, component selections, pin allocation, and provisional power budget. Circuit implementation and PCB layout are not complete; the board has not been fabricated or electrically validated.

## Planned features

- ECP5 FPGA with SDRAM and SPI configuration flash
- USB JTAG/UART debugging and a dedicated USB FIFO link
- Full-speed USB host port
- USB-C Power Delivery input, with a separate USB-C debug connection
- External power input, user controls, and 3.3 V expansion headers

These describe the design baseline, not tested hardware capabilities.

## Project

Open [`roco.kicad_pro`](roco.kicad_pro) in **KiCad 10**. Start with [`roco.kicad_sch`](roco.kicad_sch) for the top-level schematic hierarchy. Project-local symbols and footprints are under [`libraries/`](libraries/).

## Documentation

- [Rev A design and release checks](docs/rev-a-design.md)
- [Parts selection](docs/parts-selection.md)
- [USB-C PD interface](docs/usb-c-pd.md)
- [Power budget](docs/power-budget.md)
- [Pin allocation](docs/pin-plan.csv)
- [Datasheets](docs/datasheets/) and [source provenance](docs/datasheet-sources.csv)

Recalculate the provisional power budget with Python 3.9 or newer:

```sh
python3 docs/calculate_power_budget.py
```

Engineering assumptions and remaining validation work are recorded in the design documents. This project is not ready for fabrication.
