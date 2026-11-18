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
correctness. With SymbiYosys installed, `bmc-fast` runs the same bounded
assertions via ABC's bit-level `bmc3` engine; use `DEPTH` to set the bound.

### Continuous integration

The [SoC formal verification workflow](../../.github/workflows/formal.yml)
checks SoC changes on pull requests and pushes to `main` and `ci/**`. Each
matrix job is labeled `prove` (unbounded safety) or `bmc-fast` (bounded, with
an explicit depth in the workflow). CI pins OSS CAD Suite and the upstream
ISA model revision, and uploads solver logs and any counterexample VCDs.
The matrix gates the completed checks; exploratory jobs that have not closed,
including full-core `prove` and `core-multiply`, remain runnable locally.

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
directory. `SOLVER` selects the SMT solver for k-induction or witness
reconstruction for PDR, not the PDR engine itself. `SBY` can override the SymbiYosys executable path.

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
The default `core` job leaves read data unconstrained and is not a memory
coherence check.

### Whole-core data-port refinement

```sh
bash formal/run.sh core-memory bmc
bash formal/run.sh core-memory cover
bash formal/run.sh core-memory-port prove
```

`core-memory` runs the RV32I architectural assertions on the actual `roco_cpu`
with a sparse memory model. The solver chooses an arbitrary word address and
initial value. Only that word is stateful; reads elsewhere may vary. A physical
copy updates from the real data-port writes, and a separate architectural copy
updates from RVFI. The check compares address, direction, byte enables, and
active data lanes, and checks reads after writes at the tracked address. The
cover job asks for a store that changes the word followed by a read of a written
byte. `core-memory-port` isolates the data-port and retirement-accounting checks
using the same inputs, without the instruction semantics comparisons.

Neither job models coherent instruction fetch, the caches, or Sv32. An
unbounded pass for `core-memory-port` would not prove the full ISA; the combined
`core-memory` job still needs an unbounded result.

The interface is not sufficient to verify the entire implemented ISA: divides
write back independently of in-order retirement, and vector memory operations
can have multiple accesses or partial completion. Those need more trace support
before enabling their checkers. LR/SC and AMO fields are emitted but not checked
by this harness. CSR side effects and interrupt entry are not formally checked.

### Scalar register and forwarding checks

```sh
DEPTH=12 bash formal/run.sh core-gpr bmc-fast
bash formal/run.sh core-gpr prove
```

This isolates the whole-core architectural operand scoreboard and checks that a
non-x0 retired write arrives at the physical scalar write port, with the same
destination and data, on the next cycle. It also checks that the divider
cannot write in this RV32I environment. The bounded run passed at 12 steps;
there is no completed unbounded result for this group.

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

```sh
bash formal/run.sh core-divide-cutpoint bmc-fast
bash formal/run.sh core-divide-interlock bmc-fast
```

The cutpoint job passed 45 bounded steps for a fixed program on the core: two
loads, divide, an independent instruction, then a dependent read and a younger
overwrite. Operands and the divide operation are arbitrary. It substitutes a
divider with the proved busy/done timing and an arbitrary 32-bit result, then
checks the forwarded launch operands, deferred write destination and data seen
by the dependents. It also asserts that the program completes in the
always-ready environment, so the interlock checks cannot pass by hanging.
`core-divide-interlock` keeps the real divider and compares its writeback with
a lockstep instance; the 36-step bounded attempt timed out.

`core-multiply` extends the mixed RV32I program stream and semantic checks
with the upstream `MUL`, `MULH`, `MULHSU`, and `MULHU` models using their real
arithmetic, not `RISCV_FORMAL_ALTOPS`. The cover job reached a nonzero GPR
result for all four operations. The full arithmetic equivalence run timed out.
`bash formal/run.sh mul-recombine prove` passed ABC PDR for the combinational
carry-save recombination and low/high selection on arbitrary signed cross
terms and arbitrary low/high partial products. Both selection covers passed.
This unit proof does not check the DSP inputs or the pipeline.

### A and the implemented vector subset

```sh
bash formal/run.sh atomic-mem prove
bash formal/run.sh vector-regs prove
```

Both jobs passed unbounded. `atomic-mem` checks the actual MEM stage against a
coherent two-word model: all nine word AMO operations, LR/SC success and
failure, same-address invalidation, traps between operations, and arbitrary
memory backpressure. It models upstream serialization (a new lookup is
launched only when no older operation is pending); it does not verify that the
core enforces that contract or that its AXI/cache path implements it.

`vector-regs` checks all three read ports against an arbitrary tracked register
and byte, including whole-register writes, legal 8/16/32-bit element writes,
write priority, bypass, and reset during an in-flight write. It does not check
arithmetic, configuration, or vector memory sequencing.

For the end-to-end A checks on `roco_cpu`:

```sh
DEPTH=12 bash formal/run.sh core-atomic bmc-fast
bash formal/run.sh core-atomic cover
```

This mixes RV32I and supported A encodings, keeps riscv-formal for the base
instructions, and compares atomic retirements with a separate reservation and
RMW model. It reuses the symbolic coherent word at the data port and checks
that SC lookups don't race older reservation updates. Failed SC can cause a
cache-side access, but must not write memory. The 12-step bounded run passed;
cover reached successful SC, failed SC, AMO and misaligned atomics. It is not
an unbounded proof, and it does not model MMIO, other agents, or multicore
ordering.

For vector, a fixed whole-core program sets VL=2, loads two elements, and
stores them back at a different address. The source data and element width are
symbolic and the data port can stall arbitrarily. `core-vector-copy` checks
addresses, store byte lanes and data, the `vsetivli` result, and retirement
only on the last element. It passed 20 bounded steps and reached completion at
all three widths. It does not prove arbitrary vector programs.

```sh
DEPTH=20 bash formal/run.sh core-vector-copy bmc-fast
bash formal/run.sh core-vector-copy cover
```

The implementation supports a subset (128-bit VLEN, LMUL=1, and 8/16/32-bit
element widths), not all of RVV. A complete checker needs vector register
and `vl`/`vtype`/`vstart` state, plus per-element memory events to verify partial
completion and restart after a trap. A single scalar RVFI memory event cannot
express those effects. Use a separate vector reference/checker alongside the
scalar `riscv-formal` jobs.

### CSR and machine-trap integration

```sh
bash formal/run.sh core-csr-trap bmc-fast
bash formal/run.sh core-csr-trap cover
```

This fixed program writes and reads back a symbolic `mscratch` value, enters
an `ECALL` trap at `mtvec`, reads `mepc` and `mcause` in the handler, rewrites
`mepc`, and checks that `MRET` resumes at the right instruction. It checks the
RVFI handler marker, faulting versus normal retirements, PC and writeback data,
and bounded completion in the always-ready environment. It passed 48 bounded
steps and reached the post-return instruction. This is not a general CSR,
interrupt, or privilege-delegation proof.

### Sv32 load integration

```sh
bash formal/run.sh core-sv32-load bmc-fast
bash formal/run.sh core-sv32-load cover
```

This MPRV program leaves instruction fetch in M mode, and runs a real Sv32
page walk for a load with U-mode permissions. The harness chooses one of two
4 MiB leaf PTEs. For a readable page it checks the PTW address and AXI size,
physical data address, virtual RVFI address, and symbolic load value. For an
execute-only page with MXR off it checks that no data transaction commits and
that the handler reads the expected `mcause` and `mtval`. Both paths passed 55
bounded steps and reached both cover statements. This does not cover
two-level walks, TLB invalidation, or all permission combinations.

### Scalar writeback correspondence

```sh
bash formal/run.sh core-gpr-writeback prove
DEPTH=12 bash formal/run.sh core-gpr bmc-fast
```

`core-gpr-writeback` passed unbounded ABC PDR on the actual core in the
always-ready RV32I environment. In both directions, nonzero scalar WB-stage
writes correspond to RVFI register updates on the previous cycle, with the
same destination and data. The divider and scalar writers cannot contend
for the shared GPR port. The stronger `core-gpr` job still checks the
architectural operand scoreboard and absence of deferred writes; it passed
12 bounded steps, not an unbounded proof.

`bash formal/run.sh core-no-divide prove` discharges the deferred-write
exclusion in the RV32I environment by k-induction. It asserts that accepted
instruction responses, occupied fetch slots, and valid ID/EX packets never
carry a divide encoding, and that the divider stays idle. It does not assume
anything about internal pipeline state.

`core-gpr-storage` exposes one arbitrary physical GPR to check its stored
value against the RVFI write history, allowing the one-cycle delay before
scalar WB lands. `core-gpr` also asserts this relation while checking both
retired operands. The combined assertions passed 12 bounded steps; an
unbounded storage/operand proof is still open.

`bash formal/run.sh scalar-regs prove` separately proved the physical GPR
file by SMT k-induction. The one-register reference checks x0, reset,
stored data, both read ports, scalar bypass, and divider priority for
simultaneous requests. All four covers passed. This does not check the
pipeline's operand muxes against architectural state.

### Remaining whole-core proof obligations

- Close the RV32I instruction suite with inductive invariants for forwarding,
  redirects, and architectural state. Then discharge the core-to-memory
  contract with realistic fetch and memory handshakes.
- Extend end-to-end retirement checks to M and A. In particular, associate
  deferred divide writes and actual atomic completions with the issuing
  instruction, and check that the upstream contracts of the unit proofs hold.
- Check CSR transitions, trap/interrupt entry and return, then Sv32 permissions,
  page walks and fence effects against architectural models.
- Check the implemented vector subset against a vector reference, including
  element order, masks and tails, and partial effects across traps/restarts.

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
