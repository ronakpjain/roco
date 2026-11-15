# FPGA timing and validation

The board clock remains 48 MHz, generated from the 24 MHz input. Routing
uses the LFE5U-45F, CABGA381 package, speed grade 6, and the pin and clock
constraints in `constraints/roco.lpf`.

## Reproduce

Run `make bitstream` for a timing-enforced build. It produces
`build/roco.bit`, `build/roco_timing.json`, and `build/roco_route.log`.
A timing failure stops the build before the configuration is packaged.
`make timing` is diagnostic: it permits timing failures and writes
`build/timing_seed4.json` by default. A successful diagnostic command does
not establish timing closure. Both targets share `PNR_SEED` and `PNR_FLAGS`.
Defaults are seed 4 and `--placer-heap-timingweight 30`.
To reproduce explicitly, use
`make bitstream PNR_SEED=4 PNR_FLAGS="--placer-heap-timingweight 30"`.

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
