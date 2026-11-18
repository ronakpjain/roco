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

### Unbounded safety proofs

Install [SymbiYosys](https://github.com/YosysHQ/sby) and Yosys's ABC executable.
Both bus contracts passed unbounded with ABC's property-directed reachability
(PDR):

```sh
bash formal/run.sh bridge prove
bash formal/run.sh xbar prove
```

The core's retirement-accounting contract also passed unbounded:

```sh
bash formal/run.sh core-accounting prove
```

This uses the same RV32I environment as `core`, but only checks that normal
retirement and synchronous exceptions are mutually exclusive, the normal RVFI
instruction and PC match the commit trace, exceptions have no reported register
or memory writes, and the 64-bit order counter starts at zero and advances
exactly once per event. It also checks that a pending synchronous trap cannot
have a valid EX/MEM packet. It does not compare architectural values against the
ISA model. `bash formal/run.sh core prove` attempts the full RV32I check suite,
which does not yet have a completed unbounded proof. PDR is not limited by `DEPTH`. `PROOF_TIMEOUT` defaults to 300 seconds; a timeout is
inconclusive. Proof logs and any counterexample are under the job's `prove/`
directory. `SOLVER` selects the SMT engine for the divider's k-induction
or the witness reconstruction solver for PDR, not the PDR engine itself. `SBY` can override the SymbiYosys executable path.

A `PASS` proves the harness assertions for all reachable states under its
assumptions. It does not widen the instruction or protocol scope, or prove
forward progress under arbitrary stalls.

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

### RV32M divide and remainder

```sh
bash formal/run.sh divider prove
bash formal/run.sh divider cover
```

The standalone divider passes unbounded k-induction against an independent
radix-2 restoring-division model for `DIV`, `DIVU`, `REM`, and `REMU`. It checks
all operand values, divide by zero, signed overflow, completion timing in active
cycles, and arbitrary `halt` pauses. The caller must only start a supported
operation when not busy. This job does not need `riscv-formal`; the core jobs
continue to use it. This unit proof does not cover core forwarding, scoreboard
hazards, or placing the deferred GPR write in the right RVFI retirement record.

### A and the implemented vector subset

Neither has an end-to-end formal proof yet. For A, the scalar RVFI packet can
represent a word AMO with both masks and its old/new data, and an unsuccessful
SC with no memory effect. Proving A also requires a coherent memory reference
and a reservation model to check LR/SC, invalidating stores and traps, and
ordering. Seeing the fields in the trace is not that proof.

For vector, the implementation supports a subset (128-bit VLEN, LMUL=1, and
8/16/32-bit element widths), not all of RVV. A checker needs vector register
and `vl`/`vtype`/`vstart` state, plus per-element memory events to verify partial
completion and restart after a trap. A single scalar RVFI memory event cannot
express those effects. Use a separate vector reference/checker alongside the
scalar `riscv-formal` jobs.

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

## AXI4 crossbar

```sh
bash formal/run.sh xbar bmc
bash formal/run.sh xbar cover
```

`formal/axi_xbar_contract.sv` checks all five master ports and both slave ports.
It assumes upstream requests and downstream responses are held stable under
backpressure, and asserts that on the corresponding crossbar outputs. It
checks address decode, payload preservation, and one-to-one handshakes on all
five channels. A per-master scoreboard checks that each data or response
transfer uses the destination of the accepted address and that writes return
only after `WLAST`. Cover checks include both destinations accepting addresses
in the same cycle, and concurrent read and write responses.

This checks routing, not whether endpoints generate correct `LAST`, IDs, or
burst lengths. It does not prove arbitration fairness. The AXI memory master
and SDRAM adapter still need separate jobs for burst beat/address progression
and response accounting before composing the checks at the SoC boundary.
