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
`make bitstream`). It creates two rectangular regions on the 85F grid
(X 0..126, Y 0..95) and constrains packed macros by hierarchical prefix:

- `hart0` (X 0..66, Y 12..93): the `DP16KD`/`MULT18X18D`/`TRELLIS_RAMW`
  cells of `u_soc.u_cpu0` + `u_icache0` + `u_dcache0` and their private AXI
  masters.
- `hart1` (X 60..126, Y 12..93): the same macro types for the hart1
  counterparts. The 7-column overlap gives shared headroom without letting
  the macros intermix.

Only macros are constrained; all LUT/FF logic stays free and the
timing-driven placer pulls each hart's logic toward its own
caches/DSPs/registers instead of intermixing the harts. The crossbar, CDC
bridge, SDRAM adapter/controller, bootloader, UART, APB peripherals, and
Yosys-merged TOP glue (`user_led_*`, `sdram_*`, ...) stay unconstrained, as
do LPF-fixed cells (`TRELLIS_IO`, PLL, globals, `*$tr_io`). Each hart
region spans Y 12..93 so it keeps all four block-RAM rows
(Y 22/46/70/82) and the 34/58 DSP rows.

Fencing all LUT/FF logic (v1 with an extra bottom `mem` strip, v2 with two
full hart fences) was tried first and reverted: the heap placer could not
find a legal placement (`ERROR: Unable to find legal placement ...
TRELLIS_COMB`) despite generous capacity, so v3 anchors only the ~1k macro
cells instead of ~52k logic cells.

To try a different floorplan without losing the shared routing flags,
override the file rather than the flags, e.g.
`make timing PNR_FLOORPLAN="--pre-place constraints/my_floorplan.py"`.

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
