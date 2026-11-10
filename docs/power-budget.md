# Rev A current and power budget

## Interpretation

This is a **design load allocation**, not measured consumption, a guaranteed worst case, or a substitute for Lattice Diamond Power Calculator. FPGA resources, clocks, activity, I/O capacitance, temperature and startup current remain unknown until an implementation exists.

Full operation is now supplied by **either external 5 V / 4 A or an accepted USB-PD 9 V / 3 A contract**. The previous reduced USB mode is removed: core, host-port and expansion allocations are identical for both sources. Non-PD, 5 V-only or insufficient-current USB sources do not enable main loads. DEBUG USB-C remains data/VBUS-sense only and never powers the board.

See [usb-c-pd.md](usb-c-pd.md) for negotiation and higher-voltage protection, [rev-a-design.md](rev-a-design.md) for the wider design, and [parts-selection.md](parts-selection.md) for MPNs.

Machine-readable inputs are in [current-budget.csv](current-budget.csv). Run:

```sh
python3 docs/calculate_power_budget.py
```

The CSV's `usb_mA` column now means **accepted PD full mode**, not the superseded 5 V reduced mode.

## Load allocations

| Load | Rail | Both full modes | Basis |
|---|---|---:|---|
| FPGA core | 1.1 V | 2,000 mA | Engineering allocation; replace with implemented Diamond estimate |
| FPGA auxiliary | 2.5 V | 100 mA | Engineering allocation |
| FPGA I/O | 3.3 V | 250 mA | Depends on loading and activity |
| SDRAM | 3.3 V | 180 mA | 120 mA Idd4 output-open limit + 60 mA output-loading allocation |
| FT2232HL | 3.3 V | 200 mA | 70 mA typical core + 60 mA maximum PHY + 70 mA I/O/uncertainty allowance |
| USB2512B | 3.3 V | 120 mA | 65 mA one-port HS maximum base + 25 mA additional HS port + 30 mA allowance |
| Flash | 3.3 V | 30 mA | 25 mA maximum program/erase + allowance |
| TUSB1106 | 3.3 V | 15 mA | 8 mA supply + 2.5 mA I/O maxima + allowance |
| 24 MHz reference | 3.3 V | 15 mA | ASV maximum in the 15–29.9 MHz band |
| FT2232 EEPROM | 3.3 V | 5 mA | Active/write allocation |
| LEDs | 3.3 V | 20 mA | Up to ten simultaneous 2 mA LEDs |
| Isolation/control/pullups | 3.3 V | 30 mA | Engineering allocation |
| Shared expansion export | 3.3 V | 250 mA | Hardware-qualified selected full source; same in PD mode |
| FT232HL + EEPROM | 5.088 V | 200 mA | Includes all local regulators and I/O; engineering allocation, not guaranteed total maximum |
| USB-A device | 5.088 V | 500 mA | One useful high-power USB 2.0 load; same in PD mode |
| USB-A bleed | 5.088 V | 6 mA | Rounded 1 kOhm output-discharge allowance |

The four rails have separate switching converters. Auxiliary 2.5 V is not an LDO load on main 3.3 V. FT232H VREGIN gets regulated 5.088 V, and its local VCCD/VCORE/other rails and EEPROM are counted there, not counted again on main 3.3 V.

Raw-input control allocation: **5 mA external**, **10 mA USB PD**, with the latter including autonomous controller/negotiation overhead. These are engineering allowances, not guaranteed controller maxima. With both connectors attached, control power may come from USB while the mux selects external; the simplified per-source budget is not a detailed dual-input current split.

## Converter sizing

| Converter output | Full allocation, either source | With 25% margin | Selected converter |
|---|---:|---:|---|
| 1.1 V | 2.000 A | 2.500 A | TPS62130, 3 A rated |
| 2.5 V | 0.100 A | 0.125 A | TPS62130; selected for controllable ramp |
| 3.3 V | 1.115 A | 1.39375 A | TPS63070; check actual VIN/VOUT and thermal limits |
| 5.088 V | 0.706 A | 0.8825 A | TPS63070; check actual VIN/VOUT and thermal limits |

The load model uses **85% converter efficiency** and **25% current-allocation margin**. Neither is a datasheet-guaranteed worst case. Changing input to 9 V changes converter efficiency, duty ratio, ripple and dissipation; retain the conservative planning assumption until actual curves/measurements replace it.

Both TPS62130 bucks now use nominal **1.25 MHz / 2.2 uH**, not the earlier 2.5 MHz / 1 uH setting. The TPS63070 converters retain 1.5 uH and forced PWM. See the PD document for the minimum-on-time and duty-ratio checks.

## Source/path model

Voltage is specified **at the board input connector**. Model connector contacts, copper, selected eFuse and mux as **0.18 Ohm total resistance**, a target to verify. STUSB4500 is not another series power switch: it controls authorization of the existing USB eFuse, so no second controller-switch resistance is silently omitted. External cable/harness drop is additional.

```text
P = sum(Vrail * Irail / 0.85)
Vbus = Vs - Ibranch * Rpath
P = Ibranch * (Vs - Ibranch * Rpath)
Itotal = Ibranch + Icontrol
```

The calculator solves the low-current quadratic root, adds bypassing control current separately, and rejects a source/path with no steady solution. The small resistor-target offsets from nominal 1.1/2.5/3.3 V are below this model's other uncertainties; use actual rail tolerances in the final implementation estimate.

### External 5 V / 4 A

| Input at board connector | Load allocation | With 25% margin | Bus at margin |
|---|---:|---:|---:|
| 5.00 V | 2.520 A | **3.243 A** | 4.417 V |
| 4.75 V | 2.685 A | **3.471 A** | 4.126 V |
| 4.00 V, sensitivity only | 3.376 A | **4.482 A** | 3.194 V — reject for full mode |

The selected external source remains regulated 5 V / 4 A, nominal 20 W. Check its line/temperature/cable derating and actual delivered voltage. The external eFuse's 806 Ohm programming sets a fault threshold, not permission to exceed 4 A continuous adapter output.

### USB-PD 9 V / 3 A

| Input at board connector | Same full allocation | With 25% margin | Bus at margin |
|---|---:|---:|---:|
| 9.00 V | 1.315 A | **1.655 A** | 8.704 V |
| 8.55 V, -5% sensitivity | 1.388 A | **1.748 A** | 8.238 V |
| 8.10 V, -10% sensitivity | 1.469 A | **1.853 A** | 7.769 V |

These voltage cases are sensitivity calculations, not certification of every USB-C cable/PD-source minimum. At nominal 9 V the margined input is approximately **14.90 W**, comfortably below the 27 W contract. Host and expansion allocations are included; no reduced-core assumption remains.

Use USB eFuse **RILM=1.27 kOhm ±1%**. With the stated ±10% IC tolerance, the estimated DC limit is **2.339–2.917 A**. The maximum plus margined 12.5 mA control overhead is approximately **2.929 A**, below 3 A. The modeled worst sensitivity load is also below the minimum DC limit. ITIMER is open for fastest response. Inrush/transients can exceed DC limits and still require checking; this does not prove Type-C/PD compliance.

## Loss and thermal planning

- Un-margined converter input power is about **11.44 W**, with **1.72 W** total converter loss at the assumed 85% efficiency, in either mode under that simplifying assumption.
- Nominal external path loss: about **1.14 W**, or **1.89 W with margin**. At 4.75 V with margin: about **2.16 W**.
- Nominal PD path loss: about **0.31 W**, or **0.49 W with margin**. At 8.1 V with margin: about **0.61 W**. Higher-voltage PD reduces input-path current/heating substantially.
- Loss is distributed across eFuse/mux/copper/contacts. Validate each junction/contact temperature; do not assign the entire result to arbitrary board area.
- FPGA allocated rail power is about **3.275 W**. This is rail power, not all die dissipation: I/O energy can dissipate externally. A real package/activity model is needed before selecting heatsink/airflow.
- FT232H's internal linear-regulator dissipation remains a package thermal check under FIFO traffic.
- AON regulator input may rise to 9 V while its output stays approximately 2.983 V. Include that increased small-branch LDO loss. STUSB4500 powers from VBUS directly; do not connect its VSYS to the below-minimum AON rail.

Higher input voltage also requires the **35 V / 300 uF total bus bulk**, suitably rated raw-input bypass, updated USB OVP dividers and removal of the old USB-path 5 V TVS. Effective input capacitance must be checked at 9.45 V. Detailed protection/qualification conditions are in [usb-c-pd.md](usb-c-pd.md).

## Evidence and release limits

Manufacturer document locators:

| Document | Relevant evidence |
|---|---|
| ECP5 family v3.4 | Page 51 Table 3.2, supply ranges; page 52 ramps/POR |
| Hardware checklist v2.1 | Page 13 sequencing; page 14 power estimation; Table 3.1 bypass/filtering |
| FT2232H mirror v2.21 | Physical pages 48/50, Tables 5.2/5.4 |
| FT232H mirror v1.82 | Physical pages 49/51, Tables 5.2/5.4; section 6 power topology |
| USB251xB DS00001692E | Page 41 Table 6-4; section 5.1 configuration |
| IS42S16160J mirror Rev C3 | Page 17 Idd4/output-open note |
| W25Q128JV Rev F | Physical page 63 read/program/erase currents |
| TUSB1106 | Page 8 supply/I/O currents; differential truth tables |
| ASV | Page 1 frequency-dependent current |
| TPS62130 / TPS63070 | Electrical limits, timing/duty behavior, LC and soft-start application guidance |
| TPS2553 | Equations 1–3 current limits and maximum switch resistance |
| TPS25947 | 3334/R limit equation, accuracy, negative-input limits, ITIMER/dVdt |
| STUSB4500 Rev 7 | Table 4 status behavior, section 3.3 matching, section 5 NVM, section 7 ratings |

FTDI typical core currents do not establish total maxima; SDRAM output-open limits omit loading; FPGA consumption is still an allocation. Older mirrored documents need current-revision confirmation before ordering. Local PDF provenance/hashes are in [datasheet-sources.csv](datasheet-sources.csv).

The design is not fabrication-ready: finish the circuit, program/read back controller NVM, obtain implementation-based FPGA power, check loop stability/DC bias, and measure startup, source transitions, thermal behavior and USB port operation. No new circuit was placed or physical test performed by these calculations.
