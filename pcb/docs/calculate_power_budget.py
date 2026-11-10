#!/usr/bin/env python3
"""Recalculate the Rev A load allocations and input/path sensitivity cases."""
import csv
import math
from pathlib import Path

EFFICIENCY = 0.85  # Planning assumption for each converter; not a guaranteed minimum.
MARGIN = 1.25
RAIL_VOLTAGES = {"1.1V": 1.1, "2.5V": 2.5, "3.3V": 3.3, "5.088V": 5.088}
# Includes connector contacts, copper, selected eFuse/mux; the eFuse also
# provides input reverse-polarity protection. External cable loss is separate.
# This is a design target to verify, not a guaranteed assembled-board resistance.
PATH_RESISTANCE = 0.18
SOURCE_VOLTAGES = {"external": (5.0, 4.75, 4.0), "usb": (9.0, 8.55, 8.1)}
USB_ILIM_RESISTANCE = 1270  # Ohms; 1% resistor, PD contract is 9 V / 3 A.


def rail_totals(path: Path, mode: str) -> dict[str, float]:
    if mode not in ("external", "usb"):
        raise ValueError("mode must be external or usb")
    totals = dict.fromkeys((*RAIL_VOLTAGES, "AON"), 0.0)
    with path.open(newline="") as source:
        for row in csv.DictReader(source):
            current = float(row[f"{mode}_mA"]) / 1000
            if not math.isfinite(current) or current < 0:
                raise ValueError("Current allocations must be finite and nonnegative")
            totals[row["rail"]] += current
    return totals


def converter_input_power(totals: dict[str, float], scale: float = 1.0) -> float:
    # All four rails have separate switching converters; no 2.5 V LDO remains.
    return sum(RAIL_VOLTAGES[rail] * totals[rail] * scale / EFFICIENCY
               for rail in RAIL_VOLTAGES)


def source_current(power: float, source_voltage: float, resistance: float) -> float:
    """Low-current solution of P = I * (Vs - I*R), excluding the AON branch."""
    if power < 0 or source_voltage <= 0 or resistance < 0:
        raise ValueError("Invalid power path parameters")
    if resistance == 0:
        return power / source_voltage
    discriminant = source_voltage ** 2 - 4 * resistance * power
    if discriminant < 0:
        raise ValueError("No steady constant-power solution for this source/path")
    # Equivalent to the quadratic solution, avoiding cancellation at small R.
    return 2 * power / (source_voltage + math.sqrt(discriminant))


def main() -> None:
    path = Path(__file__).with_name("current-budget.csv")
    for mode in ("external", "usb"):
        totals = rail_totals(path, mode)
        label = "USB-PD 9 V / 3 A" if mode == "usb" else "EXTERNAL 5 V / 4 A"
        print(f"\n{label}: full-mode engineering allocations, not verified maxima")
        for rail, current in totals.items():
            suffix = "raw input current" if rail == "AON" else "converter output"
            print(f"  {rail}: {current:.3f} A ({suffix}), margin {current * MARGIN:.4f} A")
        for scale, label in ((1.0, "allocation"), (MARGIN, "25% margin")):
            power = converter_input_power(totals, scale)
            for voltage in SOURCE_VOLTAGES[mode]:
                branch = source_current(power, voltage, PATH_RESISTANCE)
                aon = totals["AON"] * scale
                bus = voltage - branch * PATH_RESISTANCE
                print(f"  {label}, source {voltage:.2f} V: "
                      f"{branch + aon:.3f} A, bus {bus:.3f} V, "
                      f"path loss {branch * branch * PATH_RESISTANCE:.3f} W")
        print(f"  Allocated converter losses: "
              f"{converter_input_power(totals) * (1 - EFFICIENCY):.3f} W")
    # Include 1% programming resistor tolerance and the stated 10% IC tolerance.
    usb_limit_min = 3334 / (USB_ILIM_RESISTANCE * 1.01) * 0.90
    usb_limit_max = 3334 / (USB_ILIM_RESISTANCE * 0.99) * 1.10
    print(f"\nUSB eFuse RILM=1.27k, DC estimate: {usb_limit_min:.3f}–{usb_limit_max:.3f} A")
    usb_aon_margin = rail_totals(path, "usb")["AON"] * MARGIN
    print(f"DC maximum plus margined PD/control overhead: {usb_limit_max + usb_aon_margin:.3f} A")
    print("Both sources support identical rail loads; non-PD/insufficient sources leave main loads off.")
    print("Fast transients and blanking can exceed that DC limit; it is not an instantaneous ceiling.")
    print("AON current bypasses the main eFuse and must be included in the source limit.")
    print("Input voltage, resistance, efficiency, startup and thermal behavior require validation.")


if __name__ == "__main__":
    main()
