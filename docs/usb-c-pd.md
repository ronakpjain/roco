# USB-C PD power input

## Decision

Replace the POWER connector's TUSB320 current detector with **STMicroelectronics STUSB4500QTR**, a standalone USB Power Delivery sink controller in QFN-24, 4 x 4 mm. Keep the separate, self-powered DEBUG USB-C data connector.

Request a **fixed 9 V / 3 A PDO (27 W)**. A compliant USB-C-to-C 3 A cable is sufficient; 5 A/e-marked cable operation, PPS and higher voltages are not required. A charger must explicitly offer 9 V / 3 A: a marketing label such as "30 W" alone does not establish that PDO.

Once the required contract is accepted, USB-C supplies the **same full board allocation** as external 5 V / 4 A, including the host port and expansion. Remove the previous USB-specific core-current reduction. Actual maximum FPGA activity still needs implementation/power qualification in either mode.

Plain 5 V, non-PD, or insufficient-current sources power only negotiation/control circuitry. They do not enable the main board. No automatic reduced-performance fallback is included in Rev A.

## Autonomous negotiation and hardware gate

The STUSB4500's NVM must be provisioned before normal use:

| Setting | Required value |
|---|---|
| Enabled sink PDO count | 2 |
| PDO1 | 5 V, 0.5 A, mandatory negotiation/default profile; never authorizes main loads |
| PDO2 | 9 V, 3 A |
| PDO3 | Disabled |
| PWR_OK_CFG[1:0] | `10b`, dedicated PDO2/PDO3 status outputs |
| POWER_ONLY_ABOVE_5V | 1 |
| REQ_SRC_CURRENT | 0; request the selected sink PDO current, not an arbitrary larger source current |
| Voltage monitoring | Enabled; retain documented safe transition/monitoring defaults unless specifically validated |

The datasheet's section 3.3 algorithm requires an equal voltage and source current **at least** the configured sink current before matching PDO2. A 9 V / 2 A offer therefore does not authorize the board. This distinction is why a generic "VBUS is above 7 V" detector is not enough.

Define:

```text
PD_ACCEPTED = NOT(VBUS_EN_SNK OR POWER_OK2)
USB_PATH_ENABLE = AON_READY AND PD_ACCEPTED
```

Both controller signals are active-low open drain, pulled up to AON through 47 kOhm resistors. Use the selected AON-powered NOR/AND logic and an eFuse-enable pull-down. No FPGA firmware participates in negotiation or main-power authorization.

**Do not use POWER_OK2 alone:** the datasheet states that it can remain asserted after detach. VBUS_EN_SNK deasserts on detach and must also qualify the gate. POWER_OK2 asserts after PS_READY for PDO2 and releases during renegotiation. Check the completed analog startup/off-state wiring, not just the Boolean expression.

Factory NVM is not assumed to contain this profile. Verify/read back the programmed image and test insufficient-current, detach and hard-reset cases before declaring this gate qualified.

## Power path

```text
POWER USB-C VBUS, initially 5 V then negotiated 9 V
  +-- STUSB4500 VDD and VBUS monitoring/discharge
  +-- small AON control branch
  `-- USB TPS259470A, enabled only by qualified PD
        `-- TPS2121 IN2 -- common converter bus

EXTERNAL 5 V -- external TPS259470A -- TPS2121 IN1
```

External 5 V retains priority. The selected common converter bus can therefore be approximately **5 V or 9 V**, depending on the source. Do not directly connect it to any nominal 5 V load. The four selected output converters remain separately regulated, including 5.088 V for FT232H/USB-A.

STUSB4500 contains the negotiation logic, **not the main load switch**. Retain the USB eFuse for load switching, current limit, reverse-current protection, inrush and OVP. A separate controller-driven series PMOS is not required by this architecture.

| Power-path change | Selected value / rationale |
|---|---|
| USB eFuse RILM | **1.27 kOhm, 1%**; nominal 2.625 A; estimated DC envelope 2.339–2.917 A including ±10% IC and resistor tolerance |
| USB eFuse OVLO | **2.00 MOhm / 249 kOhm, 0.1%**, raw VBUS to GND; nominal rising threshold 10.839 V, about 10.47–11.27 V including threshold/leakage/resistor bounds |
| External eFuse programming | Unchanged: 806 Ohm current setting, 2.00 MOhm/499 kOhm OVLO divider |
| AON feedback | 150 kOhm / 100 kOhm, 0.1%; approximately 2.983 V |
| AON-ready supervisor | TPS3808G01, 560 kOhm / 100 kOhm, CT open; approximately 2.673 V falling threshold and 20 ms typical release delay |
| External-valid supervisor | TPS3808G01, 909 kOhm / 100 kOhm; approximately 4.086 V falling threshold; include ±2% threshold, leakage, hysteresis and resistor error |
| Mux OV1, external input | Unchanged: 499 kOhm/100 kOhm |
| Mux OV2, USB input | **909 kOhm / 100 kOhm, 0.1%**; nominal 10.695 V, approximately 10.08–11.21 V including reference/leakage/resistor bounds |
| eFuse dVdt | 10 nF; typical 0.2 V/ms, now about 45 ms to 9 V |
| Mux CSS | 100 nF; check inrush at both 5 V and 9 V, not just the old 5 V example |
| Converter-bus bulk | **2 x Rubycon 35ZLH150MEFC6.3X11**, 300 uF nominal total; replaces the 10 V / 330 uF part |
| Raw USB / STUSB4500 VDD bypass | 1 uF **25 V** plus local 100 nF **25 V**, with total unswitched connector capacitance checked against Type-C requirements |
| Converter input ceramics | Existing 16 V 1210 parts must be evaluated for effective capacitance at 9.45 V; add input footprints if needed. Do not apply the old 5 V bias assumption |
| USB control overhead | 10 mA raw-input engineering allocation, including AON and PD negotiation; not a guaranteed STUSB4500 maximum |

The eFuse DC maximum plus 10 mA overhead is about 2.927 A; with 25% overhead margin it is about 2.929 A, below a 3 A contract. Fast transients can exceed the programmed DC limit and must be checked separately.

The controller can tolerate/encounter higher USB-PD voltages even though the application requests only 9 V. The raw path uses devices rated accordingly: STUSB4500 VDD operating to 22 V, eFuse input operating to 23 V, AON regulator to 60 V, diode OR rated 30 V, and 25 V raw-input bypass. OVP prevents unintended higher voltage from reaching the converter bus. Check the entire path, not just the controller rating.

### Protection changes that must not be missed

- **Never fit SMF5.0CA across the negotiated USB path.** It would clamp a legitimate 9 V source. Keep the external 5 V branch's existing clamp proposal separate.
- For the USB branch, reserve an **unpopulated TVS footprint** until clamp coordination is complete. A conventional 10 V TVS may reach about 17 V at rated surge current, leaving inadequate margin for 16 V-input converters. Select/validate the complete clamp-plus-eFuse-plus-capacitor response before population; do not call a catalogue stand-off voltage a guaranteed safe clamp voltage.
- STUSB4500 has built-in CC-to-VBUS protection up to 22 V. Do not blindly retain a low-voltage CC clamp that defeats this fault behavior. Any optional external CC ESD network must preserve BMC signaling and the selected fault-voltage requirement. DEBUG retains its separate low-voltage CC protection.
- Input bulk and debug VBUS sensing remain distinct. There must be no 9 V path to DEBUG VBUS or USB-A VBUS.

## Controller support connections

- VDD from raw POWER VBUS; VSYS to GND for VDD-only operation. Do not supply VSYS from nominal 2.983 V AON: its minimum is 3.0 V.
- Connect CC1DB to CC1 and CC2DB to CC2 for dead-battery attach. Do not add duplicate external Rd resistors.
- VREG_1V2 and VREG_2V7 each get 1 uF bypass (effective 0.5–10 uF per datasheet). These are **decoupling-only outputs**, not board supplies or convenient I2C pullup rails.
- VBUS_VS_DISCH senses raw VBUS through an initial **2.2 kOhm, 1206, 0.25 W** resistor. This limits current below 50 mA even at 22 V; check discharge pulse energy and the actual pre-switch capacitance. Use the internal VBUS_VS_DISCH path for the small pre-eFuse capacitance; leave the optional external DISCH output unconnected. It is not a general logic output to tie to a rail.
- RESET is active high; use its specified inactive pull-down and provide a service pad. Strap ADDR pins low for I2C address 0x28 and verify against the chosen package pin table.
- Provide GND/SDA/SCL/RESET and voltage-reference service pads/header for off-board NVM programming. No extra runtime MCU and no new FPGA I2C assignment are required. External programmer supplies its own permitted logic pullups; use only while the controller is powered from a non-PD 5 V source. Do not power the board through its I2C or internal-regulator pins.
- Unused status/interrupt pins are left per datasheet, not assumed interchangeable with push-pull outputs. QFN exposed pad and GND pins go to the ground plane.

## Converter changes for the higher input

TPS62130 and TPS63070 accept the normal 9 V input without an intermediate 9-to-5 V converter. Avoiding that extra stage saves loss and components.

However, the core buck's old 2.5 MHz / 1 uH setting is not a good nominal-frequency target for 9 V-to-1.1 V conversion. Use **FSW tied to main 3.3 V, nominal 1.25 MHz, 2.2 uH SRP4020TA-2R2M** for both TPS62130 bucks; do not use the 9 V input as a casual logic pullup. Its family table lists 4 A thermal / 6 A saturation ratings. Review the LC/stability table with actual distributed output capacitance. The datasheet's approximately 80 ns minimum on-time can still reduce operating frequency in some conditions; do not depend on exact converter switching frequency.

The TPS63070 3.3 V converter has a nominal 34.9% duty ratio at 9.45 V, above the stated 30% minimum buck-duty operating condition. Its 5.088 V output also remains within the normal input/output range. Check PWM ripple, derating and thermal performance at both input voltages.

## Provisioning and release checks

1. First power the controller from a non-PD 5 V source with main loads held off. Read device identity/NVM, program the two-PDO policy with ST's documented NVM interface, and verify it after a full power cycle. A development GUI is a programming tool, not a runtime dependency.
2. Require 9 V / 3 A and confirm POWER_OK2 plus VBUS_EN_SNK behavior. Verify 5 V-only and 9 V / 2 A sources never authorize the main board.
3. Check cable detach, PD hard reset, renegotiation and external-source handover. Loss of PD permission must turn off host/expansion if no other full source is available; uninterrupted execution is not promised.
4. Measure pre-contract current, inrush, actual current limit, input voltage, all rail ramps and port voltages at full allocated load. Qualify the TVS network, decoupling and layout before fabrication/population release.
5. Keep the service connection/programming specification with manufacturing instructions. No NVM binary is invented here: create the image using the documented register/sector definitions, preserve reserved bits, and retain a verified readback when provisioning real hardware.

## Sources

[STUSB4500 datasheet, DS12499 Rev 7](datasheets/STUSB4500.pdf): section 2.2.8/Table 4 (PDO status and detach behavior), sections 2.2.11–2.2.16 (power/monitoring pins), section 3.3 (strict PDO matching), section 3.5 (dead-battery connections), section 5 (NVM configuration), section 7 (ratings), and application diagrams. Downloaded from an identified GitHub mirror because the manufacturer endpoint did not return a PDF; provenance/hash is recorded in [datasheet-sources.csv](datasheet-sources.csv).

The alternative TI TPS25730 was examined but not selected: its CAP_MIS output is toggled, and its sink-enable state can remain asserted with a capability mismatch. The STUSB4500's strict PDO match plus separate hardware PDO status better fits the no-runtime-MCU authorization requirement. No temporary controller test files are retained in the project.
