#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

job=${1:-}
mode=${2:-bmc}
flags=()
parameters=''
proof_engine='abc pdr'
proof_depth=20
proof_lowering='memory_map; techmap; opt; setundef -anyseq'
case "$mode" in
  bmc|bmc-fast) ;;
  cover) flags=(-c) ;;
  prove) ;;
  *) echo "Unknown formal mode: $mode" >&2; exit 2 ;;
esac

case "$job" in
  core|core-accounting|core-memory|core-memory-port|core-atomic|core-gpr)
    top=rvfi_rv32i
    if [[ "$job" == core-accounting ]]; then
      parameters="chparam -set AccountingOnly 1 $top;"
    elif [[ "$job" == core-memory ]]; then
      parameters="chparam -set CoherentMemory 1 $top;"
    elif [[ "$job" == core-memory-port ]]; then
      parameters="chparam -set CoherentMemory 1 -set AccountingOnly 1 $top;"
    elif [[ "$job" == core-atomic ]]; then
      parameters="chparam -set CoherentMemory 1 -set Atomics 1 $top;"
    elif [[ "$job" == core-gpr ]]; then
      parameters="chparam -set AccountingOnly 1 -set RegisterOnly 1 $top;"
    fi
    depth=9
    if [[ "$job" == core-atomic ]]; then depth=10; fi
    if [[ "$mode" == cover ]]; then depth=18; fi
    ref=${RISCV_FORMAL_DIR:-third_party/riscv-formal}/insns
    if [[ ! -f "$ref/isa_rv32i.txt" ]]; then
      echo 'Set RISCV_FORMAL_DIR to a riscv-formal checkout (see docs/formal.md).' >&2
      exit 2
    fi
    sources=(rtl/core/*.sv formal/rvfi_rv32i.sv formal/rvfi_rv32a_model.sv "$ref/isa_rv32i.v")
    while read -r insn; do sources+=("$ref/insn_$insn.v"); done < "$ref/isa_rv32i.txt"
    defines='-DROCO_RVFI -DROCO_RVFI_RV32I_CHECKS -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_ALIGNED_MEM'
    if [[ "$job" == core-atomic ]]; then defines+=' -DROCO_RVFI_RV32A_CHECKS'; fi
    if [[ "$job" == core-gpr ]]; then defines+=' -DROCO_RVFI_GPR_CHECKS'; fi
    ;;
  core-vector-copy)
    top=core_vector_copy
    depth=20
    sources=(rtl/core/*.sv formal/core_vector_copy.sv)
    defines='-DROCO_RVFI'
    ;;
  divider)
    top=rv32m_divider_contract
    depth=24
    sources=(rtl/core/roco_cpu_divider.sv formal/rv32m_divider_contract.sv)
    defines='-DROCO_DIVIDER_FORMAL'
    proof_engine="smtbmc ${SOLVER:-z3}"
    proof_depth=4
    proof_lowering=''
    ;;
  atomic-mem)
    top=rv32a_mem_contract
    depth=12
    sources=(rtl/core/roco_cpu_mem_stage.sv rtl/core/roco_cpu_addsub.sv
             rtl/core/roco_cpu_mul_sum.sv formal/rv32a_mem_contract.sv)
    defines=''
    ;;
  vector-regs)
    top=vector_regs_contract
    depth=9
    sources=(rtl/core/roco_cpu_vec.sv formal/vector_regs_contract.sv)
    defines=''
    proof_engine="smtbmc ${SOLVER:-z3}"
    proof_depth=4
    proof_lowering=''
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
  *) echo 'Usage: bash formal/run.sh {core|core-accounting|core-memory|core-memory-port|core-atomic|core-gpr|core-vector-copy|divider|atomic-mem|vector-regs|bridge|xbar} [bmc|bmc-fast|cover|prove]' >&2; exit 2 ;;
esac

out="${FORMAL_BUILD_DIR:-build/formal}/$top"
if [[ "$top" == rvfi_rv32i && "$job" == core-* ]]; then
  out="${out}_${job#core-}"
fi
mkdir -p "$out"
if [[ "$mode" == prove || "$mode" == bmc-fast ]]; then
  sby_mode=prove
  if [[ "$mode" == bmc-fast ]]; then
    sby_mode=bmc
    proof_depth=${DEPTH:-$depth}
    proof_engine='abc bmc3'
    proof_lowering='memory_map; techmap; opt; setundef -anyseq'
  fi
  if ! command -v "${SBY:-sby}" >/dev/null; then
    echo 'Install SymbiYosys (sby) for prove or bmc-fast mode.' >&2
    exit 2
  fi
  # SBY executes the Yosys script in its work directory.
  for i in "${!sources[@]}"; do
    if [[ "${sources[i]}" != /* ]]; then sources[i]="$PWD/${sources[i]}"; fi
  done
  printf -v files ' "%s"' "${sources[@]}"
  exec "${SBY:-sby}" --yosys "${YOSYS:-yosys}" -f -d "$out/$mode" <<EOF
[options]
mode $sby_mode
depth $proof_depth
timeout ${PROOF_TIMEOUT:-300}
aigsmt ${SOLVER:-z3}

[engines]
$proof_engine

[script]
read_verilog -formal -sv -DSYNTHESIS $defines -I. $files
$parameters
prep -top $top -flatten
# For PDR, make undefined values symbolic rather than forcing them to zero.
$proof_lowering

[files]
rtl/common/axi4_defs.svh
rtl/common/roco_cpu_defs.svh
rtl/common/roco_rvfi.svh
formal/rv32m_divider_checks.svh
EOF
fi

# Quote source paths for Yosys, including external references with spaces.
printf -v files ' "%s"' "${sources[@]}"
"${YOSYS:-yosys}" -Qq -l "$out/yosys.log" -p "
  read_verilog -formal -sv -DSYNTHESIS $defines -Irtl/common -Iformal $files;
  $parameters
  prep -top $top -flatten;
  async2sync; dffunmap;
  write_smt2 -wires \"$out/design.smt2\"
"
exec "${SMTBMC:-yosys-smtbmc}" -s "${SOLVER:-z3}" -t "${DEPTH:-$depth}" "${flags[@]}" \
  --noprogress --dump-vcd "$out/$mode-%.vcd" "$out/design.smt2"
