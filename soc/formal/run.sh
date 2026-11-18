#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${2:-bmc}
flags=()
case "$mode" in
  bmc) ;;
  cover) flags=(-c) ;;
  prove) ;;
  *) echo "Unknown formal mode: $mode" >&2; exit 2 ;;
esac

case "${1:-}" in
  core)
    top=rvfi_rv32i
    depth=9
    if [[ "$mode" == cover ]]; then depth=18; fi
    ref=${RISCV_FORMAL_DIR:-third_party/riscv-formal}/insns
    if [[ ! -f "$ref/isa_rv32i.txt" ]]; then
      echo 'Set RISCV_FORMAL_DIR to a riscv-formal checkout (see docs/formal.md).' >&2
      exit 2
    fi
    sources=(rtl/core/*.sv formal/rvfi_rv32i.sv "$ref/isa_rv32i.v")
    while read -r insn; do sources+=("$ref/insn_$insn.v"); done < "$ref/isa_rv32i.txt"
    defines='-DROCO_RVFI -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_ALIGNED_MEM'
    ;;
  bridge)
    top=axi_apb_contract
    depth=10
    sources=(rtl/bus/axi4_apb_bridge.sv formal/axi_apb_contract.sv)
    defines=''
    ;;
  xbar)
    top=axi_xbar_contract
    depth=9
    sources=(rtl/bus/axi4_xbar.sv formal/axi_xbar_contract.sv)
    defines=''
    ;;
  *) echo 'Usage: bash formal/run.sh {core|bridge|xbar} [bmc|cover|prove]' >&2; exit 2 ;;
esac

out="${FORMAL_BUILD_DIR:-build/formal}/$top"
mkdir -p "$out"
if [[ "$mode" == prove ]]; then
  if ! command -v "${SBY:-sby}" >/dev/null; then
    echo 'Install SymbiYosys (sby) to run unbounded proofs.' >&2
    exit 2
  fi
  # SBY executes the Yosys script in its work directory.
  for i in "${!sources[@]}"; do
    if [[ "${sources[i]}" != /* ]]; then sources[i]="$PWD/${sources[i]}"; fi
  done
  printf -v files ' "%s"' "${sources[@]}"
  "${SBY:-sby}" --yosys "${YOSYS:-yosys}" -f -d "$out/prove" <<EOF
[options]
mode prove
timeout ${PROOF_TIMEOUT:-300}
aigsmt ${SOLVER:-z3}

[engines]
abc pdr

[script]
read_verilog -formal -sv -DSYNTHESIS $defines -I. $files
prep -top $top -flatten
memory_map
techmap
opt
# Make undefined values (including out-of-range mux inputs) symbolic, not zero.
setundef -anyseq

[files]
rtl/common/axi4_defs.svh
rtl/common/roco_cpu_defs.svh
rtl/common/roco_rvfi.svh
EOF
  exit
fi

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
