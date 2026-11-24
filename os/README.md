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

## Simulated console

```sh
make console
```

Wait for `roco> `, then try:

```text
run countdown &
run worker 0 &
hart
jobs
wait
exit
```

The shell runs in user mode on hart 0. Either hart can time-slice
`worker` and `countdown` in separate user address spaces. On hart 0 the
shell gets its own time slice and is the only task allowed to read UART
input. The timer slice is 20,000 `mtime` ticks; `yield()` can hand off
early. `run <worker|countdown> [0|1] &` returns immediately and defaults to
hart 1 when no hart is specified. There is one instance
slot for each bundled program; duplicate active launches are rejected.
`jobs` reports both slots and `wait` waits for all active jobs. A fresh
launch resets that program's writable data and stack. Both programs
are bundled at build time.

Job output uses the same UART and can appear next to the shell prompt.
Host terminal line editing works as usual. `exit` or Ctrl-D closes the
shell and waits for any running job before stopping the simulator.

You can also pipe commands from a script:

```sh
printf 'run countdown &\nhart\nwait\nexit\n' | make console
```

`make test` also checks the shell transcript over the simulated UART.

### Editor and scripts

`edit` opens a single RAM-only document (12 lines of up to 79 characters).
Type a line to append it. `.list` shows numbered lines, `.set N text`
replaces a line, `.del N` deletes one, `.clear` empties the document, and
`.quit` returns to the shell without discarding the document. Reset or
exit loses the document; there is no filesystem.

Try typing this at the console:

```text
edit
print result:
set 40
add 2
show
repeat 2 hello
.quit
script
```

`script` runs the document from the top. Blank lines and `#` comments
are ignored. `set` and `add` operate on a single decimal accumulator
(0 through 999999), `show` prints it, and `repeat N text` prints text up
to 20 times. An invalid statement stops execution and reports the line
number. Scripts run in the shell task; background jobs still get their
own time slices.

## Boot artifacts

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
| `0x00400000` to `0x00401fff` | Read, execute | `.text`, `.rodata` |
| `0x00402000` to `0x00402fff` | Read, write | `.data`, zeroed `.bss` |
| `0x00403000` to `0x00403fff` | Unmapped | Stack guard |
| `0x00404000` to `0x00405fff` | Read, write | 8 KiB stack |

The kernel, backing-page aliases, and MMIO are supervisor-only. The
kernel validates user buffer ranges before reading through its own aliases.
The UART lock prevents writes from different harts interleaving.

Physical allocations stay in the first MiB of SDRAM to avoid aliasing in
the SoC's simulation model. The kernel starts at `0x10000000`, the user
backing pages start at `0x10040000`, `0x10048000`, and `0x10050000`
(countdown in the console image), and the kernel
stacks grow down from `0x100ff000` and `0x100fd000`.

`user/syscall.h` declares wrappers for the syscall ABI: put the number in
`a7`, arguments in `a0` and `a1`, and issue `ecall`. Results come back in `a0`.

| Number | Call | Result |
| --- | --- | --- |
| 1 | `write(buf, len)` | Bytes written, or `-1` for an invalid nonempty buffer or a length over 256 |
| 2 | `exit(status)` | Never returns; returning from `main` does the same thing |
| 3 | `gethart()` | `0` or `1` |
| 4 | `yield()` | `0`; a console task gives up the rest of its time slice if another task is runnable |
| 5 | `readchar()` | Next UART byte for the hart 0 shell (or the default hart 0 program); `-1` if unavailable |
| 6 | `syscall(SYS_RUN_JOB, id, hart)` | Shell only: submits a job, returns `0`, `JOB_BUSY`, or `-1` |
| 7 | `syscall(SYS_JOB_STATUS, id, 0)` | Shell only: returns idle, `JOB_ACTIVE + hart`, or completion status |

Unknown calls return `-1`. In the default image the system stops when both
programs exit successfully, or immediately on a nonzero exit or an
unhandled trap. In the console image a nonzero job exit or a delegated
user-mode fault is reported as job status rather than stopping the shell.
The scheduler saves RV32 integer registers and the program counter; vector
jobs are not supported. There is no filesystem or runtime executable loading.
