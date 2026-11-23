# Estimated current usage

Planning estimates, not measured consumption or guaranteed maximums. FPGA usage depends on the implemented design. Includes the full USB-A and expansion loads.

| Component / load | Supply | Estimated current |
|---|---:|---:|
| FPGA core | 1.1 V | 3,000 mA |
| FPGA auxiliary | 2.5 V | 100 mA |
| FPGA I/O banks | 3.3 V | 250 mA |
| SDRAM | 3.3 V | 180 mA |
| FT2232HL JTAG/UART bridge | 3.3 V | 200 mA |
| USB2512B hub | 3.3 V | 120 mA |
| SPI flash | 3.3 V | 30 mA |
| TUSB1106 USB host PHY | 3.3 V | 15 mA |
| 24 MHz oscillator | 3.3 V | 15 mA |
| FT2232H EEPROM | 3.3 V | 5 mA |
| LEDs | 3.3 V | 20 mA |
| Isolation, supervisors, buffers and pullups | 3.3 V | 30 mA |
| Expansion output, shared across headers | 3.3 V | 250 mA |
| FT232HL FIFO bridge and its EEPROM/local rails | 5.088 V | 200 mA |
| USB-A peripheral | 5.088 V | 500 mA |
| USB-A discharge resistor | 5.088 V | 6 mA |
| Always-on / input-control allowance | Raw 5 V input | 10 mA |

| Supply | Total current | Power |
|---|---:|---:|
| 1.1 V | **3,000 mA** | 3.300 W |
| 2.5 V | **100 mA** | 0.250 W |
| 3.3 V | **1,115 mA** | 3.680 W |
| 5.088 V | **706 mA** | 3.592 W |
| Raw 5 V control | **10 mA** | 0.050 W |
| **Total load power** | — | **10.872 W** |

Do not add currents from different-voltage rails to obtain USB input current.

**Estimated 5 V input current: about 2.9 A**, assuming 85% converter efficiency and 0.18 Ohm board input-path resistance, with 5 V delivered at the connector. This includes the 10 mA control allowance, but no extra load margin or external cable drop. With the previous 25% load margin it is about **3.6 A**. Laptop full-load operation is not yet verified.

The 1.1 V core estimate grows from the previous 2.0 A single-core planning estimate to 3.0 A for the dual-core 85F at high utilization. Validate with the Lattice Power Calculator against the routed bitstream before finalizing the regulator margins; the TPS62130 1.1 V buck is rated 3 A.
