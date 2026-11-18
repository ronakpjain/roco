# Formal verification

From `soc/`, install Yosys, `yosys-smtbmc`, and Z3. The core harness uses
reference instruction models from [riscv-formal](https://github.com/YosysHQ/riscv-formal):

```sh
git clone https://github.com/YosysHQ/riscv-formal /tmp/riscv-formal
git -C /tmp/riscv-formal checkout c992aa61fdfe0846c5ed90324c596202a1c69b76
export RISCV_FORMAL_DIR=/tmp/riscv-formal
bash formal/run.sh core bmc
bash formal/run.sh core cover
```

`DEPTH` sets the number of solver time steps; `SOLVER` overrides Z3. Logs,
SMT models, and counterexample/cover VCDs are under `build/formal/` by default.
BMC checks the selected number of steps from reset, not arbitrary execution
length. Cover checks that interesting cases are reachable; it does not prove
correctness.

## Core

Define `ROCO_RVFI` to expose the single-channel, 32-bit RVFI ports on `roco_cpu`.
They report the architectural instruction at MEM commit, or at synchronous trap
entry. Interrupt entry does not consume an order number; the first handler
instruction carries `rvfi_intr`. The existing simulation trace is unchanged.
Memory uses the `RISCV_FORMAL_ALIGNED_MEM` convention (aligned virtual address,
native little-endian byte lanes). External `halt` is a pause, not `rvfi_halt`.

`formal/rvfi_rv32i.sv` checks RV32I instruction results against the upstream
model, plus GPR consistency, PC continuity, order, and synchronous traps.
The harness assumes one-cycle fetch replies, always-ready data memory with
unconstrained read data, M-mode, and no interrupts. It limits fetched words to
instructions recognized by the upstream RV32I model plus ECALL, EBREAK and the
all-zero illegal encoding. FENCE and privileged/CSR behavior are not checked.
There is no coherent memory model, so this does not prove store-to-load behavior,
instruction fetch coherence, or cache/MMU correctness.

The interface is not sufficient to verify the entire implemented ISA: divides
write back independently of in-order retirement, and vector memory operations
can have multiple accesses or partial completion. Those need more trace support
before enabling their checkers. LR/SC and AMO fields are emitted but not checked
by this harness. CSR side effects and interrupt entry are not formally checked.

## AXI4-to-APB4 bridge

This job uses only the local RTL, with no riscv-formal dependency:

```sh
bash formal/run.sh bridge bmc
bash formal/run.sh bridge cover
```

`formal/axi_apb_contract.sv` assumes the master holds AXI AR/AW/W payloads
and `VALID` stable while stalled; it asserts the same for the bridge's R/B
channels. APB can stall and return arbitrary data or errors. The harness checks
setup/access sequencing and payload stability, then uses an independent
handshake scoreboard to check address alignment, byte strobes, IDs, response
data/status, rejected bursts, and response beat counts. It also exercises a
missing final `WLAST`. No fairness assumptions are imposed, so this is safety
checking, not a promise that an unresponsive peripheral will complete.

## Extending to the AXI fabric

Use the same assume/assert split at each component boundary. For the crossbar,
assume stable upstream requests and stable downstream responses; assert stable
forwarded requests and upstream responses. Add a scoreboard for decoded target,
master/ID, and accepted beat count, and cover simultaneous masters, simultaneous
read/write traffic, decode errors, and stalls on each channel. For the memory
master and SDRAM adapter, verify burst beat/address progression and response
accounting separately. Run these component checks before composing them; the
bridge job does **not** verify the crossbar, memory master, or SDRAM adapter.
