# Execution-time characterization

Compare identical program images and testbenches. `cycles / Fmax_MHz` gives
estimated microseconds; this is not a board measurement. Timing uses seed 96,
speed grade 6, and `--placer-heap-timingweight 30`. Baseline RTL is `cc6bcc7`
(before vector-address preparation); candidate adds vector-address preparation
and a one-cycle load-use interlock, removing cache-to-EX forwarding.

Baseline Fmax: 37.4266 MHz; candidate: 41.7938 MHz. Worst-path routing:
20.913 ns -> 18.369 ns. Neither meets the 96 MHz objective.

The simulations use 48 MHz SDRAM timing. Reset-to-halt includes initialization,
cache misses and refresh. Active time runs from first retirement to halt and
excludes initial fetch/startup; it still includes subsequent misses and refresh.
At another clock the SDRAM cycle counts must be re-simulated, so Fmax-scaled
times are comparative estimates for this fixed latency model.

## Results

### core

| Program | Total cycles baseline / candidate | Total µs baseline / candidate | Active µs baseline / candidate | Active speedup |
|---|---:|---:|---:|---:|
| basic | 256 / 262 | 6.84 / 6.27 | 6.71 / 6.15 | 1.091× |
| muldiv | 264 / 264 | 7.05 / 6.32 | 6.92 / 6.20 | 1.117× |
| vector | 739 / 808 | 19.75 / 19.33 | 19.61 / 19.21 | 1.021× |
| vector_start | 1620 / 1667 | 43.28 / 39.89 | 43.15 / 39.77 | 1.085× |
| vector_retire | 42 / 44 | 1.12 / 1.05 | 0.99 / 0.93 | 1.059× |
| vm | 441 / 443 | 11.78 / 10.60 | 11.65 / 10.48 | 1.112× |
| atomic | 131 / 132 | 3.50 / 3.16 | 3.37 / 3.04 | 1.108× |
| cpi_forward | 6095 / 7183 | 162.85 / 171.87 | 162.72 / 171.75 | 0.947× |
| cpi_vector | 1484 / 1484 | 39.65 / 35.51 | 39.52 / 35.39 | 1.117× |
| cpi_vm | 605 / 733 | 16.16 / 17.54 | 16.03 / 17.42 | 0.920× |
| cpi_jalr | 692 / 692 | 18.49 / 16.56 | 18.36 / 16.44 | 1.117× |

### soc

| Program | Total cycles baseline / candidate | Total µs baseline / candidate | Active µs baseline / candidate | Active speedup |
|---|---:|---:|---:|---:|
| basic | 10505 / 10506 | 280.68 / 251.38 | 22.98 / 20.60 | 1.115× |
| muldiv | 9963 / 9963 | 266.20 / 238.38 | 8.50 / 7.61 | 1.117× |
| vector | 11443 / 11496 | 305.75 / 275.06 | 48.04 / 44.29 | 1.085× |
| vector_start | 13933 / 13947 | 372.28 / 333.71 | 114.57 / 102.93 | 1.113× |
| vector_retire | 9835 / 9836 | 262.78 / 235.35 | 5.08 / 4.57 | 1.111× |
| vm | 12238 / 12238 | 326.99 / 292.82 | 69.28 / 62.04 | 1.117× |
| atomic | 10248 / 10248 | 273.82 / 245.20 | 16.11 / 14.43 | 1.117× |
| cpi_forward | 16394 / 17457 | 438.03 / 417.69 | 180.33 / 186.92 | 0.965× |
| cpi_vector | 11350 / 11350 | 303.26 / 271.57 | 45.56 / 40.80 | 1.117× |
| cpi_vm | 10972 / 11100 | 293.16 / 265.59 | 35.46 / 34.81 | 1.018× |
| cpi_jalr | 10411 / 10411 | 278.17 / 249.10 | 20.47 / 18.33 | 1.117× |

The core forwarding and VM loops regress despite the higher Fmax. The
load-use change therefore remains a timing step with workload-dependent
performance, not a demonstrated overall performance win. These short directed
programs are not an application benchmark suite; no workload-weighted aggregate
is claimed.

## Reproduce

Build each RTL variant with the same current `sim/tb_core.sv`, `sim/tb_soc.sv`
and program images. Use `+measure_execution` to report reset-to-halt cycles and
first-retirement-to-halt cycles. For example:

```sh
python3 scripts/measure_execution.py \
  --variant 'baseline=vvp build/perf-baseline/tb_soc.vvp' \
  --variant 'loadbubble=vvp build/tb_soc.vvp' \
  --timing baseline=build/timing_seed96.json \
  --timing loadbubble=build/loadbubble/timing_seed96.json \
  --output build/execution-soc.json
```

Use `--images` to select additional finite programs and `--build-dir` for their
hex images. The JSON records total and active estimated times, speedups, cycle
ratios and break-even frequency. A simulation failure or missing measurement
stops the command. Simulator host wall time is not CPU execution time.
