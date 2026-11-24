# roco_os

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

Wait for `roco_os> `, then try:

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

## Filesystem

The kernel image embeds a small RAM filesystem built from
`rootfs/base.manifest` by `tools/mkfs.py`. At boot the kernel copies every
manifest entry into 512-byte blocks in a 192 KiB SDRAM arena; directories,
file data, and free space all live there until the next reset. There are 64
inodes and 384 blocks.

The shell works with paths the way you would expect:

```text
roco_os> ls /examples
roco_os> cat /readme.txt
roco_os> mkdir /home/user/work
roco_os> cd /home/user
roco_os> pwd
roco_os> edit /home/user/notes.txt
roco_os> df
```

`edit [path]` opens a file into the 12-line editor, or resumes the
current document with no path. `.save [path]` writes the document back,
`.clear` empties it, `.quit` leaves the editor without discarding it, and
`script` still runs the document as before.
`read` on a console descriptor never blocks the kernel: it returns what is
available, or `-2` when the input queue is empty.

User programs use these calls:

| Number | Call | Result |
| --- | --- | --- |
| 7 | `open(path, flags)` | File descriptor, or `-1` |
| 8 | `close(fd)` | `0`, or `-1` |
| 9 | `seek(fd, offset, whence)` | New offset, or `-1` |
| 10 | `stat(path, info)` | `0`, or `-1` |
| 11 | `fstat(fd, info)` | `0`, or `-1` |
| 12 | `unlink(path)` | `0`, or `-1` |
| 13 | `mkdir(path)` | `0`, or `-1` |
| 14 | `rmdir(path)` | `0`, or `-1` |
| 15 | `rename(from, to)` | `0`, or `-1` |
| 16 | `readdir(fd, index, name, cap)` | Entry type, `0` at the end, or `-1` |
| 17 | `fsinfo(info)` | `0`, or `-1` |
| 18 | `chdir(path)` | `0`, or `-1` |
| 19 | `getcwd(buffer, cap)` | `0`, or `-1` |
| 20 | `getpid()` | Process id |
| 21 | `getppid()` | Parent process id (`0`) |
| 22 | `exec(path)` | Replaces the program, or `-1` |
| 23 | `spawn(path, hart)` | Job slot (1 or 2), `JOB_BUSY`, or `-1` |

`open` flags are `O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_CREAT`, `O_TRUNC`,
and `O_APPEND`; `seek` origins are `SEEK_SET`, `SEEK_CUR`, and `SEEK_END`.
`stat` fills four words: type (`FS_FILE`, `FS_DIR`, `FS_DEV`), size in
bytes, inode number, and block count. `fsinfo` fills four words: total and
free blocks, then total and free inodes. Every process has its own
descriptors and working directory; descriptors 0, 1, and 2 start as
console input, console output, and console output.


## Programs and processes

User programs live in the filesystem, not in the kernel image. Each image
manifest lists them as `exe` entries: the default image ships
`/bin/hello` and `/bin/worker`, the probe image swaps in `/bin/probe`,
and the console image ships a shell plus `worker`, `countdown`, `primes`,
and `chain`. The kernel loads a program's text and data from its file into
the slot's backing RAM at boot and whenever the slot is reused.

The shell runs anything under `/bin`, either by its bare name or by path:

```text
roco_os> run primes &
roco_os> run /bin/chain &
```

`run` with `&` returns immediately and reports the job slot; without
`&` the job runs in the foreground and its console output is shown
instead of dropped. `jobs` and `wait` work as before, showing the spawned
program's name. At most two background
jobs fit; a third reports no free slot until one finishes. A job that
`exec()`s another path keeps its slot, files, and working directory but
starts the new program from its entry point with a fresh stack.

`/bin/primes` prints primes up to 100 and records them in
`/tmp/primes.txt`, since background jobs cannot write to the console.
`/bin/chain` writes `/tmp/chained.txt` and then execs `/bin/worker`.
`/bin/spin` yields forever until the shell kills it.

`sleep <ticks>` parks the calling task for at least that many `mtime`
ticks; `uptime` prints the low 32 bits of `mtime`. The shell keeps the
last eight commands: Up recalls older entries and Down moves back toward
a blank line. `sbrk` moves the
program break inside the 8 KiB heap, and the user runtime builds
`malloc`, `free`, and `calloc` on top of it; `/bin/alloc` exercises the
allocator and records `/tmp/alloc.ok`. `ps` lists every
process id with its state, and `kill <pid>` stops a job (or clears a
finished one) at any time:

```text
roco_os> run spin &
roco_os> ps
pid 1 shell: active on hart 0.
pid 2 spin: active on hart 1.
roco_os> kill 2
roco_os> jobs
No job yet.
```

## Crash reports

A trap the kernel cannot resume prints a self-contained report before the
hart halts: the mode, hart, process and cause, the faulting addresses, the
whole register file, and a backtrace. A user-mode fault in a job slot is
reported the same way and then retires that job, so the shell survives.

```text
*** roco_os panic: user-mode fault on hart 0, pid 1 (/bin/shell)
    cause 15 (store page fault)  epc 004013cc  tval 0040c000
 zero 00000000 ra 00401414 sp 0040efc0 gp 00408800
 ...
    user stack 0040efc0..00410000
      #0 004013cc  level3+0x2c
      #1 00401414  level2+0x24
      #2 00401458  level1+0x24
      #3 004014bc  main+0x44
```

Backtraces follow the frame records roco_cc emits (`[s0+12]` holds the
return address, `[s0+8]` the caller's `s0`). Names come from symbol tables
that `tools/mksyms.py` builds from the linker's `-Map` output: the kernel
is linked twice, once for the map, and every user program link writes
`build/user-<name>.map`. A corrupted frame chain falls back to listing
stack words that point into text.

## Boot artifacts

`build/roco_os.elf` has kernel symbols, `build/roco_os.bin` is the flat
board image, and `build/roco_os.packet.hex` is the UART packet for simulation.
To upload on hardware with the SoC bootloader waiting for a packet:

```sh
python3 ../soc/scripts/boot.py --bin build/roco_os.bin --port /dev/tty.YOUR_DEVICE
```

This upload command requires `pyserial` and returns after the `K`
acknowledgment. User output follows on the same 115200-baud UART.

## User programs

The default image runs `user/hello.c` (hart 0) and `user/worker.c`
(hart 1); the console image runs the `user/shell.c` shell on hart 0 with
`worker`, `countdown`, `primes`, and `chain` available under `/bin`.
Each program is linked at `0x00400000`; each hart sees its own physical
backing pages at the same virtual addresses. The filesystem packer rejects
programs that do not fit the following layout:

| Virtual range | User permissions | Contents |
| --- | --- | --- |
| `0x00400000` to `0x00407fff` | Read, execute | `.text`, `.rodata` (32 KiB) |
| `0x00408000` to `0x00409fff` | Read, write | `.data`, zeroed `.bss` (8 KiB) |
| `0x0040a000` to `0x0040bfff` | Read, write | 8 KiB heap |
| `0x0040c000` to `0x0040cfff` | Unmapped | Stack guard |
| `0x0040d000` to `0x0040ffff` | Read, write | 12 KiB stack |

The kernel, backing-page aliases, and MMIO are supervisor-only. The
kernel validates user buffer ranges before reading through its own aliases.
The UART is a shared console guarded by a spinlock; only the console owner
may write. Background jobs that need output must redirect it to a file, so
their lines never interrupt a shell prompt or a foreground command.

Physical allocations stay in the first MiB of SDRAM to avoid aliasing in
the SoC's simulation model. The kernel starts at `0x10000000`, each user
address space owns one 64 KiB backing slab starting at `0x10040000`,
`0x10050000`, and `0x10060000` (countdown in the console image), and the
kernel stacks grow down from `0x100ff000` and `0x100fd000`.

`user/syscall.h` declares wrappers for the syscall ABI: put the number in
`a7`, arguments in `a0` and `a1`, and issue `ecall`. Results come back in `a0`.

| Number | Call | Result |
| --- | --- | --- |
| 1 | `write(fd, buf, len)` | Bytes written, or `-1` for a bad descriptor or buffer |
| 2 | `read(fd, buf, len)` | Bytes read, `0` at end of file, `SYS_AGAIN` if no console input is ready |
| 3 | `exit(status)` | Never returns; returning from `main` does the same thing |
| 4 | `yield()` | `0`; a console task gives up the rest of its time slice if another task is runnable |
| 5 | `gethart()` | `0` or `1` |
| 6 | `readchar()` | Next UART byte for the hart 0 shell (or the default hart 0 program); `-1` if unavailable |
| 22 | `exec(path)` | Replaces the program, or `-1` (keeps running the old one) |
| 23 | `spawn(path, hart)` | Job slot, `JOB_BUSY`, or `-1` |
| 30 | `syscall(SYS_RUN_JOB, id, hart)` | Shell only: submits a job, returns `0`, `JOB_BUSY`, or `-1` |
| 31 | `syscall(SYS_JOB_STATUS, id, 0)` | Shell only: returns idle, `JOB_ACTIVE + hart`, or completion status |

The file calls are documented under Filesystem below. Unknown calls
return `-1`. In the default image the system stops when both programs
exit successfully, or immediately on a nonzero exit or an unhandled trap.
In the console image a nonzero job exit or a delegated user-mode fault is
reported as job status rather than stopping the shell. The scheduler saves
RV32 integer registers and the program counter; vector jobs are not
supported.
