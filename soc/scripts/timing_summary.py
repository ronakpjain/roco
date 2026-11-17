#!/usr/bin/env python3
"""Render nextpnr ECP5 timing reports as GitHub-flavored Markdown."""

import argparse
import json
import os
from pathlib import Path


def format_mhz(value):
    return f"{value:.2f} MHz" if value is not None else "-"


def format_slack(value):
    return f"{value:+.2f} ns" if value is not None else "-"


def format_count(entry):
    used = entry.get("used", 0)
    available = entry.get("available", 0)
    percent = f" ({100 * used / available:.1f}%)" if available else ""
    return f"{used}/{available}{percent}"


def format_cell(endpoint):
    name = endpoint.get("cell", "?")
    if len(name) > 72:
        name = name[:69] + "..."
    return name.replace("|", "\\|")


def render_report(path):
    report = json.loads(path.read_text())
    lines = [f"### `{path}`", ""]
    fmax = report.get("fmax") or {}
    if fmax:
        lines += [
            "| Clock | Achieved | Constraint | Slack | Result |",
            "| --- | ---: | ---: | ---: | --- |",
        ]
        for clock, entry in sorted(fmax.items()):
            achieved = entry.get("achieved")
            constraint = entry.get("constraint")
            slack = (
                1000.0 / constraint - 1000.0 / achieved
                if achieved and constraint
                else None
            )
            result = "PASS" if slack is not None and slack >= 0 else "FAIL"
            lines.append(
                f"| `{clock}` | {format_mhz(achieved)} | {format_mhz(constraint)} | "
                f"{format_slack(slack)} | {result} |"
            )
        lines.append("")

    paths = report.get("critical_paths") or []
    if paths:
        critical = paths[0]
        segments = critical.get("path") or []
        delay = sum(segment.get("delay", 0.0) for segment in segments)
        start = segments[0].get("from", {}) if segments else {}
        end = segments[-1].get("to", {}) if segments else {}
        lines += [
            f"Critical path from {critical.get('from', '?')}: "
            f"{delay:.2f} ns, {len(segments)} segments",
            "",
            f"- start: `{format_cell(start)}`",
            f"- end: `{format_cell(end)}`",
            "",
        ]

    utilization = report.get("utilization") or {}
    resources = ["TRELLIS_COMB", "TRELLIS_FF", "DP16KD", "MULT18X18D", "TRELLIS_IO"]
    present = [name for name in resources if name in utilization]
    if present:
        lines += ["| Resource | Used |", "| --- | ---: |"]
        for name in present:
            lines.append(f"| {name} | {format_count(utilization[name])} |")
        lines.append("")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Markdown output file; defaults to GITHUB_STEP_SUMMARY or stdout",
    )
    args = parser.parse_args()

    lines = ["## FPGA timing", ""]
    for path in args.reports:
        lines += render_report(path)
    text = "\n".join(lines).rstrip() + "\n"

    output = args.output
    if output is None and os.environ.get("GITHUB_STEP_SUMMARY"):
        output = Path(os.environ["GITHUB_STEP_SUMMARY"])
    print(text, end="")
    if output is not None:
        with output.open("a") as stream:
            stream.write(text)


if __name__ == "__main__":
    main()
