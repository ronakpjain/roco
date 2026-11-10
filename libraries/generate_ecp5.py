"""Generate exact ECP5U-45 CABGA381 symbol from Lattice document 50486.
Run from the project root: python3 libraries/generate_ecp5.py
"""
import collections
import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NAME = 'LFE5U-45F-6BG381C'
rows = list(csv.reader((ROOT / 'sources/ECP5U-45-pinout.csv').open()))
header = next(i for i, r in enumerate(rows) if r and r[0] == 'PAD')
pins = [r for r in rows[header + 1:] if len(r) > 8 and r[8] not in ('', '-')]
assert len(pins) == len({r[8] for r in pins}) == 381
q = json.dumps
groups = collections.defaultdict(list)
for r in pins:
    name, bank = r[1], r[2]
    if re.fullmatch(r'P[LRTB]\d+[ABCD]', name):
        group = 'Bank ' + bank
    elif name.startswith('VCC'):
        group = 'Power'
    elif name == 'GND':
        group = 'Ground'
    else:
        group = 'Configuration and reserved'
    groups[group].append(r)
units = []
for label in sorted(groups):
    members = groups[label]
    # All balls are visible, unique pins; no hidden or stacked power pins.
    for start in range(0, len(members), 40):
        suffix = f' {start // 40 + 1}' if len(members) > 40 else ''
        units.append((label + suffix, members[start:start + 40]))
output = ['(kicad_symbol_lib (version 20241209) (generator "roco_ecp5_generator")',
          f'(symbol {q(NAME)} (pin_names (offset 1.016)) (in_bom yes) (on_board yes)',
          '(property "Reference" "U" (at 0 5.08 0) (effects (font (size 1.27 1.27))))',
          f'(property "Value" {q(NAME)} (at 0 2.54 0) (effects (font (size 1.27 1.27))))',
          '(property "Footprint" "roco:BGA381C80P20X20_1700X1700X176N" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
          '(property "Datasheet" "https://www.latticesemi.com/view_document?document_id=50486" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
          '(property "Description" "Lattice ECP5U-45, speed -6, caBGA381, commercial; exact 45F pinout" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))']
for unit, (label, members) in enumerate(units, 1):
    height = (len(members) + 2) * 2.54
    output += [f'(symbol "{NAME}_{unit}_1"',
               f'(rectangle (start -35.56 0) (end 35.56 {-height:.2f}) (stroke (width 0.254) (type default)) (fill (type background)))',
               f'(text {q(label)} (at 0 -2.54 0) (effects (font (size 1.27 1.27))))']
    for index, r in enumerate(members):
        name, ball = r[1], r[8]
        if re.fullmatch(r'P[LRTB]\d+[ABCD]', name):
            kind = 'bidirectional'
            if r[3] not in ('', '-'):
                name += '/' + r[3]
        elif name.startswith('VCC') or name == 'GND':
            kind = 'power_in'
        elif name == 'NC':
            kind = 'no_connect'
        elif name in ('TCK', 'TDI', 'TMS', 'PROGRAMN', 'CFG_0', 'CFG_1', 'CFG_2'):
            kind = 'input'
        elif name == 'TDO':
            kind = 'output'
        elif name in ('INITN', 'DONE', 'CCLK'):
            kind = 'bidirectional'
        else:
            kind = 'passive'  # Reserved: consult data sheet; never assume NC.
        y = -(index + 2) * 2.54
        output += [f'(pin {kind} line (at -40.64 {y:.2f} 0) (length 5.08)',
                   f'(name {q(name)} (effects (font (size 1.016 1.016))))',
                   f'(number {q(ball)} (effects (font (size 1.016 1.016)))))']
    output.append(')')
output += [')', ')']
(ROOT / 'roco.kicad_sym').write_text('\n'.join(output) + '\n')
print(f'Generated {len(units)} units, {len(pins)} unique balls')
