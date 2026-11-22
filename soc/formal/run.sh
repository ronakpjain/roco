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
  soc-system)
    # Run the end-to-end and component obligations separately. Report a
    # failure if any job fails, while still collecting the remaining results.
    case "$mode" in
      prove) ;;
      cover) export COVER_FAST=1 ;;
      *) echo 'soc-system requires prove or cover mode.' >&2; exit 2 ;;
    esac
    jobs=(soc-isa-memory soc-mmio bridge xbar sv32 dcache-memory axi-mem-master sdram-memory)
    failed=()
    for part in "${jobs[@]}"; do
      printf '\n=== %s %s ===\n' "$part" "$mode"
      if ! bash formal/run.sh "$part" "$mode"; then failed+=("$part"); fi
    done
    if (( ${#failed[@]} )); then
      printf '\n%s did not pass: %s\n' "$mode" "${failed[*]}" >&2
      exit 1
    fi
    exit 0
    ;;
  core|core-accounting|core-vector-mem-stream|core-m-stream|core-memory|core-memory-port|core-atomic|core-atomic-stream|core-irq|core-gpr|core-gpr-writeback|core-gpr-storage|core-no-divide|core-forward|core-isa|core-isa-stall|core-multiply)
    top=rvfi_rv32i
    if [[ "$job" == core-accounting ]]; then
      parameters="chparam -set AccountingOnly 1 $top;"
    elif [[ "$job" == core-isa-stall ]]; then
      parameters="chparam -set CoherentMemory 1 -set StallMemory 1 $top;"
    elif [[ "$job" == core-memory || "$job" == core-isa ]]; then
      parameters="chparam -set CoherentMemory 1 $top;"
    elif [[ "$job" == core-m-stream ]]; then
      parameters="chparam -set AccountingOnly 1 -set RegisterOnly 1 -set StallMemory 1 $top;"
    elif [[ "$job" == core-vector-mem-stream ]]; then
      # Reuse the RVFI-to-GPR storage check without the scalar ISA/operand checks.
      parameters="chparam -set AccountingOnly 1 -set RegisterOnly 1 -set StorageOnly 1 -set StallMemory 1 $top;"
    elif [[ "$job" == core-irq ]]; then
      parameters="chparam -set AccountingOnly 1 -set StallMemory 1 $top;"
    elif [[ "$job" == core-memory-port ]]; then
      parameters="chparam -set CoherentMemory 1 -set AccountingOnly 1 $top;"
    elif [[ "$job" == core-atomic* ]]; then
      parameters="chparam -set CoherentMemory 1 -set Atomics 1 $top;"
    elif [[ "$job" == core-gpr || "$job" == core-gpr-storage || "$job" == core-forward ]]; then
      parameters="chparam -set AccountingOnly 1 -set RegisterOnly 1 $top;"
      if [[ "$job" == core-gpr-storage ]]; then
        parameters="chparam -set AccountingOnly 1 -set RegisterOnly 1 -set StorageOnly 1 $top;"
      fi
    elif [[ "$job" == core-gpr-writeback || "$job" == core-no-divide ]]; then
      parameters="chparam -set AccountingOnly 1 $top;"
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
    if [[ "$job" == core-atomic* ]]; then defines+=' -DROCO_RVFI_RV32A_CHECKS'; fi
    if [[ "$job" == core-gpr || "$job" == core-gpr-writeback || "$job" == core-gpr-storage ]]; then
      defines+=' -DROCO_RVFI_GPR_WRITEBACK_CHECKS'
    fi
    if [[ "$job" == core-gpr || "$job" == core-no-divide || "$job" == core-gpr-storage ||
         "$job" == core-forward ]]; then
      defines+=' -DROCO_RVFI_NO_DIV_CHECKS'
    fi
    if [[ "$job" == core-gpr || "$job" == core-gpr-storage || "$job" == core-forward ]]; then
      defines+=' -DROCO_RVFI_GPR_STATE'
    fi
    if [[ "$job" == core-forward ]]; then
      defines+=' -DROCO_RVFI_GPR_WRITEBACK_CHECKS -DROCO_RVFI_FORWARD_CHECKS -DROCO_FORMAL_SIMPLE_FETCH'
    elif [[ "$job" == core-isa* || "$job" == core-atomic-stream ]]; then
      defines+=' -DROCO_RVFI_GPR_STATE -DROCO_RVFI_GPR_WRITEBACK_CHECKS -DROCO_RVFI_FORWARD_CHECKS -DROCO_RVFI_INSN_CHECKS -DROCO_RVFI_NO_DIV_CHECKS -DROCO_RVFI_PC_CHECKS'
    fi
    if [[ "$job" == core-isa-stall ]]; then defines+=' -DROCO_RVFI_STALL_CHECKS'; fi
    if [[ "$job" == core-atomic-stream ]]; then defines+=' -DROCO_ATOMIC_STREAM_CHECKS'; fi
    if [[ "$job" == core-m-stream ]]; then
      depth=40
      defines+=' -DROCO_M_STREAM_CHECKS -DROCO_RVFI_DIV_CHECKS -DROCO_DIVIDER_FORMAL'
      defines+=' -DROCO_RVFI_GPR_STATE -DROCO_RVFI_GPR_WRITEBACK_CHECKS -DROCO_RVFI_FORWARD_CHECKS -DROCO_RVFI_NO_DIV_CHECKS -DROCO_FORMAL_SIMPLE_FETCH'
      proof_engine="smtbmc ${SOLVER:-bitwuzla}"
      proof_depth=7
      proof_lowering='memory_map -rom-only; opt'
    fi
    if [[ "$job" == core-vector-mem-stream ]]; then
      depth=24
      defines+=' -DROCO_VECTOR_MEM_STREAM -DROCO_RVFI_GPR_STATE -DROCO_RVFI_GPR_WRITEBACK_CHECKS'
      proof_engine="smtbmc ${SOLVER:-bitwuzla}"
      proof_depth=6
      proof_lowering='memory_map -rom-only; opt'
    fi
    if [[ "$job" == core-irq ]]; then
      depth=52
      defines+=' -DROCO_IRQ_PIPELINE_CHECKS'
      proof_engine="smtbmc ${SOLVER:-bitwuzla}"
      proof_depth=7
      proof_lowering='memory_map -rom-only; opt'
    fi
    if [[ "$job" == core-no-divide || "$job" == core-forward || "$job" == core-isa* || "$job" == core-atomic-stream ]]; then
      proof_engine="smtbmc ${SOLVER:-bitwuzla}"
      proof_depth=6
      proof_lowering=''
    fi
    if [[ "$job" == core-no-divide ]]; then
      defines+=' -DROCO_RVFI_NO_DIV_INDUCTION'
      proof_lowering='memory_map -rom-only; opt'
    fi
    if [[ "$job" == core-atomic-stream ]]; then
      # Decoder ROM constants must hold in the induction step, not only at reset.
      proof_lowering='memory_map -rom-only; opt'
    fi
    if [[ -n "${ROCO_FORMAL_PDR:-}" ]]; then
      proof_engine='abc pdr'
      proof_depth=20
      proof_lowering='memory_map; techmap; opt; setundef -anyseq'
    fi
    if [[ "$job" == core-multiply ]]; then
      defines+=' -DROCO_FORMAL_MULTIPLY'
      sources+=(formal/rvfi_isa_rv32i_mul.sv "$ref"/insn_mul{,h,hsu,hu}.v)
    fi
    ;;
  core-divide-interlock|core-divide-cutpoint)
    top=core_divide_interlock
    depth=45
    sources=(rtl/core/*.sv formal/core_divide_interlock.sv)
    defines='-DROCO_RVFI -DROCO_RVFI_DIV_CHECKS'
    if [[ "$job" == core-divide-cutpoint ]]; then
      cut_sources=()
      for source in "${sources[@]}"; do
        if [[ "$source" != rtl/core/roco_cpu_divider.sv ]]; then cut_sources+=("$source"); fi
      done
      sources=("${cut_sources[@]}" formal/divider_cutpoint.sv)
      defines+=' -DROCO_FORMAL_DIV_CUTPOINT'
    fi
    ;;
  csr-trap)
    top=csr_trap_contract
    depth=12
    sources=(rtl/core/roco_cpu_csr.sv formal/csr_trap_contract.sv)
    defines=''
    ;;
  core-csr-trap)
    top=core_csr_trap
    depth=48
    sources=(rtl/core/*.sv formal/core_csr_trap.sv)
    defines='-DROCO_RVFI'
    ;;
  core-sv32-load)
    top=core_sv32_load
    depth=55
    sources=(rtl/core/*.sv formal/core_sv32_load.sv)
    defines='-DROCO_RVFI'
    ;;
  core-vector-copy)
    top=core_vector_copy
    depth=20
    sources=(rtl/core/*.sv formal/core_vector_copy.sv)
    defines='-DROCO_RVFI'
    ;;
  mul-prod)
    top=mul_prod_contract
    depth=2
    sources=(rtl/core/roco_cpu_mul_prod.sv formal/mul_prod_contract.sv)
    defines=''
    ;;
  mul-recombine)
    top=mul_recombine_contract
    depth=2
    sources=(rtl/core/roco_cpu_mul_{term,sum}.sv formal/mul_recombine_contract.sv)
    defines=''
    ;;
  divider)
    top=rv32m_divider_contract
    depth=24
    sources=(rtl/core/roco_cpu_divider.sv formal/rv32m_divider_contract.sv)
    defines='-DROCO_DIVIDER_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
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
  scalar-regs)
    top=roco_cpu_regfile
    depth=7
    sources=(rtl/core/roco_cpu_regfile.sv)
    defines='-DROCO_REGFILE_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=4
    proof_lowering=''
    ;;
  vector-execute)
    top=roco_cpu_vec_execute
    depth=2
    sources=(rtl/core/roco_cpu_vec_{execute,alu,reduce}.sv)
    defines='-DROCO_VECTOR_EXECUTE_FORMAL -DROCO_VECTOR_REDUCE_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=2
    proof_lowering='memory_map -rom-only; opt'
    ;;
  vector-regs)
    top=vector_regs_contract
    depth=9
    sources=(rtl/core/roco_cpu_vec.sv formal/vector_regs_contract.sv)
    defines=''
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=4
    proof_lowering=''
    ;;
  sv32)
    top=roco_cpu_mmu
    depth=24
    sources=(rtl/core/roco_cpu_mmu.sv)
    defines='-DROCO_SV32_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=5
    proof_lowering=''
    ;;
  if-cache)
    top=if_cache_contract
    depth=27
    sources=(rtl/mem/icache.sv rtl/core/roco_cpu_if_stage.sv formal/if_cache_contract.sv)
    defines='-DROCO_FETCH_PROTOCOL_CHECKS'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=6
    proof_lowering=''
    ;;
  icache)
    top=icache
    depth=28
    sources=(rtl/mem/icache.sv)
    defines='-DROCO_ICACHE_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=4
    proof_lowering=''
    ;;
  soc-control|soc-fence|soc-ram|soc-dcache-client|soc-sdram-memory|soc-dcache-memory|soc-fence-memory|soc-fetch-memory|soc-retire-memory|soc-isa-memory)
    top=roco_soc
    depth=8
    sources=(rtl/core/*.sv rtl/bus/*.sv rtl/mem/*.sv rtl/periph/*.sv rtl/roco_soc.sv)
    defines='-DROCO_SOC_CONTROL_FORMAL'
    if [[ "$job" == soc-fence ]]; then defines='-DROCO_SOC_FENCE_FORMAL'; fi
    if [[ "$job" == soc-dcache-client ]]; then defines='-DROCO_SOC_RAM_FORMAL -DROCO_SOC_DC_CLIENT_FORMAL -DROCO_SOC_FENCE_FORMAL'; fi
    if [[ "$job" == soc-ram ]]; then defines='-DROCO_SOC_RAM_FORMAL -DROCO_SOC_DC_CLIENT_FORMAL -DROCO_SOC_FENCE_FORMAL'; fi
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=5
    if [[ "$job" == soc-sdram-memory || "$job" == soc-dcache-memory || "$job" == soc-fence-memory || "$job" == soc-fetch-memory || "$job" == soc-retire-memory || "$job" == soc-isa-memory ]]; then
      defines='-DROCO_SOC_RAM_FORMAL -DROCO_SOC_DC_CLIENT_FORMAL -DROCO_SOC_FENCE_FORMAL -DROCO_SOC_SDRAM_MEMORY_FORMAL -DROCO_SDRAM_ADAPTER_FORMAL -DROCO_SDRAM_PIN_FORMAL -DROCO_SDRAM_LINK_FORMAL -DROCO_SDRAM_MEMORY_FORMAL'
      proof_depth=10
      if [[ "$job" == soc-dcache-memory || "$job" == soc-fence-memory || "$job" == soc-fetch-memory || "$job" == soc-retire-memory || "$job" == soc-isa-memory ]]; then
        defines+=' -DROCO_DCACHE_MEMORY_FORMAL -DROCO_SOC_DCACHE_MEMORY_FORMAL'
      fi
      if [[ "$job" == soc-fence-memory || "$job" == soc-fetch-memory || "$job" == soc-retire-memory || "$job" == soc-isa-memory ]]; then
        defines+=' -DROCO_ICACHE_FORMAL -DROCO_SOC_ICACHE_MEMORY_FORMAL'
      fi
      if [[ "$job" == soc-fetch-memory || "$job" == soc-retire-memory || "$job" == soc-isa-memory ]]; then
        defines+=' -DROCO_SOC_FETCH_MEMORY_FORMAL'
      fi
      if [[ "$job" == soc-retire-memory || "$job" == soc-isa-memory ]]; then
        defines+=' -DROCO_SOC_RETIRE_MEMORY_FORMAL -DROCO_RVFI'
        if [[ "$mode" == cover ]]; then defines+=' -DROCO_SOC_RETIRE_COVER'; fi
      fi
    fi
    if [[ "$job" == soc-isa-memory ]]; then
      ref=${RISCV_FORMAL_DIR:-third_party/riscv-formal}/insns
      if [[ ! -f "$ref/isa_rv32i.txt" ]]; then
        echo 'Set RISCV_FORMAL_DIR to a riscv-formal checkout (see docs/formal.md).' >&2
        exit 2
      fi
      sources+=("$ref/isa_rv32i.v")
      while read -r insn; do sources+=("$ref/insn_$insn.v"); done < "$ref/isa_rv32i.txt"
      defines+=' -DROCO_SOC_ISA_MEMORY_FORMAL -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_ALIGNED_MEM'
    fi
    proof_lowering='opt_clean'
    if [[ "$job" == soc-isa-memory && "$mode" == prove ]]; then
      # Yosys can infer separate ROMs for the live and replay decoders.
      # Their contents are otherwise constrained only by SMT initial-state
      # predicates, which k-induction does not apply. Map read-only tables
      # to combinational logic so both decoders are fixed in every state.
      proof_lowering='memory_map -rom-only; opt_clean'
    fi
    if [[ "$mode" == cover && -n "${COVER_FAST:-}" ]]; then
      # A full-depth cover searches from reset with the real boot path. The
      # fast variant skips the boot image and shortens SDRAM power-up so CPU
      # traffic is reachable in a bound a word-level solver can unroll.
      parameters="chparam -set BOOT_OVERRIDE 1 -set CLK_HZ 520000 -set SDRAM_POWERUP 8 -set ICACHE_LINES 2 -set DCACHE_LINES 2 $top;"
      depth=${DEPTH:-80}
    fi
    ;;
  soc-gpr)
    top=roco_soc
    depth=12
    sources=(rtl/core/*.sv rtl/bus/*.sv rtl/mem/*.sv rtl/periph/*.sv rtl/roco_soc.sv)
    defines='-DROCO_SOC_CONTROL_FORMAL -DROCO_RVFI -DROCO_RVFI_GPR_STATE -DROCO_SOC_GPR_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=8
    proof_lowering='memory_map -rom-only; opt_clean'
    if [[ "$mode" == cover ]]; then
      top=soc_mmio_memory
      sources+=(formal/soc_mmio_memory.sv)
      parameters="chparam -set SdramPowerup 8 -set MmioOnly 1 $top;"
      depth=160
    fi
    ;;
  soc-mmio)
    top=roco_soc
    depth=12
    sources=(rtl/core/*.sv rtl/bus/*.sv rtl/mem/*.sv rtl/periph/*.sv rtl/roco_soc.sv)
    defines='-DROCO_SOC_CONTROL_FORMAL -DROCO_SOC_MMIO_FORMAL'
    if [[ "$mode" != cover ]]; then
      # Reuse the actual fabric ownership and physical-address invariants.
      defines+=' -DROCO_SOC_RAM_FORMAL -DROCO_SOC_DC_CLIENT_FORMAL -DROCO_SOC_FENCE_FORMAL'
    fi
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=8
    proof_lowering='memory_map -rom-only; opt_clean'
    if [[ "$mode" == cover ]]; then
      # Drive the actual SoC from an external SDRAM program; no internal
      # CPU or bus cutpoints. The prove job keeps the production parameters.
      top=soc_mmio_memory
      sources+=(formal/soc_mmio_memory.sv)
      parameters="chparam -set SdramPowerup 8 -set MmioOnly 1 $top;"
      depth=160
    fi
    ;;
  soc-mmio-memory)
    top=soc_mmio_memory
    depth=422
    sources=(rtl/core/*.sv rtl/bus/*.sv rtl/mem/*.sv rtl/periph/*.sv rtl/roco_soc.sv
      formal/soc_mmio_memory.sv)
    defines=''
    ;;
  dcache-memory)
    top=dcache
    depth=64
    sources=(rtl/mem/dcache.sv)
    defines='-DROCO_DCACHE_MEMORY_FORMAL'
    parameters="chparam -set LINE_WORDS 8 -set NUM_LINES 128 $top;"
    if [[ "$mode" == cover ]]; then
      parameters="chparam -set LINE_WORDS 8 -set NUM_LINES 4 $top;"
    fi
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=6
    proof_lowering='opt_clean'
    ;;
  sdram-pins)
    top=sdram_ctrl
    depth=8
    if [[ "$mode" == cover ]]; then
      depth=120
      parameters="chparam -set T_POWERUP 8 -set REFRESH_CYCLES 64 $top;"
    fi
    sources=(rtl/mem/sdram_ctrl.sv)
    defines='-DROCO_SDRAM_PIN_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=8
    proof_lowering='opt_clean'
    ;;
  axi-mem-master)
    top=axi_mem_master_contract
    depth=12
    sources=(rtl/bus/axi4_mem_master.sv formal/axi_mem_master_contract.sv)
    defines=''
    ;;
  sdram-adapter|sdram-link|sdram-memory)
    top=axi_sdram_contract
    depth=36
    sources=(rtl/bus/axi4_sdram_adapter.sv formal/axi_sdram_contract.sv)
    defines='-DROCO_SDRAM_ADAPTER_FORMAL'
    proof_engine="smtbmc ${SOLVER:-bitwuzla}"
    proof_depth=5
    proof_lowering='opt_clean'
    if [[ "$job" == sdram-adapter && "$mode" == cover && -n "${COVER_DEEP:-}" ]]; then
      # A 256-beat rejected burst only fits inside this bound.
      defines+=' -DROCO_SDRAM_DEEP_COVER'
      depth=260
    fi
    if [[ "$job" != sdram-adapter ]]; then
      sources+=(rtl/mem/sdram_ctrl.sv)
      defines+=' -DROCO_SDRAM_PIN_FORMAL -DROCO_SDRAM_LINK_FORMAL'
      proof_depth=8
      if [[ "$mode" == cover ]]; then
        parameters="chparam -set PowerupCycles 8 $top;"
        depth=261
      fi
    fi
    if [[ "$job" == sdram-memory ]]; then
      defines+=' -DROCO_SDRAM_MEMORY_FORMAL'
      proof_depth=10
      depth=104
    fi
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
  *) echo 'Usage: bash formal/run.sh {soc-system|soc-isa-memory|soc-retire-memory|soc-fetch-memory|soc-fence-memory|soc-dcache-memory|soc-sdram-memory|soc-dcache-client|soc-ram|soc-fence|dcache-memory|sdram-pins|axi-mem-master|sdram-adapter|sdram-link|sdram-memory|soc-control|soc-mmio|soc-gpr|soc-mmio-memory|core|core-accounting|core-vector-mem-stream|core-m-stream|core-memory|core-memory-port|core-atomic|core-atomic-stream|core-irq|core-gpr|core-gpr-writeback|core-gpr-storage|core-no-divide|core-forward|core-isa|core-isa-stall|core-multiply|core-divide-interlock|core-divide-cutpoint|core-csr-trap|csr-trap|core-sv32-load|core-vector-copy|mul-prod|mul-recombine|divider|atomic-mem|scalar-regs|vector-regs|vector-execute|sv32|icache|if-cache|bridge|xbar} [bmc|bmc-fast|cover|prove]' >&2; exit 2 ;;
esac

out="${FORMAL_BUILD_DIR:-build/formal}/$top"
if [[ "$job" == soc-mmio || "$job" == soc-gpr ]]; then
  out="${FORMAL_BUILD_DIR:-build/formal}/roco_soc_${job#soc-}"
elif [[ "$top" == rvfi_rv32i && "$job" == core-* ]]; then
  out="${out}_${job#core-}"
elif [[ "$job" == core-divide-cutpoint ]]; then
  out="${out}_cutpoint"
elif [[ "$job" == sdram-link || "$job" == sdram-memory ]]; then
  out="${out}_${job#sdram-}"
elif [[ "$job" == soc-fence || "$job" == soc-ram || "$job" == soc-dcache-client || "$job" == soc-sdram-memory || "$job" == soc-dcache-memory || "$job" == soc-fence-memory || "$job" == soc-fetch-memory || "$job" == soc-retire-memory || "$job" == soc-isa-memory ]]; then
  out="${out}_${job#soc-}"
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
aigsmt ${SOLVER:-bitwuzla}

[engines]
$proof_engine

[script]
read_verilog -formal -sv -DSYNTHESIS $defines -I. $files
$parameters
prep -top $top -flatten
# Apply engine/job-specific lowering (including symbolic undef for PDR).
$proof_lowering

[files]
rtl/common/axi4_defs.svh
rtl/common/roco_cpu_defs.svh
rtl/common/roco_rvfi.svh
formal/rv32m_divider_checks.svh
formal/scalar_regs_checks.svh
formal/icache_checks.svh
formal/sv32_checks.svh
formal/if_cache_pc_checks.svh
formal/icache_backing_checks.svh
formal/irq_ex_checks.svh
formal/irq_fetch_filter.svh
formal/irq_pipeline_checks.svh
formal/m_ex_checks.svh
formal/m_stream_checks.svh
formal/vector_mem_filter.svh
formal/vector_mem_ex_checks.svh
formal/vector_mem_commit_checks.svh
formal/soc_control_checks.svh
formal/sdram_pin_checks.svh
formal/sdram_memory_checks.svh
formal/dcache_memory_checks.svh
formal/soc_fence_checks.svh
formal/soc_ram_checks.svh
formal/axi_sdram_state.svh
formal/axi_sdram_checks.svh
formal/soc_sdram_memory_checks.svh
formal/soc_icache_memory_checks.svh
formal/soc_fetch_queue_checks.svh
formal/soc_fetch_link_checks.svh
formal/soc_retire_memory_checks.svh
formal/soc_isa_memory_checks.svh
formal/soc_mmio_checks.svh
formal/soc_gpr_checks.svh
EOF
fi

# Retirement covers target the new pipeline witnesses. Inherited standalone
# adapter covers include burst shapes the connected caches never issue.
# Cover mode ignores assertions; drop their unused monitor state as well.
cover_selection=''
if [[ ( "$job" == soc-retire-memory || "$job" == soc-isa-memory ) && "$mode" == cover ]]; then
  cover_sources='a:src=*soc_retire_memory_checks.svh*'
  if [[ "$job" == soc-isa-memory ]]; then
    cover_sources+=' a:src=*soc_isa_memory_checks.svh* %u'
  fi
  cover_selection="chformal -cover -remove $cover_sources %n; chformal -assert -remove; opt_clean -purge;"
elif [[ ( "$job" == soc-mmio || "$job" == soc-gpr ) && "$mode" == cover ]]; then
  cover_selection="chformal -cover -remove a:src=*soc_${job#soc-}_checks.svh* %n; chformal -assert -remove; opt_clean -purge;"
fi

# Quote source paths for Yosys, including external references with spaces.
printf -v files ' "%s"' "${sources[@]}"
"${YOSYS:-yosys}" -Qq -l "$out/yosys.log" -p "
  read_verilog -formal -sv -DSYNTHESIS $defines -Irtl/common -Iformal $files;
  $parameters
  prep -top $top -flatten;
  $cover_selection
  async2sync; dffunmap;
  write_smt2 -wires \"$out/design.smt2\"
"
exec "${SMTBMC:-yosys-smtbmc}" -s "${SOLVER:-bitwuzla}" -t "${DEPTH:-$depth}" "${flags[@]}" \
  --noprogress --dump-vcd "$out/$mode-%.vcd" "$out/design.smt2"
