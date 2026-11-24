# FPGA timing and validation

The board runs the SDRAM at 96 MHz and the dual-core SoC fabric at
48 MHz, both generated from the 24 MHz input. Routing targets the
LFE5U-85F, CABGA381 package, speed grade 6, and the pin and clock
constraints in `constraints/roco.lpf`, whose balls follow
`../pcb/docs/pin_plan.csv`.

## Reproduce

Run `make bitstream` for a timing-enforced build. It produces
`build/roco.bit`, `build/roco_timing.json`, and `build/roco_route.log`.
A timing failure stops the build before the configuration is packaged.
`make timing` is diagnostic: it permits timing failures and writes
`build/timing_seed96.json` by default. A successful diagnostic command does
not establish timing closure. Both targets share `PNR_SEED` and `PNR_FLAGS`.
Defaults are seed 96 and `--placer-heap-timingweight 30`.
To reproduce explicitly, use
`make bitstream PNR_SEED=96 PNR_FLAGS="--placer-heap-timingweight 30"`.

## Floorplan

`constraints/floorplan.py` runs as a nextpnr `--pre-place` hook (see
`PNR_FLOORPLAN` in the Makefile, shared by `make timing` and
`make bitstream`). It creates three overlapping rectangular regions on the
85F grid (X 0..126, Y 0..95; logic lives on Y 2..93) and constrains every
non-IO cell by hierarchical prefix:

- `hart0` (X 0..85, Y 2..93): `u_soc.u_cpu0` + `u_icache0` + `u_dcache0`
  and their private AXI masters (~44% of cells).
- `center` (X 25..102, Y 2..93): crossbar, CDC bridge, SDRAM
  adapter/controller, bootloader, UART, APB peripherals and Yosys-merged
  TOP glue (~14%).
- `hart1` (X 42..126, Y 2..93): the hart1 counterparts (~42%).

Overlap is deliberate: tight partitioned fences deadlock heap
legalization (`ERROR: Unable to find legal placement`) at 56% COMB
utilization, while the shared headroom here places first try and still
keeps the hart extremes apart (hart0 out of the far right, hart1 out of
the far left). LPF-fixed cells (`TRELLIS_IO`, PLL, globals, `*$tr_io`)
are never re-constrained.

## Registered AXI fabric

`rtl/bus/axi4_register_slice.sv` is a 2-deep skid buffer (VALID/READY
both flopped, one beat per cycle, +1 cycle of forward latency). The
`axi4_xbar` instantiates 24 of them: AR/AW/W slice at each of the two
slave ports (cutting the 9:1 owner muxes), R/B sliced per master
(keeping beat->owner pairing when the owner changes with beats still
in flight). Cost is ~2 core cycles per cache-line miss; MMIO/PTW
transactions are unaffected in practice. `make test_bus` covers
decode/bursts/stalls/concurrency/ownership/round-robin through the
sliced fabric, and `sim/tb_soc.sv` tolerates the extra retire bubbles.

## Status and next steps

nextpnr closes neither with seeds nor fences: every critical path is a
long, routing-dominated broadcast through the D$/I$ tag compares,
snoop/store-compare, branch predictor, PTW and regfile of both harts.
The AXI fabric itself is off the critical path after slicing.

Hub pipelining round 1 is done: the dcache commit hit no longer re-reads
the tag RAM (`rtl/mem/dcache.sv` snapshots the committing op's own lookup
hit plus full address at first presentation, shadowed by a sticky
per-index snoop-kill cleared on fill), and the BTB update dropped its
trap/fence/halt/cancel gating (`rtl/core/roco_cpu_ex_stage.sv`; the
predictor is advisory-only, so this only pollutes table entries). Both
are fully re-verified (`test_dcache`, `test_soc`, `test_smp`, `test_vm`,
`test_boot`, full `test_isa_soc`, `make lint`, re-synth; the
`dcache-memory` BMC failure at `dcache_memory_checks.svh:211` reproduces
identically on the unmodified cache and is a pre-existing model gap,
not a regression). The commit arc is gone, but the chain re-formed through
the lookup and snoop-hit arcs, which still combinationally read the tag
arrays — further rounds would need those arcs registered too, at a cache
latency cost.

The 48 MHz vehicle is Lattice Diamond, not further nextpnr tuning:
Diamond's Synplify mapping plus PAR closes the target, while nextpnr
does not — a synthesis+mapping+placement gap, not a design error.

Diamond runs headless in a container on a separate x86 host (see
`soc/diamond/README.md`); `make diamond-bitstream` syncs the sources,
runs `synthesis -> Map -> PAR -> Export(Bitgen)` and fetches the
bitstream back. Two flow rules matter:

- Timing is reported and gated against the **LPF-derived** preference
  file (`constraints/roco.lpf`), never PAR's internal `.pt`. The `.pt`
  is not delivered with the build and its derived clock relations
  disagree with the LPF on the same NCD, so it is kept only as
  `roco_diamond_par.twr` for comparison. `roco_diamond.twr` is
  reproduced exactly by re-running TRACE on the delivered
  `.ncd`/`.prf`, and a failing preference fails the build.
- Both `clk_core` (48 MHz) and `clk_mem` (96 MHz) are constrained as
  nets, and the PLL input net (`clk_24_c`, the post-buffer name Diamond
  uses — a `FREQUENCY PORT` scores zero items) is constrained too, so
  the PLL's derived output periods are correct instead of defaulting.

Cross-domain transfers between `clk_core` and `clk_mem` are timed, not
blocked: the two clocks are related outputs of one PLL, and Lattice's
own constraint reference warns that blanket `BLOCK INTERCLOCKDOMAIN
PATHS` is unsafe. Every such crossing in this SoC is a two-flop
synchronizer or toggle-handshake payload (`axi_cdc_bridge`, plus the
`c_ready`/`init_done` synchronizers in `roco_soc`), so the design is
correct under either clock relationship rather than relying on
single-cycle closure across the boundary.

The cache pipelining above still helps Diamond (same cones, more
margin) and stays regardless.

## CI

The `FPGA timing` GitHub Actions workflow runs this diagnostic route for
changes under `soc/`. It writes the per-clock achieved and constraint
frequencies to the job summary and attaches the complete `soc/build`
directory as a `fpga-build.tar.gz` archive in the `fpga-build-<run-id>`
artifact. A manually dispatched run can override the nextpnr seed.

## Reset

Every clocked process uses an active-high asynchronous reset,
`always_ff @(posedge clk or posedge rst)` with `if (rst)` as the first
branch. Yosys maps that to the flip-flop's dedicated LSR pin, so reset costs
no look-up table and the reset net is excluded from the routed timing report
by `BLOCK ASYNCPATHS` in `constraints/roco.lpf`. A synchronous reset instead
has to meet setup at every flip-flop through general routing, which made the
reset distribution net the longest path in the design.

Two rules keep that mapping intact:

- The asynchronous branch must be guarded by the reset signal alone. A
  combined test such as `if (rst || flush)` is rejected by Yosys, so the
  clear is repeated in a separate `else if` branch.
- Only constant values may be loaded by the asynchronous branch. State that
  must take a non-constant value after reset is loaded on the first cycle
  instead; `roco_cpu_if_stage` does this for the boot address. Memory arrays
  with no reset value must be written from a separate process that does not
  mention `rst`, otherwise Yosys cannot map them to block or distributed RAM
  and expands them into flip-flops.

Reset is asserted asynchronously and released synchronously by the
`rst_sync` shift register in `roco_top`.

## Multiply pipeline

Multiplication is split across EX and MEM. `roco_cpu_mul_prod` forms four
signed DSP products in EX and `roco_cpu_mul_term` compresses them to two
carry-save terms; those two 64-bit terms are registered at EX/MEM. The final
carry-propagating sum and the low/high word selection then run in MEM through
`roco_cpu_mul_sum`.

Splitting here rather than after the DSPs is deliberate: an ECP5 carry chain
cannot cross a PFU column, so the 64-bit carry-propagate sum is the expensive
part of the operation, not the compression. A dependent instruction costs one
bubble (`mul_conflict`) and then reads the result from the MEM-stage forwarding
path. `make test_cpi` reports the resulting cycles per instruction as
information only.

## Regression coverage

`make all` checks formatting, syntax, and structural lint. Unit tests cover
scalar/vector register reset and write collisions, randomized register
updates, cache refill/eviction/forwarding, MMU permissions and canceled
walks, and multiply/divide arithmetic. Directed core and cached-SoC programs
cover vector memory/reduction, interrupts, FENCE redirects, canceled
younger redirect side effects, atomics including MMIO and acquire/release
ordering under cache conflicts, and CSR write intent. The official ISA
suites run 41 RV32UI, 8 RV32UM, and 10 RV32UA tests on each of the core
and SoC testbenches (118 total).
The SDRAM and UART boot paths have separate simulations.

Every gated formal job also runs `cover` mode, so a witness state that becomes
unreachable fails CI rather than leaving a proof that passes vacuously; see
[formal verification](formal.md).

CSRRS/CSRRC write intent follows the encoded source register, including a
nonzero register containing zero, as specified by
[Zicsr](https://docs.riscv.org/reference/isa/unpriv/zicsr.html).
These checks are simulation and FPGA routing validation; they do not
constitute a board test.

`make test_cpi` exercises warmed core and cached-SoC dependency loops.
`make test_vector_reduce` compares 3,000 randomized reductions with a
sequential arithmetic reference, including zero length, partial VL, full
VL and overflow.

Vector memory retires exactly once on its final element; VL zero retires
one no-op without accessing memory. `make test_vector_retire` checks both
cases through minstret on the core and SoC. Counter reads include the older
instruction committing in MEM, keeping the observed count independent of
fetch/cache stalls. `make test_trap_pipeline` checks trap PC/cause/value,
reservation clearing and cancellation of younger stores, scalar, CSR and
vector writes. The cache unit test compares the forwarding mirror against
committed data across refills, byte writes, forwarding and eviction.
