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

The measured post-vector baseline at commit `3f1ddc9` was 11.667 MHz with
seed 4. The final routed design reaches 48.809 MHz against nextpnr's
48.00077 MHz PLL constraint (20.488 ns critical path versus 20.833 ns
required), measured on 2026-11-14 with the defaults above. Tool versions
used for this work were Yosys 0.71+post
(`5628c13240f670b97aaaca3d47940c4afb8ff572`) and nextpnr
`0.11.1-89-g445e2a65` from OSS CAD Suite 20261110.

## Implementation tradeoffs

- Scalar and vector register data use distributed RAM with reset validity
  bits. Reads of unwritten registers remain zero; the first partial vector
  load initializes the untouched bytes. Divider completion waits when
  normal writeback owns the scalar register port.
- Vector reductions use separate carry-save trees for each supported
  element width and complete in one EX cycle. Arithmetic wraps at SEW.
  Vector memory retains its current element address across a miss and stops
  issuing lookups at VL, including VL zero.
- AMOs compute the RMW value from the EX lookup and commit one write in
  MEM. A miss delays both the write and retirement until data is available.
  LR/SC retain their existing path. Held MEM operations preserve older
  writeback data needed by forwarding.
- Data-cache bank comparisons are registered alongside the EX lookup data,
  preserving EX-to-MEM hit latency. Combining the registered bank results
  adds one cycle to miss detection. Misses hold MEM until refill recovery
  has read the requested word. A pending response persists until commit.
  Lookup tag read ports are preserved independently of eviction/flush,
  preventing synthesis from putting lookup controls ahead of SDRAM
  request addresses through resource sharing.
- The data MMU retains the most recent translation and permission context.
  A new translated page or context adds one EX cycle; repeated accesses in
  that context avoid the TLB-to-cache combinational path. Bare accesses do
  not incur this translation cycle. SFENCE and SATP writes invalidate it.
- Branch target prediction is checked in ID; branches still resolve in EX.
  Redirects reach fetch one cycle after EX resolution, adding one recovery
  cycle. The pending redirect cancels younger EX side effects, including
  CSR/vector writes and divider starts. Predictor training is registered
  one cycle after resolution. Trap-vector candidates compute before interrupt arbitration. Fetch flushes invalidate
  queue pointers independently of speculative payload writes.

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

## Retirement counters

Vector loads and stores increment `minstret` once, when their final element
commits. VL-zero memory instructions retire once without issuing a request.
Counter reads include the older instruction committing in MEM on that edge.
Run `make test-vector-retire` to check counts on the core and cached SoC.

Trap entry records PC, cause and trap value before updating the CSR state
and selecting the handler vector. Pending traps cancel younger EX side
effects. `make test-trap-pipeline` checks trap payloads, reservation clearing
and cancellation of younger stores, scalar, CSR and vector writes.
