# FPGA timing and validation

The board clock remains 48 MHz, generated from the 24 MHz input. Routing
uses the LFE5U-45F, CABGA381 package, speed grade 6, and the pin and clock
constraints in `constraints/roco.lpf`.

## Reproduce

Run `make bitstream` for a timing-enforced build. It produces
`build/roco.bit`, `build/roco_timing.json`, and `build/roco_route.log`.
A timing failure stops the build before the configuration is packaged.
`make timing` is diagnostic: it permits timing failures and writes
`build/timing-seed4.json` by default. A successful diagnostic command does
not establish timing closure. Both targets share `PNR_SEED` and `PNR_FLAGS`.
Defaults are seed 4 and `--placer-heap-timingweight 30`.
To reproduce explicitly, use
`make bitstream PNR_SEED=4 PNR_FLAGS="--placer-heap-timingweight 30"`.

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

`make test-cpi` exercises warmed core and cached-SoC dependency loops.
`make test-vector-reduce` compares 3,000 randomized reductions with a
sequential arithmetic reference, including zero length, partial VL, full
VL and overflow.

Vector memory retires exactly once on its final element; VL zero retires
one no-op without accessing memory. `make test-vector-retire` checks both
cases through minstret on the core and SoC. Counter reads include the older
instruction committing in MEM, keeping the observed count independent of
fetch/cache stalls. `make test-trap-pipeline` checks trap PC/cause/value,
reservation clearing and cancellation of younger stores, scalar, CSR and
vector writes. The cache unit test compares the forwarding mirror against
committed data across refills, byte writes, forwarding and eviction.
