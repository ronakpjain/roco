#!/usr/bin/env python3
"""Build and run the official riscv-tests rv32ui suite on tb_core.

The riscv-tests checkout is expected under third_party/riscv-tests
(scripts/get-riscv-tests.sh fetches the pinned revision) or is taken
from $RISCV_TESTS. Each test is linked at 0x1000_0000, converted to a
$readmemh image, and run until the core stores to tohost.
"""

import argparse
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build" / "isa"
ENV = ROOT / "tests" / "riscv-env"
LINKER = ROOT / "tests" / "riscv-test.ld"
SECTIONS = (".text", ".rodata", ".data")

# This core implements precise misaligned load/store traps (mcause 4/6).
# rv32ui/ma_data instead requires hardware misaligned access support.
EXCLUDED = {"ma_data"}


def default_prefix() -> str:
    if shutil.which("riscv64-elf-gcc"):
        return "riscv64-elf-"
    homebrew = pathlib.Path("/opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf-")
    if pathlib.Path(str(homebrew) + "gcc").exists():
        return str(homebrew)
    return "riscv64-elf-"


def build_test(src: pathlib.Path, prefix: str, tests_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    name = src.stem
    elf = BUILD / f"{name}.elf"
    binfile = BUILD / f"{name}.bin"
    hexfile = BUILD / f"{name}.hex"
    compile_cmd = [
        f"{prefix}gcc",
        "-march=rv32i_zicsr_zifencei",
        "-mabi=ilp32",
        "-nostdlib",
        "-nostartfiles",
        "-I",
        str(ENV),
        "-I",
        str(tests_dir / "isa" / "macros" / "scalar"),
        "-T",
        str(LINKER),
        "-o",
        str(elf),
        str(src),
    ]
    subprocess.run(compile_cmd, check=True, capture_output=True, text=True)
    for sections in (SECTIONS, (".text", ".data")):
        objcopy = [f"{prefix}objcopy", "-O", "binary"]
        for section in sections:
            objcopy += ["-j", section]
        objcopy += [str(elf), str(binfile)]
        result = subprocess.run(objcopy, capture_output=True, text=True)
        if result.returncode == 0:
            break
    else:
        raise RuntimeError(result.stderr)
    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "elf2hex.py"), str(binfile), str(hexfile)],
        check=True,
        capture_output=True,
        text=True,
    )
    return elf, hexfile


def run_test(src: pathlib.Path, prefix: str, tests_dir: pathlib.Path, max_cycles: int) -> tuple[str, bool, str]:
    name = src.stem
    try:
        _, hexfile = build_test(src, prefix, tests_dir)
        result = subprocess.run(
            ["vvp", str(ROOT / "build" / "tb_core.vvp"), f"+hex={hexfile}", f"+max_cycles={max_cycles}"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        passed = "tb_core: PASS" in result.stdout
        detail = "" if passed else result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "no output"
        return name, passed, detail
    except subprocess.CalledProcessError as exc:
        return name, False, f"build failed: {exc.stderr.strip().splitlines()[-1] if exc.stderr.strip() else ''}"
    except subprocess.TimeoutExpired:
        return name, False, "simulation timeout"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--riscv-prefix", default=os.environ.get("RISCV_PREFIX", default_prefix()))
    parser.add_argument("--tests", nargs="*", help="only run these test names")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--max-cycles", type=int, default=2_000_000)
    parser.add_argument(
        "--tests-dir",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("RISCV_TESTS", ROOT / "third_party" / "riscv-tests")),
    )
    args = parser.parse_args()

    tests_dir: pathlib.Path = args.tests_dir
    suite = tests_dir / "isa" / "rv32ui"
    if not suite.is_dir():
        print(f"riscv-tests not found at {tests_dir}", file=sys.stderr)
        print("run scripts/get-riscv-tests.sh first", file=sys.stderr)
        return 2

    BUILD.mkdir(parents=True, exist_ok=True)
    sources = [path for path in sorted(suite.glob("*.S")) if path.stem not in EXCLUDED]
    if args.tests:
        wanted = set(args.tests)
        sources = [path for path in sources if path.stem in wanted]
    if not sources:
        print("no tests selected", file=sys.stderr)
        return 2

    print(f"rv32ui: {len(sources)} tests")
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [
            pool.submit(run_test, src, args.riscv_prefix, tests_dir, args.max_cycles)
            for src in sources
        ]
        for future in concurrent.futures.as_completed(futures):
            name, passed, detail = future.result()
            status = "PASS" if passed else "FAIL"
            print(f"  {name:8s} {status}" + (f"  ({detail})" if detail else ""))
            if not passed:
                failures.append(name)

    print(f"\n{len(sources) - len(failures)}/{len(sources)} passed")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
