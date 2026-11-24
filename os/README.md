# ROCO OS

A small freestanding RV32 operating system for the dual-hart SoC in `../soc`.
Machine-mode startup prepares memory and releases hart 1. Each hart enters
the same supervisor kernel, installs its own Sv32 page table, and runs a
separately linked user program. User `ecall` traps go directly to S mode;
they return to the calling program with `sret`.

## Build and run

```sh
cmake -S ../cc -B ../cc/build
cmake --build ../cc/build
make
make test
```

The target build uses `roco_cc`, `roco_as`, and `roco_ld` from `../cc`; no
RISC-V GCC or binutils are needed. Packaging uses Python 3. `make test`
uses the SoC's Verilator UART boot testbench and checks that both programs
exit successfully and print their own messages, in either order:

```text
hart 0 user hello
hart 1 user worker
```

The same test target boots a second image where a user program on hart 1
loads from an S-only kernel page. The test expects a load page fault
handled by the supervisor on hart 1, rather than a successful load.

`build/roco-os.elf` has kernel symbols, `build/roco-os.bin` is the flat
board image, and `build/roco-os.packet.hex` is the UART packet for simulation.
To upload on hardware with the SoC bootloader waiting for a packet:

```sh
python3 ../soc/scripts/boot.py --bin build/roco-os.bin --port /dev/tty.YOUR_DEVICE
```

This upload command requires `pyserial` and returns after the `K`
acknowledgment. User output follows on the same 115200-baud UART.

## User programs

The default programs are `user/hello.c` (hart 0) and `user/worker.c` (hart 1).
Replace either program's `int main(void)` and rebuild to run other code.
Each program is linked at `0x00400000`; each hart sees its own physical
backing pages at the same virtual addresses. The packer rejects programs
that do not fit the following layout:

| Virtual range | User permissions | Contents |
| --- | --- | --- |
| `0x00400000` to `0x00400fff` | Read, execute | `.text`, `.rodata` |
| `0x00401000` to `0x00401fff` | Read, write | `.data`, zeroed `.bss` |
| `0x00402000` to `0x00402fff` | Unmapped | Stack guard |
| `0x00403000` to `0x00404fff` | Read, write | 8 KiB stack |

The kernel, backing-page aliases, and MMIO are supervisor-only. The
kernel validates user buffer ranges before reading through its own aliases.
The UART lock prevents writes from different harts interleaving.

Physical allocations stay in the first MiB of SDRAM to avoid aliasing in
the SoC's simulation model. The kernel starts at `0x10000000`, the user
backing pages start at `0x10040000` and `0x10048000`, and the kernel
stacks grow down from `0x100ff000` and `0x100fd000`.

`user/syscall.h` declares wrappers for the syscall ABI: put the number in
`a7`, arguments in `a0` and `a1`, and issue `ecall`. Results come back in `a0`.

| Number | Call | Result |
| --- | --- | --- |
| 1 | `write(buf, len)` | Bytes written, or `-1` for an invalid nonempty buffer or a length over 256 |
| 2 | `exit(status)` | Never returns; returning from `main` does the same thing |
| 3 | `gethart()` | `0` or `1` |
| 4 | `yield()` | `0`; currently a no-op |

Unknown calls return `-1`. The system stops when both programs exit with
status zero, or immediately on a nonzero exit or an unhandled trap.
This is a static two-program system: no scheduler, timer preemption,
filesystem, or runtime executable loading.
