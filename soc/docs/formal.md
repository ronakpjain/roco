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
matrix job is labeled `prove` (unbounded safety), `bmc` or `bmc-fast`
(bounded, with an explicit depth in the workflow). CI pins OSS CAD Suite and the upstream
ISA model revision, and uploads solver logs and any counterexample VCDs.
The matrix gates the completed checks, including `core-isa`, `core-isa-stall`
and `csr-trap`.
Exploratory jobs such as the monolithic `core prove` and `core-multiply prove`
remain runnable locally but are not gates.

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
ISA model. Use `core-isa prove` for the unbounded scalar ISA check: it adds
invariants that the original `core prove` PDR job lacks. PDR is not limited by
`DEPTH`. `PROOF_TIMEOUT` defaults to 300 seconds; a timeout is inconclusive.
Proof logs and any counterexample are under the job's `prove/`
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
The default `core` job assumes one-cycle fetch replies, always-ready data memory
with unconstrained read data, M-mode, and no interrupts. It limits fetched words
to instructions recognized by the upstream RV32I model, ordinary FENCE (`fm=0`),
ECALL, EBREAK, and the all-zero illegal encoding. FENCE is checked as a scalar
no-op in this in-order, single-hart harness, not as a system ordering guarantee.
FENCE.I, privilege returns, and CSR instructions are not in this fetch set. The
`core` job is not a memory coherence check.

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

Neither job models coherent instruction fetch, the caches, or Sv32. The
unbounded `core-isa` job includes this same data-port contract together with the
RV32I semantics checks.

The interface is not sufficient to verify the entire implemented ISA: divides
write back independently of in-order retirement, and vector memory operations
can have multiple accesses or partial completion. Those need more trace support
before enabling general end-to-end checkers. The bounded `core-atomic` job
checks the LR/SC and AMO fields; separate jobs below cover selected CSR, trap,
interrupt and vector contracts.

### Scalar register and forwarding checks

```sh
DEPTH=12 bash formal/run.sh core-gpr bmc-fast
bash formal/run.sh core-gpr prove
```

This isolates the whole-core architectural operand scoreboard and checks that a
non-x0 retired write arrives at the physical scalar write port, with the same
destination and data, on the next cycle. It also checks that the divider
cannot write in this RV32I environment. The bounded run passed at 12 steps. `core-forward` and `core-isa` prove these
register relations unbounded in their respective fetch environments.

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
SOLVER=bitwuzla DEPTH=45 bash formal/run.sh core-divide-interlock bmc
```

The cutpoint job passed 45 bounded steps for a fixed program on the core: two
loads, divide, an independent instruction, then a dependent read and a younger
overwrite. Operands and the divide operation are arbitrary. It substitutes a
divider with the proved busy/done timing and an arbitrary 32-bit result, then
checks the forwarded launch operands, deferred write destination and data seen
by the dependents. It also asserts that the program completes in the
always-ready environment, so the interlock checks cannot pass by hanging.
`core-divide-interlock` keeps the real divider and compares its writeback with
an instance driven by the independently checked launch operands. The SMT job
passed 45 bounded steps with Bitwuzla, including the completion deadline.
At the same depth, cover reached program completion for all four divide and
remainder variants. Neither job proves the interlock for arbitrary instruction
sequences.

```sh
bash formal/run.sh core-m-stream prove
SOLVER=bitwuzla bash formal/run.sh core-m-stream cover
```

`core-m-stream` passed unbounded k-induction on arbitrary scalar streams
including all eight M operations, one-cycle fetch and arbitrary data-port
backpressure. The independent radix-2 divider checker runs on the actual
pipeline-launched divider. The core checks the launch's decoded operands,
its in-order RVFI instruction event, and the separate destination-tagged
GPR completion. The operand scoreboard checks forwarding and prevents a
younger dependent read, overwrite or second divide from issuing early.
Multiplication composes the separately proved product/recombination units
with checks of operand selection, EX/MEM transfer and GPR commit. Covers
reach a nonzero multiply, divide launch and deferred write, and a blocked
second divide. This job is bare M-mode without IRQs; it does not claim
that every non-M instruction's semantics are checked in this mixed stream.

`core-multiply` extends the mixed RV32I program stream and semantic checks
with the upstream `MUL`, `MULH`, `MULHSU`, and `MULHU` models using their real
arithmetic, not `RISCV_FORMAL_ALTOPS`. The cover job reached a nonzero GPR
result for all four operations. The full arithmetic equivalence run timed out.
`bash formal/run.sh mul-recombine prove` passed ABC PDR for the combinational
carry-save recombination and low/high selection on arbitrary signed cross
terms and arbitrary low/high partial products. Both selection covers passed.
This unit proof does not check the DSP inputs or the pipeline.
`bash formal/run.sh mul-prod prove` closes that input half: the four DSP
partial products equal the signed/unsigned half-word decomposition for all
multiply variants, with all four sign-combination covers reached. Together
the two jobs fix the full low/high product for arbitrary operands.
`core-m-stream` checks the composition through EX/MEM and writeback;
it does not need a monolithic 32×32 arithmetic equivalence run.

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
cover reached successful SC, failed SC, AMO and misaligned atomics.

```sh
SOLVER=bitwuzla bash formal/run.sh core-atomic-stream prove
```

`core-atomic-stream` passed unbounded k-induction for arbitrary mixed RV32I
and supported A instruction streams in bare M-mode with one-cycle fetch,
always-ready data memory, and no interrupts. It checks PC continuity, GPR
operands and writeback, AMO and LR/SC results, the reservation history and
lookup interlock, and the actual byte-lane writes and coherent reads at an
arbitrary address. The separate `atomic-mem` proof covers backpressure at
MEM; this whole-core proof does not cover data stalls, MMIO, DMA, or
multicore ordering.

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

### Vector execution datapath

```sh
bash formal/run.sh vector-execute prove
SOLVER=bitwuzla bash formal/run.sh vector-execute cover
```

`vector-execute` proves the combinational vector lane arithmetic, moves,
result selection, and byte-level active/undisturbed/agnostic merge for
arbitrary operands at all three widths. The reduction proof checks that
each carry-save group conserves the sum modulo SEW, that ungrouped
terms pass through, and that the final two terms produce the result.
This does not prove how the core decodes an instruction or generates its
lane masks.

### CSR trap and interrupt contract

```sh
bash formal/run.sh csr-trap prove
bash formal/run.sh csr-trap cover
bash formal/run.sh core-csr-trap bmc-fast
bash formal/run.sh core-csr-trap cover
```

`csr-trap` passed unbounded ABC PDR on the actual CSR file against a separate
M/S/U trap-state model. It checks interrupt enable and delegation, target
privilege before interrupt cause priority, direct/vectored trap addresses,
EPC/cause/tval, status save/restore, and clearing MPRV when xRET returns below
M-mode. The harness supplies accepted CSR writes, synchronous trap events,
interrupt inputs, and legal returns. It does not prove EX's CSR instruction
checks, when the pipeline takes an interrupt, or general CSR behavior outside
that state. Covers reach a delegated exception, a vectored supervisor interrupt,
competing interrupt priorities, and both return paths.

This fixed program writes and reads back a symbolic `mscratch` value, enters
an `ECALL` trap at `mtvec`, reads `mepc` and `mcause` in the handler, rewrites
`mepc`, and checks that `MRET` resumes at the right instruction. It checks the
RVFI handler marker, faulting versus normal retirements, PC and writeback data,
and bounded completion in the always-ready environment. It passed 48 bounded
steps and reached the post-return instruction. This is not a general CSR,
interrupt, or privilege-delegation proof.

### Pipeline interrupt precision

```sh
bash formal/run.sh core-irq prove
SOLVER=bitwuzla bash formal/run.sh core-irq cover
```

`core-irq` passed unbounded k-induction on the real pipeline. The fetch
set mixes scalar I/M/A, CSR accesses and MRET. IRQ inputs and data-port
backpressure are arbitrary. A retirement-driven PC scoreboard checks
that interrupt entry saves the next unretired PC, redirects to the
correct direct or vectored M-mode entry, and flags the first handler
report without consuming an extra RVFI order number. The proof forbids
entry with unfinished memory operations or deferred divide writes, or
capture against stale CSR interrupt enables. Covers reach entry after a
MEM hold and after a divide, capture both in EX and in an EX bubble, and
the first handler event. The job uses bare addressing, M-target traps
with delegation disabled, no external halt, and no vector instructions.
Delegation arbitration is checked by `csr-trap`, not by this pipeline job.

### Sv32 walker and TLBs

```sh
bash formal/run.sh sv32 prove
SOLVER=bitwuzla bash formal/run.sh sv32 cover
```

`sv32` passed unbounded k-induction on the production MMU. The reference
checks the root and second-level PTE addresses, SDRAM bounds, single-beat
AXI ownership and stall stability, 4 KiB and 4 MiB leaf decoding, reserved
non-leaf bits, U/S permissions (including SUM and MXR), software-managed
A/D bits, fault results, and cancellation/draining on flush or redirect.
It tracks an arbitrary TLB row in each TLB and checks the hot instruction
translation against the installed entry. A full flush invalidates both
TLBs and the hot slot. Covers reach both page sizes, translated fetch and
store hits, a second-level fault, and cancellation before and after AR.
The reference uses the SoC's documented 32-bit physical address subset
and arbitrarily delayed AXI responses. This is not a proof of the CPU's
SFENCE.VMA decode, trap retirement, or the coherence of page-table stores.

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
retired operands. The combined assertions passed 12 bounded steps in that
job; `core-forward` and `core-isa` close the register relations by induction.

`bash formal/run.sh scalar-regs prove` separately proved the physical GPR
file by SMT k-induction. The one-register reference checks x0, reset,
stored data, both read ports, scalar bypass, and divider priority for
simultaneous requests. All four covers passed. This does not check the
pipeline's operand muxes against architectural state.

### Operand forwarding on the whole core

```sh
SOLVER=bitwuzla bash formal/run.sh core-forward prove
bash formal/run.sh core-forward cover
```

`core-forward` proved unbounded by SMT k-induction: every RVFI operand read
(`rs1`/`rs2`) at retirement or synchronous-trap report equals the value the
architectural scoreboard holds for that register, for arbitrary programs over
the fetch set (syntactically restricted scalar RV32I opcodes, including OP-IMM,
plus CSR accesses outside the excluded addresses, ECALL/EBREAK/FENCE). The
proof checks operands, not the legality or behavior of every word this
syntactic filter admits. It carries an asserted invariant set, never
assumed: a two-deep per-register retirement history aligned with the WB port,
the stored register file one retirement behind it, the EX capture muxes
matched to that history (plain, EX/MEM-forwarded, and held lookup operands),
the EX/MEM and exception report registers, the presence of the forwarded
producer in MEM, and reachability facts excluding trap returns, interrupts, translation,
divider completion, and encodings for M, A, vector, SFENCE, FENCE.I and
CSR accesses that could enable translation or interrupts.
Each fact was needed inductively; the queue-slot and stage exclusions match
the restricted fetch set exactly. BitWuzla closes the induction step in
seconds where z3 timed out. This covers operand capture and reporting only:
the ALU results, memory effects, and branch resolution that consume the
operands are checked by the semantic jobs.

### Whole-core RV32I semantics

```sh
SOLVER=bitwuzla bash formal/run.sh core-isa prove
SOLVER=bitwuzla bash formal/run.sh core-isa-stall prove
SOLVER=bitwuzla bash formal/run.sh core-isa-stall cover
```

`core-isa` passed unbounded k-induction with Bitwuzla on the actual core. It
checks retirement results, GPR operands and writeback, PC continuity, selected
synchronous traps, and physical data-port effects against the RV32I model in
the fetch environment above. It uses the sparse memory model: the solver can
pick any word to verify reads after writes and byte-lane updates there.

The proof asserts the instruction-set restriction at every occupied fetch
slot, ID/EX, EX/MEM, and the pending exception. It tracks the next PC through
BTB predictions, queue entries, EX redirection, and synchronous trap restarts.
The proof does not assume that a word fetched at a given address is stable
across visits; the core must recover if an old taken prediction now refers to
an ordinary instruction.

`core-isa-stall` also passed unbounded k-induction, with the same assertions
and arbitrary data-port backpressure. The additional invariants check decoded
operands and effects even while EX or MEM is held, so an indefinitely stalled
packet cannot hide incorrect state from induction. The harness also checks
that a stalled transaction holds its address, direction and store payload
until ready. Cover reached a store stalled on a stale-prediction redirect
that later committed. These are safety proofs, not liveness guarantees or
proofs of fetch coherence, I-cache misses, or Sv32.

### Instruction-cache refill and lookup

```sh
bash formal/run.sh icache prove
SOLVER=bitwuzla bash formal/run.sh icache cover
```

`icache` passed unbounded k-induction at the production geometry (128
lines, four words per line). It checks one-cycle hit/miss reporting and
response addresses, aligned refill requests, busy and request acceptance,
refill beat placement, tag/valid installation, and invalidation during an
outstanding refill. One arbitrary row and word are tracked, so the check
applies to every row and lane. The backing bus may stall indefinitely and
supply arbitrary data, but must return exactly four ordered beats for each
accepted request. Covers reach a hit, a stalled address request and a fill
discarded by invalidation. This job checks the cache, not the fetch queue,
D-cache coherence, or when `FENCE.I` signals completion.

```sh
bash formal/run.sh if-cache prove
SOLVER=bitwuzla bash formal/run.sh if-cache cover
```

`if-cache` connects the real four-entry IF queue to the production I-cache
in a bare-address environment. Unbounded k-induction checks the PC stream
from boot through arbitrarily delayed misses, retries, prediction bubbles,
redirects, backpressure from ID, invalidation and temporary halt. Every queued
copy of a symbolic, immutable backing word must match memory. The harness
checks prediction metadata and treats redirects as the resolved target input;
it does not prove EX's branch decision or the SoC's D-cache writeback and
`FENCE.I` handshake. Covers include misses coincident with a prediction or a
redirect, a hit arriving during halt, a backed-up queue, and consumption of
the tracked word.

### Remaining whole-core proof obligations

- Extend the scalar proof to the actual fetch/cache protocol, including
  instruction misses, retries, coherent fetch, FENCE.I and external halt.
- Extend end-to-end retirement checks to M and A. In particular, associate
  deferred divide writes and actual atomic completions with the issuing
  instruction, and check that the upstream contracts of the unit proofs hold.
- Compose the CSR trap/interrupt unit result with precise EX entry, CSR
  instruction legality and return behavior. Prove Sv32 permissions, page walks
  and fence effects against an architectural model.
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
