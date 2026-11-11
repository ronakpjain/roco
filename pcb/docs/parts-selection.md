# Parts selection

## Power

| Part | Qty | Purpose / short justification |
|---|---:|---|
| GCT USB4105-GF-A | 1 | Combined USB-C power and USB 2.0 debug connector. |
| TI TPS259470ARPWR | 2 | Input protection, current limiting and inrush control; one per input if external power is retained. USB programming values TBD. |
| TI TPS2121RUXR | 1 | Selects USB or optional external 5 V without backfeeding the sources. |
| TI TPS7A1601DGNR | 1 | Approximately 2.98 V always-on control supply. |
| BAT54C | 1 | Diode-OR for the low-current control supply. |
| TI TPS62130RGTR | 2 | Separate 1.1 V FPGA core and 2.5 V auxiliary bucks with soft start. Buck inductors/frequency TBD. |
| TI TPS63070RNMR | 2 | Regulated 3.3 V and 5.088 V despite input-path voltage drop. |
| Bourns SRP4020TA-1R5M | 2 | 1.5 µH inductors for the buck-boost converters. |
| TI TPS3808G01DBVR | TBD | Startup/reset supervision and source qualification. |
| TI SN74LVC2G02DCUR / SN74LVC1G08DBVR / SN74LVC1G32DBVR | TBD | Hardware enable and source-qualification logic; final circuit TBD. |
| TI TPD2E2U06DRLR | Candidate | CC ESD protection, subject to final sink circuit. |
| CC termination/current detector | TBD | Detects the laptop's advertised current before enabling board loads. |
| USB TVS and input bulk | TBD | Must suit the completed 5 V protection/inrush circuit. |
| JST B2P-VH(LF)(SN) | 1 optional | Keyed external 5 V connector. |
| VHR-2N + SVH-21T-P1.1 contacts | 1 housing + 2 contacts, optional | Matching external-power harness using 18 AWG wire. |
| Mean Well GST25A05-P1J | 1 optional | External 5 V / 4 A adapter; requires a suitable harness. |

## FPGA and memory

| Part | Qty | Purpose / short justification |
|---|---:|---|
| Lattice LFE5U-45F-6BG381C | 1 | ECP5 FPGA; existing project device and library. |
| Winbond W25Q128JVSIQ | 1 | 16 MiB SPI configuration/application flash. |
| ISSI IS42S16160J-7TLI | 1 | 32 MiB x16 SDR SDRAM. |
| Abracon ASV-24.000MHZ-LJ-T | 1 | 24 MHz reference for FPGA PLL clocks. |
| TI SN74LVC125APWR | 1 | JTAG buffering and powered-domain isolation for source status. |

## USB debug and FIFO

| Part | Qty | Purpose / short justification |
|---|---:|---|
| Microchip USB2512B-AEZG | 1 | Shares the upstream USB connection between both FTDI bridges; power-mode setup TBD. |
| FTDI FT2232HL | 1 | JTAG programming plus USB-UART. |
| FTDI FT232HL | 1 | Dedicated synchronous FIFO link; uses regulated 5.088 V input. Keep local VCCD separate from board 3.3 V. |
| Microchip 93LC56BT-I/SN | 2 | FTDI configuration EEPROMs; compatible with FT232H's required EEPROM family. |
| TI SN74CB3Q3245PWR | 2 | FIFO signal isolation when either domain is unpowered. |
| Abracon ABM3B-12.000MHZ-10-1-U-T | 2 | FTDI reference crystals. |
| Abracon ABM3B-24.000MHZ-10-1-U-T | 1 | Hub reference crystal. |
| TI TPD2EUSB30DRTR | 1 | Low-capacitance upstream USB data ESD protection. |

## USB host

| Part | Qty | Purpose / short justification |
|---|---:|---|
| TI TUSB1106PWR | 1 | External USB transceiver for full-speed 12 Mbit/s host operation. |
| TE Connectivity 292303-1 | 1 | Through-hole USB-A socket. |
| TI TPS2553DBVR | 1 | Host-port power limiting; 44.2 kΩ programming resistor for a 500 mA useful load. |
| TI TPD2EUSB30DRTR | 1 | Host USB data ESD protection. |
| Rubycon 35ZLH150MEFC6.3X11 | 1 | 150 µF host-port output reservoir. |
| Vishay CRCW06031K00FKEA | 1 | 1 kΩ host-port output discharge resistor. |
| Vishay CRCW060315K0FKEA | 2 | 15 kΩ host data pulldowns. |

## Controls, expansion and passives

| Part | Qty | Purpose / short justification |
|---|---:|---|
| Omron B3U-1000P | 4 | Reconfigure, reset and two user buttons. |
| Kingbright APT1608SGC | Up to 10 | Status/user LEDs, approximately 2 mA each. |
| Samtec TSW-106-07-G-D | 2 | JTAG recovery and Pmod headers. |
| Samtec TSW-105-07-G-D | 1 | GPIO header. |
| Samtec TSW-104-07-G-S | 1 | UART header. |
| TI TPS2553DBVR | 1 | Shared expansion power limiting; 88.7 kΩ programming resistor for a 250 mA useful load. |
| Keystone 5015 | As needed | Rail and ground test points. |
| Murata BLM18PG121SN1D | 1 | FPGA auxiliary supply filtering. |
| Murata GRM188R71C104KA01D | As needed | 100 nF bypass and buck soft-start capacitors. |
| Murata GRM188R61A105KA61D | As needed | 1 µF local bypass. |
| Murata GRM21BR61A106KE19L | As needed | 10 µF local bulk. |
| Murata GRM32ER71C226KE18L | As needed | 22 µF regulator/local reservoirs; check effective capacitance. |
| Murata GRM1885C1H160JA01D | 6 | Initial 16 pF crystal load capacitors; tune on hardware. |
| Vishay TNPW0603 series | As needed | Precision feedback/divider and current-programming resistors. |
| Vishay CRCW0603 series | As needed | General pulls, LED resistors and series terminations. |

Datasheets and provenance: [datasheet-sources.csv](datasheet-sources.csv). Exact footprints, values and quantities need checking against the completed schematic before ordering.
