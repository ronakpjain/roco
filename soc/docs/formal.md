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

The workflow also runs a simulation matrix for `test_core`, `test_soc`,
`test_boot` and `test_dcache`, building the sibling `cc` toolchain from source.
`test_boot` includes parser restart and two-image cache-coherence reload.
Program failures, timeouts and SDRAM model errors fail the test process and
the CI job. Changes to either `soc/` or `cc/` trigger this workflow.

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

## Whole-SoC control safety (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-control prove
```

K-induction passes on `roco_soc` with its default parameters, no internal
cutpoints, an initially asserted reset, and otherwise unconstrained external
inputs and subsequent resets. The assertions cover CPU release after boot,
retirement suppression during halt or core reset, APB setup/access sequencing
and stalled payload stability, UART MMIO FIFO side effects, and syscon exit-code
byte merges, halt and restart ordering. The small induction depth is not an
execution bound. These are selected control invariants, not an architectural
refinement proof of every path through the SoC.

## Whole-SoC FENCE.I ordering (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-fence prove
```

On the actual `roco_soc` at default parameters, with only initial reset
assumed, a retiring FENCE.I must have reached the real fence-completion
signal. Independent history tracks the ordering from the request through
D-cache flush completion, SDRAM controller readiness, and I-cache
invalidation. A pending fence request blocks retirement and both CPU data
lookup and commit. Every D-cache dirty bit is clear when flush completes;
every I-cache line is invalid and no cache hit is delivered after the
invalidation, including while an old refill drains. Checks of the live
pipeline flags connect the instruction encoding to the handshake.

The same sequencer handles UART boot restart. Unbounded assertions check that
the CPU stays in reset and boot writes are blocked during maintenance, dirty
flush completes before the controller drain and I-cache invalidation, and the
D-cache is idle before its metadata reset. Old I-cache refills drain using
the invalidation protocol; their stalled requests are not canceled. Boot
writes after a restart require completed cleaning and invalidation history.
These checks also run in `soc-ram` and `soc-sdram-memory`.

`make test_boot_reload` (also part of `make test_boot`) uploads two different
images at the same address. The first leaves dirty data and restarts without
FENCE.I. The second checks replacement instruction/data visibility and
preservation of a dirty word outside the upload. It reproduced stale first-
image instruction execution before the restart-maintenance fix.

This verifies control and cache metadata, not that the post-fence instruction
bytes equal a preceding CPU store for every legal program. The latter still
requires composing the CPU/D-cache data contract, fabric coherence and
instruction-fetch refinement.

## Whole-SoC SDRAM AXI ingress (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-ram prove
```

The actual `roco_soc` with normal boot and default geometry satisfies the
SDRAM slave's AXI input contract. Only initial reset is assumed. AR/AW
are aligned, 32-bit INCR bursts within the SDRAM window and within one row;
AR, AW and W hold their payloads during stalls. A downstream handshake
scoreboard checks that AW and W use the same master and WLAST agrees with
AWLEN. It also checks that the MMIO master cannot own SDRAM traffic and that
a UART boot restart does not cancel a stalled boot write.

At the CPU boundary, every live memory packet retains the physical word
address and SDRAM/MMIO selection of its EX lookup, including while halt or
AMO preparation suppresses `dmem_valid`. A newer lookup cannot replace the
selection before the older live packet commits. These results discharge the
AXI input assumptions of `sdram-memory` on the real slave wires. They do
not yet discharge the D-cache contract's held address/format and backing
read-data assumptions at its native ports.

## Whole-SoC SDRAM memory coherence (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-sdram-memory prove
```

This runs the SDRAM memory checker on the actual default `roco_soc`, with
normal UART boot, every CPU/cache/page-walk master, and no internal cutpoints.
Only initial reset and an ideal sparse BL2/CL3 memory device at the external
SDRAM data pins are assumed. Subsequent resets and other external inputs are
unconstrained. An arbitrary word tracks accepted AXI writes independently
from the actual WRITE pins and byte masks; AXI reads of that word must return
the resulting value, and B cannot precede completion at the pins.

The standalone `sdram-memory` job and this job share the handshake scoreboard,
pin-cell model and induction assertions. AXI request stability and WLAST,
which are assumptions in the standalone job, become assertions here. The
SoC ingress, cache ownership and refill-beat checks run alongside them.
Independent native-port address counters follow accepted I-cache and D-cache
bursts through routing and AXI response conversion. Every refill of the
tracked word must match memory. Another word updates only from native D-cache
and boot-loader writes, including byte enables, and must equal the AXI copy.
Together these assertions connect native cache/boot traffic to the SDRAM pins;
they do not assume the cache's backing-read data contract internally.
Reset starts a new memory epoch. This proves native memory traffic through
the fabric and SDRAM boundary;
it does not yet prove coherent CPU loads or instruction fetch against CPU
stores, or coherence between dirty cache lines and UART boot writes.

## D-cache caller ownership (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-dcache-client prove
```

On the actual default SoC, k-induction proves that each SDRAM lookup owns a
live MEM packet until its ready-qualified commit, with the original word
address. A new lookup can overlap the older packet only on its commit edge.
The job retains all `soc-ram` assertions. Supporting assertions prove that
held ID/EX memory classes exclude scalar control/system instructions and that
scalar and vector memory classes are mutually exclusive. No internal state
is assumed.

The real cache backing ports are checked through the actual AXI masters,
crossbar, SDRAM adapter and controller. Independent handshake counters prove
four ordered beats per I-cache read and eight per D-cache read, with `LAST`
only on the final beat. D-cache requests are aligned eight-word bursts;
native requests and write payloads remain stable under backpressure. These
checks do not assume anything about SDRAM input data. The `soc-ram` CI gate
also includes this complete assertion set.

The ownership scoreboard starts a new epoch on CPU reset. UART boot restart
immediately resets the CPU, then drains and cleans the D-cache before resetting
its metadata and admitting boot writes, as checked by `soc-fence`. This job
checks ownership and transport; `soc-dcache-memory` below composes the data
contract, flush exclusion and cancellation across restart. Inactive lookup
inputs may change freely; the cache retains the accepted address and format.

## Whole-SoC CPU data-port memory coherence (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-dcache-memory prove
```

On the actual default SoC, the D-cache checker runs together with the real
CPU, AXI fabric, SDRAM controller and sparse pin-level memory device. One
arbitrary physical word has a reference updated only by CPU-port stores and
native boot writes. Ready CPU reads must return that word on both the raw
and formatted forwarding ports. The checker follows both physical cache
copies through hits, byte stores, refills, conflicts and dirty writeback;
flush completion requires the reference to equal backing memory.

The D-cache caller and backing-read constraints are checked as assertions,
with an explicit canceled-lookup state for CPU reset.
Independent cache and fabric scoreboards agree on each beat and address;
the backing shadow is related to the independent pin-level memory copy,
including write halfwords still in flight.
Only initial global reset and the ideal external BL2/CL3 device are assumed.
The elaborated assumption set contains no D-cache, CPU or internal bus
constraints. Other external inputs and subsequent resets are unconstrained.

CPU reset can abandon a lookup while the cache finishes its outstanding
work. The checker retains that lookup until the maintenance reset, prohibits
its commit, and checks normal ownership again when the CPU resumes. Before
a maintenance reset discards metadata, the CPU-port reference must already
equal backing memory. Boot writes are admitted only with invalid cache lines
and update the memory references with their actual byte enables. Global reset
alone begins a fresh memory epoch.

This proves the SDRAM data path from the CPU's physical memory port through
the cache and pins, including boot replacement. It does not compare the
CPU's addresses, store values or instruction results against an ISA model,
prove Sv32 architectural permissions, or prove coherent instruction fetch
after FENCE.I. Those architectural compositions remain open.

## Whole-SoC memory and MMIO integration (bounded)

```sh
SOLVER=bitwuzla bash formal/run.sh soc-mmio-memory bmc-fast
```

This 422-step CI check instantiates the actual `roco_soc`, with no internal bus
cutpoints. A fixed ten-instruction program reads symbolic GPIO buttons through
AXI/APB, stores them to one byte in a symbolically initialized SDRAM word, and
runs FENCE.I. The harness checks the byte merge at the SDRAM pins before the
fence retires and observes an instruction refetch after the fence. A conflicting
load evicts the clean data line; the next load must refill it from SDRAM and
return the merged word. The program writes the buttons to the LEDs and the
merged word to syscon. The checker verifies the retirement sequence, output
values, and that halt takes effect on retirement of the exit store, with a
420-cycle completion deadline to catch deadlocks.

The external model implements BL2/CL3 reads and tracks writes to one word,
including the two DQM lanes on each beat. The check uses boot override, two
lines per cache, a reduced clock parameter to shorten SDRAM startup, and an
idle serial input. This is a bounded integration check of one program, not a
full SDRAM timing model or an unbounded proof of the SoC. It does not cover
arbitrary traffic, UART boot/restart, page-walk contention, or interrupts end
to end.

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

### Whole-core vector memory streams

```sh
SOLVER=bitwuzla bash formal/run.sh core-vector-mem-stream prove
SOLVER=bitwuzla bash formal/run.sh core-vector-mem-stream cover
DEPTH=24 bash formal/run.sh core-vector-mem-stream bmc-fast
```

`core-vector-mem-stream` proves unmasked unit-stride loads and stores mixed
with `vsetivli`, `ADDI`, and `LUI`, with one element width per stream. It uses
bare M-mode, one-cycle fetch, no interrupts, and arbitrary data backpressure.

The checker verifies element addresses from the EX base operand, byte enables,
stall stability, final-element and zero-VL retirement, and misalignment detection
in EX. A reference byte updated from accepted loads checks vector-register state
and store payloads. `vsetivli` checks include VL and the stored GPR result.
Scalar base-operand computation and external memory coherence are out of scope.

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

### Write-back D-cache coherence (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh dcache-memory prove
SOLVER=bitwuzla bash formal/run.sh dcache-memory cover
```

K-induction proves the actual D-cache at the default SoC geometry (128 lines,
eight words per line). For one arbitrary word, a CPU-side shadow updates on
ready-qualified stores and a backing-store shadow updates on accepted write
beats. Assertions track the word across hits, byte stores, both physical data
copies, conflicts, dirty evictions and partial refills. A ready load must
return the architectural word on the raw port and the correctly formatted
value on the forwarding port, including a lookup alongside an older store to
the same word. Dirty writebacks must present the latest value, and flush
completion must leave backing memory coherent. The native memory request and
write channels also hold valid payloads during stalls.

The caller has one lookup outstanding and may issue the next lookup on the
commit edge. Inactive lookup address and format inputs are unconstrained;
the cache retains the accepted fields through hits, stalls and refill
recovery. The caller starts and holds flush only when no demand is pending. The backing port may
stall indefinitely and supplies exactly a line's worth of ordered responses
if it completes a read, with coherent data only at the tracked word. Each
reset starts a fresh memory epoch. Cover mode uses four lines to reach dirty
eviction, changed data surviving flush, and same-cycle store/load forwarding.
This standalone job isolates the cache contract. `soc-dcache-memory`
discharges the connected CPU and backing-port constraints, including boot
replacement; architectural instruction-fetch coherence across FENCE.I still
requires composing both caches with the CPU's instruction model.

### Remaining whole-core proof obligations

- Extend the scalar proof to the actual fetch/cache protocol, including
  instruction misses, retries, coherent fetch, FENCE.I and external halt.
- Extend end-to-end retirement checks to M and A. In particular, associate
  deferred divide writes and actual atomic completions with the issuing
  instruction, and check that the upstream contracts of the unit proofs hold.
- Compose the CSR trap/interrupt unit result with precise EX entry, CSR
  instruction legality and return behavior. Prove Sv32 permissions, page walks
  and fence effects against an architectural model.
- Extend vector verification to arithmetic streams, masking and tails, and
  partial effects and restart across mid-stream traps.

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
burst lengths. It does not prove arbitration fairness.

## AXI4 memory master (unbounded)

```sh
bash formal/run.sh axi-mem-master prove
bash formal/run.sh axi-mem-master cover
```

ABC PDR proves the actual memory master against a public-handshake scoreboard.
The contract checks AR/AW attributes and payload, W data/strobes and `LAST`,
read data and error conversion, and that the client port stays reserved until
B after a write. The source holds the request and each write payload stable
until accepted; AXI stalls and subsequent resets are unconstrained. The job
checks how the master handles the response it sees, not whether the slave
sends a legal number of read beats. Both covers reached: a stalled next
request held behind B, and an error read response.

## AXI4-to-SDRAM adapter (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh sdram-adapter prove
SOLVER=bitwuzla DEPTH=260 bash formal/run.sh sdram-adapter cover
```

K-induction proves the actual adapter against a separate handshake scoreboard.
It checks request direction, word address and burst length, write payload and
strobes, read data and `LAST`, response IDs and status, and that a successful
write waits for controller drain before returning B. A symbolic beat index
checks each entry of the read buffer, including a full 16-word burst arriving
while AXI R is stalled. Unsupported addresses, alignment, sizes and burst
shapes return `SLVERR` without a controller request; even rejected 256-beat
transactions are counted to completion. All four read/write covers reached,
including both maximum-length rejected transaction cases.

The environment holds AXI request channels stable during backpressure, uses
`WLAST` consistent with AWLEN, and sends controller read beats only after an
accepted read, at most as many as requested. There is no progress assumption:
AXI and controller stalls may be indefinite, and reset may recur. This does not
prove that the actual SoC endpoints satisfy all of the assumptions.

## SDRAM controller pins (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh sdram-pins prove
SOLVER=bitwuzla bash formal/run.sh sdram-pins cover
```

K-induction checks the actual controller at its default parameters, starting
in reset, with arbitrary subsequent resets, request and write stalls, and
arbitrary SDRAM input data. An independent pin monitor checks row ownership,
closed rows on refresh, BL2/CL3 mode setup, successive burst columns, the two
write halfwords and DQM masks, and sampling and assembly of both read
halfwords with `RLAST` on the final word. A new command cannot be accepted
while a previous burst is still issuing reads or driving its write data.
The caller must not submit a burst crossing a 256-word row; the adapter
contract checks that condition on requests it forwards. Cover mode alone
shortens the power-up and refresh intervals to reach maximum-length reads,
writes and operational refresh quickly.

This is not an SDRAM device model. It does not establish all JEDEC timing
constraints, a refresh deadline during arbitrary write stalls, pin-to-cell
coherence, or unbounded end-to-end memory correctness through the caches.

## AXI-to-SDRAM pin composition (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh sdram-link prove
```

This connects the actual AXI adapter to the actual SDRAM controller at default
parameters. Both blocks' assertions run together. The controller contract's
row-boundary assumption and the adapter contract's incoming-read-beat
assumption become assertions on the connected wires. The proof checks that
controller responses belong to the currently issued AXI burst and match its
address and beat count, and that a successful B reply cannot precede the final
write at the pins. AXI masters must still hold payloads stable while stalled
and use `WLAST` consistent with AWLEN; reset and pin input data remain arbitrary.
This proves preservation and ordering up to the pins, not a coherent SDRAM
cell model or an end-to-end proof through the rest of the SoC.

## AXI-to-SDRAM memory coherence (unbounded)

```sh
SOLVER=bitwuzla bash formal/run.sh sdram-memory prove
SOLVER=bitwuzla bash formal/run.sh sdram-memory cover
```

The connected adapter and controller now drive a sparse BL2/CL3 memory model.
The proof checks an arbitrary word in the entire SDRAM window: one copy
updates from actual WRITE pins and DQM, and the other updates independently
from accepted AXI W beats and strobes. Inductive assertions allow the two
copies to differ only for the halfwords still in flight, and check that they
agree at B. READ commands snapshot the pin copy and return the two halfwords
through the CAS-latency pipeline. The corresponding AXI R beat must report
the architectural copy, including when the adapter buffers it under stalls.
Checking an arbitrary word and an arbitrary buffer index covers every
address and beat. All other word data may vary without restriction.

The proof retains the link contract's AXI assumptions and uses default
controller timing. The checker models reset as starting a new memory epoch
with the same arbitrary word; it does not prove contents across reset. Cover
mode alone shortens power-up and reaches a write that changes the word followed
by an AXI read of it. This still assumes an ideal memory device, not physical
SDRAM timing or retention, and does not include the crossbar or caches.
