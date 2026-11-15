#!/usr/bin/env python3
"""Measure complete program cycles and estimate runtime from routed Fmax.

Use identical program images and testbench settings for every variant. SoC
cycles include SDRAM initialization, cache misses and refresh at the simulated
CLK_HZ. Scaling these cycles by Fmax is an estimate, not a board measurement;
rerun at the intended CLK_HZ when changing peripheral timing.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess


def assignment(value):
    name, sep, item = value.partition('=')
    if not sep or not name or not item:
        raise argparse.ArgumentTypeError('expected NAME=VALUE')
    return name, item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', action='append', type=assignment, required=True,
                        help='NAME=simulator command; first variant is the baseline')
    parser.add_argument('--timing', action='append', type=assignment, default=[],
                        help='NAME=nextpnr report JSON, optional until route completes')
    parser.add_argument('--images', nargs='+', default=[
        'basic', 'muldiv', 'vector', 'vector_start', 'vector_retire',
        'vm', 'atomic', 'cpi_forward', 'cpi_vector', 'cpi_vm', 'cpi_jalr'])
    parser.add_argument('--build-dir', type=Path, default=Path('build'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    frequencies = {}
    for name, filename in args.timing:
        report = json.loads(Path(filename).read_text())
        frequencies[name] = min(clock['achieved'] for clock in report['fmax'].values())
    rows = []
    for image in args.images:
        baseline = None
        for name, command in args.variant:
            result = subprocess.run([
                *shlex.split(command), f'+hex={args.build_dir / (image + ".hex")}',
                '+measure_execution', '+max_cycles=2000000'],
                capture_output=True, text=True, timeout=120)
            match = re.search(r'^EXECUTION cycles=(\d+) active_cycles=(\d+)$', result.stdout, re.MULTILINE)
            if result.returncode or not match or ': PASS' not in result.stdout or ': FAIL' in result.stdout:
                raise SystemExit(f'{name}/{image} failed:\n{result.stdout}\n{result.stderr}')
            cycles = int(match[1])
            frequency = frequencies.get(name)
            row = dict(image=image, variant=name, cycles=cycles, active_cycles=int(match[2]),
                       active_estimated_us=int(match[2]) / frequency if frequency else None,
                       fmax_mhz=frequency,
                       estimated_us=cycles / frequency if frequency else None)
            if baseline is None:
                baseline = row
            row['active_speedup'] = (baseline['active_estimated_us'] / row['active_estimated_us']
                                     if baseline['active_estimated_us'] and row['active_estimated_us'] else None)
            row['active_break_even_mhz'] = (baseline['fmax_mhz'] * row['active_cycles'] / baseline['active_cycles']
                                             if baseline['fmax_mhz'] else None)
            row['cycle_ratio'] = cycles / baseline['cycles']
            row['break_even_mhz'] = (baseline['fmax_mhz'] * row['cycle_ratio']
                                     if baseline['fmax_mhz'] else None)
            row['speedup'] = (baseline['estimated_us'] / row['estimated_us']
                              if baseline['estimated_us'] and row['estimated_us'] else None)
            rows.append(row)
            runtime = f'{row["estimated_us"]:.3f} us' if frequency else 'timing pending'
            print(f'{image:15} {name:14} {cycles:8} cycles {runtime}', flush=True)
    summary = {}
    for name, _ in args.variant:
        selected = [row for row in rows if row['variant'] == name]
        summary[name] = {
            'programs': len(selected),
            'total_cycles': sum(row['cycles'] for row in selected),
            'active_cycles': sum(row['active_cycles'] for row in selected),
            'total_estimated_us': (sum(row['estimated_us'] for row in selected)
                                   if all(row['estimated_us'] is not None for row in selected) else None),
            'active_estimated_us': (sum(row['active_estimated_us'] for row in selected)
                                    if all(row['active_estimated_us'] is not None for row in selected) else None),
        }
    baseline = summary[args.variant[0][0]]
    for entry in summary.values():
        entry['total_speedup'] = (baseline['total_estimated_us'] / entry['total_estimated_us']
                                  if baseline['total_estimated_us'] and entry['total_estimated_us'] else None)
        entry['active_speedup'] = (baseline['active_estimated_us'] / entry['active_estimated_us']
                                   if baseline['active_estimated_us'] and entry['active_estimated_us'] else None)
    args.output.write_text(json.dumps({'results': rows, 'summary': summary}, indent=2) + '\n')


if __name__ == '__main__':
    main()
