#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${2:-bmc}
flags=()
case "$mode" in
  bmc) ;;
  cover) flags=(-c) ;;
  induction) flags=(-i) ;;
  *) echo "Unknown formal mode: $mode" >&2; exit 2 ;;
esac

case "${1:-}" in
  core)
    top=rvfi_rv32i
    depth=10
    ref=${RISCV_FORMAL_DIR:-third_party/riscv-formal}/insns
    if [[ ! -f "$ref/isa_rv32i.txt" ]]; then
      echo 'Set RISCV_FORMAL_DIR to a riscv-formal checkout (see docs/formal.md).' >&2
      exit 2
    fi
    sources=(rtl/core/*.sv formal/rvfi_rv32i.sv "$ref/isa_rv32i.v")
    while read -r insn; do sources+=("$ref/insn_$insn.v"); done < "$ref/isa_rv32i.txt"
    defines='-DROCO_RVFI -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_ALIGNED_MEM'
    ;;
  *) echo 'Usage: bash formal/run.sh core [bmc|cover|induction]' >&2; exit 2 ;;
esac

out="${FORMAL_BUILD_DIR:-build/formal}/$top"
mkdir -p "$out"
# Quote source paths for Yosys, including external references with spaces.
printf -v files ' "%s"' "${sources[@]}"
"${YOSYS:-yosys}" -Qq -l "$out/yosys.log" -p "
  read_verilog -formal -sv -DSYNTHESIS $defines -Irtl/common $files;
  prep -top $top -flatten;
  async2sync; dffunmap;
  write_smt2 -wires \"$out/design.smt2\"
"
"${SMTBMC:-yosys-smtbmc}" -s "${SOLVER:-z3}" -t "${DEPTH:-$depth}" "${flags[@]}" \
  --noprogress --dump-vcd "$out/$mode-%.vcd" "$out/design.smt2"
