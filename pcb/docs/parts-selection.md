# Rev A parts and architecture selection

This is the selected **Rev A design baseline**, not a purchasing release or completed schematic. These decisions supersede the earlier candidate shortlist. Supporting calculations and operating modes are in [rev-a-design.md](rev-a-design.md); current allocations are in [power-budget.md](power-budget.md). Stock and price are not guaranteed. Linked-only drawings still require the normal footprint/dimension check before PCB release.

## Power and connectors

Use **two USB-C connectors**: a power-only input and a self-powered USB 2.0 debug connection. The debug connector does not feed the power mux. Full peripheral operation uses either external 5 V / 4 A or an accepted **USB-PD 9 V / 3 A** contract. The previous reduced USB envelope is removed; see [usb-c-pd.md](usb-c-pd.md).

| Function | Selected part / initial quantity | Connection / rationale | Reference |
|---|---|---|---|
| USB-C power and debug receptacles | GCT USB4105-GF-A / 2 | Same footprint family, distinctly labeled POWER and DEBUG; power-only D+/D- left unconnected | [Drawing](datasheets/USB4105.pdf) |
| USB-PD sink controller, POWER connector | ST STUSB4500QTR / 1 | Standalone, NVM-provisioned 9 V / 3 A; hardware-qualified PDO2 status, no FPGA dependency | [Datasheet](datasheets/STUSB4500.pdf), [implementation](usb-c-pd.md) |
| DEBUG CC protection | TI TPD2E2U06DRLR / 1 | DEBUG CC1/CC2 only; POWER uses STUSB4500 high-voltage CC protection, with any extra ESD network separately qualified | [Datasheet](datasheets/TPD2E2U06.pdf) |
| DEBUG CC termination | Vishay CRCW06035K10FKEA / 2 | Independent 5.1 kOhm 1% Rd on DEBUG CC1 and CC2; POWER uses controller dead-battery Rd, not duplicate resistors | [Resistor family](datasheets/CRCW-resistors.pdf) |
| Source input protection | TI TPS259470ARPWR / 2 | One per power input; reverse polarity, reverse current, OVP, current limit and slew control. No extra series reverse-polarity MOSFET required | [Datasheet](datasheets/TPS25947.pdf) |
| Power mux | TI TPS2121RUXR / 1 | External 5 V IN1 has priority over qualified PD 9 V IN2; output is a 5 V-or-9 V converter bus, never direct peripheral VBUS | [Datasheet](datasheets/TPS2121.pdf) |
| Always-on regulator | TI TPS7A1601DGNR / 1 | Adjustable, set to approximately 2.983 V; powered through diode OR from the two raw power inputs | [Datasheet](datasheets/TPS7A16.pdf) |
| AON diode OR | BAT54C common-cathode dual Schottky / 1 | Only carries the <=5 mA control allocation; never the main load | [Nexperia family, linked only](https://assets.nexperia.com/documents/data-sheet/BAT54.pdf) |
| Main 3.3 V regulator | TI TPS63070RNMR / 1 | Buck-boost, not the earlier buck: retains regulation when input headroom falls | [Datasheet](datasheets/TPS63070.pdf) |
| Regulated peripheral 5.088 V | TI TPS63070RNMR / 1 | Feeds FT232H VREGIN and host switch; solves host VBUS voltage loss through input mux/protection | [Datasheet](datasheets/TPS63070.pdf) |
| Core 1.1 V buck | TI TPS62130RGTR / 1 | Nominal resistor target 1.0992 V; 3 A rating; programmable soft start | [Datasheet](datasheets/TPS62130.pdf) |
| Auxiliary 2.5 V buck | TI TPS62130RGTR / 1 | Nominal resistor target 2.496 V; independent soft start replaces the earlier fixed LDO proposal | [Datasheet](datasheets/TPS62130.pdf) |
| Buck inductors | Bourns SRP4020TA-2R2M / 2 | 2.2 uH at nominal 1.25 MHz for 5 V/9 V operation; 4 A thermal / 6 A saturation family ratings | [Datasheet](datasheets/SRP4020TA.pdf) |
| Buck-boost inductors | Bourns SRP4020TA-1R5M / 2 | 1.5 uH; 4.5 A thermal / 7 A saturation; fits the converter's recommended nominal inductance | [Datasheet](datasheets/SRP4020TA.pdf) |
| Slow reset and source qualification | TI TPS3808G01DBVR / as required by schematic | Use for AON delay, external-input qualification and delayed combined power-good reset; its adjustable threshold is **±2% maximum**, not its typical ±1% | [Datasheet](datasheets/TPS3808.pdf) |
| Hardware qualification gates | TI SN74LVC2G02DCUR, SN74LVC1G08DBVR, SN74LVC1G32DBVR | PD active-low status decode, enable qualification and selected-full-source peripheral gating, powered from AON; final gate count from schematic | [NOR](datasheets/SN74LVC2G02.pdf), [AND](datasheets/SN74LVC1G08.pdf), [OR](datasheets/SN74LVC1G32.pdf) |
| External power header | JST B2P-VH(LF)(SN) / 1 | Keyed 3.96 mm, pin 1 +5 V, pin 2 GND | [JST drawing, linked only](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf) |
| External power harness | VHR-2N housing + two SVH-21T-P1.1 contacts, 18 AWG | Use correctly crimped contacts and a short cable; never connect AC mains to the board | Same JST reference |
| External adapter | Mean Well GST25A05-P1J | 5 V / 4 A, 20 W; center-positive 5.5/2.1 mm output, needs a correctly rated barrel-to-VH harness | [Datasheet](datasheets/MeanWell-GST25A.pdf) |
| USB raw-input TVS, selected / DNP pending qualification | Vishay SMBJ12A-E3/52 / 1 | Unidirectional, 12 V stand-off, SMB; before USB eFuse, cathode to raw VBUS. 19.9 V max clamp at specified 30.2 A pulse is **not** safe directly for the 16 V converter bus. See coordination and sustained-fault limits in [PD implementation](usb-c-pd.md) | [Manufacturer datasheet](datasheets/Vishay-SMBJ.pdf) |
| Transient clamp footprints | Littelfuse SMF5.0CA / external branch only | After external 5 V eFuse. **Never populate on the 9 V USB branch**; USB clamp footprint stays unpopulated until coordinated with eFuse/converter limits | [Manufacturer family, linked only](https://www.littelfuse.com/products/overvoltage-protection/tvs-diodes/surface-mount/smf.aspx) |

## FPGA, configuration and memory

| Function | Selected part / quantity | Notes | Reference |
|---|---|---|---|
| FPGA | Lattice LFE5U-45F-6BG381C / 1 | Existing project symbol/footprint; preserve exact device | [Family datasheet](ECP5-ECP5-5G-Family-Data-Sheet-FPGA-DS-02012-v3.4.pdf) |
| Main reference oscillator | Abracon ASV-24.000MHZ-LJ-T / 1 | 3.3 V, ±20 ppm option; 24 MHz supports exact 48/96 MHz PLL outputs | [Datasheet](datasheets/ASV.pdf) |
| Boot/application flash | Winbond W25Q128JVSIQ / 1 | 128 Mbit = 16 MiB, 3.3 V, SOIC-8; initial boot uses standard single-bit SPI | [Datasheet](datasheets/W25Q128JV.pdf) |
| SDR SDRAM | ISSI IS42S16160J-7TLI / 1 | 16M x16 = 32 MiB, 3.3 V, 54-pin TSOP-II, 143 MHz grade; initial target is 48 MHz, not the part's limit | [Datasheet](datasheets/IS42S16160J.pdf) |
| JTAG isolation | TI SN74LVC125APWR / 1 | Three channels buffer FTDI TCK/TMS/TDI with recovery OE jumper; fourth independently enabled channel buffers AON full-power-valid into main 3.3 V domain | [Datasheet](datasheets/SN74LVC125A.pdf) |

Reference guides: [hardware checklist](datasheets/ECP5-Hardware-Checklist.pdf), [power calculation](datasheets/ECP5-Power-Management.pdf), [configuration](datasheets/ECP5-sysCONFIG.pdf), [PLL/clocking](datasheets/ECP5-sysCLOCK.pdf). The [pin plan](pin-plan.csv) accounts for 107 unique balls, including dedicated configuration/JTAG pins. It is a package-checked starting allocation, not place-and-route signoff.

## USB debug/programming

| Function | Selected part / quantity | Notes | Reference |
|---|---|---|---|
| USB 2.0 internal hub | Microchip USB2512B-AEZG / 1 | Self-powered, two permanently attached FTDI devices; upstream VBUS sensing from DEBUG connector | [Datasheet](datasheets/USB251xB.pdf) |
| JTAG and UART bridge | FTDI FT2232HL / 1 | LQFP-64; A=MPSSE JTAG, B=UART | [Datasheet](datasheets/FT2232H.pdf) |
| Bulk FIFO bridge | FTDI FT232HL / 1 | LQFP-48; **5 V-input power mode**, from regulated 5.088 V rail | [Datasheet](datasheets/FT232H.pdf) |
| FTDI EEPROMs | Microchip 93LC56BT-I/SN / 2 | 128x16 organization. FT232H explicitly rejects 93LC46B | [Datasheet](datasheets/93LC56B.pdf) |
| FIFO powered/unpowered isolation | TI SN74CB3Q3245PWR / 2 | 16 available switch channels cover 8 data + 6 controls + 60 MHz clock; Ioff support; OE held off until domains are powered | [Datasheet](datasheets/SN74CB3Q3245.pdf) |
| FTDI clock crystals | Abracon ABM3B-12.000MHZ-10-1-U-T / 2 | 12 MHz, 10 pF CL, ±10 ppm initial / tight stability option; total error and startup verified during bring-up | [Datasheet](datasheets/ABM3B.pdf) |
| Hub crystal | Abracon ABM3B-24.000MHZ-10-1-U-T / 1 | 24 MHz, same family | [Datasheet](datasheets/ABM3B.pdf) |
| DEBUG D+/D- ESD | TI TPD2EUSB30DRTR / 1 | Low-capacitance protection near connector | [Datasheet](datasheets/TPD2EUSB30.pdf) |

FT232H power: VREGIN gets regulated 5.088 V; VCCD is then a **local output**, feeding its VCCIO/VPLL/VPHY and its EEPROM. Follow the reference circuit for VCCA/VCORE. **Never join VCCD to the board 3.3 V rail.** Its whole allocation therefore belongs to the 5.088 V converter, not the main 3.3 V converter. This removes the earlier external-3.3 V minimum-input ambiguity.

FT232H EEPROM selects 245 mode; host software then calls `FT_SetBitMode(..., 0x40)` (or equivalent libftdi API) for synchronous FIFO. A blank EEPROM does not boot directly into synchronous FIFO mode. FIFO clock is 60 MHz and must cross asynchronously to the system's 48 MHz domain. FTDI local regulator outputs are not general board power sources.

## USB host

| Function | Selected part / quantity | Notes | Reference |
|---|---|---|---|
| External transceiver | TI TUSB1106PWR / 1 | 16-pin TSSOP; differential VPO/VMO interface; external 3.3 V power mode | [Datasheet](datasheets/TUSB1106.pdf) |
| USB-A connector | TE Connectivity 292303-1 / 1 | Through-hole full-size socket | [Product/drawing, linked only](https://www.te.com/en/product-292303-1.html) |
| Host current-limited switch | TI TPS2553DBVR / 1 | Feed from regulated 5.088 V; 44.2 kOhm ILIM resistor; selected external or accepted PD source required for enable | [Datasheet](datasheets/TPS2553.pdf) |
| Host D+/D- ESD | TI TPD2EUSB30DRTR / 1 | Same part as debug protection | [Datasheet](datasheets/TPD2EUSB30.pdf) |
| Host output bulk capacitor | Rubycon 35ZLH150MEFC6.3X11 / 1 | 150 uF, ±20%, 35 V, 6.3x11 mm, 2.5 mm pitch. Family table confirms this value/size and 94 mOhm max impedance at 20°C/100 kHz | [Datasheet](datasheets/Rubycon-ZLH.pdf) |
| Host output bleed | Vishay CRCW06031K00FKEA / 1 | 1 kOhm after switch; about 5.1 mA, <=27 mW; discharges output when off | [Resistor family](datasheets/CRCW-resistors.pdf) |
| Host bus pull-downs | Vishay CRCW060315K0FKEA / 2 | 15 kOhm from D+ and D- to GND, subject to selected PHY reference configuration; no device pull-up |

Selected logic path is UltraEmbedded `core_usb_host` + `core_usb_fs_phy`, both at 48 MHz, mapped to TUSB1106 differential pins. Rev A supports **full-speed 12 Mbit/s only**. Do not advertise low-speed keyboard/mouse support or assume a USB hub provides an implemented low-speed transaction translator path. Host core is GPL-2.0-or-later; PHY is LGPL-2.1-or-later; a closed-source distribution needs appropriate licensing/alternative IP. See [design record](rev-a-design.md) for pinned source revisions and limited integration results.

## Controls, expansion and passives

| Function | Selected part / starting population | Notes / reference |
|---|---|---|
| Reconfigure, application reset, two user buttons | Omron B3U-1000P / 4 | [Datasheet](datasheets/B3U.pdf); active low; reset and PROGRAMN have different functions |
| Status LEDs | Kingbright APT1608SGC / up to 10 | [Datasheet](datasheets/Kingbright-LED.pdf); target ~2 mA, use 680 Ohm from 3.3 V or 1.5 kOhm from regulated 5.088 V as initial values |
| JTAG recovery | Samtec TSW-106-07-G-D / 1 | [Drawing](datasheets/Samtec-TSW.pdf); explicit board-specific pinout in design record, not an assumed ARM/SWD pinout |
| Pmod | Samtec TSW-106-07-G-D / 1 | 2x6, 8 GPIO, switched 3.3 V and ground; [drawing](datasheets/Samtec-TSW.pdf) |
| GPIO header | Samtec TSW-105-07-G-D / 1 | 2x5, 8 GPIO, switched 3.3 V and ground; [drawing](datasheets/Samtec-TSW.pdf) |
| UART header | Samtec TSW-104-07-G-S / 1 | GND, FPGA TX, FPGA RX, 3.3 V reference; no expansion-power allowance from this pin; [drawing](datasheets/Samtec-TSW.pdf) |
| Expansion power switch | TI TPS2553DBVR / 1 | 3.3 V input, 88.7 kOhm ILIM resistor; full-source-qualified enable (external or PD); 250 mA useful allocation shared by both headers |
| Test points | Keystone 5015 / rail + ground locations | [Catalog](datasheets/Keystone-5015.pdf) |
| 100 nF bypass | Murata GRM188R71C104KA01D | 0603 X7R 16 V for low-voltage rails, **not raw PD bypass** (use >=25 V there); [manufacturer product data](https://www.murata.com/en-us/products/productdetail?partno=GRM188R71C104KA01D) |
| 1 uF bypass | Murata GRM188R61A105KA61D | 0603 X5R 10 V for low-voltage rails, **not raw PD bypass** (use >=25 V there); [manufacturer product data](https://www.murata.com/en-us/products/productdetail?partno=GRM188R61A105KA61D) |
| 22 uF ceramic reservoir | Murata GRM32ER71C226KE18L | 1210 X7R 16 V, ±10%; larger package for DC-bias headroom; [manufacturer product data](https://www.murata.com/en-us/products/productdetail?partno=GRM32ER71C226KE18L) |
| Mux-bus bulk | Rubycon 35ZLH150MEFC6.3X11 / 2 | 300 uF total, 35 V, 6.3x11 mm each; replaces the old 10 V bulk for PD voltage headroom; [family](datasheets/Rubycon-ZLH.pdf) |
| Crystal load capacitors | Murata GRM1885C1H160JA01D / 6 | 16 pF C0G 50 V, ±5%; initial equal loads for CL=10 pF with estimated 2 pF stray. Tune against actual PCB/crystal error, not an assumed exact stray |
| Buck SS capacitors | Murata GRM188R71C104KA01D / 2 | 100 nF, programmable ramp; calculation in design record |
| Feedback/programming resistors | Vishay TNPW0603 series | 0.1% for feedback/dividers, 1% current-limit resistors as explicitly calculated; [manufacturer family](https://www.vishay.com/docs/28758/tnpw_e3.pdf) |
| General resistors / terminations | Vishay CRCW0603 series | 1%; 0/22/33 Ohm series options; 4.7/10/47/100 kOhm pullup/down choices per interface; [family](datasheets/CRCW-resistors.pdf) |

Capacitor quantity/placement is set by the IC supply-pin counts and the completed schematic, not this parts-family list. Converter output **effective** capacitance, crystal loading, signal termination and power transients require layout-specific validation; a catalogue nominal value alone is not that validation. There is no reason to purchase exact passive quantities before the schematic is complete.

Manufacturer pages confirmed TUSB1106 and TPS63070 as ACTIVE during this pass. This is not confirmation of distributor stock. The FTDI/ISSI local PDFs are older manufacturer documents from identified mirrors; recheck current revisions at ordering time. [datasheet-sources.csv](datasheet-sources.csv) records the local PDF provenance and hashes.
