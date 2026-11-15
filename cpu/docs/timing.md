# FPGA timing and validation

The board clock remains 48 MHz, generated from the 24 MHz input. Routing
uses the LFE5U-45F, CABGA381 package, speed grade 6, and the pin and clock
constraints in `constraints/roco.lpf`.

## Reproduce

Run `make bitstream` for a timing-enforced build. It produces
`build/roco.bit`, `build/roco-timing.json`, and `build/roco-route.log`.
A timing failure stops the build before the configuration is packaged.
`make timing` is diagnostic: it permits timing failures and writes
`build/timing-seed4.json` by default. A successful diagnostic command does
not establish timing closure. Both targets share `PNR_SEED` and `PNR_FLAGS`.
Defaults are seed 4 and `--placer-heap-timingweight 30`.
To reproduce explicitly, use
`make bitstream PNR_SEED=4 PNR_FLAGS="--placer-heap-timingweight 30"`.

The reference design at commit `280c935` achieved 48.809 MHz against nextpnr's
48.00077 MHz PLL constraint (20.488 ns critical path versus 20.833 ns
required), measured on 2026-11-14 with the defaults above. Tool versions
used for this work were Yosys 0.71+post
(`5628c13240f670b97aaaca3d47940c4afb8ff572`) and nextpnr
`0.11.1-89-g445e2a65` from OSS CAD Suite 20261110.

## Implementation tradeoffs

- Scalar and vector register data use distributed RAM with reset validity
  bits. Reads of unwritten registers remain zero; the first partial vector
  load initializes the untouched bytes. Vector arithmetic now commits full
  results in MEM, with forwarding to all three EX operand reads. Divider
  completion waits when normal writeback owns the scalar register port.
- Vector reduction uses separate 8-, 16- and 32-bit carry-save trees and
  completes in one EX cycle. Arithmetic wraps at SEW. Vector memory still
  issues one element per cycle and holds its current address across misses.
- Cached loads, LR/SC and AMO old values forward from MEM to EX. Multiply
  uses four signed DSP partial products and a carry-save sum in EX, so MEM
  forwards its registered product. These fixed dependency bubbles are removed.
  Uncached load/LR/AMO dependencies retain one bubble and forward from WB.
  An unfinished memory operation holds both stages. Held operations preserve older WB data for forwarding.
- AMOs compute their RMW value from the EX lookup and commit one write in
  MEM, without a fixed extra cycle. Misses delay both the write and retirement.
- The data cache reads tags and data synchronously in EX and compares tags
  in MEM. A separate lookup tag copy has registered LUT-RAM reads while
  eviction/flush retains its own tag port. A byte-identical LUT-RAM data
  mirror aligns load values before its read register and supplies early
  forwarding; block RAM supplies committed data and
  writeback. Every store/refill updates both copies. Hit latency is unchanged. Misses hold MEM
  until refill recovery has read the requested word; responses persist until
  commit. Store-to-load forwarding merges the preceding committed bytes.
- The data MMU compares each TLB entry and its permissions in parallel,
  then selects the physical page with a one-hot merge. Warm translated
  accesses can alternate pages and load/store permission contexts without
  adding an EX cycle. SFENCE and SATP writes invalidate the TLB.
- Branch target prediction is checked in ID; branches still resolve in EX.
  Redirects reach fetch one cycle after EX resolution, adding one recovery
  cycle. Traps capture their PC/cause/value before applying entry and
  selecting their vector the following cycle. Pending traps and redirects
  cancel younger EX side effects, including CSR/vector writes and divider
  starts. Deferred interrupt entry uses the captured cause for delegation.
  Predictor training is registered one cycle after resolution. Fetch flushes
  invalidate queue pointers independently of speculative payload writes.

## Regression coverage

`make all` checks formatting, syntax, and structural lint. Unit tests cover
scalar/vector register reset and write collisions, randomized register
updates, cache refill/eviction/forwarding, MMU permissions and canceled
walks, and multiply/divide arithmetic. Directed core and cached-SoC programs
cover vector memory/reduction, interrupts, FENCE redirects, canceled
younger redirect side effects, atomics including
MMIO, and CSR write intent. The official ISA suites run 41 RV32UI, 8 RV32UM,
and 10 RV32UA tests on each of the core and SoC testbenches (118 total).
The SDRAM and UART boot paths have separate simulations.

CSRRS/CSRRC write intent follows the encoded source register, including a
nonzero register containing zero, as specified by
[Zicsr](https://docs.riscv.org/reference/isa/unpriv/zicsr.html).
These checks are simulation and FPGA routing validation; they do not
constitute a board test.

## CPI checks

`make test-cpi` asserts one architectural retirement every cycle in 12
warmed windows on each of the standalone core and cached SoC, for 128
consecutive instructions per window. They cover stable JALR targets,
load-to-ALU/store/load/branch/JALR/CSR dependencies, subword alignment,
dependent multiplies, LR/SC, all AMO arithmetic classes, alternating warm
translated pages and load/store contexts, vector arithmetic,
and dependent reductions at all three supported element widths. Each
program also checks architectural results and wrong-path side effects.

JALR uses its most recently resolved BTB target. ID precomputes the two
source operands that produce that target after JALR clears bit zero; EX
compares the forwarded source against those candidates. The resolved
redirect target reuses scalar memory address sums.

The monitor fails on any retirement gap and on a missing or incomplete
measurement window. `make test-vector-reduce` compares
3,000 randomized reductions with a sequential arithmetic reference,
including zero length, partial VL, full VL and overflow.

The windows exclude startup and predictor training. They do not establish
CPI=1 for vector memory, uncached dependencies, fences, cache/TLB misses or branch mispredictions.
Division is multi-cycle. The FPGA clock target remains 48 MHz; the current
CPI optimizations do not yet meet that target. `make bitstream` rejects a
route that misses timing. The reference result above is not timing
qualification for the current RTL.

Vector memory retires exactly once on its final element; VL zero retires
one no-op without accessing memory. `make test-vector-retire` checks both
cases through minstret on the core and SoC. Counter reads include the older
instruction committing in MEM, keeping the observed count independent of
fetch/cache stalls. `make test-trap-pipeline` checks trap PC/cause/value,
reservation clearing and cancellation of younger stores, scalar, CSR and
vector writes. The cache unit test compares the forwarding mirror against
committed data across refills, byte writes, forwarding and eviction.
