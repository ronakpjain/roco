"""Generate the exact ECP5U-85F CABGA381 symbol from the Lattice pinout.
Run from the project root: python3 libraries/generate_ecp5.py

Source: Lattice document 50487 -> sources/ECP5U-85-pinout.csv.
"""
import collections
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

PARTS = [
    ('LFE5U-85F-6BG381C', 'sources/ECP5U-85-pinout.csv', '50487',
     'Lattice ECP5U-85, speed -6, caBGA381, commercial; exact 85F pinout'),
]


def build_symbol(name, csv_path, doc_id, description):
    rows = list(csv.reader((ROOT / csv_path).open()))
    header = next(i for i, r in enumerate(rows) if r and r[0] == 'PAD')
    ball_col = [h.strip() for h in rows[header]].index('CABGA381')
    pins = [r for r in rows[header + 1:] if len(r) > ball_col and r[ball_col] not in ('', '-')]
    assert len(pins) == len({r[ball_col] for r in pins}) == 381, (name, len(pins))
    q = json.dumps
    groups = collections.defaultdict(list)
    for r in pins:
        pin_name, bank = r[1], r[2]
        if re.fullmatch(r'P[LRTB]\d+[ABCD]', pin_name):
            group = 'Bank ' + bank
        elif pin_name.startswith('VCC'):
            group = 'Power'
        elif pin_name == 'GND':
            group = 'Ground'
        else:
            group = 'Configuration and reserved'
        groups[group].append(r)
    units = []
    for label in sorted(groups):
        members = groups[label]
        # All balls are visible unique pins; no hidden or stacked power pins.
        for start in range(0, len(members), 40):
            suffix = f' {start // 40 + 1}' if len(members) > 40 else ''
            units.append((label + suffix, members[start:start + 40]))
    output = [f'(symbol {q(name)} (pin_names (offset 1.016)) (in_bom yes) (on_board yes)',
              f'(property "Reference" "U" (at 0 5.08 0) (effects (font (size 1.27 1.27))))',
              f'(property "Value" {q(name)} (at 0 2.54 0) (effects (font (size 1.27 1.27))))',
              '(property "Footprint" "roco:BGA381C80P20X20_1700X1700X176N" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
              f'(property "Datasheet" "https://www.latticesemi.com/view_document?document_id={doc_id}" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
              f'(property "Description" {q(description)} (at 0 0 0) (effects (font (size 1.27 1.27)) hide))']
    for unit, (label, members) in enumerate(units, 1):
        height = (len(members) + 2) * 2.54
        output += [f'(symbol "{name}_{unit}_1"',
                   f'(rectangle (start -35.56 0) (end 35.56 {-height:.2f}) (stroke (width 0.254) (type default)) (fill (type background)))',
                   f'(text {q(label)} (at 0 -2.54 0) (effects (font (size 1.27 1.27))))']
        for index, r in enumerate(members):
            pin_name, ball = r[1], r[ball_col]
            if re.fullmatch(r'P[LRTB]\d+[ABCD]', pin_name):
                kind = 'bidirectional'
                if r[3] not in ('', '-'):
                    pin_name += '/' + r[3]
            elif pin_name.startswith('VCC') or pin_name == 'GND':
                kind = 'power_in'
            elif pin_name == 'NC':
                kind = 'no_connect'
            elif pin_name in ('TCK', 'TDI', 'TMS', 'PROGRAMN', 'CFG_0', 'CFG_1', 'CFG_2'):
                kind = 'input'
            elif pin_name == 'TDO':
                kind = 'output'
            elif pin_name in ('INITN', 'DONE', 'CCLK'):
                kind = 'bidirectional'
            else:
                kind = 'passive'  # Reserved: consult data sheet; never assume NC.
            y = -(index + 2) * 2.54
            output += [f'(pin {kind} line (at -40.64 {y:.2f} 0) (length 5.08)',
                       f'(name {q(pin_name)} (effects (font (size 1.016 1.016))))',
                       f'(number {q(ball)} (effects (font (size 1.016 1.016)))))']
        output.append(')')
    output.append(')')
    return output, len(units), len(pins)


def main():
    only = sys.argv[1:] or None
    output = ['(kicad_symbol_lib (version 20241209) (generator "roco_ecp5_generator")']
    for name, csv_path, doc_id, description in PARTS:
        if only and name not in only:
            continue
        lines, n_units, n_pins = build_symbol(name, csv_path, doc_id, description)
        output += lines
        print(f'Generated {name}: {n_units} units, {n_pins} unique balls')
    if only:
        print('Refusing to rewrite the library for a partial build', file=sys.stderr)
        sys.exit(2)
    output.append(')')
    (ROOT / 'roco.kicad_sym').write_text('\n'.join(output) + '\n')


if __name__ == '__main__':
    main()
