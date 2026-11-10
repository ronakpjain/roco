# roco CPU

A five-stage pipelined RV32I processor with instruction and data caches,
an SDRAM controller, a UART bootloader and a small memory-mapped
peripheral set, targeting the roco Rev A board (Lattice LFE5U-45F-6BG381C,
16-bit SDR SDRAM, FT2232H UART).

The design is plain SystemVerilog with no vendor primitives below the
board top level, so it can be simulated with Icarus/Verilator and
synthesized with Yosys. `rtl/roco_top.sv` is the only file that
instantiates the ECP5 PLL.

## Block diagram

`roco_top` contains the 24 MHz to 48 MHz PLL and reset synchronizer, and
instantiates `roco_soc`. Inside the SoC:

- `rv32_core` is the five-stage pipeline (IF, ID, EX, MEM, WB), built
  from the stage modules listed below.
- `icache` and `dcache` connect to `mem_arbiter`, which shares
  `sdram_ctrl` with the UART image loader.
- The uncached path decodes the UART, timer, LED, button, cache-counter,
  boot-status and `tohost` registers.

Pipeline: IF, ID, EX, MEM, WB. Branches, jumps, traps and MRET resolve in
EX; a taken control transfer costs two flushed slots. Full EX/MEM and
MEM/WB forwarding; a load-use dependency inserts one bubble. Each stage
lives in its own module and owns its pipeline register:

| Module | Responsibility |
|---|---|
| `rv32_if_stage.sv` | Program counter, fetch handshake, IF/ID register |
| `rv32_decoder.sv` | Combinational instruction decode |
| `rv32_id_stage.sv` | Register file, ID/EX register |
| `rv32_ex_stage.sv` | Forwarding, ALU, branches, traps, CSR file, EX/MEM |
| `rv32_mem_stage.sv` | Data memory request, load alignment, MEM/WB |
| `rv32_wb_stage.sv` | Writeback select |
| `rv32_hazard_unit.sv` | Load-use and memory-wait stalls |

## Implemented ISA

- RV32I base integer instructions.
- Zicsr: `CSRRW/CSRRS/CSRRC` and immediate forms.
- Machine-mode traps: illegal instruction, `ECALL`, `EBREAK`, misaligned
  load/store, misaligned instruction address; `MRET`.
- `FENCE` is a NOP; `FENCE.I` writes back the D-cache, invalidates the
  I-cache and flushes younger instructions.
- CSRs: `mstatus`, `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch`,
  `mie`/`mip` (stored, no sources), `misa`, `mhartid`, `mcycle[h]`,
  `minstret[h]`.

Not implemented: M/A/F/D/C extensions, interrupts, user/supervisor mode,
PMP, MMU, debug module. Misaligned loads and stores trap precisely; the
official `rv32ui/ma_data` test (which requires hardware misaligned
access) is therefore excluded, and the directed test checks the trap
path instead.

## Caches and memory

| Cache | Size | Organisation | Policy |
|---|---|---|---|
| I-cache | 2 KiB | 128 lines x 16 B, direct mapped | read-only, whole-line fill |
| D-cache | 4 KiB | 256 lines x 16 B, direct mapped | write-back, write-allocate, byte enables |

Both caches are blocking: one memory transaction is outstanding per
cache. The D-cache data array is split into four byte-lane memories so
ECP5 block RAMs implement byte enables. A dirty victim is written back
before the new line is fetched; a store miss fetches the line and then
merges the store bytes so partial writes never fabricate data. A single
word request from the bootloader shares the SDRAM controller through
`mem_arbiter.sv` with round-robin priority.

`sdram_ctrl.sv` drives the IS42S16160J at 48 MHz with BL=2 and CL=3.
Transactions move 32-bit words (two halfword beats), reads are pipelined
one word per two cycles, and the controller keeps a row open until a
different row or a refresh is needed. Power-up wait, precharge, two
auto-refreshes, mode register, tRCD/tRP/tRFC/tMRD/tWR waits and periodic
auto-refresh are implemented. A timing-checking behavioural model
(`sim/sdram_model.sv`) flags protocol violations in simulation.

## Memory map

| Address | Access | Function |
|---|---|---|
| `0x1000_0000` - `0x11FF_FFFF` | R/W, cached | 32 MiB SDRAM |
| `0x8000_0000` | R/W | UART data (read pops RX, write pushes TX) |
| `0x8000_0004` | R | UART status: bit0 TX ready, bit1 RX valid, bit3 RX overflow (read clears) |
| `0x8000_0010` | R/W | User LEDs |
| `0x8000_0014` | R | User buttons |
| `0x8000_0018/1c` | R | `mtime` low/high |
| `0x8000_0020/24` | R/W | `mtimecmp` low/high |
| `0x8000_0028` | R | Timer pending (`mtime >= mtimecmp`) |
| `0x8000_0030/34/38/3c` | R/W | I-cache hits/misses, D-cache hits/misses (write clears) |
| `0x8000_0100` | R | Boot status: bit0 done, bit1 busy, bit2 error, bit3 SDRAM ready |
| `0x8000_0104` | R | Loaded image base |
| `0x8000_0108` | W | Restart the bootloader |
| `0x8000_1000` | R/W | `tohost`: write halts the core, value is the exit code |

Instruction fetch outside SDRAM returns instruction 0 (illegal), which
traps through `mtvec`. Programs must be linked at `0x1000_0000`.

## Boot protocol

After reset the CPU is held in reset and the loader waits for:

```text
"ROCO" | base (LE32) | length (LE32) | crc32(payload) (LE32) | payload
```

Payload bytes are packed into 32-bit words and written to SDRAM at
`base`, which must be word aligned and inside `0x1000_0000` -
`0x11FF_FFFF`. On success the loader sends `K`, records `base` as the
CPU reset vector and releases the core. A framing, range or CRC error
sends `E` and returns to the magic search; the CPU stays in reset.

`scripts/boot.py` builds the packet from an ELF or flat binary, can emit
a byte-per-line hex file for simulation, and sends it over a serial
port:

```sh
python3 scripts/boot.py --elf build/hello.elf --port /dev/tty.usbserial-XXXX
```

The SDRAM controller needs about 200 us after reset; the script waits
350 ms before sending so the loader is ready.

## Building and testing

Requirements: Icarus Verilog, Verilator, Yosys, Verible, Python 3 and a
RISC-V ELF toolchain (`riscv64-elf-gcc` on `PATH`, or pass
`RISCV=/path/to/prefix`). `nextpnr-ecp5` and `ecppack` are only needed
for a bitstream.

```sh
make lint        # Verilator lint of the core and SDRAM controller
make test-core   # directed pipeline smoke test
make test-sdram  # SDRAM controller: bursts, refresh, retention
make test-soc    # same program through caches, arbiter and SDRAM
make test-isa    # official riscv-tests rv32ui on the bare core
make test-isa-soc # official riscv-tests rv32ui through the SoC
make test-boot   # boot the hello image over UART in simulation
make synth       # Yosys synth_ecp5 -> build/roco.json
make bitstream   # nextpnr-ecp5 + ecppack (if installed)
```

`make format` applies the repository Verible profile. The pre-commit
hook (`git config core.hooksPath .githooks`) checks formatting and
syntax of staged SystemVerilog.

## Verification status

Simulation (2026-11, Icarus Verilog 13):

- Directed smoke test: 20/20 checks.
- `riscv-tests` rv32ui: 41/41 on the bare core and 41/41 through the
  cached SoC. `ma_data` is excluded by design (see above).
- SDRAM controller: bursts, row/bank changes, refresh and data
  retention pass with zero timing-check violations.
- Hello program: PASS through the backdoor preload and through the
  UART bootloader, printing cache counters over UART.

Yosys `synth_ecp5 -top roco_top` (LFE5U-45F): 9009 LUT4, 4099
flip-flops, 8 DP16KD, 422 CCU2C, 1 EHXPLLL. This is synthesis only; the
design has not been placed, routed, constrained for I/O timing or run on
hardware. The SDRAM clock-to-pin delay, board skew and 48 MHz margin
remain bring-up checks, as noted in `pcb/docs/rev-a-design.md`.

## Known limitations and next steps

- The I-cache responds three cycles after a request and the front end
  only holds one instruction, so instruction throughput is well below
  one IPC even on hits. A pipelined cache lookup and a fetch queue are
  the obvious next step.
- The D-cache is blocking and has no write buffer.
- There is no cache coherence: `FENCE.I` flushes the D-cache and
  invalidates the I-cache; there is no DMA or second master.
- Boot is over UART only. Booting from the W25Q128 flash needs an SPI
  controller and a flash-resident loader.
- `mtvec` supports direct mode only and interrupts are not wired to the
  core.
- The core has no M extension, so software must avoid compiler-emitted
  multiply/divide.

## Layout

```text
rtl/
  roco_top.sv        board top: PLL, reset, buttons, pins
  roco_soc.sv        CPU + caches + memory + peripherals + bootloader
  core/              pipeline stages, decoder, ALU, CSR, regfile
  mem/               I/D caches, arbiter, SDRAM controller
  periph/            UART and UART image loader
  common/            shared RV32 control encodings
constraints/roco.lpf ECP5 pin locations and clock constraint
sim/                 testbenches and the SDRAM behavioural model
sw/                  crt0, linker script and the hello/cache demo
tests/               riscv-tests environment and linker script
scripts/             ISA runner, image converter, host bootloader
```
