#!/usr/bin/env python3
"""Run the SoC UART boot testbench and check both programs' serial output."""

import argparse
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sim", type=Path)
    parser.add_argument("packet", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--probe", action="store_true")
    modes.add_argument("--console", action="store_true")
    args = parser.parse_args()
    sim, packet = args.sim.resolve(), args.packet.resolve()
    # 8N1 at the testbench's 96 core clocks per bit, plus runtime headroom.
    cycles = 960 * len(packet.read_bytes().splitlines())
    cycles += 90_000_000 if args.console else 30_000_000
    command = [str(sim), f"+packet={packet}", f"+max_cycles={cycles}"]
    commands = None
    if args.console:
        command.append("+console")
        commands = (
            "help\r\necho UART input\nmissing\n" + "x" * 80 + "\n"
            "jobs\nrun missing &\nrun worker\nrun countdown &\nrun countdown &\nrun worker &\nhart\njobs\nwait\n"
            "run countdown 0 &\necho shell still active\nrun worker 0 &\nwait\n"
            "edit\nprint temporary\nset 40\nadd 2\nshow\nrepeat 2 hi\n"
            ".set 1 print script works\n.list\n.quit\nscript\n"
            "edit\n.del 5\ninvalid\n.quit\nscript\nexit\n"
        )
    run = subprocess.run(
        command,
        input=commands,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if args.probe:
        # Supervisor trap marker (0x400), hart 1 (0x100), load page fault (13).
        if not run.returncode or "tb_soc_boot: FAIL code=1293 (0 sdram errors)" not in run.stdout:
            print(run.stdout, end="")
            sys.exit("Expected a supervisor load-page-fault report from hart 1")
        print("User isolation: PASS (hart 1 supervisor load page fault)")
        return
    print(run.stdout, end="")
    if run.returncode or "tb_soc_boot: PASS (0 sdram errors)" not in run.stdout:
        sys.exit("SoC boot test failed")
    if args.console:
        expected = (
            "roco_os user shell; type help.\n"
            "roco_os> Commands: help, hart, echo [text], run <worker|countdown> [0|1] &, jobs, wait, edit, script, exit\n"
            "roco_os> UART input\n"
            "roco_os> Unknown command; try help.\n"
            "roco_os> Line too long.\n"
            "roco_os> No job yet.\n"
            "roco_os> No such program.\n"
            "roco_os> Usage: run <worker|countdown> [0|1] &\n"
        )
        if expected not in run.stdout:
            sys.exit("Unexpected shell transcript")
        # UART lines can arrive from either hart; check the causal order,
        # not their exact position relative to the next shell prompt.
        # Background jobs are not allowed to write to the console, so only
        # the shell's own output appears in the transcript.
        offset = 0
        for line in (
            "Started on hart 1.\n", "That program is already active.\n", "Started on hart 1.\n",
            "hart 0\n",
            "worker: completed successfully.\n", "countdown: completed successfully.\n",
            "Started on hart 0.\n", "shell still active\n",
            "worker: completed successfully.\n", "countdown: completed successfully.\n",
            "1 print script works\n2 set 40\n3 add 2\n4 show\n5 repeat 2 hi\n",
            "script works\n42\nhi\nhi\n", "script works\n42\nScript error on line 5.\n", "Bye.\n",
        ):
            pos = run.stdout.find(line, offset)
            if pos < 0:
                sys.exit(f"Missing or out-of-order shell output: {line.rstrip()!r}")
            offset = pos + len(line)
        if run.stdout.count("Started on hart 0.\n") != 2:
            sys.exit("Expected two foreground-style launches on hart 0")
        if run.stdout.count("worker: completed successfully.\n") != 2:
            sys.exit("Expected both worker runs to complete")
        return
    for expected in ("hart 0 user hello\n", "hart 1 user worker\n"):
        if run.stdout.count(expected) != 1:
            sys.exit(f"Expected exactly one UART message: {expected.rstrip()!r}")


if __name__ == "__main__":
    main()
