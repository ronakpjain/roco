# Rev A engineering decisions

## Scope and status

The baseline is a **headless ECP5 development computer**, with SDRAM, USB JTAG/UART, a dedicated USB FIFO link, a full-speed USB host, and 3.3 V expansion. No display, Ethernet, microSD, high-speed USB host, or low-speed USB host is included. The hardware can later run a soft CPU, but choosing/implementing a CPU, USB software stack and firmware is separate from a board current budget.

This record settles the previously open **architecture choices**. It is not a claim that unbuilt circuits, PCB timing, FPGA power or USB compliance have been measured. Existing KiCad sheets are still an organizational skeleton. No new circuit was silently placed and no commit was made as part of this research.

## 1. Power connections and operating modes

Use two clearly labeled GCT USB4105-GF-A connectors:

- **POWER:** standalone STUSB4500 USB-PD sink, requesting **9 V / 3 A**. No USB data and no duplicate external Rd resistors. See [usb-c-pd.md](usb-c-pd.md) for NVM, hardware authorization, voltage ratings and support circuitry.
- **DEBUG:** USB 2.0 data into USB2512B. Two independent 5.1 kOhm Rd resistors. VBUS is sensed, never connected to the system power mux. The debug hub and FTDI devices remain self-powered.
- **EXTERNAL 5 V:** keyed JST VH input; full operation requires 5 V / 4 A at the board connector. Mean Well GST25A05-P1J remains the adapter baseline.

| Source condition | Main board | USB-A VBUS | Expansion power |
|---|---|---|---|
| DEBUG connector alone | Off | Off | Off |
| POWER connector, 5 V-only/non-PD/insufficient PDO | Off; negotiation/control only | Off | Off |
| POWER connector, accepted 9 V / 3 A PDO | Full allocated operating envelope | FPGA-requested | FPGA-requested |
| Qualified EXTERNAL 5 V | Full allocated operating envelope | FPGA-requested | FPGA-requested |
| Both full-capability sources | External preferred | FPGA-requested | FPGA-requested |

The earlier reduced USB mode is removed. USB PD and external power now have identical output-load allocations. These are not guarantees that an arbitrary bitstream fits: actual FPGA power still needs implementation/measurement. Cables/adapters must deliver the modeled voltage at the board connector. A USB-C charger must actually offer the fixed 9 V / 3 A profile.

## 2. Input protection, selection and authorization

Retain one TPS259470A per power input, then TPS2121, with EXTERNAL on IN1 and PD USB on IN2. The mux output is now a **5 V-or-9 V converter bus**, not a directly usable 5 V rail. All four output converters accept the nominal PD voltage. External 5 V retains priority.

The AON diode OR/TPS7A1601 remains approximately 2.983 V. STUSB4500 powers itself from raw USB VBUS and negotiates without the FPGA. Its NVM is programmed for two PDOs: mandatory 5 V / 0.5 A and 9 V / 3 A; above-5-V-only power authorization and dedicated PDO2 status are enabled. Both active-low VBUS_EN_SNK and POWER_OK2 must assert before AON logic enables the USB eFuse. POWER_OK2 alone is unsafe because it can remain asserted after detach.

Define FULL_POWER_VALID from a qualified **selected** source: external-valid with mux IN1 selected, or accepted PD with mux IN2 selected. Gate host and expansion requests with this signal, not external-only detection. Loss of source qualification resets the board if no other qualifying source is available. Do not promise seamless full-load handover. Buffer FULL_POWER_VALID into the FPGA domain using the fourth SN74LVC125A channel, powered from main 3.3 V with that channel's OE low. This avoids directly driving an unpowered FPGA input from AON; the other three channel OEs remain separately controlled for JTAG recovery.

For TPS2121 priority, CP2 gets about 1.49 V from an equal AON divider; PR1 is about 2.98 V when external-valid, 0 V otherwise. Use protected-input sensing and source status; check analog transition timing and unpowered states in the final schematic.

Programming baseline is consolidated in [usb-c-pd.md](usb-c-pd.md). External eFuse RILM remains 806 Ohm; USB becomes **1.27 kOhm**. USB OVLO and mux OV2 must be raised for 9 V while the external branch keeps its 5 V thresholds. Keep ITIMER open for fastest response, eFuse dVdt=10 nF and mux CSS=100 nF. DC limits are not instantaneous current ceilings.

Replace the old 10 V bus bulk with **two 35 V / 150 uF Rubycon capacitors**. Never populate the former 5 V TVS on the negotiated USB branch. USB TVS/clamp coordination remains an explicit release check; the PD document describes the required ratings and unpopulated footprint policy.

## 3. Regulator targets and sequence

The simple three-rail shortlist had two weaknesses: a fixed LDO did not establish the FPGA auxiliary ramp, and a nominal 5 V source could not guarantee USB-A VBUS after path loss. Use four converters:

| Rail | Converter | Feedback top/bottom, 0.1% | Calculated nominal |
|---|---|---|---:|
| Core | TPS62130 | 37.4 kOhm / 100 kOhm | 1.0992 V |
| Auxiliary | TPS62130 | 212 kOhm / 100 kOhm | 2.496 V |
| Main I/O | TPS63070 | 312 kOhm / 100 kOhm | 3.296 V |
| FT232H + host input | TPS63070 | 536 kOhm / 100 kOhm | 5.088 V |

Budget labels retain nominal 1.1/2.5/3.3 V. Their small resistor-target offsets are below other planning uncertainties, but the final power calculator should use actual rail tolerances. All are fed from the mux bus; the 2.5 V rail is **not an LDO load on 3.3 V** anymore.

- TPS62130: DEF=GND, FSW=main 3.3 V for 1.25 MHz nominal, **2.2 uH SRP4020TA-2R2M**, 100 nF SS/TR each. The lower frequency/larger inductor accommodates the 9 V PD input; check minimum-on-time behavior and the updated LC network. With ISS/TR=2.3–2.7 uA and C tolerance ±10%, approximately 26.7–38.3 ms to the 0.8 V reference, before other effects. The auxiliary average ramp is about 0.066–0.094 mV/us, well below the FPGA's **30 mV/us** ceiling. Verify the actual monotonic waveform and startup current.
- TPS63070: PS/SYNC=GND for forced PWM and the specified ±1% feedback accuracy; VSEL=GND, FB2 left unconnected for the single-target configuration. Fit 100 nF from VAUX to GND and never load VAUX externally. Use 1.5 uH SRP4020TA-1R5M.
- Start main 3.3 V first. Enable core and auxiliary only after I/O power-good. This satisfies Lattice's VCCIO-before-or-together requirement. Hold PROGRAMN/reset through startup and until combined power-good has been delayed; keep FTDI interfaces isolated until the relevant domains are powered.
- Combine all four converter PG outputs with an AON pullup, qualify that logic with main authorization, and feed the result to the delayed reset supervisor's MR input. Use TPS3808G01 sensing AON through 560 kOhm/100 kOhm and CT=18 nF for about 103 ms typical release delay. Its open-drain RESET holds PROGRAMN low; use a separate synchronized application reset inside the FPGA. Pull control outputs to their own valid domains, not local FT232H VCCD. Check unpowered PG behavior and logic thresholds in the completed circuit.
- Use PG outputs for sequencing, not as precision ±5% brownout detectors: their falling thresholds can be below the FPGA's recommended supply range. The internal FPGA POR and system reset behavior must be checked for brownout. Do not claim a 90%-of-output PG threshold proves operation remains valid down to that threshold.
- TPS3808G01 has ±2% maximum adjustable-threshold error. It cannot silently be treated as a ±0.5% precision rail-window monitor. If exact within-range brownout reset is required, select a tighter supervisor/window circuit and recheck both falling threshold and rising hysteresis before PCB release.

Starting capacitance population: TPS62130 input 22 uF + 100 nF each; output two 22 uF ceramic footprints each, including the effective downstream local capacitance in the LC stability check. TPS63070 input two 22 uF + 100 nF, output three 22 uF + 1 uF + 100 nF each, plus its separate 100 nF VAUX capacitor. Use the selected 16 V 1210 ceramics and verify their actual effective capacitance; do not substitute arbitrary tiny-package nominal equivalents. TPS63070 specifies 15–470 uF effective output capacitance for its nominal 1.5 uH network, including distributed/switched capacitance. Place the two 35 V / 150 uF electrolytics (300 uF total) after the input slew limiting. Verify all converter input capacitor effective values at 9.45 V. Large distributed FPGA capacitors participate in the regulator output network and cannot be ignored in the stability calculation.

The CABGA381 pinout has 20 VCC balls, 4 VCCAUX balls and 18 VCCIO balls. Following hardware-checklist Table 3.1, reserve **42 x 100 nF** close to these power balls, **3 x 10 uF** on core, **1 x 10 uF** on auxiliary after a **120 Ohm-at-100-MHz ferrite**, and local bulk on each of the seven I/O banks. Use 22 uF on SDRAM banks 0/1 and 10 uF on the other five as the starting bank population. Murata BLM18PG121SN1D is the auxiliary-bead selection; verify DCR/drop and damping with its local capacitor. 120 Ohm is the bead's high-frequency impedance, not a 120 Ohm series resistor. The general 10 uF selection is Murata GRM21BR61A106KE19L. These are additional local bypass locations, but their capacitance must be included in each regulator's total LC network.

These are starting populations supported by the converter application guidance, not a closed loop-stability/transient test. DC-bias curves, PCB parasitics and measured load steps are release checks.

## 4. Host VBUS limits and discharge

The host switch is TPS2553 fed by regulated 5.088 V. Use **44.2 kOhm 1%** RILIM, not 49.9 kOhm: the latter can limit below the desired 500 mA useful load.

Using datasheet min/max equations and resistor tolerance:

- At 44.2 kOhm: approximately **532–659 mA**.
- Useful peripheral allocation: 500 mA, plus ~5.1 mA for the bleed resistor.
- 150 uF ±20% gives **120 uF minimum nominal-tolerance bulk** at the host port.
- 1 kOhm bleed, maximum 180 uF capacitor and 5.15 V start: approximately **0.339 s to 0.8 V**, ignoring capacitor leakage and any attached device.
- Converter nominal 5.088 V with ±1% reference and 0.1% divider: roughly 5.03–5.15 V static. Allowing 135 mOhm switch plus a 40 mOhm board-path target at 500 mA gives about **4.94 V minimum static connector voltage** before load-transient droop. That leaves useful margin above 4.75 V, unlike directly switching the raw input bus. Verify the USB voltage limit appropriate to the final port implementation; this calculation is not a compliance test.
- Host enable is `AON_READY AND FULL_POWER_VALID AND FPGA_HOST_REQUEST`; either selected external power or accepted 9 V / 3 A PD qualifies. FPGA request defaults low. Port overcurrent is returned to the FPGA. Rail caps/inrush and the FT232H's simultaneous load must be included in the load-step test.

## 5. Expansion

Use a second TPS2553 from main 3.3 V with **88.7 kOhm 1%** ILIM. Datasheet-equation envelope is approximately 262–342 mA; useful exported allocation is 250 mA shared across Pmod and GPIO headers. Enable only under the same full-source qualification as the host port (selected external or accepted PD), with a separate FPGA request and fault return.

Unpowered modules must not be back-powered through GPIO. Keep expansion GPIO high impedance until exported power is valid; self-powered modules need an explicitly documented power-disconnect/isolation arrangement. GPIO is 3.3 V only, not generally 5 V tolerant. A programmable FPGA can violate its intended I/O policy; the header is not intrinsically protected against arbitrary bitstreams or wiring faults.

## 6. FPGA clocks, memory and pins

Use a 24 MHz reference on package ball A4 (ULC_GPLL0T_IN). A candidate PLL configuration uses CLKI_DIV=1, CLKFB_DIV=2, CLKOP_DIV=12 and internal CLKOP feedback, giving 48 MHz output and 576 MHz VCO. A second output divider of 6 can provide 96 MHz later. Confirm the exact primitive attributes and physical PLL placement with the implementation tools; arithmetic alone is not routing validation.

Initial system/USB digital PHY and SDRAM target: **48 MHz**. Start SDRAM testing slower if necessary. A 143 MHz-rated SDRAM is not a promise that this PCB/controller closes at 143 MHz. Future 96 MHz requires new constraints and timing/SI validation.

[pin-plan.csv](pin-plan.csv) maps 107 unique CABGA381 balls against the official project-local pinout:

- SDRAM: 39 signals split across banks 0 and 1; 16 data, 13 address, 2 bank address, 2 DQM, CLK, CKE, CSn, RASn, CASn, WEn.
- FIFO: 15 signals on bank 2, with 60 MHz clock on a PCLKT input.
- Host/UART/power controls: bank 6.
- Pmod/GPIO: bank 3.
- Reference clock/buttons/LEDs: bank 7.
- SPI configuration: bank 8 and dedicated CCLK.
- Dedicated JTAG: TCK=T5, TMS=U5, TDI=R5, TDO=V4. The source CSV labels this special group bank 40; that is not an independently assignable ordinary VCCIO bank.

There are 203 GPIO balls in this package; 96 are used by this plan and 107 remain unassigned. This does not mean all unassigned pins are equally convenient clock/PLL/interface substitutes. All bank supply choices, BGA escape and controller timing need physical implementation review. The plan is intentionally not an LPF file presented as timing-closed hardware.

## 7. USB host logic and software contract

Chosen source revisions:

- [UltraEmbedded host](https://github.com/ultraembedded/core_usb_host), commit `81eb9f131dbb434a9047ae074fea5c31ef46ce5d`, top `usbh_host`, GPL-2.0-or-later.
- [UltraEmbedded digital PHY](https://github.com/ultraembedded/core_usb_fs_phy), commit `68a63ff937e58e90f4f534b9c6705c649d545136`, top `usb_fs_phy`, LGPL-2.1-or-later.

Connect the 8-bit UTMI interfaces internally. Physical TUSB1106 mapping:

| Digital PHY | TUSB1106 | Direction at FPGA |
|---|---|---|
| usb_tx_dp_o | VPO | Out |
| usb_tx_dn_o | VMO | Out |
| usb_tx_oen_o | OE, high disables transmitter | Out |
| usb_rx_dp_i | VP | In |
| usb_rx_dn_i | VM | In |
| usb_rx_rcv_i | RCV | In |
| Fixed full-speed | SPEED=1 | Strap |
| Active receiver | SUSPND=0 | Strap |

TUSB1106 differential truth table: VPO/VMO=10 -> J, 01 -> K, 00 -> SE0, 11 illegal. This is the needed interface, not the TUSB1105's alternate VO/FSE0 encoding. Put an OE pullup on the FPGA side so the transceiver is disabled before configuration. Add the host pulldowns specified by the reference circuit; no device D+ pullup.

Installed Icarus Verilog using Homebrew and ran a temporary integration prototype. It passed reset high-impedance control, driven SE0, legal differential transmit states and two periodic SOF packets over about 2.3 ms. Yosys ECP5 synthesis reported zero check errors, 2,279 LUT4 and 1,394 FF cells for the exposed host+PHY prototype. These figures include the selected FIFOs and are not a routed device utilization or power result.

**Not exercised:** receive/CRC transactions, actual enumeration, USB class drivers, disconnect/reconnect, suspend/resume, hubs, physical timing or signal integrity. Software must drive the core's AXI4-Lite registers, perform reset/enumeration/control/bulk/interrupt transfers and provide the desired class driver. The repository includes a Linux HCD, not a ready-made bare-metal stack for an unspecified soft CPU. FS-only is an explicit Rev A restriction, not a hidden claim of keyboard compatibility. All temporary verification files are removed after the research as requested.

### Debug hub provisioning and startup

USB2512B can boot without a third EEPROM: strap CFG_SEL[1:0]=00 for its ROM self-powered configuration, and NON_REM[1:0]=10 for both FTDI devices permanently attached. This is a compound device. Leave battery-charging enables low. Use the specified 12.0 kOhm 1% RBIAS resistor, and connect upstream VBUS_DET through **100 kOhm / 100 kOhm** from the DEBUG connector; it is not a direct 5 V connection.

Connect port 1 to FT2232H and port 2 to FT232H. Both are locally/self-powered. Use each hub PRTPWR output, qualified with system power-good, to release the corresponding FTDI RESETn; pull OCSn high for these internal non-user-accessible loads. Set the FTDI EEPROM self-powered descriptors and unique serials accordingly; do not describe board loads as downstream VBUS power. Keep the FTDI local regulators and bypass networks as in each reference circuit. Hub reset releases only after main rails/clocks settle. The enumeration/power-cycle sequence needs testing, particularly FIFO isolation and the FT232H's local VCCD domain.

The three crystals start with equal 16 pF C0G loads: CL≈(16*16)/(16+16)+2=10 pF for an assumed 2 pF stray. FTDI's ±30 ppm budget must include initial tolerance, temperature, aging **and load-pulling error**. The ±10 ppm crystal options leave about 7 ppm for load error after an assumed ±3 ppm aging contribution. Measure frequency and tune the loading on the actual board; catalogue CL alone does not guarantee it. Check the order-code default operating-temperature range rather than assigning the industrial range of unrelated parts to the crystal.

## 8. Configuration and recovery

- Strap CFG[2:0]=010 for Master SPI, using the exact dedicated pin mapping and recommended pull strengths. Boot in standard single-bit mode first; retain optional WPn/HOLDn/I/O2/I/O3 connections for later quad read.
- Use W25Q128JV 16 MiB. Initial partition policy: primary reservation 0x000000–0x3FFFFF; golden reservation 0x400000–0x7FFFFF; application data 0x800000–0xFEFFFF; reserve final 64 KiB 0xFF0000–0xFFFFFF for boot records/tool formatting.
- The sysCONFIG guide says dual-boot fallback searches from 0xFFFF00 by default. That is **not a 256-byte slot into which an entire golden bitstream fits**. Use the documented formatter/header/jump mechanism to point to the actual golden image. Do not concatenate raw bitstreams and call that a tested fallback image.
- Diamond Deployment Tool supports formatting this layout. An open-source flow needs equivalent verified records and a corruption/fallback test. No formatted image exists yet because no actual application/golden bitstreams exist. Keep the golden region out of normal application updates; configure actual flash protection deliberately rather than assuming WPn protects an arbitrary middle partition.
- CRC/load-timeout fallback does not recover every functionally bad, CRC-valid application. Physical JTAG remains the independent recovery path.
- FT2232H programs SRAM/flash through JTAG; SPI flash clock in user mode needs USRMCLK access to dedicated CCLK. Choose persistence options consistently with runtime flash access.
- External recovery header must disable the onboard JTAG driver's OE before another programmer drives TCK/TMS/TDI. VCCIO reference is a reference, not authorization to feed board power.

Board-specific JTAG 2x6 assignment, numbered by the KiCad footprint: 1=3.3 V reference, 2=GND, 3=TCK, 4=GND, 5=TMS, 6=GND, 7=TDI, 8=GND, 9=TDO, 10=GND, 11=PROGRAMN open-drain request, 12=GND. Label this pinout; it is not an ARM connector standard.

Pmod standard-style ordering: 1–4 GPIO[0:3], 5 GND, 6 switched 3.3 V, 7–10 GPIO[4:7], 11 GND, 12 switched 3.3 V. General 2x5: pins 1–8 GPIO[0:7], 9 GND, 10 switched 3.3 V. UART: 1 GND, 2 FPGA TX, 3 FPGA RX, 4 3.3 V reference, not a general power outlet.

## 9. Layout baseline

Use a **six-layer conventional-through-via PCB** as the planning baseline: L1 signals, L2 solid GND, L3 power, L4 signals, L5 solid GND, L6 signals. Obtain an actual fabricator stackup before calculating widths. Route both USB 2.0 pairs on uninterrupted ground reference with a 90 Ohm differential target. Keep the BGA/SDRAM compact; reserve clock termination footprints at the driver, not halfway along the trace. Do not route critical signals across plane splits.

The CABGA381 0.8 mm pitch is compatible with ordinary dogbone escape at suitable design rules, but the full escape, via/pad dimensions, solder mask and assembly process must be checked by the chosen fabricator/assembler. Place decoupling at supply pins, minimize switcher hot loops and solder exposed pads to thermal copper/vias. A component's catalog current rating is not a board thermal result.

## 10. What must exist before fabrication release

These are concrete release conditions, not further architecture decisions:

1. Complete schematics: every power pin, reset, strap, enable, protection divider, bypass network, clock and header connection; check all powered/unpowered states and exact package/drawing dimensions.
2. Exact implemented FPGA design and Lattice Diamond power calculation over process/temperature/activity, including startup/configuration. Diamond is not installed and is not a normal Homebrew package; installing Icarus/Yosys does not substitute for its power model.
3. Manufacturer DC-bias data and the final regulator output-network/stability calculations. Crystal tolerance/loading and USB/SDRAM timing constraints tied to actual routing.
4. FPGA place-and-route with the chosen bank/clock assignments and timing constraints; PCB SI/return-path review.
5. Electrical bring-up: rail ramps, inrush, fault behavior, source transitions, actual input/current limits, USB-A voltage/load steps, PLL/SDRAM tests, EEPROM provisioning, host enumeration and recovery-image corruption tests.
6. Thermal validation and a decision on heatsink/airflow from actual package power. Obtain current authorized-distributor quotes and confirm all MPNs/lifecycle/drawings before buying.

The task can resolve design choices now; it cannot truthfully produce measurements or a power estimate for an FPGA implementation that has not been designed yet.
