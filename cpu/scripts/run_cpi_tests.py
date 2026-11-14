#!/usr/bin/env python3
"""Assert continuous retirement in warmed program regions."""
import argparse
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--riscv-prefix', default='riscv64-elf-')
parser.add_argument('--case', help='run one image instead of the whole CPI suite')
args = parser.parse_args()
cases = {
    'cpi-jalr': ('cpi_target_a', 'cpi_target_b'),
    'cpi-forward': ('cpi_load', 'cpi_load_control', 'cpi_mul', 'cpi_lrsc'),
    'cpi-vector': ('cpi_reduce8', 'cpi_reduce16', 'cpi_reduce32', 'cpi_vec_alu'),
}
if args.case:
    if args.case not in cases:
        parser.error(f'unknown CPI case: {args.case}')
    cases = {args.case: cases[args.case]}
for image, windows in cases.items():
    symbols = {}
    for line in subprocess.check_output(
        [args.riscv_prefix + 'nm', f'build/{image}.elf'], text=True
    ).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    for sim in ('core', 'soc'):
        for symbol in windows:
            result = subprocess.run(
                ['vvp', f'build/tb_{sim}.vvp', f'+hex=build/{image}.hex',
                 f'+cpi_pc={symbols[symbol]:08x}', '+cpi_skip=8', '+cpi_count=128',
                 '+max_cycles=100000'],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
            )
            print(f'{sim} {symbol}:\n{result.stdout}', end='', flush=True)
            if result.returncode or 'CPI=1 PASS' not in result.stdout or f'tb_{sim}: PASS' not in result.stdout:
                raise SystemExit(1)
